import Foundation
import SQLite3

/// Resolves whether a local file is shared on Google Drive by reading the
/// Drive for Desktop sync metadata directly (no API/OAuth). Lookup is by
/// POSIX inode against `mirror_sqlite.db`'s `mirror_item` table, which Drive
/// populates with a `shared` boolean for every mirrored file.
///
/// Files not present in that DB are treated as "not shared" — they're not
/// tracked by Drive on this machine.
final class GoogleDriveShareCache {
    private var cache: [String: Bool] = [:]
    private let cacheQueue = DispatchQueue(label: "ro.victorrentea.gdrive-share-cache")
    private let dbPath: String?

    init() {
        self.dbPath = Self.locateMirrorDB()
        if let p = dbPath {
            overlayInfo("GDrive share cache: using \(p)")
        } else {
            overlayInfo("GDrive share cache: DriveFS mirror DB not found — treating all files as not shared")
        }
    }

    /// Returns true iff the file is marked `shared` in DriveFS's local mirror.
    /// Blocks on SQLite for cache misses; safe to call from any thread.
    func isShared(path: String) -> Bool {
        if let cached = cacheQueue.sync(execute: { cache[path] }) {
            return cached
        }
        let result = evaluate(path: path)
        cacheQueue.sync { cache[path] = result }
        return result
    }

    private func evaluate(path: String) -> Bool {
        guard let dbPath = self.dbPath else { return false }

        var statBuf = stat()
        guard stat(path, &statBuf) == 0 else { return false }
        let inode = Int64(statBuf.st_ino)

        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }

        // file: URI with mode=ro lets us read even while Drive holds it.
        let uri = "file:\(dbPath)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else { return false }

        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        let sql = "SELECT shared FROM mirror_item WHERE inode = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_int64(stmt, 1, inode)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) != 0
        }
        return false
    }

    private static func locateMirrorDB() -> String? {
        let driveFSDir = NSString("~/Library/Application Support/Google/DriveFS").expandingTildeInPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: driveFSDir) else {
            return nil
        }
        for entry in entries where !entry.isEmpty && entry.allSatisfy({ $0.isNumber }) {
            let candidate = "\(driveFSDir)/\(entry)/mirror_sqlite.db"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
