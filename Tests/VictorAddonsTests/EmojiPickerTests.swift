import AppKit
import XCTest
@testable import VictorAddons

final class EmojiPickerTests: XCTestCase {
    private let catalog = EmojiCatalog.shared

    func testBundledCatalogLoadsEveryGroup() {
        XCTAssertGreaterThan(catalog.entries.count, 1500)
        XCTAssertEqual(catalog.groups.first, "Smileys & Emotion")
        XCTAssertEqual(catalog.entry(for: "🍑")?.name, "peach")
    }

    func testSearchFindsEnglishAndDiacriticFreeRomanian() {
        XCTAssertEqual(catalog.search("peach").first?.emoji, "🍑")
        XCTAssertEqual(catalog.search("piersica").first?.emoji, "🍑")
        XCTAssertEqual(catalog.search("gâscă").first?.emoji, "🪿")
    }

    func testOwnNameOutranksAKeywordAndPartialWordsMatch() {
        XCTAssertEqual(catalog.search("cat").first?.emoji, "🐈")
        XCTAssertTrue(catalog.search("sad fa").contains { $0.emoji == "😥" })
        XCTAssertTrue(catalog.search("zzzqqq").isEmpty)
    }

    func testNormalizationIgnoresPresentationSelectorAndSkinTone() {
        XCTAssertEqual(EmojiPickerPolicy.normalized("☁️"), EmojiPickerPolicy.normalized("☁"))
        XCTAssertEqual(EmojiPickerPolicy.normalized("👴🏻"), "👴")
    }

    func testKeyedEmojiCarryTheirChord() {
        let keyed = EmojiPickerPolicy.keyedEmoji([
            .option: [8: "💥"],
            .controlOption: [3: "🍑", 45: "☁️"],
        ])
        XCTAssertEqual(keyed["🍑"], "⌃⌥F")
        XCTAssertEqual(keyed["💥"], "⌥C")
        XCTAssertEqual(keyed["☁"], "⌃⌥N")
    }

    func testFirstEmojiOfAGroupLandsOnItsAnchor() {
        var board = EmojiBoard()
        board.use("😀", group: 0)
        board.use("🦒", group: 2)
        board.use("🍕", group: 3)
        XCTAssertEqual(board.slot(for: "😀").map { [$0.column, $0.row] }, [0, 0])
        XCTAssertEqual(board.slot(for: "🦒").map { [$0.column, $0.row] }, [EmojiBoard.columns - 1, 0])
        XCTAssertEqual(board.slot(for: "🍕").map { [$0.column, $0.row] }, [0, EmojiBoard.rows - 1])
    }

    func testAPlacedEmojiNeverMovesWhateverComesAfter() {
        var board = EmojiBoard()
        board.use("😀", group: 0)
        let landed = board.slot(for: "😀")
        for (index, emoji) in ["😃", "😄", "😁", "😆", "🥲", "😅"].enumerated() {
            board.use(emoji, group: 0, at: Date(timeIntervalSince1970: Double(index)))
        }
        board.use("😀", group: 0)
        XCTAssertEqual(board.slot(for: "😀")?.column, landed?.column)
        XCTAssertEqual(board.slot(for: "😀")?.row, landed?.row)
        XCTAssertEqual(board.slots.count, 7, "reusing does not add a second copy")
        XCTAssertEqual(Set(board.slots.map { "\($0.column),\($0.row)" }).count, 7, "one emoji per cell")
    }

    func testNewcomerTakesTheFreeCellNearestItsAnchor() {
        var board = EmojiBoard()
        board.use("😀", group: 0)
        board.use("😃", group: 0)
        XCTAssertEqual(board.slot(for: "😃").map { [$0.column, $0.row] }, [1, 0], "along the top edge before down the side")
    }

    func testAFullBoardEvictsTheLeastRecentlyUsedAndMovesNothingElse() {
        var board = EmojiBoard()
        let all = Array(EmojiCatalog.shared.entries.prefix(EmojiBoard.columns * EmojiBoard.rows))
        for (index, entry) in all.enumerated() { board.use(entry.emoji, group: 0, at: Date(timeIntervalSince1970: Double(index + 10))) }
        let before = board.slots
        let oldest = before.min { $0.lastUsed < $1.lastUsed }!
        board.use("🦒", group: 2, at: Date(timeIntervalSince1970: 100_000))
        XCTAssertNil(board.slot(for: oldest.emoji))
        XCTAssertEqual(board.slot(for: "🦒").map { [$0.column, $0.row] }, [oldest.column, oldest.row])
        for slot in before where slot.emoji != oldest.emoji {
            XCTAssertEqual(board.slot(for: slot.emoji), slot)
        }
    }

