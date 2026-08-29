import Foundation

/// Keeps the tablet's **LaunchBreak app** in sync with its sources: whenever the
/// tablet is plugged into the Mac over USB, this rebuilds and reinstalls it — but
/// **only when the tablet is actually carrying an older build**.
///
/// The tablet is a device Victor deploys to by hand between workshops, which
/// means the Android app is regularly a few commits behind the Mac add-on it
/// talks to (new sounds, new tiles, a changed protocol) and nothing says so
/// until something misbehaves in front of a room. Plugging the cable in is the
/// one moment the Mac can fix that on its own, so that is the trigger.
///
/// **What "behind" means is a stamp, not a version number.** `versionName` in
/// `build.gradle.kts` never changes, and a rebuilt APK hashes differently every
/// time (zip timestamps), so neither can answer the question. Instead the Mac
/// computes a stamp from the *source tree* (`AndroidDeployPolicy.SourceState`:
/// the HEAD commit, plus the newest edit when the tree is dirty) and, after a
/// successful install, pushes it to a marker file on the tablet. The next plug-in
/// compares the two: equal → nothing happens at all (no build, no reinstall, no
/// notification, no app restart); different → deploy. The marker lives on
/// `/sdcard`, not in the app's data directory, so it survives the very reinstall
/// it describes.
///
/// **The gradle build is the expensive part**, so it runs only *after* the stamp
/// says a deploy is needed — the common case (cable plugged in to charge, sources
/// unchanged) costs one `adb shell cat`.
///
/// Every outcome — success or failure — is reported as a standard macOS
/// notification via `onNotify`, because a deploy that silently failed is worse
/// than one that never ran: the tablet then keeps running the old build while
/// Victor believes it is current.
///
/// Caveat, deliberately accepted: a deploy **restarts the tablet app**. If the
/// cable goes in mid-workshop *and* the sources moved since the last deploy, the
/// LaunchBreak UI blinks and comes back. Gating that on "not during a session"
/// would mean the deploy never happens on the day it matters.
final class AndroidAppDeployer {
    static let packageName = "ro.victorrentea.helloworld"
    static let launchActivity = "ro.victorrentea.helloworld/.MainActivity"
    /// Marker file recording which source stamp the tablet is running.
    static let deviceStampPath = "/sdcard/victor-launchbreak-deploy.stamp"

    private static let buildTimeout: TimeInterval = 15 * 60
    private static let adbTimeout: TimeInterval = 5 * 60
    /// A stamp that just failed to deploy isn't retried for this long: a broken
    /// build fails the same way every time, and re-plugging the cable shouldn't
    /// mean re-running a 10-minute gradle build to be told so again.
    private static let failureCooldown: TimeInterval = 10 * 60
    /// How long a freshly plugged cable is given to settle before we deploy over it.
    private static let arrivalSettleDelay: TimeInterval = 8
    /// `adb install` attempts. A USB link that has just come up can drop one
    /// mid-transfer, and re-plugging the cable to recover from that is exactly
    /// the manual step this feature exists to remove.
    private static let installAttempts = 3
    private static let installRetryDelay: TimeInterval = 4

    /// Posts the standard macOS notification (title, body). Wired to
    /// `AppDelegate.postAndroidDeployNotification`; nil in tests.
    var onNotify: ((String, String) -> Void)?

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.android-deploy", qos: .utility)
    /// All of the below live only on `queue`, so reads/writes are sequential.
    private var inFlight = false
    private var lastFailedStamp: String?
    private var lastFailureAt: Date?
    private var lastOutcome = "never run"
    private var lastRunAt: Date?

    // MARK: - Entry points

    /// The USB plug-in edge (`UsbTunnelKeeper.onTunnelArmed`): adb has just
    /// answered, so the tablet is not only attached but talking.
    ///
    /// It answers *early*, though — the first deploy this ever ran started 3s
    /// after the edge and its `adb install` died mid-transfer while the tunnel
    /// re-armed underneath it (a freshly plugged cable renegotiates for a few
    /// seconds). So the deploy waits for the connection to settle first; a
    /// tablet that has been sitting plugged in loses nothing by the delay.
    func tabletConnected() {
        queue.asyncAfter(deadline: .now() + Self.arrivalSettleDelay) { [weak self] in
            self?.deploy(force: false)
        }
    }

