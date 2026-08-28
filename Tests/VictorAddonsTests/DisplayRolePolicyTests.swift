import XCTest
@testable import VictorAddons

/// Role resolution for the projector workflow. The cases that matter are the
/// ones where a display has **no name**: mirrored displays collapse into a
/// single `NSScreen`, so a mirror slave is anonymous — and guessing what it is
/// produced the 2026-08-27 room-TV incident (the ASUS was taken for the
/// projector and left mirroring, Retina stayed main).
final class DisplayRolePolicyTests: XCTestCase {

    private let isKnown: (String) -> Bool = { $0.uppercased().contains("DELL S2421HN") }

    private func retina(_ id: UInt32 = 1) -> DisplayFacts {
        DisplayFacts(id: id, isBuiltin: true, name: "Built-in Retina Display", isMirrored: false)
    }
    private func external(_ id: UInt32, _ name: String?, mirrored: Bool = false) -> DisplayFacts {
        DisplayFacts(id: id, isBuiltin: false, name: name, isMirrored: mirrored)
    }

    func testVenueWithNamedAsusAndProjector() {
        let r = DisplayRolePolicy.resolve(
            [retina(), external(2, "ASUS MB166C"), external(5, "SAMSUNG TV")], isKnown: isKnown)
        XCTAssertEqual(r.retina, 1)
        XCTAssertEqual(r.asus, 2)
        XCTAssertEqual(r.projector, 5)
        XCTAssertFalse(r.needsUnmirrorProbe)
    }

    /// The regression: the room TV's hot-plug swept both externals into the
    /// mirror set, so neither had a name. The old code called the first one
    /// "the projector" and dropped the second — mirroring the ASUS.
    func testAnonymousMirrorSlavesAreNeverGuessed() {
        let r = DisplayRolePolicy.resolve(
            [retina(), external(2, nil, mirrored: true), external(5, nil, mirrored: true)], isKnown: isKnown)
        XCTAssertNil(r.projector, "an anonymous mirror slave must not be taken for the projector")
        XCTAssertNil(r.asus)
        XCTAssertEqual(r.unidentified, [2, 5])
        XCTAssertTrue(r.needsUnmirrorProbe)
    }

    /// Only the ASUS got swept into the mirror set: still a probe, because the
    /// anonymous one could be the ASUS *or* a second venue screen.
    func testOneAnonymousSlaveAlongsideNamedProjectorStillProbes() {
        let r = DisplayRolePolicy.resolve(
            [retina(), external(2, nil, mirrored: true), external(5, "EPSON PU100")], isKnown: isKnown)
        XCTAssertEqual(r.projector, 5)
        XCTAssertNil(r.asus)
        XCTAssertTrue(r.needsUnmirrorProbe)
    }

    /// Once `DisplayNameCache` supplies the name, a mirrored ASUS resolves
    /// straight away — no probe, no flicker.
    func testMirroredAsusResolvesWhenItsNameIsRecovered() {
        let r = DisplayRolePolicy.resolve(
            [retina(), external(2, "ASUS MB166C", mirrored: true), external(5, "EPSON PU100")], isKnown: isKnown)
        XCTAssertEqual(r.asus, 2)
        XCTAssertEqual(r.projector, 5)
        XCTAssertFalse(r.needsUnmirrorProbe)
    }

    func testHomeMonitorsAreKnownExternalsAndNotProjectors() {
        let r = DisplayRolePolicy.resolve(
            [retina(), external(2, "DELL S2421HN"), external(3, "DELL S2421HN")], isKnown: isKnown)
        XCTAssertNil(r.projector)
        XCTAssertEqual(r.knownExternals, [2, 3])
        XCTAssertTrue(r.hasKnownExternal)
    }

    /// A second venue screen used to be dropped on the floor — i.e. left
    /// mirroring whatever macOS had decided. Now it is reported and placed.
    func testSecondUnknownExternalIsReportedNotDropped() {
        let r = DisplayRolePolicy.resolve(
            [retina(), external(5, "EPSON PU100"), external(6, "BenQ")], isKnown: isKnown)
        XCTAssertEqual(r.projector, 5)
        XCTAssertEqual(r.extraExternals, [6])
        XCTAssertFalse(r.needsUnmirrorProbe)
    }

    /// A nameless display that is *not* mirrored keeps the old reading: some
    /// venue gear simply reports no name, and it is still the projector.
    func testNamelessButExtendedDisplayIsTheProjector() {
        let r = DisplayRolePolicy.resolve([retina(), external(5, nil)], isKnown: isKnown)
        XCTAssertEqual(r.projector, 5)
        XCTAssertFalse(r.needsUnmirrorProbe)
    }
}
