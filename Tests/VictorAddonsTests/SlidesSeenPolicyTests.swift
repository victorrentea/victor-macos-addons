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
}