    /// `GET /test/android-deploy` — deploy now regardless of the stamp and the
    /// failure cooldown, and return a JSON snapshot of the last known state.
    /// The deploy itself runs in the background (a gradle build far outlasts an
    /// HTTP response), so the snapshot describes the *previous* run.
    func forceDeployJSON() -> String {
        let snapshot = queue.sync { statusJSON(pending: true) }
        queue.async { [weak self] in self?.deploy(force: true) }
        return snapshot
    }

    /// JSON snapshot, read on `queue`.
    private func statusJSON(pending: Bool) -> String {
        let repo = Self.repoDir()
        let source = repo.flatMap { Self.readSourceState(repo: $0) }
        var parts: [String] = []
        parts.append("\"repo\":\(Self.jsonString(repo ?? ""))")
        parts.append("\"source_stamp\":\(Self.jsonString(source?.stamp ?? ""))")
        parts.append("\"source_commit\":\(Self.jsonString(source?.commit ?? ""))")
        parts.append("\"source_dirty\":\(source?.dirty ?? false)")
        parts.append("\"adb\":\(Self.jsonString(UsbTunnelKeeper.adbPath ?? ""))")
        let tablet = Self.tabletSerial()
        let devices = Self.attachedDevices().map { d -> String in
            let serial = Self.jsonString(d.serial)
            let model = Self.jsonString(d.model)
            let chars = Self.jsonString(d.characteristics)
            return "{\"serial\":\(serial),\"model\":\(model),\"characteristics\":\(chars)}"
        }
        parts.append("\"devices\":[\(devices.joined(separator: ","))]")
        switch tablet {
        case .tablet(let d):
            let serial = d.serial
            parts.append("\"tablet_serial\":\(Self.jsonString(serial))")
            parts.append("\"tablet_connected\":true")
            parts.append("\"device_stamp\":\(Self.jsonString(Self.readDeviceStamp(serial: serial) ?? ""))")
        case .none(let why):
            parts.append("\"tablet_serial\":\"\"")
            parts.append("\"tablet_connected\":false")
            parts.append("\"tablet_error\":\(Self.jsonString(why))")
            parts.append("\"device_stamp\":\"\"")
        }
        parts.append("\"last_outcome\":\(Self.jsonString(lastOutcome))")
        parts.append("\"last_run_at\":\(Self.jsonString(lastRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""))")
        parts.append("\"in_flight\":\(inFlight || pending)")
        return "{\(parts.joined(separator: ","))}"
    }

    // MARK: - The deploy itself (always on `queue`)

