import Foundation

/// The pure half of the tablet's USB auto-deploy (`AndroidAppDeployer`): what
/// counts as "the tablet is behind the sources", and the exact wording of the
/// notification that reports it. Kept free of processes and files so both can be
/// unit-tested without a tablet, a git repo or a gradle build.
enum AndroidDeployPolicy {

    /// What the Mac's copy of the Android sources currently *is*: the commit it
    /// sits on, whether there is uncommitted work on top of it, and when that
    /// state was last touched — the commit's own date when the tree is clean,
    /// the newest edited source file when it isn't.
    struct SourceState: Equatable {
        let commit: String        // short HEAD hash; empty when git can't be read
        let dirty: Bool
        let changedAt: Date

        /// The value compared against the marker the tablet carries. A clean
        /// tree is identified by its **commit alone**, so plugging the cable in
        /// ten times after a pull that changed nothing deploys nothing.
        /// Uncommitted work has no commit of its own to be named by, so it
        /// carries the newest edit's timestamp instead: every save produces a
        /// new stamp, and the next plug-in redeploys it.
        var stamp: String {
            let base = commit.isEmpty ? "nogit" : commit
            return dirty ? "\(base)+local-\(Int(changedAt.timeIntervalSince1970))" : base
        }
    }

    /// One Android device as `adb devices -l` and one `getprop` describe it.
    struct Device: Equatable {
        let serial: String
        /// The `model:` field from `adb devices -l` (`TB350FU`, `SM_S928B`, …).
        let model: String
        /// `ro.build.characteristics` — `tablet` on the Lenovo, `phone` on the S24.
        let characteristics: String
    }

    /// Which of the attached devices is **the tablet**, or why none of them is.
    ///
    /// This exists because the deploy used to address "the adb device", singular,
    /// and adb has no such notion — it just uses the only one attached. So the
    /// morning Victor plugged the *phone* in, the tablet's LaunchBreak APK was
    /// built and installed onto the phone, the app was force-stopped and
    /// restarted there, and the marker was written to the phone's `/sdcard`. It
    /// looked like a successful deploy in every log line.
    ///
    /// The test is a **positive** one — a device has to look like a tablet to be
    /// deployed to — because the failure mode of guessing wrong in the other
    /// direction is installing on a device Victor did not mean to touch, and it
    /// is silent. `ro.build.characteristics` is the device's own answer;
    /// `tabletModels` is a belt-and-braces fallback for a tablet that does not
    /// declare itself. Ambiguity (two candidates) refuses rather than picks.
    static let tabletModels = ["TB350"]

    /// Either the tablet, or the reason there isn't one to deploy to. Not a
    /// `Result`: "the phone is on the cable" is an ordinary, expected answer,
    /// not an error to be thrown around.
    enum TabletPick: Equatable {
        case tablet(Device)
        case none(String)
    }

    static func pickTablet(_ devices: [Device]) -> TabletPick {
        guard !devices.isEmpty else { return .none("no adb device attached") }
        let candidates = devices.filter { isTablet($0) }
        if candidates.count == 1 { return .tablet(candidates[0]) }
        let seen = devices.map { "\($0.model)/\($0.characteristics)" }.joined(separator: ", ")
        if candidates.isEmpty {
            return .none("no tablet among the attached devices (\(seen))")
        }
        return .none("more than one device looks like a tablet (\(seen)) — set VICTOR_TABLET_SERIAL")
    }

    static func isTablet(_ d: Device) -> Bool {
        if d.characteristics.lowercased().split(separator: ",").contains("tablet") { return true }
        let model = d.model.uppercased()
        return tabletModels.contains { model.contains($0) }
    }

    /// The tablet is behind whenever its marker doesn't match the source stamp.
    /// **A missing marker deploys**: it means either we have never installed
    /// this app from here or the marker was wiped, and in both cases what is on
    /// the tablet is unknown — installing once to establish a known baseline is
    /// cheaper than assuming it is current and being wrong all session.
    static func shouldDeploy(source: SourceState, deviceStamp: String?) -> Bool {
        let onDevice = (deviceStamp ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !onDevice.isEmpty else { return true }
        return onDevice != source.stamp
    }

    /// `4 Aug 2026, 19:41` — a fixed `en_US_POSIX` format so the wording reads
    /// the same whatever the Mac's locale is (and is assertable in a test).
    static func describe(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }

    static let successTitle = "Android app updated to version"
    static let failureTitle = "Android app update FAILED"

    /// The body under the title: the date/time of the build being installed
    /// first — that is what answers "is this the change I just made?" — then the
    /// commit it came from, marked `+local` when uncommitted work was included.
    static func successBody(source: SourceState, timeZone: TimeZone = .current) -> String {
        let when = describe(source.changedAt, timeZone: timeZone)
        if !source.commit.isEmpty {
            return "\(when) · \(source.commit)\(source.dirty ? "+local" : "")"
        }
        return source.dirty ? "\(when) · local changes" : when
    }

    /// A failure names the step that broke (build / install / …) so the log is
    /// worth opening, and still carries the build's date — the notification is
    /// otherwise indistinguishable from the previous attempt's.
    static func failureBody(step: String, detail: String, source: SourceState, timeZone: TimeZone = .current) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = trimmed.isEmpty ? step : "\(step): \(trimmed)"
        return "\(head) — \(describe(source.changedAt, timeZone: timeZone))"
    }
}
