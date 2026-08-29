import XCTest
@testable import VictorAddons

final class FocusPlaylistTests: XCTestCase {

    /// A watch page, shrunk to the shape the parser actually depends on: one
    /// `playlistPanelVideoRenderer` per track, each followed by its `videoId`.
    private func mixPage(ids: [String]) -> String {
        let panel = ids.map { id in
            """
            "playlistPanelVideoRenderer":{"title":{"runs":[{"text":"Track"}]},\
            "videoId":"\(id)","lengthText":{"simpleText":"3:21"}}
            """
        }.joined(separator: ",")
        return "{\"contents\":{\"playlist\":{\"contents\":[\(panel)]}}}"
    }

    func testReadsTheMixTracksInPanelOrder() {
        let html = mixPage(ids: ["LEEx_UkHmBU", "MiAsgo9k0RM", "LhMyAYil3N8"])
        XCTAssertEqual(FocusPlaylist.videoIds(inMixPage: html),
                       ["LEEx_UkHmBU", "MiAsgo9k0RM", "LhMyAYil3N8"])
    }

    /// YouTube repeats the current track's id in the panel and elsewhere; a
    /// duplicate would weight the random pick towards it.
    func testDropsDuplicates() {
        let html = mixPage(ids: ["LEEx_UkHmBU", "MiAsgo9k0RM", "LEEx_UkHmBU"])
        XCTAssertEqual(FocusPlaylist.videoIds(inMixPage: html),
                       ["LEEx_UkHmBU", "MiAsgo9k0RM"])
    }

    func testIgnoresRenderersWhoseIdIsNotAVideoId() {
        let html = """
        "playlistPanelVideoRenderer":{"videoId":"too-short"},\
        "playlistPanelVideoRenderer":{"videoId":"MiAsgo9k0RM"}
        """
        XCTAssertEqual(FocusPlaylist.videoIds(inMixPage: html), ["MiAsgo9k0RM"])
    }

    /// The id must come from *this* renderer: a page whose first renderer has no
    /// id at all must not adopt the next track's.
    func testDoesNotReachPastTheRenderersOwnWindow() {
        let filler = String(repeating: "x", count: 4000)
        let html = """
        "playlistPanelVideoRenderer":{"title":"\(filler)"},\
        "playlistPanelVideoRenderer":{"videoId":"MiAsgo9k0RM"}
        """
        XCTAssertEqual(FocusPlaylist.videoIds(inMixPage: html), ["MiAsgo9k0RM"])
    }

    func testRandomUrlKeepsTheFocusListAndOnlyMovesTheTrack() {
        let html = mixPage(ids: ["LEEx_UkHmBU", "qXQ6wEipSug"])
        let url = FocusPlaylist.randomWatchUrl(fromMixPage: html) { $0.last }
        XCTAssertEqual(url,
            "https://www.youtube.com/watch?v=qXQ6wEipSug&list=RDLEEx_UkHmBU&start_radio=1")
    }

    /// Offline, or after YouTube reshapes its markup, the shortcut still has to
    /// open the right music — just at the front of the mix.
    func testFallsBackToTheSeedWhenThePageYieldsNothing() {
        XCTAssertEqual(FocusPlaylist.randomWatchUrl(fromMixPage: "<html>consent</html>"),
                       FocusPlaylist.seedUrl)
        XCTAssertEqual(FocusPlaylist.seedUrl,
            "https://www.youtube.com/watch?v=LEEx_UkHmBU&list=RDLEEx_UkHmBU&start_radio=1")
    }

    func testListIdIsDerivedFromTheSeedSoOneConstantMovesTheWholeShortcut() {
        XCTAssertEqual(FocusPlaylist.listId, "RD" + FocusPlaylist.seedVideoId)
    }
}
