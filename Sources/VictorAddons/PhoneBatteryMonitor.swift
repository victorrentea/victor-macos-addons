import Foundation
import SQLite3

/// Watches Notification Center for Soduto's "Low Battery | <phone>" notification
/// and publishes it as a reading the `/ping` response can carry to the tablet.
///
/// See `PhoneBatteryPolicy` for *why* the notification is the source. Mechanically
/// this reads macOS's own notification store, `~/Library/Group Containers/
/// group.com.apple.usernoted/db2/db` — a WAL-mode SQLite database. Two
/// consequences drive the implementation:
///
/// 1. **It is copied before it is read.** A read-only SQLite connection to a WAL
///    database still needs to write the `-shm` index, and pointing a read-write
///    connection at the live file would put us in usernoted's way. So `db`,
///    `db-wal` and `db-shm` are copied to a scratch folder per poll (~2.5 MB,
///    every 30 s) and the copy is queried and deleted. Skipping the `-wal` would
///    be cheaper and wrong: the most recent notifications are exactly the ones
///    still sitting in it.
/// 2. **It needs Full Disk Access**, and this app does not have it by default.
///    A denial is indistinguishable from "the phone is fine" unless we say so,
///    hence `onPermissionDenied` — fired once, so the user is told rather than
///    left with a feature that silently never triggers.
final class PhoneBatteryMonitor {

    /// How often the store is re-read. Soduto refreshes the notification on every
    /// battery packet, so a 30 s cadence is far finer than the phone reports.
    static let pollInterval: TimeInterval = 30

