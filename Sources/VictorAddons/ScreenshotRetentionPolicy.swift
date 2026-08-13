import Foundation

/// Decides which of the kept ⌃P screenshots are no longer worth the disk.
///
/// They live in `~/Library/Caches` precisely so that emptying the Trash or
/// running any "free up space" tool reclaims them — but a folder nobody looks
/// at must also bound itself, because the day it matters is the day the disk is
/// full mid-workshop. Two independent ceilings, because either one alone leaks:
/// **age** (a shot from three weeks ago belongs to a summary that was written
/// long ago) and **total size** (a day of heavy ⌃P can outweigh a fortnight of
/// light use).
///
/// **The newest shot is never deleted, ever.** Not when it is older than the age
/// limit, not when it alone exceeds the size cap. This is the guard against a
/// wrong clock — a machine that comes back from sleep with a bad date, a file
/// stamped in the future — deleting the capture that was taken one second ago,
/// which is the one the user is about to paste.
enum ScreenshotRetentionPolicy {
    struct Item: Equatable {
        let name: String
        let modified: Date
        let bytes: Int
    }

    /// Long enough for a wrap-up run days after a multi-day session, short
    /// enough that the folder never becomes an archive.
    static let maxAge: TimeInterval = 14 * 24 * 3600
    /// Backstop, not the usual bound — at ~400 KB a shot this is thousands of
    /// them. It exists so one runaway day cannot fill the disk.
    static let maxBytes: Int = 2 * 1024 * 1024 * 1024

    /// Names to delete, newest-first order preserved for the caller's log.
    static func toDelete(_ items: [Item],
                         now: Date,
                         maxAge: TimeInterval = maxAge,
                         maxBytes: Int = maxBytes) -> [String] {
        guard !items.isEmpty else { return [] }
        // Newest first. Ties broken by name so the result is deterministic.
        let sorted = items.sorted {
            $0.modified == $1.modified ? $0.name > $1.name : $0.modified > $1.modified
        }

        var doomed: [String] = []
        var kept = 0
        var total = 0
        for item in sorted {
            if kept == 0 {                       // the newest survives unconditionally
                kept += 1
                total += item.bytes
                continue
            }
            let tooOld = now.timeIntervalSince(item.modified) > maxAge
            let tooBig = total + item.bytes > maxBytes
            if tooOld || tooBig {
                doomed.append(item.name)
            } else {
                kept += 1
                total += item.bytes
            }
        }
        return doomed
    }
}
