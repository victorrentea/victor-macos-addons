import XCTest
@testable import VictorAddons

final class SlidesSeenPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func s(_ sec: Double, id: Int?, front: Bool = true, path: String = "/d/a.pptx", slide: Int = 1) -> PowerPointSample {
        PowerPointSample(at: t0.addingTimeInterval(sec), deck: "a.pptx", path: path, slide: slide,
                         slideID: id, presenting: true, frontmost: front, saved: true)
    }

    private func run(_ samples: [PowerPointSample]) -> [SlidesSeenPolicy.Action] {
        var p = SlidesSeenPolicy()
        return samples.flatMap { p.consume($0) }
    }

    func testSlideShownLessThanSevenSecondsIsIgnored() {
        XCTAssertEqual(run([s(0, id: 256), s(2, id: 256), s(4, id: 256), s(6, id: 257)]), [])
    }

    func testQualifiesOnceAtSevenSecondsAndClosesWhenTheSlideChanges() {
        let a = run([s(0, id: 256), s(4, id: 256), s(8, id: 256), s(10, id: 256), s(12, id: 300)])
        XCTAssertEqual(a.count, 2)
        guard case .qualified(let q) = a[0], case .closed(let c) = a[1] else { return XCTFail("\(a)") }
        XCTAssertEqual(q.slideID, 256)
        XCTAssertEqual(c.end.timeIntervalSince(c.start), 10)
    }

    func testPowerPointLeavingTheFrontClosesTheSpan() {
        let a = run([s(0, id: 256), s(8, id: 256), s(10, id: 256, front: false)])
        XCTAssertEqual(a.count, 2)
        guard case .closed(let c) = a[1] else { return XCTFail("\(a)") }
        XCTAssertEqual(c.end.timeIntervalSince(c.start), 8)
    }

    func testTimeInTheBackgroundDoesNotCount() {
        XCTAssertEqual(run([s(0, id: 256, front: false), s(9, id: 256, front: false), s(10, id: 256)]), [])
    }

    func testSameIdAtAnotherPositionIsTheSameSlide() {
        // A slide inserted above it moves it from position 4 to 5: still one span.
        let a = run([s(0, id: 256, slide: 4), s(4, id: 256, slide: 5), s(8, id: 256, slide: 5), s(9, id: 1)])
        XCTAssertEqual(a.count, 2)
    }

    func testSameIdInAnotherDeckIsAnotherSlide() {
        let a = run([s(0, id: 256), s(4, id: 256, path: "/d/b.pptx"), s(8, id: 256, path: "/d/b.pptx")])
        XCTAssertEqual(a, [])
    }

    func testGoneClosesAQualifiedSpan() {
        let a = run([s(0, id: 256), s(7, id: 256), .gone(at: t0.addingTimeInterval(9))])
        XCTAssertEqual(a.count, 2)
    }

    // MARK: - 🔎 Spotlight re-import

    private func p(_ path: String?, saved: Bool) -> PowerPointSample {
        PowerPointSample(at: t0, deck: "a.pptx", path: path, slide: 1, slideID: 256,
                         presenting: false, frontmost: true, saved: saved)
    }

    func testADeckIsHandedToSpotlightWhenFirstSeenAndAfterEachSave() {
        var r = SpotlightReindexPolicy()
        XCTAssertEqual(r.consume(p("/d/a.pptx", saved: true)), "/d/a.pptx")   // first sight
        XCTAssertNil(r.consume(p("/d/a.pptx", saved: true)))                  // nothing changed
        XCTAssertNil(r.consume(p("/d/a.pptx", saved: false)))                 // being edited
        XCTAssertNil(r.consume(p("/d/a.pptx", saved: false)))
        XCTAssertEqual(r.consume(p("/d/a.pptx", saved: true)), "/d/a.pptx")   // just saved
        XCTAssertNil(r.consume(p("/d/a.pptx", saved: true)))
    }

    func testADeckFirstSeenUnsavedWaitsForItsSave() {
        var r = SpotlightReindexPolicy()
        XCTAssertNil(r.consume(p("/d/b.pptx", saved: false)))
        XCTAssertEqual(r.consume(p("/d/b.pptx", saved: true)), "/d/b.pptx")
    }

    func testDecksAreTrackedSeparatelyAndAPathlessDeckIsIgnored() {
        var r = SpotlightReindexPolicy()
        XCTAssertNil(r.consume(p(nil, saved: true)))
        XCTAssertNil(r.consume(p("/d/a.pptx", saved: false)))
        XCTAssertEqual(r.consume(p("/d/b.pptx", saved: true)), "/d/b.pptx")
        XCTAssertEqual(r.consume(p("/d/a.pptx", saved: true)), "/d/a.pptx")
    }

    func testTheDeckCopiesMoveOnceIntoAFolderSpotlightSkips() throws {
        XCTAssertTrue(SlidesSeenRecorder.decksDirName.hasSuffix(".noindex"))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slides-seen-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("decks"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("decks/abc.pptx"))
        SlidesSeenRecorder.migrateDecksDir(root: root)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("decks").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("decks.noindex/abc.pptx").path))
        SlidesSeenRecorder.migrateDecksDir(root: root)   // second run: nothing left to move
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("decks.noindex/abc.pptx").path))
    }

    func testDeckCopiesLiveOneDaySinceLastShownAndDayLogsThirty() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slides-seen-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let decks = root.appendingPathComponent(SlidesSeenRecorder.decksDirName)
        let log = root.appendingPathComponent("log")
        for d in [decks, log] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func file(_ dir: URL, _ name: String, hoursAgo: Double) throws -> URL {
            let u = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: u)
            SlidesSeenRecorder.markShown(u, at: now.addingTimeInterval(-hoursAgo * 3600))
            return u
        }
        let shownToday = try file(decks, "today.pptx", hoursAgo: 20)
        let shownTwoDaysAgo = try file(decks, "old.pptx", hoursAgo: 49)
        // An untouched deck: the copy carries a months-old mtime until it is marked as shown.
        let oldDeckShownNow = try file(decks, "untouched.pptx", hoursAgo: 24 * 90)
        SlidesSeenRecorder.markShown(oldDeckShownNow, at: now)
        let logLastWeek = try file(log, "week.jsonl", hoursAgo: 24 * 7)
        let logLastQuarter = try file(log, "quarter.jsonl", hoursAgo: 24 * 31)

        SlidesSeenRecorder.prune(root: root, now: now)

        XCTAssertTrue(fm.fileExists(atPath: shownToday.path))
        XCTAssertFalse(fm.fileExists(atPath: shownTwoDaysAgo.path))
        XCTAssertTrue(fm.fileExists(atPath: oldDeckShownNow.path))
        XCTAssertTrue(fm.fileExists(atPath: logLastWeek.path))
        XCTAssertFalse(fm.fileExists(atPath: logLastQuarter.path))
    }
}
