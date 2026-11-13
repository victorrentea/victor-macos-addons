import Foundation

/// Keeps the **phone app** (`victor-phone-addons`, on the S24 Ultra) in sync with its
/// sources the same way `AndroidAppDeployer` keeps the tablet: the first time the phone
/// is plugged into the Mac after its sources moved, it is rebuilt and reinstalled.
///
/// Asked for on 8 Nov 2026: the phone app is deployed by hand with `deploy.sh`, so a
/// change made on the Mac sat unused until someone remembered to run it. The cable going
/// in is the one moment the Mac can do it unasked.
///
/// **Same stamp, different marker.** "Behind" is decided exactly as for the tablet
/// (`AndroidDeployPolicy.SourceState`: HEAD, plus the newest edit when the tree is dirty),
/// compared with `/sdcard/victor-phone-addons-deploy.stamp`, written only after a deploy
/// succeeded. Unchanged sources cost one `adb shell cat` per plug, nothing else.
///
/// **The deploy itself is the project's own `deploy.sh`**, not a copy of it here: that
/// script also re-grants half a dozen permissions, re-enables two accessibility services,
/// pushes the clipboard key and keeps the app out of hibernation — every one of them a
/// lesson recorded in that repo — and verifies the beacon came back. It gets the serial
/// via `PHONE_SERIAL`, so it installs on the device recognised here and nowhere else.
///
/// **USB only** (`AndroidDeployPolicy.pickPhone`). The phone is on wireless adb all day;
/// deploying over it would restart the beacon and the clipboard at a moment nobody chose.
///
/// The trigger is `UsbTunnelKeeper.onUsbAttach` — the raw IOKit edge, since the phone
/// never arms the tablet's tunnel. It fires for the tablet too; that costs one
/// `adb devices -l` and ends silently.
final class PhoneAppDeployer {
    static let deviceStampPath = "/sdcard/victor-phone-addons-deploy.stamp"

    private static let deployTimeout: TimeInterval = 15 * 60
    private static let failureCooldown: TimeInterval = 10 * 60
    /// A freshly enumerated cable renegotiates for a few seconds (see `AndroidAppDeployer`).
    private static let arrivalSettleDelay: TimeInterval = 8

    var onNotify: ((String, String) -> Void)?

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.phone-deploy", qos: .utility)
    private var inFlight = false
    private var lastFailedStamp: String?
    private var lastFailureAt: Date?
    private var lastOutcome = "never run"
    private var lastRunAt: Date?

    /// The USB plug-in edge.
    func usbAttached() {
        queue.asyncAfter(deadline: .now() + Self.arrivalSettleDelay) { [weak self] in
            self?.deploy(force: false)
        }
    }

    /// `GET /test/phone-deploy` — **every call deploys** (build, reinstall, restart the
    /// phone's service). The JSON describes the *previous* run; it is not a status endpoint.
    func forceDeployJSON() -> String {
        let snapshot = queue.sync { statusJSON() }
        queue.async { [weak self] in self?.deploy(force: true) }
        return snapshot
    }

