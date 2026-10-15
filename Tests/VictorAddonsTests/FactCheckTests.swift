import XCTest
@testable import VictorAddons

final class FactCheckTests: XCTestCase {
    func testTheHeaderShowsTheLastWordsSaid() {
        XCTAssertEqual(FactCheck.header(for: "Kafka keeps   offsets\nper partition"),
                       "🔬 «Kafka keeps offsets per partition»")
        XCTAssertEqual(FactCheck.header(for: "🎙️ the broker. 🎙️ Throws an exception."),
                       "🔬 «the broker. Throws an exception.»")
        let long = String(repeating: "a ", count: 50) + "the end"
        let header = FactCheck.header(for: long, limit: 10)
        XCTAssertEqual(header, "🔬 «…a the end»")
    }

    func testThePromptCarriesTheTranscriptAndAsksForOneLinePerClaim() {
        let prompt = FactCheck.prompt(for: "[17:52] Kafka was written in Go.")
        XCTAssertTrue(prompt.contains("overheard"))
        XCTAssertTrue(prompt.contains("[17:52] Kafka was written in Go."))
        XCTAssertTrue(prompt.contains("one short line each"))
        XCTAssertTrue(prompt.contains("in the language of the discussion"))
    }
}