    private let dbFolder: String
    private let queue = DispatchQueue(label: "ro.victorrentea.phone-battery", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Guards everything read from the HTTP server / main thread.
    private let lock = NSLock()
    private var _reading: PhoneBatteryPolicy.Reading?
    private var _lastPollAt: Date?
    private var _lastError: String?
    private var permissionDeniedReported = false
    private var _simulated: PhoneBatteryPolicy.Reading?
    private var _simulatedUntil = Date.distantPast

    /// Fired on the main thread whenever the warning appears, changes percentage
    /// or clears.
    var onChange: ((PhoneBatteryPolicy.Reading?) -> Void)?

    /// Fired on the main thread at most once per app run, when the notification
    /// store cannot be read for lack of Full Disk Access.
    var onPermissionDenied: (() -> Void)?

    init(dbFolder: String = (("~/Library/Group Containers/group.com.apple.usernoted/db2") as NSString).expandingTildeInPath) {
        self.dbFolder = dbFolder
    }

    var reading: PhoneBatteryPolicy.Reading? {
        lock.lock(); defer { lock.unlock() }
        if let simulated = _simulated, Date() < _simulatedUntil { return simulated }
        return _reading
    }

    /// Preview hook (`/test/phone-battery/simulate/<pct>`): pretend the phone is
    /// at `chargePct` for the next `duration`. Waiting for a genuinely flat phone
    /// is a terrible way to check that the tablet blinks — and this is a warning
    /// you want to have proven *before* the day it matters. The simulation shadows
    /// the real reading rather than replacing it, so a real warning arriving
    /// mid-preview is not lost; it simply resumes when the preview lapses.
    func simulate(chargePct: Int, duration: TimeInterval = 120) {
        lock.lock()
        _simulated = PhoneBatteryPolicy.Reading(chargePct: chargePct, updatedAt: Date())
        _simulatedUntil = Date().addingTimeInterval(duration)
        lock.unlock()
        overlayInfo("📱 phone battery: simulating \(chargePct)% for \(Int(duration))s")
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// JSON snapshot for `GET /test/phone-battery` — read-only.
    var diagnosticsJSON: String {
        let reading = self.reading   // simulation-aware, same value /ping sends
        lock.lock()
        let polledAt = _lastPollAt
        let error = _lastError
        let simulating = _simulated != nil && Date() < _simulatedUntil
        lock.unlock()
        let now = Date()
        let warn = PhoneBatteryPolicy.shouldWarn(reading, now: now)
        var fields: [String] = [
            "\"warning\":\(warn)",
            "\"charge_pct\":\(reading?.chargePct ?? -1)",
            "\"stale_after_s\":\(Int(PhoneBatteryPolicy.staleAfter))",
            "\"poll_interval_s\":\(Int(Self.pollInterval))",
            "\"simulated\":\(simulating)",
        ]
        if let reading {
            fields.append("\"age_s\":\(Int(now.timeIntervalSince(reading.updatedAt)))")
        }
        if let polledAt {
            fields.append("\"last_poll_age_s\":\(Int(now.timeIntervalSince(polledAt)))")
        }
        // Errors are our own strings (sqlite / Foundation messages), but escape
        // anyway rather than trust a message we didn't write.
        if let error, let escaped = try? JSONSerialization.data(withJSONObject: [error]),
           let arr = String(data: escaped, encoding: .utf8) {
            fields.append("\"last_error\":\(arr.dropFirst().dropLast())")
        }
        return "{\(fields.joined(separator: ","))}"
    }

    /// Poll now (also the `/test` path). Runs on `queue`.
    func pollNow() { queue.async { [weak self] in self?.poll() } }

    // MARK: - Polling

    private func poll() {
        var newReading: PhoneBatteryPolicy.Reading?
        var error: String?
        var denied = false
        do {
            newReading = try readLowBatteryNotification()
        } catch let denial as PermissionError {
            error = denial.message
            denied = true
        } catch let failure {
            // Not fatal: usernoted rewrites its files, so a copy can land
            // mid-checkpoint. The next tick sees a consistent snapshot, and the
            // last good reading is kept rather than flapping the tablet dark.
            let message = (failure as NSError).localizedDescription
            return finish(reading: nil, error: message, denied: false, keepPreviousReading: true)
        }
        finish(reading: newReading, error: error, denied: denied, keepPreviousReading: denied)
    }

    private func finish(reading: PhoneBatteryPolicy.Reading?,
                        error: String?,
                        denied: Bool,
                        keepPreviousReading: Bool) {
        lock.lock()
        let previous = _reading
        if !keepPreviousReading { _reading = reading }
        _lastPollAt = Date()
        _lastError = error
        let shouldReportDenial = denied && !permissionDeniedReported
        if shouldReportDenial { permissionDeniedReported = true }
        let current = _reading
        lock.unlock()

        if shouldReportDenial {
            overlayInfo("📱 phone battery: \(error ?? "notification store unreadable")")
            DispatchQueue.main.async { [weak self] in self?.onPermissionDenied?() }
        }
        if current != previous {
            DispatchQueue.main.async { [weak self] in self?.onChange?(current) }
        }
    }

    private struct PermissionError: Error { let message: String }

    /// Copy the notification store aside, query Soduto's records, and return the
    /// most recently refreshed low-battery one. Internal (not private) so tests
    /// can point a monitor at a fabricated store and exercise the real query.
    func readLowBatteryNotification() throws -> PhoneBatteryPolicy.Reading? {
        let fm = FileManager.default
        let scratch = NSTemporaryDirectory() + "victor-phone-battery-\(UUID().uuidString)"
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }

        do {
            try fm.copyItem(atPath: dbFolder + "/db", toPath: scratch + "/db")
        } catch let e as NSError {
            // Any failure to copy this file is a permission problem in practice:
            // the path is fixed, the destination is our own fresh temp folder,
            // and TCC is the only thing that stands between us and it. Foundation
            // reports the denial as a *write* error naming the destination
            // ("“db” couldn't be copied because you don't have permission to
            // access “victor-phone-battery-…”"), so classifying on the error code
            // alone silently mislabels the one case that needs telling.
            throw PermissionError(message: "cannot read Notification Center's store — grant Victor Addons Full Disk Access in System Settings → Privacy & Security (\(e.localizedDescription))")
        }
        // Sidecars are optional: a freshly checkpointed database has no -wal.
        for sidecar in ["db-wal", "db-shm"] {
            try? fm.copyItem(atPath: dbFolder + "/" + sidecar, toPath: scratch + "/" + sidecar)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(scratch + "/db", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open failed"
            sqlite3_close(db)
            throw PermissionError(message: "notification store unreadable: \(message)")
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT r.data, r.delivered_date, r.request_last_date
            FROM record r JOIN app a ON r.app_id = a.app_id
            WHERE lower(a.identifier) = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PermissionError(message: "notification store query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, PhoneBatteryPolicy.sodutoAppId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var best: PhoneBatteryPolicy.Reading?
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let length = Int(sqlite3_column_bytes(stmt, 0))
            guard length > 0 else { continue }
            let payload = Data(bytes: blob, count: length)
            guard let request = Self.requestDictionary(from: payload) else { continue }
            let identifier = request["iden"] as? String
            let title = request["titl"] as? String
            guard PhoneBatteryPolicy.isLowBatteryNotification(identifier: identifier, title: title) else { continue }
            guard let pct = PhoneBatteryPolicy.chargePercent(fromBody: request["body"] as? String) else { continue }
            // Both columns are Core Data / Apple epoch seconds (2001-01-01).
            let stamp = max(sqlite3_column_double(stmt, 1), sqlite3_column_double(stmt, 2))
            let updatedAt = Date(timeIntervalSinceReferenceDate: stamp)
            if best == nil || updatedAt > best!.updatedAt {
                best = PhoneBatteryPolicy.Reading(chargePct: pct, updatedAt: updatedAt)
            }
        }
        return best
    }

    /// The record blob is a binary plist whose `req` sub-dictionary holds the
    /// notification proper (`titl` / `body` / `iden`).
    static func requestDictionary(from data: Data) -> [String: Any]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else { return nil }
        return root["req"] as? [String: Any]
    }
}