    func testAnEmojiPutOnAKeyLeavesTheBoardAndFreesItsCell() {
        var board = EmojiBoard()
        board.use("🍑", group: 3)
        board.use("🍕", group: 3)
        let pizza = board.slot(for: "🍕")
        board.removeKeyed(["🍑"])
        XCTAssertNil(board.slot(for: "🍑"))
        XCTAssertEqual(board.slot(for: "🍕"), pizza)
    }

    func testPlacementFollowsTheCheatSheetAndScalesUpOnAnExternal() {
        let retina = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let external = NSRect(x: 1512, y: 0, width: 1920, height: 1080)
        let alone = EmojiPickerPlacement.frame(retinaFrame: retina, externalFrames: [], mouseLocation: nil)
        XCTAssertEqual(alone.scale, 1)
        XCTAssertEqual(alone.frame.maxX, retina.maxX)
        XCTAssertEqual(alone.frame.minY, retina.minY)
        let side = EmojiPickerPlacement.frame(retinaFrame: retina, externalFrames: [external], mouseLocation: NSPoint(x: 100, y: 100))
        XCTAssertEqual(side.frame, external, "full screen on the external")
        XCTAssertGreaterThan(side.scale, 1.4)
        let mouseThere = EmojiPickerPlacement.frame(retinaFrame: retina, externalFrames: [external], mouseLocation: NSPoint(x: 2000, y: 500))
        XCTAssertTrue(retina.contains(mouseThere.frame), "never under the cursor")
    }

    // MARK: - Left ⌥ double tap

    private func tap(_ d: inout OptionDoubleTap, at t: TimeInterval, code: Int = 58, alone: Bool = true, hold: TimeInterval = 0.08) -> Bool {
        _ = d.flagsChanged(keyCode: code, optionDown: true, optionAlone: alone, at: t)
        return d.flagsChanged(keyCode: code, optionDown: false, optionAlone: false, at: t + hold)
    }

    func testTwoQuickLeftOptionTapsFire() {
        var d = OptionDoubleTap()
        XCTAssertFalse(tap(&d, at: 0))
        XCTAssertTrue(tap(&d, at: 0.2))
        XCTAssertFalse(tap(&d, at: 0.4), "a third tap starts over")
    }

    func testSlowTapsHoldsRightOptionAndTypingDoNotFire() {
        var d = OptionDoubleTap()
        _ = tap(&d, at: 0); XCTAssertFalse(tap(&d, at: 1.0), "too far apart")
        d = OptionDoubleTap()
        _ = tap(&d, at: 0); XCTAssertFalse(tap(&d, at: 0.2, hold: 0.6), "the second was a hold — the cheat-sheet's gesture")
        d = OptionDoubleTap()
        _ = tap(&d, at: 0); XCTAssertFalse(tap(&d, at: 0.2, code: 61), "right ⌥")
        d = OptionDoubleTap()
        _ = tap(&d, at: 0); d.interrupt(); XCTAssertFalse(tap(&d, at: 0.2), "⌥-typing an emoji in between")
        d = OptionDoubleTap()
        _ = tap(&d, at: 0); XCTAssertFalse(tap(&d, at: 0.2, alone: false), "⌥ with ⇧ or ⌘ held")
    }

    // MARK: - Seeding from Apple's history

