import Foundation

/// `~/Downloads/<yyyy-MM-dd_HH-mm-ss>.png`, `-2`, `-3`… — the one naming rule
/// for every image this app files there: the menu's 📥 row and the ⬇️ button
/// on a ⌘⇧V image (2026-09-22). Two copies of it would be two ways for two
/// files saved in the same second to disagree about which one is `-2`.
enum DownloadsFolder {
    static func freshURL(ext: String = "png", now: Date = Date()) -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = stamp.string(from: now)
        var url = downloads.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent("\(stem)-\(n).\(ext)")
            n += 1
        }
        return url
    }
}