    private func deploy(force: Bool) {
        guard !inFlight else {
            NSLog("[AndroidDeploy] already running — skipping")
            return
        }
        guard let adb = UsbTunnelKeeper.adbPath else {
            NSLog("[AndroidDeploy] adb not found — auto-deploy disabled")
            return
        }
        guard let repo = Self.repoDir() else {
            NSLog("[AndroidDeploy] victor-vibe-board sources not found — auto-deploy disabled")
            return
        }
        // Which device — never "whichever one adb happens to have". Plugging the
        // *phone* in used to install the tablet's app onto the phone.
        let serial: String
        switch Self.tabletSerial() {
        case .tablet(let d): serial = d.serial
        case .none(let why):
            lastOutcome = "no tablet: \(why)"
            NSLog("[AndroidDeploy] \(why) — skipping")
            // Silent on the passive path: the phone goes on the same cable all
            // day and a notification each time would be noise. When someone
            // *asked* for a deploy, they get told why nothing happened.
            if force { notify(AndroidDeployPolicy.failureTitle, "no tablet attached — \(why)") }
            return
        }

        let source = Self.readSourceState(repo: repo)
        if !force {
            let onDevice = Self.readDeviceStamp(serial: serial)
            guard AndroidDeployPolicy.shouldDeploy(source: source, deviceStamp: onDevice) else {
                lastOutcome = "up to date (\(source.stamp))"
                NSLog("[AndroidDeploy] tablet is up to date (\(source.stamp)) — nothing to do")
                return
            }
            // A stamp that failed a moment ago will fail again the same way.
            if lastFailedStamp == source.stamp,
               let failedAt = lastFailureAt,
               Date().timeIntervalSince(failedAt) < Self.failureCooldown {
                NSLog("[AndroidDeploy] \(source.stamp) failed recently — waiting out the cooldown")
                return
            }
            NSLog("[AndroidDeploy] tablet has \(onDevice ?? "no marker"), sources are \(source.stamp) — deploying")
        }

        inFlight = true
        lastRunAt = Date()
        defer { inFlight = false }

        // 1. Build. Incremental, so an unchanged tree that lost its marker is cheap.
        let build = Self.run(
            "\(repo)/gradlew",
            ["assembleDebug"],
            cwd: repo,
            env: Self.buildEnvironment(),
            timeout: Self.buildTimeout
        )
        guard build.status == 0 else {
            return fail(step: "gradle assembleDebug", detail: Self.lastLines(build.output), source: source)
        }
        let apk = "\(repo)/app/build/outputs/apk/debug/app-debug.apk"
        guard FileManager.default.fileExists(atPath: apk) else {
            return fail(step: "APK missing", detail: apk, source: source)
        }

        // 2. Install over the existing app (keeps its data and granted permissions).
        var installOut = ""
        var installed = false
        for attempt in 1...Self.installAttempts {
            let install = Self.run(adb, ["-s", serial, "install", "-r", apk], timeout: Self.adbTimeout)
            installOut = install.output
            if install.status == 0, !installOut.contains("Failure"), !installOut.contains("Error") {
                installed = true
                break
            }
            NSLog("[AndroidDeploy] install attempt \(attempt)/\(Self.installAttempts) failed: \(Self.lastLines(installOut))")
            guard attempt < Self.installAttempts else { break }
            Thread.sleep(forTimeInterval: Self.installRetryDelay)
            guard Self.attachedDevices().contains(where: { $0.serial == serial }) else { break }   // cable pulled
        }
        guard installed else {
            return fail(step: "adb install", detail: Self.lastLines(installOut), source: source)
        }

        // 3. Best-effort post-install housekeeping. None of it is worth failing a
        //    good install over: the grant + safe-volume reset keep Android's
        //    headphone-safety dialog from covering the soundboard mid-workshop
        //    (see the android repo's CLAUDE.md), and are no-ops when already set.
        Self.run(adb, ["-s", serial, "shell", "pm", "grant", Self.packageName, "android.permission.WRITE_SECURE_SETTINGS"], timeout: 60)
        Self.run(adb, ["-s", serial, "shell", "settings", "put", "global", "audio_safe_volume_state", "0"], timeout: 60)

        // 4. Restart the app: `install -r` leaves the old process running the old
        //    code, so without this the deploy isn't visible until Victor kills it.
        Self.run(adb, ["-s", serial, "shell", "am", "force-stop", Self.packageName], timeout: 60)
        Self.run(adb, ["-s", serial, "shell", "am", "start", "-n", Self.launchActivity], timeout: 60)

        // 5. Only now write the marker — it must never claim an install that
        //    didn't happen, or the tablet stays behind forever.
        if !Self.writeDeviceStamp(source.stamp, serial: serial) {
            NSLog("[AndroidDeploy] WARNING: could not write the marker to the tablet — the next plug-in will deploy again")
        }

        lastFailedStamp = nil
        lastFailureAt = nil
        lastOutcome = "deployed \(source.stamp)"
        NSLog("[AndroidDeploy] deployed \(source.stamp) to the tablet")
        notify(AndroidDeployPolicy.successTitle, AndroidDeployPolicy.successBody(source: source))
    }

    private func fail(step: String, detail: String, source: AndroidDeployPolicy.SourceState) {
        lastFailedStamp = source.stamp
        lastFailureAt = Date()
        lastOutcome = "failed: \(step)"
        NSLog("[AndroidDeploy] FAILED at \(step): \(detail)")
        notify(
            AndroidDeployPolicy.failureTitle,
            AndroidDeployPolicy.failureBody(step: step, detail: detail, source: source)
        )
    }

    private func notify(_ title: String, _ body: String) {
        guard let onNotify else { return }
        DispatchQueue.main.async { onNotify(title, body) }
    }

