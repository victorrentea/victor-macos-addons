import XCTest
@testable import VictorAddons

final class VideoPlayLogTests: XCTestCase {
    func testLineCarriesWhatTheDaemonJoinsOn() throws {
        let line = VideoPlayLog.line(id: "KD_1Z8iUDho", title: "Argentina", startSeconds: 145, kind: "video",
                                     at: Date(timeIntervalSince1970: 1_792_684_800))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, "KD_1Z8iUDho")
        XCTAssertEqual(obj["title"] as? String, "Argentina")
        XCTAssertEqual(obj["startSeconds"] as? Int, 145)
        XCTAssertEqual(obj["kind"] as? String, "video")
        let ts = try XCTUnwrap(obj["ts"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: ts.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)))
        XCTAssertFalse(line.contains("\n"))
    }

    func testAppendWritesOneLinePerPlay() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vpl-\(UUID()).jsonl")
        let saved = VideoPlayLog.fileURL
        VideoPlayLog.fileURL = tmp
        defer { VideoPlayLog.fileURL = saved; try? FileManager.default.removeItem(at: tmp) }
        VideoPlayLog.append(id: "a", title: "A", startSeconds: 0, kind: "video")
        VideoPlayLog.append(id: "b", title: "B", startSeconds: 3, kind: "soundtrack")
        let exp = expectation(description: "flushed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let lines = try String(contentsOf: tmp, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("\"kind\":\"soundtrack\""))
    }
}
