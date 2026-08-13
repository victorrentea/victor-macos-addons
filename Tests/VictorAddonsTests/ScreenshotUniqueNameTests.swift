import XCTest
@testable import VictorAddons

final class ScreenshotUniqueNameTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screenshot-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Two captures can land inside one second — a ⌃P tap followed straight away
    /// by another, or a crop right after one. When both got the same name the
    /// second overwrote the first, and a shot taken seconds ago was simply gone.
    func testSecondCaptureInTheSameSecondGetsItsOwnName() throws {
        let now = Date()
        let first = ScreenshotManager.uniqueURL(for: now, in: dir)
        FileManager.default.createFile(atPath: first.path, contents: Data())

        let second = ScreenshotManager.uniqueURL(for: now, in: dir)
        XCTAssertNotEqual(second, first)
        FileManager.default.createFile(atPath: second.path, contents: Data())

        let third = ScreenshotManager.uniqueURL(for: now, in: dir)
        XCTAssertNotEqual(third, first)
        XCTAssertNotEqual(third, second)
    }

    /// The summarizer skills read the date and time straight off the filename,
    /// so the suffix may only ever be appended after the timestamp.
    func testTimestampPrefixSurvivesTheSuffix() {
        let now = Date()
        let stamped = ScreenshotManager.filename(for: now).dropLast(4)
        let first = ScreenshotManager.uniqueURL(for: now, in: dir)
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = ScreenshotManager.uniqueURL(for: now, in: dir)

        XCTAssertEqual(first.lastPathComponent, stamped + ".jpg")
        XCTAssertEqual(second.lastPathComponent, stamped + "-2.jpg")
    }

    func testFreeSecondKeepsThePlainName() {
        let url = ScreenshotManager.uniqueURL(for: Date(), in: dir)
        XCTAssertEqual(url.lastPathComponent, ScreenshotManager.filename(for: Date()))
    }
}
