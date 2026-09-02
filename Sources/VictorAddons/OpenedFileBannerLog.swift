import Foundation

/// Remembers which files have already flashed in the bottom-left banner, so the
/// *same* file opening again stays silent.
///
/// The editors' side only skips a file when it repeats **consecutively** (see
/// `docs/activity-monitors.md`), which is no help for the way a file is actually
/// re-opened: A, then B, then back to A — and A flashes a second time. The
/// banner is worth a glance the first time a file appears in a session and is
/// pure distraction after that, so the memory has to span the whole day, not
/// just the previous event.
///
/// Persisted in `UserDefaults` (a plist on disk) so an app restart — routine
/// here, `build-app.sh` restarts it several times a day — doesn't hand back
/// every announcement that was already made this morning.
enum OpenedFileBannerLog {
    /// How long a file stays "already announced". Longer than a training day,
    /// so a file opened at 9:00 never flashes again at 16:00; short enough that
    /// tomorrow's session starts with a clean slate.
    static let repeatAfter: TimeInterval = 20 * 3600
    /// Bound on the stored log. Far above a day of editing, and pruning keeps
    /// the newest entries — the ones that would actually be re-opened.
    static let maxEntries = 500

    private static let defaultsKey = "OpenedFileBannerLog.v1"

    /// Pure decision, plus the log to store afterwards. `seen` maps a file path
    /// to the `timeIntervalSinceReferenceDate` of its last banner.
    ///
    /// A stamp in the *future* (a Mac back from sleep with a bad clock) counts
    /// as expired rather than as a permanent mute: one banner, and the entry is
    /// rewritten with a sane `now`.
    static func decide(seen: [String: Double],
                       path: String,
                       now: Double,
                       repeatAfter: TimeInterval = repeatAfter,
                       maxEntries: Int = maxEntries) -> (announce: Bool, seen: [String: Double]) {
        let key = (path as NSString).standardizingPath
        guard !key.isEmpty else { return (false, seen) }

        let last = seen[key]
        let announce = last.map { now - $0 >= repeatAfter || $0 > now } ?? true

        var updated = seen
        updated[key] = now
        // Drop anything past the horizon first — it can never mute again — and
        // only then trim by count, oldest going first.
        updated = updated.filter { now - $0.value < repeatAfter || $0.value > now }
        if updated.count > maxEntries {
            let keep = updated.sorted { $0.value > $1.value }.prefix(maxEntries)
            updated = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return (announce, updated)
    }

    /// `true` the first time this file is seen (and again once `repeatAfter`
    /// has passed); records the visit either way. Called from the HTTP
    /// server's queue, which `UserDefaults` handles fine on its own.
    static func shouldAnnounce(path: String, now: Date = Date()) -> Bool {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        let (announce, updated) = decide(seen: stored, path: path,
                                         now: now.timeIntervalSinceReferenceDate)
        UserDefaults.standard.set(updated, forKey: defaultsKey)
        return announce
    }

    /// Forget everything — the escape hatch for "show me these again".
    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
