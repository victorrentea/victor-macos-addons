import XCTest
@testable import VictorAddons

/// 🎥 Layout Zoom's geometry, on the rig it was designed against: a 1728×1117
/// Retina at the origin and a 1920×1080 DELL sitting on top of it, 89 pt to the
/// left — global top-left coordinates, so the DELL's y is negative.
final class ZoomMeetingLayoutPolicyTests: XCTestCase {

    private let retina = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let top = CGRect(x: -89, y: -1080, width: 1920, height: 1080)
    private let left = CGRect(x: -1920, y: 37, width: 1920, height: 1080)
    private let right = CGRect(x: 1728, y: 37, width: 1920, height: 1080)

    func testPicksTheDisplaySittingOnTopOfTheRetina() {
        XCTAssertEqual(ZoomMeetingLayoutPolicy.displayAbove(retina, among: [left, top, right]), top)
    }

    /// Side monitors touch the Retina too, just not on its top edge.
    func testNoDisplayAboveWhenOnlySideMonitors() {
        XCTAssertNil(ZoomMeetingLayoutPolicy.displayAbove(retina, among: [left, right]))
    }

    /// A display whose bottom edge is at the Retina's top but entirely off to
    /// the side is diagonal, not above.
    func testDiagonalDisplayIsNotAbove() {
        let diagonal = CGRect(x: 1728, y: -1080, width: 1920, height: 1080)
        XCTAssertNil(ZoomMeetingLayoutPolicy.displayAbove(retina, among: [diagonal]))
    }

    func testVideoLeftParticipantsOverChatRight() {
        let usable = CGRect(x: -89, y: -1055, width: 1920, height: 1055)   // menu bar taken out
        let f = ZoomMeetingLayoutPolicy.frames(in: usable)

        XCTAssertEqual(f.meeting, CGRect(x: -89, y: -1055, width: 1560, height: 1055))
        XCTAssertEqual(f.participants.minX, f.meeting.maxX)
        XCTAssertEqual(f.participants.width, 360)
        XCTAssertEqual(f.chat.width, 360)
        // The column is split with no gap and no overlap, down to the bottom edge.
        XCTAssertEqual(f.participants.minY, usable.minY)
        XCTAssertEqual(f.participants.maxY, f.chat.minY)
        XCTAssertEqual(f.chat.maxY, usable.maxY)
        XCTAssertEqual(f.chat.maxX, usable.maxX)
        XCTAssertEqual(f.chat.height, 380)
    }

    /// On a narrow display the column must not eat the video.
    func testColumnCappedAtThirtyPercentOfANarrowDisplay() {
        let f = ZoomMeetingLayoutPolicy.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 700))
        XCTAssertEqual(f.participants.width, 300)
        XCTAssertEqual(f.meeting.width, 700)
    }

    /// Zoom's View-menu items carry the selector name with its trailing colon;
    /// missing that is why a closed panel was never opened.
    func testMenuIdentifierMatchesTheSelectorSpelling() {
        XCTAssertTrue(ZoomMeetingLayoutPolicy.menuIdentifier("onChat:", is: "onChat"))
        XCTAssertTrue(ZoomMeetingLayoutPolicy.menuIdentifier("onChat", is: "onChat"))
        XCTAssertFalse(ZoomMeetingLayoutPolicy.menuIdentifier("onChatX:", is: "onChat"))
        XCTAssertFalse(ZoomMeetingLayoutPolicy.menuIdentifier(nil, is: "onChat"))
    }
}