    static func pinnedSerial() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".victor-phone-serial")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func statusJSON() -> String {
        let j = AndroidAppDeployer.jsonString
        let repo = Self.repoDir()
        let source = repo.map { AndroidAppDeployer.readSourceState(repo: $0) }
        let phone = AndroidDeployPolicy.pickPhone(AndroidAppDeployer.attachedDevices())
        let onDevice = phone.flatMap { AndroidAppDeployer.readDeviceStamp(serial: $0.serial, path: Self.deviceStampPath) }
        let parts = [
            "\"repo\":\(j(repo ?? ""))",
            "\"source_stamp\":\(j(source?.stamp ?? ""))",
            "\"phone_serial\":\(j(phone?.serial ?? ""))",
            "\"device_stamp\":\(j(onDevice ?? ""))",
            "\"last_outcome\":\(j(lastOutcome))",
            "\"last_run_at\":\(j(lastRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""))",
            "\"in_flight\":true",
        ]
        return "{\(parts.joined(separator: ","))}"
    }

    // MARK: - On `queue`

    private func deploy(force: Bool) {
        guard !inFlight else { return }
        guard let adb = UsbTunnelKeeper.adbPath else { return }
        guard let repo = Self.repoDir() else {
            NSLog("[PhoneDeploy] victor-phone-addons sources not found — auto-deploy disabled")
            return
        }
        guard let phone = AndroidDeployPolicy.pickPhone(AndroidAppDeployer.attachedDevices()) else {
            lastOutcome = "no phone on USB"
            if force { notify(AndroidDeployPolicy.phoneFailureTitle, "no phone on the USB cable") }
            return
        }
        let serial = phone.serial
        // Only the phone this Mac knows (`~/.victor-phone-serial`), not any S24 Ultra on the
        // cable: the deploy hands it the clipboard key and the relay token (security review,
        // 13 Nov 2026). No file = by model, as before.
        if let pinned = Self.pinnedSerial(), pinned != serial {
            lastOutcome = "not Victor's phone (\(serial))"
            NSLog("[PhoneDeploy] \(serial) is not the pinned phone — not deploying")
            return
        }
        let source = AndroidAppDeployer.readSourceState(repo: repo)
        // Automatically, only committed code: a half-written edit from any session used to go
        // onto the phone, with its accessibility and SMS rights, at the next plug-in.
        if !force, source.dirty {
            lastOutcome = "uncommitted changes — not deployed automatically (\(source.stamp))"
            NSLog("[PhoneDeploy] victor-phone-addons has uncommitted changes — skipping the automatic deploy")
            return
        }
        if !force {
            let onDevice = AndroidAppDeployer.readDeviceStamp(serial: serial, path: Self.deviceStampPath)
            guard AndroidDeployPolicy.shouldDeploy(source: source, deviceStamp: onDevice) else {
                lastOutcome = "up to date (\(source.stamp))"
                NSLog("[PhoneDeploy] phone is up to date (\(source.stamp))")
                return
            }
            if lastFailedStamp == source.stamp, let at = lastFailureAt,
               Date().timeIntervalSince(at) < Self.failureCooldown {
                NSLog("[PhoneDeploy] \(source.stamp) failed recently — waiting out the cooldown")
                return
            }
            NSLog("[PhoneDeploy] phone has \(onDevice ?? "no marker"), sources are \(source.stamp) — deploying")
        }

        inFlight = true
        lastRunAt = Date()
        defer { inFlight = false }

        var env = AndroidAppDeployer.buildEnvironment()
        env["PHONE_SERIAL"] = serial
        env["WAIT_SECONDS"] = "30"
        // A LaunchAgent's PATH has no adb; deploy.sh calls it by name.
        let adbDir = (adb as NSString).deletingLastPathComponent
        env["PATH"] = "\(adbDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let r = AndroidAppDeployer.run("/bin/bash", ["\(repo)/deploy.sh"], cwd: repo, env: env,
                                        timeout: Self.deployTimeout)
        guard r.status == 0 else {
            lastFailedStamp = source.stamp
            lastFailureAt = Date()
            lastOutcome = "failed: deploy.sh exit \(r.status)"
            let detail = AndroidAppDeployer.lastLines(r.output)
            NSLog("[PhoneDeploy] FAILED (exit \(r.status)): \(detail)")
            notify(AndroidDeployPolicy.phoneFailureTitle,
                   AndroidDeployPolicy.failureBody(step: "deploy.sh exit \(r.status)", detail: detail, source: source))
            return
        }
        if !AndroidAppDeployer.writeDeviceStamp(source.stamp, serial: serial, path: Self.deviceStampPath) {
            NSLog("[PhoneDeploy] WARNING: could not write the marker — the next plug-in will deploy again")
        }
        lastFailedStamp = nil
        lastFailureAt = nil
        lastOutcome = "deployed \(source.stamp)"
        NSLog("[PhoneDeploy] deployed \(source.stamp) to the phone")
        notify(AndroidDeployPolicy.phoneSuccessTitle, AndroidDeployPolicy.successBody(source: source))
    }

    private func notify(_ title: String, _ body: String) {
        guard let onNotify else { return }
        DispatchQueue.main.async { onNotify(title, body) }
    }

    static func repoDir() -> String? {
        var candidates: [String] = []
        if let root = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"], !root.isEmpty {
            candidates.append("\(root)/../victor-phone-addons")
        }
        candidates.append("\(NSHomeDirectory())/workspace/victor-phone-addons")
        return candidates
            .map { URL(fileURLWithPath: $0).standardized.path }
            .first { FileManager.default.fileExists(atPath: "\($0)/deploy.sh") }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