    // MARK: - Reading the two sides

    /// The Android sources: an explicit override, then the canonical checkout
    /// next to this repo, then the workspace path.
    static func repoDir() -> String? {
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["VICTOR_ANDROID_ROOT"], !env.isEmpty {
            candidates.append(env)
        }
        if let root = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"], !root.isEmpty {
            candidates.append("\(root)/../victor-vibe-board")
        }
        candidates.append("\(home)/workspace/victor-vibe-board")
        for c in candidates {
            let resolved = URL(fileURLWithPath: c).standardized.path
            if FileManager.default.fileExists(atPath: "\(resolved)/gradlew") { return resolved }
        }
        return nil
    }

    static func readSourceState(repo: String) -> AndroidDeployPolicy.SourceState {
        let commit = git(repo, ["rev-parse", "--short", "HEAD"]) ?? ""
        let dirty = !(git(repo, ["status", "--porcelain"]) ?? "").isEmpty
        let changedAt: Date
        if dirty {
            changedAt = newestSourceMtime(repo: repo) ?? Date()
        } else if let epoch = git(repo, ["log", "-1", "--format=%ct"]).flatMap({ TimeInterval($0) }) {
            changedAt = Date(timeIntervalSince1970: epoch)
        } else {
            changedAt = newestSourceMtime(repo: repo) ?? Date()
        }
        return AndroidDeployPolicy.SourceState(commit: commit, dirty: dirty, changedAt: changedAt)
    }

    /// Newest modification time across the sources that can change the APK —
    /// i.e. "when was this build made". `build/` is skipped: it is the *output*,
    /// and it is touched by the very build whose input we are timing.
    private static func newestSourceMtime(repo: String) -> Date? {
        let fm = FileManager.default
        var newest: Date?
        var roots = ["\(repo)/app/src"]
        roots += [
            "\(repo)/app/build.gradle.kts",
            "\(repo)/build.gradle.kts",
            "\(repo)/settings.gradle.kts",
            "\(repo)/gradle/libs.versions.toml",
        ]
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(atPath: root) else { continue }
                for case let rel as String in e {
                    if rel.hasPrefix("build/") || rel.contains("/build/") { continue }
                    if let d = mtime("\(root)/\(rel)"), d > (newest ?? .distantPast) { newest = d }
                }
            } else if let d = mtime(root), d > (newest ?? .distantPast) {
                newest = d
            }
        }
        return newest
    }

    private static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Every **authorized** device adb currently lists, with enough of its
    /// identity to tell the tablet from the phone. A cable that is only
    /// charging, or a device showing the "allow USB debugging?" dialog, reads
    /// `unauthorized` / `offline` and is left out.
    static func attachedDevices() -> [AndroidDeployPolicy.Device] {
        guard let adb = UsbTunnelKeeper.adbPath else { return [] }
        let out = run(adb, ["devices", "-l"], timeout: 30).output
        return out.split(separator: "\n").dropFirst().compactMap { line -> AndroidDeployPolicy.Device? in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            let serial = fields[0]
            let model = fields.first { $0.hasPrefix("model:") }?
                .replacingOccurrences(of: "model:", with: "") ?? ""
            // Both getprops in one shell, because this runs per device on every
            // poll and each spawn is a round trip over USB or WiFi.
            let props = run(adb, ["-s", serial, "shell",
                                  "getprop ro.build.characteristics; getprop ro.serialno"], timeout: 30)
                .output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let chars = props.first ?? ""
            let hw = props.count > 1 ? props[1] : ""
            return AndroidDeployPolicy.Device(serial: serial, model: model,
                                              characteristics: chars, hardwareSerial: hw)
        }
    }

    /// The tablet's adb serial, or why we could not name one. An explicit
    /// `VICTOR_TABLET_SERIAL` wins over the sniffing, for a device that refuses
    /// to identify itself.
    static func tabletSerial() -> AndroidDeployPolicy.TabletPick {
        if let env = ProcessInfo.processInfo.environment["VICTOR_TABLET_SERIAL"], !env.isEmpty {
            return .tablet(AndroidDeployPolicy.Device(serial: env, model: "", characteristics: "tablet",
                                                      hardwareSerial: ""))
        }
        return AndroidDeployPolicy.pickTablet(attachedDevices())
    }

    static func readDeviceStamp(serial: String) -> String? {
        guard let adb = UsbTunnelKeeper.adbPath else { return nil }
        let r = run(adb, ["-s", serial, "shell", "cat", deviceStampPath], timeout: 60)
        guard r.status == 0 else { return nil }
        let s = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // A missing file answers on stdout/stderr, not with a non-zero status.
        if s.isEmpty || s.contains("No such file") || s.contains("Permission denied") { return nil }
        return s
    }

    /// Written via `adb push` rather than `adb shell echo >`, so the stamp never
    /// has to survive a round trip through the device's shell quoting.
    private static func writeDeviceStamp(_ stamp: String, serial: String) -> Bool {
        guard let adb = UsbTunnelKeeper.adbPath else { return false }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("victor-launchbreak-deploy.stamp")
        do { try stamp.write(to: tmp, atomically: true, encoding: .utf8) } catch { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return run(adb, ["-s", serial, "push", tmp.path, deviceStampPath], timeout: 120).status == 0
    }

    // MARK: - Process plumbing

    /// The environment a gradle build needs when we are the parent — a
    /// LaunchAgent-started app inherits almost nothing, so `JAVA_HOME` in
    /// particular has to be resolved rather than assumed.
    private static func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let java = javaHome() { env["JAVA_HOME"] = java }
        let sdk = "\(NSHomeDirectory())/Library/Android/sdk"
        if FileManager.default.fileExists(atPath: sdk) {
            env["ANDROID_HOME"] = sdk
            env["ANDROID_SDK_ROOT"] = sdk
        }
        return env
    }

    /// AGP 8.7 runs on JDK 17–21 and *fails* on the newer JDKs also installed on
    /// this Mac, so the candidates are ordered by "what Victor's shell builds
    /// with" first (sdkman's current, a 21), and only then asked of the system.
    private static func javaHome() -> String? {
        let home = NSHomeDirectory()
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["VICTOR_ANDROID_JAVA_HOME"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append("\(home)/.sdkman/candidates/java/current")
        for version in ["21", "17"] {
            let r = run("/usr/libexec/java_home", ["-v", version], timeout: 30)
            let path = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.status == 0, !path.isEmpty { candidates.append(path) }
        }
        if let env = ProcessInfo.processInfo.environment["JAVA_HOME"], !env.isEmpty {
            candidates.append(env)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: "\($0)/bin/java") }
    }

    private static func git(_ repo: String, _ args: [String]) -> String? {
        let r = run("/usr/bin/git", ["-C", repo] + args, timeout: 60)
        guard r.status == 0 else { return nil }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Last few lines of a failed command's output — enough to name the cause in
    /// a notification body without pasting a gradle log into it.
    private static func lastLines(_ output: String, count: Int = 3) -> String {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(count).joined(separator: " / ")
    }

    @discardableResult
    private static func run(
        _ path: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval
    ) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "could not run \(path): \(error)") }

        // Read the pipe on another thread: a gradle build easily outgrows the
        // 64 KB pipe buffer, and a full buffer would deadlock `waitUntilExit`.
        // The reader is *joined* before we return — sleeping "long enough"
        // instead truncated the tail, which is exactly where the reason a
        // command failed is written (an `adb install` failure once reported only
        // "failed to install …:", with the cause cut off).
        var data = Data()
        let lock = NSLock()
        let drained = DispatchSemaphore(value: 0)
        let reader = DispatchQueue(label: "android-deploy-reader", qos: .utility)
        reader.async {
            let chunk = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); data.append(chunk); lock.unlock()
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 1.0)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            _ = drained.wait(timeout: .now() + 2)
            lock.lock(); let partial = String(data: data, encoding: .utf8) ?? ""; lock.unlock()
            return (-2, partial + "\ntimed out after \(Int(timeout))s")
        }
        p.waitUntilExit()
        _ = drained.wait(timeout: .now() + 5)
        lock.lock(); let out = String(data: data, encoding: .utf8) ?? ""; lock.unlock()
        return (p.terminationStatus, out)
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}
