import XCTest
import SQLite3
@testable import VictorAddons

/// Exercises the real query against a *fabricated* copy of macOS's notification
/// store, built here with the same schema `usernoted` uses. The live store can't
/// be used as a fixture — it needs Full Disk Access and, more importantly, it
/// only contains a Soduto low-battery record when the phone actually is flat.
final class PhoneBatteryMonitorTests: XCTestCase {

    private var folder: String!

    override func setUpWithError() throws {
        folder = NSTemporaryDirectory() + "phone-battery-fixture-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: folder)
    }

    // MARK: - Fixture

    /// `record.data` is a binary plist whose `req` sub-dictionary is the
    /// notification; `delivered_date` is Apple-epoch seconds (2001-01-01).
    private func makeStore(_ rows: [(app: String, identifier: String?, title: String, body: String, deliveredAt: Date)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder + "/db", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
            CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB,
                                 request_date REAL, request_last_date REAL, delivered_date REAL,
                                 presented Bool, style INTEGER, snooze_fire_date REAL);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        var appIds: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if appIds[row.app] == nil {
                let appId = appIds.count + 1
                appIds[row.app] = appId
                XCTAssertEqual(sqlite3_exec(db, "INSERT INTO app VALUES (\(appId), '\(row.app)', NULL);", nil, nil, nil), SQLITE_OK)
            }
            var req: [String: Any] = ["titl": row.title, "body": row.body]
            if let identifier = row.identifier { req["iden"] = identifier }
            let blob = try PropertyListSerialization.data(
                fromPropertyList: ["app": row.app, "req": req], format: .binary, options: 0)

            var stmt: OpaquePointer?
            let sql = "INSERT INTO record (rec_id, app_id, data, request_last_date, delivered_date) VALUES (?,?,?,?,?)"
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_int(stmt, 1, Int32(index + 1))
            sqlite3_bind_int(stmt, 2, Int32(appIds[row.app]!))
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(blob.count), nil) }
            sqlite3_bind_double(stmt, 4, row.deliveredAt.timeIntervalSinceReferenceDate)
            sqlite3_bind_double(stmt, 5, row.deliveredAt.timeIntervalSinceReferenceDate)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    private func read() throws -> PhoneBatteryPolicy.Reading? {
        try PhoneBatteryMonitor(dbFolder: folder).readLowBatteryNotification()
    }

    // MARK: - Tests

    func testReadsSodutoLowBatteryNotification() throws {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try makeStore([(app: "com.soduto.soduto",
                        identifier: "com.soduto.services.battery.abc",
                        title: "Low Battery | Galaxy S24 Ultra",
                        body: "13% of battery remaining",
                        deliveredAt: at)])
        let reading = try XCTUnwrap(read())
        XCTAssertEqual(reading.chargePct, 13)
        XCTAssertEqual(reading.updatedAt.timeIntervalSinceReferenceDate, 800_000_000, accuracy: 0.001)
    }

    func testIgnoresOtherAppsNotifications() throws {
        // A calendar invite that happens to mention a percentage must not warn.
        try makeStore([(app: "com.apple.ical", identifier: "cal.1",
                        title: "Low Battery", body: "13% of battery remaining",
                        deliveredAt: Date())])
        XCTAssertNil(try read())
    }

    func testIgnoresSodutosNonBatteryNotifications() throws {
        try makeStore([(app: "com.soduto.soduto", identifier: "com.soduto.services.share.abc",
                        title: "File received", body: "photo.jpg (13% of transfer)",
                        deliveredAt: Date())])
        XCTAssertNil(try read())
    }

    func testPicksTheMostRecentlyRefreshedRecord() throws {
        // Soduto re-delivers with the new percentage as the phone keeps draining;
        // whichever row the database hands back first, the freshest one wins.
        let old = Date(timeIntervalSinceReferenceDate: 800_000_000)
        try makeStore([
            (app: "com.soduto.soduto", identifier: "com.soduto.services.battery.abc",
             title: "Low Battery | Phone", body: "14% of battery remaining", deliveredAt: old.addingTimeInterval(600)),
            (app: "com.soduto.soduto", identifier: "com.soduto.services.battery.abc",
             title: "Low Battery | Phone", body: "9% of battery remaining", deliveredAt: old.addingTimeInterval(1800)),
            (app: "com.soduto.soduto", identifier: "com.soduto.services.battery.abc",
             title: "Low Battery | Phone", body: "11% of battery remaining", deliveredAt: old),
        ])
        XCTAssertEqual(try read()?.chargePct, 9)
    }

    func testEmptyStoreReadsAsNoWarning() throws {
        try makeStore([])
        XCTAssertNil(try read())
    }

    func testMissingStoreIsReportedRatherThanCrashing() {
        let monitor = PhoneBatteryMonitor(dbFolder: folder + "/nope")
        XCTAssertThrowsError(try monitor.readLowBatteryNotification())
    }

    func testWarningClearsWhenSodutoRemovesTheNotification() throws {
        // Plugging the phone in makes Soduto withdraw the notification, which
        // deletes the record — the tablet stops blinking because there is
        // nothing left to read, not because we track charging ourselves.
        try makeStore([(app: "com.soduto.soduto", identifier: "com.soduto.services.battery.abc",
                        title: "Low Battery | Phone", body: "8% of battery remaining",
                        deliveredAt: Date())])
        XCTAssertNotNil(try read())
        try FileManager.default.removeItem(atPath: folder + "/db")
        try makeStore([])
        XCTAssertNil(try read())
    }
}
