import XCTest
@testable import VictorAddons

/// The rules behind the 🤖 Prompts panel. Each of these fails *quietly* in the
/// real thing: a machine-written line offered to the room as if Victor had
/// typed it, a week that silently becomes six days, or a list whose newest
/// prompt is at the bottom — where nobody scrolls.
final class PromptCapturePolicyTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 12, _ mm: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    private func prompt(_ text: String, at date: Date, sent: Bool = false) -> CapturedPrompt {
        CapturedPrompt(text: text, date: date, source: .claude, sent: sent)
    }

    // MARK: normalize

    func testEmptyAndWhitespaceOnlyPromptsAreNotRecorded() {
        XCTAssertNil(PromptCapturePolicy.normalize(""))
        XCTAssertNil(PromptCapturePolicy.normalize("   \n\t "))
    }

    func testMachineInjectedPromptsAreDropped() {
        XCTAssertNil(PromptCapturePolicy.normalize("<task-notification>agent finished</task-notification>"))
        // Leading whitespace must not smuggle one past the check.
        XCTAssertNil(PromptCapturePolicy.normalize("\n  <task-notification>x"))
    }

    // MARK: unwrapPastes

    func testAPastedBlockLosesItsEnvelopeButKeepsItsText() {
        // Exactly what Claude Code sent the hook on 2026-09-30 for
        // "[Pasted text #1] pe gh 25".
        let raw = "\n\n<pasted_content id=\"22fb\">\nInterview me.\nAsk one at a time.\n</pasted_content id=\"22fb\">\n\n pe gh 25"
        XCTAssertEqual(PromptCapturePolicy.normalize(PromptCapturePolicy.unwrapPastes(raw)),
                       "Interview me.\nAsk one at a time.\n\n pe gh 25")
    }

    func testEveryPasteInOnePromptIsUnwrapped() {
        let raw = "compare\n\n<pasted_content id=\"a1\">\nfoo\n</pasted_content id=\"a1\">\n\nwith\n\n<pasted_content id=\"b2\">\nbar\n</pasted_content id=\"b2\">\n"
        XCTAssertEqual(PromptCapturePolicy.unwrapPastes(raw), "compare\n\nfoo\n\nwith\n\nbar\n")
    }

    func testAPromptWithoutPastesIsUntouched() {
        XCTAssertEqual(PromptCapturePolicy.unwrapPastes("fix <b>this</b>\n"), "fix <b>this</b>\n")
    }

    func testARealPromptIsKeptTrimmedButOtherwiseVerbatim() {
        XCTAssertEqual(PromptCapturePolicy.normalize("  refactor this class  "), "refactor this class")
        XCTAssertEqual(PromptCapturePolicy.normalize("line one\nline two"), "line one\nline two")
    }

    func testAnEnormousPasteIsTruncatedRatherThanDropped() {
        let huge = String(repeating: "x", count: PromptCapturePolicy.maxTextLength + 500)
        let kept = PromptCapturePolicy.normalize(huge)
        XCTAssertEqual(kept?.count, PromptCapturePolicy.maxTextLength + 1)  // + the ellipsis
        XCTAssertTrue(kept?.hasSuffix("…") == true)
    }

    // MARK: prune

    func testTheWindowIsSevenCalendarDaysIncludingToday() {
        let now = at(2026, 9, 22, 9, 30)
        let entries = [
            prompt("today", at: at(2026, 9, 22, 8)),
            prompt("six days ago, before dawn", at: at(2026, 9, 16, 0, 5)),
            prompt("seven days ago", at: at(2026, 9, 15, 23, 55)),
        ]
        let kept = PromptCapturePolicy.prune(entries, now: now, calendar: calendar).map(\.text)
        XCTAssertEqual(kept, ["today", "six days ago, before dawn"])
    }

    func testADayDoesNotHalfExpireAtLunchtime() {
        // The oldest kept day must survive the whole day, not 24h from its own
        // timestamp — "Wednesday's prompts" is how the list is read.
        let entries = [prompt("early", at: at(2026, 9, 16, 0, 1))]
        let morning = PromptCapturePolicy.prune(entries, now: at(2026, 9, 22, 7), calendar: calendar)
        let evening = PromptCapturePolicy.prune(entries, now: at(2026, 9, 22, 23), calendar: calendar)
        XCTAssertEqual(morning.count, 1)
        XCTAssertEqual(evening.count, 1)
    }

    // MARK: sections

    func testNewestDayFirstAndNewestPromptFirstInsideIt() {
        let now = at(2026, 9, 22, 18)
        let entries = [
            prompt("yesterday morning", at: at(2026, 9, 21, 9)),
            prompt("today 10:00", at: at(2026, 9, 22, 10)),
            prompt("today 16:00", at: at(2026, 9, 22, 16)),
        ]
        let sections = PromptCapturePolicy.sections(from: entries, now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].title, "Today")
        XCTAssertEqual(sections[0].prompts.map(\.text), ["today 16:00", "today 10:00"])
        XCTAssertEqual(sections[1].title, "Yesterday")
        XCTAssertEqual(sections[1].prompts.map(\.text), ["yesterday morning"])
    }

    func testOlderDaysAreNamed() {
        let now = at(2026, 9, 22, 18)
        let title = PromptCapturePolicy.dayTitle(at(2026, 9, 18), now: now, calendar: calendar,
                                                 locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertNotEqual(title, "Today")
        XCTAssertNotEqual(title, "Yesterday")
        XCTAssertTrue(title.contains("18"), "expected the day number in \"\(title)\"")
    }

    func testSentPromptsStayInTheListTheyAreOnlyFlagged() {
        let now = at(2026, 9, 22, 18)
        let entries = [prompt("already on screen", at: at(2026, 9, 22, 11), sent: true)]
        let sections = PromptCapturePolicy.sections(from: entries, now: now, calendar: calendar)
        XCTAssertEqual(sections.first?.prompts.first?.sent, true)
    }

    // MARK: source

    func testTheSourceComesFromTheHookAndAnythingElseIsUnbadged() {
        XCTAssertEqual(PromptSource.parse("claude"), .claude)
        XCTAssertEqual(PromptSource.parse("Copilot"), .copilot)
        XCTAssertEqual(PromptSource.parse(nil), .unknown)
        XCTAssertEqual(PromptSource.parse(""), .unknown)
        XCTAssertEqual(PromptSource.parse("cursor"), .unknown)
    }

    func testEverySourceHasItsOwnBadge() {
        let badges = Set([PromptSource.claude, .copilot, .unknown].map(\.badge))
        XCTAssertEqual(badges.count, 3)
    }

    // MARK: display

    func testAMultiLinePromptIsFlattenedForTheRow() {
        XCTAssertEqual(PromptCapturePolicy.singleLine("\nfix the\tbuild\nplease "), "fix the build please")
    }

    // MARK: the shared block-list

    func testTheOfferPillAndTheHistoryDropTheSameTexts() {
        // One list, two consumers: a prompt the pill refuses to offer must not
        // appear in the panel with a live Send button.
        XCTAssertFalse(PromptCapturePolicy.blockedPrefixes.isEmpty)
        for prefix in PromptCapturePolicy.blockedPrefixes {
            XCTAssertNil(PromptCapturePolicy.normalize(prefix + " whatever follows"))
        }
    }

    // MARK: - auto-send folders (2026-10-05)

    func testThePetclinicSessionSendsOnItsOwn() {
        XCTAssertTrue(PromptCapturePolicy.autoSends(cwd: "/Users/v/workspace/petclinic", home: "/Users/v"))
        XCTAssertTrue(PromptCapturePolicy.autoSends(cwd: "/Users/v/workspace/petclinic/", home: "/Users/v"))
    }

    func testASessionInsideThePetclinicTreeSendsToo() {
        XCTAssertTrue(PromptCapturePolicy.autoSends(cwd: "/Users/v/workspace/petclinic/petclinic-frontend",
                                                    home: "/Users/v"))
    }

    /// The petclinic-* checkouts share the prefix but are other branches, not the demo.
    func testASiblingCheckoutWithTheSamePrefixDoesNot() {
        XCTAssertFalse(PromptCapturePolicy.autoSends(cwd: "/Users/v/workspace/petclinic-main", home: "/Users/v"))
        XCTAssertFalse(PromptCapturePolicy.autoSends(cwd: "/Users/v/workspace/petclinic-pr-visit-has-vet",
                                                     home: "/Users/v"))
    }

    func testAnyOtherFolderOrNoFolderStillAsks() {
        XCTAssertFalse(PromptCapturePolicy.autoSends(cwd: "/Users/v/workspace/victor-macos-addons", home: "/Users/v"))
        XCTAssertFalse(PromptCapturePolicy.autoSends(cwd: "/Users/v/workspace", home: "/Users/v"))
        XCTAssertFalse(PromptCapturePolicy.autoSends(cwd: nil, home: "/Users/v"))
        XCTAssertFalse(PromptCapturePolicy.autoSends(cwd: "", home: "/Users/v"))
    }
}
