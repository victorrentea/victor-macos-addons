import XCTest
@testable import VictorAddons

/// The proxy has to be able to carry **bytes**, not just text.
///
/// Of everything on 55123 exactly one route answers with something that is not
/// JSON — `GET /tiles/<image>`, a tile picture the tablet fetches when the
/// manifest names an image its own APK does not carry. For the length of the
/// 2026-09 app split that route was decoded as UTF-8 on the way through
/// (`String(data:encoding:) ?? ""`), so the PNG came out as **200 image/png with
/// zero bytes**: a status and a content type that promise a picture, wrapped
/// around nothing.
///
/// It stayed invisible because every tile picture was *also* in the APK, so the
/// tablet never used the fetch path — which exists precisely for a tile added to
/// the shared folder after the last Android build. #20's ⛈️ storm (2026-09-19)
/// was the first one there had ever been, and it showed up in the room as a
/// black square that stayed black, because the tablet wrote those zero bytes
/// into its own `tile-cache` and decoded that file happily ever after.
///
/// The type now says it: `respond` and `EffectsProxy.forward` hand back `Data`.
/// These tests hold the last place it could still be flattened — the writer.
final class BinaryBodyPassThroughTests: XCTestCase {

    /// A byte sequence that is deliberately NOT valid UTF-8: the PNG signature
    /// plus a stray 0x80 continuation byte. Putting this through a `String` is
    /// exactly the bug, and it fails loudly here instead of quietly in a room.
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x80, 0xFF, 0x00, 0x42])

    func testTheBodyGoesOutByteForByte() {
        let response = TabletHttpServer.httpResponse(statusCode: 200, contentType: "image/png", body: png)
        XCTAssertEqual(response.suffix(png.count), png,
                       "the picture must reach the wire unchanged — this is the whole bug")
        XCTAssertNil(String(data: png, encoding: .utf8),
                     "if this ever decodes, the fixture stopped testing what it was written for")
    }

    /// `Content-Length` is counted on the bytes that are actually sent. Counted
    /// on a re-encoded string it would disagree with them, and a client reading
    /// the declared length off a socket would hang or truncate.
    func testContentLengthCountsTheRealBytes() throws {
        let response = TabletHttpServer.httpResponse(statusCode: 200, contentType: "image/png", body: png)
        let head = try XCTUnwrap(String(data: response.prefix(response.count - png.count), encoding: .utf8))
        XCTAssertTrue(head.contains("Content-Length: \(png.count)\r\n"), head)
        XCTAssertTrue(head.contains("Content-Type: image/png\r\n"), head)
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"), "the head must end on the blank line, with no body in it")
    }

    /// The ordinary case still has to work: every other route on this port is a
    /// short JSON or text body built in `respond`.
    func testATextBodyIsUnaffected() throws {
        let body = Data(#"{"ok":true}"#.utf8)
        let response = TabletHttpServer.httpResponse(statusCode: 200, contentType: "application/json", body: body)
        let text = try XCTUnwrap(String(data: response, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
    }

    func testStatusLinesStillCarryTheirReasons() throws {
        for (code, reason) in [(200, "OK"), (404, "Not Found"), (503, "Service Unavailable")] {
            let response = TabletHttpServer.httpResponse(statusCode: code, contentType: "text/plain", body: Data())
            let text = try XCTUnwrap(String(data: response, encoding: .utf8))
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 \(code) \(reason)\r\n"), text)
        }
    }
}
