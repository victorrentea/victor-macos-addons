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