    func testImportPutsTheMostUsedNearestTheAnchorAndKeepsWhatIsAlreadyThere() {
        var board = EmojiBoard()
        board.use("🦒", group: 2)
        let giraffe = board.slot(for: "🦒")
        board.importHistory([
            .init(emoji: "😃", count: 1, last: 500),
            .init(emoji: "😀", count: 9, last: 10),
            .init(emoji: "🦒", count: 50, last: 600),
            .init(emoji: "🍑", count: 40, last: 600),
            .init(emoji: "←", count: 30, last: 600),
            .init(emoji: "🧑🏾‍💻", count: 2, last: 600),
        ], catalog: catalog, keyed: ["🍑"])
        XCTAssertEqual(board.slot(for: "🦒"), giraffe, "already placed: untouched")
        XCTAssertEqual(board.slot(for: "😀").map { [$0.column, $0.row] }, [0, 0], "most used takes the anchor")
        XCTAssertEqual(board.slot(for: "😃").map { [$0.column, $0.row] }, [1, 0])
        XCTAssertNil(board.slot(for: "🍑"), "keyed")
        XCTAssertNil(board.slot(for: "←"), "not an emoji the catalogue knows")
        XCTAssertNotNil(board.slot(for: "🧑‍💻"), "a skin-toned use counts for its base")
        XCTAssertLessThan(board.slot(for: "😀")!.lastUsed, Date(timeIntervalSince1970: 1_000_000), "older than any real pick")
    }

    func testImportLeavesRoomToGrow() {
        var board = EmojiBoard()
        let uses = catalog.entries.prefix(300).enumerated().map { MacEmojiHistory.Use(emoji: $1.emoji, count: 1, last: $0) }
        board.importHistory(uses, catalog: catalog, keyed: [])
        XCTAssertEqual(board.slots.count, EmojiBoard.importCap)
    }

    func testReadsThisMacsHistoryWithoutCrashing() {
        _ = MacEmojiHistory.read()
    }

    func testRemovingByHandFreesTheCellAndMovesNothingElse() {
        var board = EmojiBoard()
        board.use("😀", group: 0)
        board.use("😃", group: 0)
        let second = board.slot(for: "😃")
        board.remove("😀")
        XCTAssertNil(board.slot(for: "😀"))
        XCTAssertEqual(board.slot(for: "😃"), second)
        board.use("🥲", group: 0)
        XCTAssertEqual(board.slot(for: "🥲").map { [$0.column, $0.row] }, [0, 0], "the freed cell is reused")
    }

    // MARK: - Keys from the event tap, ⌃⇧ hold

    func testKeystrokesDecodeForTheSearchBox() {
        XCTAssertEqual(EmojiPickerKey.from(keyCode: 0, characters: "a", command: false, control: false, option: false), .text("a"))
        XCTAssertEqual(EmojiPickerKey.from(keyCode: 36, characters: "\r", command: false, control: false, option: false), .enter)
        XCTAssertEqual(EmojiPickerKey.from(keyCode: 53, characters: "\u{1B}", command: false, control: false, option: false), .escape)
        XCTAssertEqual(EmojiPickerKey.from(keyCode: 51, characters: "\u{7F}", command: false, control: false, option: false), .backspace)
        XCTAssertEqual(EmojiPickerKey.from(keyCode: 9, characters: "v", command: true, control: false, option: false), .passThrough)
        XCTAssertEqual(EmojiPickerKey.from(keyCode: 0, characters: "a", command: false, control: true, option: false), .passThrough)
        XCTAssertEqual(EmojiPickerKey.from(keyCode: 0, characters: "å", command: false, control: false, option: true), .ignore)
        XCTAssertEqual(EmojiPickerKey.from(keyCode: 122, characters: "\u{F704}", command: false, control: false, option: false), .ignore)
    }

    func testControlShiftHoldOpensAfterTheDelayAndClosesOnRelease() {
        var opened = 0, closed = 0
        let hold = EmojiPickerHold(delay: { 0.05 }, open: { opened += 1; return true }, close: { closed += 1 })
        hold.held(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(opened, 1)
        hold.held(false)
        XCTAssertEqual(closed, 1)
    }

    func testAKeyUnderControlShiftMeansItWasAShortcut() {
        var opened = 0
        let hold = EmojiPickerHold(delay: { 0.05 }, open: { opened += 1; return true }, close: {})
        hold.held(true)
        hold.keyPressed()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(opened, 0)
        hold.held(false)
        hold.held(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(opened, 1, "a fresh hold works again")
    }

    func testReleaseDoesNotCloseAPickerTheHoldDidNotOpen() {
        var closed = 0
        let hold = EmojiPickerHold(delay: { 0.05 }, open: { false }, close: { closed += 1 })
        hold.held(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hold.held(false)
        XCTAssertEqual(closed, 0)
    }
}
