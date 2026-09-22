import XCTest
@testable import VictorAddons

/// Când se aude Tink-ul de eliberare a mâinilor — regula care s-a schimbat pe
/// 2026-09-22, când rig-urile de capturi au început să ceară mâinile de zeci de
/// ori pe oră și Victor a auzit bip-urile cu capacul închis.
final class HandsOffChimeTests: XCTestCase {

    /// Cazul obișnuit: capacul deschis, eliberare anunțată — se aude, fiindcă
    /// Victor nu se uită la ecran cât așteaptă.
    func testAnnouncedReleaseWithTheLidOpenIsAudible() {
        XCTAssertTrue(HandsOffOverlay.shouldChime(silent: false, lidClosed: false))
    }

    /// Cererea lui, verbatim: cu capacul închis rămâne doar heartbeat-ul.
    func testAnnouncedReleaseWithTheLidShutIsSilent() {
        XCTAssertFalse(HandsOffOverlay.shouldChime(silent: false, lidClosed: true))
    }

    /// Calea auto-ridicată tăcea deja, și tace în continuare — regula nouă nu o
    /// poate face din nou zgomotoasă.
    func testAutoRaisedReleaseStaysSilentWithTheLidOpen() {
        XCTAssertFalse(HandsOffOverlay.shouldChime(silent: true, lidClosed: false))
    }

    func testAutoRaisedReleaseStaysSilentWithTheLidShut() {
        XCTAssertFalse(HandsOffOverlay.shouldChime(silent: true, lidClosed: true))
    }
}
