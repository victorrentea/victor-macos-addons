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

    func testTyposAndSwappedLettersStillFind() {
        XCTAssertEqual(catalog.search("pizaa").first?.emoji, "🍕", "one wrong letter")
        XCTAssertEqual(catalog.search("paech").first?.emoji, "🍑", "two letters swapped")
        XCTAssertTrue(catalog.search("lfet arrow").contains { $0.emoji == "⬅️" })
        XCTAssertEqual(catalog.search("girafe").first?.emoji, "🦒", "a missing letter")
        XCTAssertEqual(catalog.search("piersca").first?.emoji, "🍑", "Romanian too")
    }

    func testACorrectSpellingOutranksATypo() {
        // "rose" is a word of its own; it must not lose to the fuzzy "rise"/"nose".
        XCTAssertEqual(catalog.search("rose").first?.emoji, "🌹")
    }

    func testOpacityFollowsHowSureTheMatchIs() {
        func opacity(_ query: String, _ emoji: String) -> Double? {
            catalog.matches(query).first { $0.entry.emoji == emoji }?.opacity
        }
        XCTAssertEqual(opacity("peach", "🍑"), 1, "its own name")
        XCTAssertEqual(opacity("pea", "🍑"), 1, "the start of it, still being typed")
        XCTAssertEqual(EmojiFuzzy.opacity(token: "aff", name: [EmojiFuzzy.noMatch], keyword: [EmojiFuzzy.noMatch], synonym: [1]), 0.8)
        XCTAssertEqual(EmojiFuzzy.typoOpacity(edits: 1, letters: 8), 0.5)
        XCTAssertEqual(EmojiFuzzy.typoOpacity(edits: 2, letters: 7), 0.2, accuracy: 1e-9)
        XCTAssertLessThan(opacity("lfet", "⬅️")!, opacity("pizzaa", "🍕")!, "1 wrong in 4 fades more than 1 in 6")
    }

    func testTheFaintestResultsGoLast() {
        let opacities = catalog.matches("smil").map(\.opacity)
        XCTAssertEqual(opacities, opacities.sorted(by: >))
    }

    func testFuzzyCostIsDamerauOnAPrefix() {
        XCTAssertEqual(EmojiFuzzy.prefixCost("left", "left"), 0)
        XCTAssertEqual(EmojiFuzzy.prefixCost("lef", "left"), 1)
        XCTAssertEqual(EmojiFuzzy.prefixCost("lfet", "left"), 5, "a swap is one edit")
        XCTAssertEqual(EmojiFuzzy.prefixCost("lfe", "left"), EmojiFuzzy.noMatch, "no fuzziness under 4 letters")
        XCTAssertEqual(EmojiFuzzy.prefixCost("elephnt", "elephant"), 5, "one missing letter, prefix of a longer word")
        XCTAssertEqual(EmojiFuzzy.prefixCost("elehpnat", "elephant"), 6, "two swaps")
        XCTAssertEqual(EmojiFuzzy.prefixCost("banana", "cherry"), EmojiFuzzy.noMatch)
    }

    func testExtraSynonymsFindWhatCLDRDoesNot() {
        XCTAssertTrue(catalog.search("approve").prefix(10).contains { $0.emoji == "👍" }, "emojilib")
        XCTAssertTrue(catalog.search("left").contains { $0.emoji == "👈" }, "emojidb")
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
        XCTAssertEqual(board.slot(for: "🍕").map { [$0.column, $0.row] }, [0, (EmojiBoard.rows - 1) / 2], "food: middle of the left edge")
    }

    func testArrowsHaveTheBottomLeftCornerAndHeartsWithArrowsDoNot() {
        var board = EmojiBoard()
        board.use(catalog.entry(for: "⬇️")!)
        board.use(catalog.entry(for: "🔄")!)
        board.use(catalog.entry(for: "💘")!)
        board.use(catalog.entry(for: "🔔")!)
        XCTAssertEqual(board.slot(for: "⬇️").map { [$0.column, $0.row] }, [4, EmojiBoard.rows - 1], "its hand-laid cell")
        XCTAssertEqual(board.slot(for: "🔄").map { [$0.column, $0.row] }, [6, EmojiBoard.rows - 5])
        XCTAssertEqual(board.slot(for: "💘").map { [$0.column, $0.row] }, [0, 0], "a smiley-group heart: top left, arrow or not")
        XCTAssertEqual(board.slot(for: "🔔").map { [$0.column, $0.row] }, [EmojiBoard.columns - 1, EmojiBoard.rows - 1])
    }

    func testTextSymbolsLikeOneHalfAreFoundFirst() {
        XCTAssertEqual(catalog.search("half").first?.emoji, "½")
        XCTAssertEqual(catalog.search("jumatate").first?.emoji, "½")
        XCTAssertTrue(catalog.search("1/2").prefix(6).contains { $0.emoji == "½" })
        XCTAssertEqual(catalog.search("degree").first?.emoji, "°")
        XCTAssertTrue(EmojiPickerPolicy.isTextSymbol("½"))
        XCTAssertEqual(catalog.entry(for: "½")?.group, 7)
    }

    func testTheExplanationLightsTheLettersThatMatched() {
        let wedding = catalog.entry(for: "💒")!
        XCTAssertEqual(catalog.explain("aff", wedding),
                       [EmojiMatch(typed: "aff", word: "affection", source: .synonym, matched: [0, 1, 2])])
        let typo = catalog.explain("afff", wedding).first!
        XCTAssertEqual(typo.word, "affection")
        XCTAssertEqual(typo.matched, [0, 1, 2], "the wrong 4th letter stays unlit")
        XCTAssertEqual(EmojiFuzzy.matchedLetters("lfet", "left"), [0, 1, 2, 3], "a swap lights both")
        XCTAssertEqual(catalog.explain("one half", catalog.entry(for: "½")!).map(\.source), [.name, .name])
        let half = catalog.explain("jumatate", catalog.entry(for: "½")!).first!
        XCTAssertEqual([half.word, "\(half.romanian)"], ["jumătate", "true"], "Romanian, with its diacritics")
        XCTAssertFalse(catalog.explain("aff", wedding).first!.romanian)
        XCTAssertTrue(catalog.explain("nunta", wedding).first!.romanian)
    }

    func testWhatWasPickedForAQueryComesFirstNextTime() {
        var memory = EmojiQueryMemory()
        let mic = catalog.search("mic")
        XCTAssertNotEqual(mic.first?.emoji, "🎙️", "not first on its own")
        XCTAssertTrue(mic.contains { $0.emoji == "🎙️" })
        memory.record(query: " Mic ", emoji: "🎙️", at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(memory.reorder(mic, for: "mic").first?.emoji, "🎙️")
        XCTAssertEqual(memory.reorder(catalog.search("mi"), for: "mi").first?.emoji, "🎙️", "on the way to \"mic\"")
        XCTAssertNotEqual(memory.reorder(catalog.search("m"), for: "m").first?.emoji, "🎙️", "one letter lifts nothing")
        XCTAssertEqual(memory.reorder(mic, for: "mic").count, mic.count, "a reorder, never a filter")
        // Exact beats prefix; among exact, the most picked.
        memory.record(query: "mi", emoji: "🎤", at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(memory.reorder(catalog.search("mi"), for: "mi").prefix(2).map(\.emoji), ["🎤", "🎙️"])
        XCTAssertEqual(memory.reason("mi", "🎙️")?.query, "mic")
    }

    func testSearchResultsFillTheBoardFromTheCentreOutwards() {
        let centre = (column: EmojiBoard.columns / 2, row: EmojiBoard.rows / 2)
        let cells = EmojiBoard.cellsFromCentre
        XCTAssertEqual(cells.count, EmojiBoard.columns * EmojiBoard.rows)
        XCTAssertEqual([cells[0].column, cells[0].row], [centre.column, centre.row], "best match in the middle")
        XCTAssertEqual([cells[1].column, cells[1].row], [centre.column + 1, centre.row], "the runner-up just right of it")
        for cell in cells[1...4] {
            XCTAssertEqual(abs(cell.column - centre.column) + abs(cell.row - centre.row), 1, "ranks 2-5: one arrow away")
        }
        let results = catalog.search("half")
        let board = EmojiBoard.searchLayout(results)
        XCTAssertEqual(board.slot(column: centre.column, row: centre.row)?.emoji, "½")
        XCTAssertEqual(board.slots.count, min(results.count, cells.count))
        XCTAssertEqual(EmojiBoard.searchLayout(Array(repeating: results[0], count: 400)).slots.count, cells.count, "only what fits")
    }

    func testPlainArrowsAreSearchableDistinctFromTheBlueOnesAndDrawnAsText() {
        let plain = catalog.search("left arrow plain").map(\.emoji)
        XCTAssertTrue(plain.contains("←"))
        XCTAssertNotEqual(catalog.entry(for: "↔\u{FE0E}")?.name, catalog.entry(for: "↔️")?.name)
        XCTAssertTrue(EmojiPickerPolicy.isTextSymbol("←"))
        XCTAssertTrue(EmojiPickerPolicy.isTextSymbol("↔\u{FE0E}"))
        XCTAssertFalse(EmojiPickerPolicy.isTextSymbol("↔️"))
        XCTAssertFalse(EmojiPickerPolicy.isTextSymbol("🔄"))
        XCTAssertTrue(EmojiCatalog.plainArrows.contains { $0.emoji == "↗\u{FE0E}" }, "↗ left ⌥⇧U for the board")
    }

    func testThe25By13BoardIsLaidOutOnTheSmallerOneCornersStayingCorners() {
        let t = Date(timeIntervalSince1970: 5)
        let board = EmojiBoard.relaid([
            EmojiSlot(emoji: "😀", column: 0, row: 0, lastUsed: t),
            EmojiSlot(emoji: "🐄", column: 24, row: 0, lastUsed: t),
            EmojiSlot(emoji: "⬅️", column: 3, row: 11, lastUsed: t),
            EmojiSlot(emoji: "🔔", column: 24, row: 12, lastUsed: t),
        ], columns: 25, rows: 13, catalog: catalog, hadArrowCorner: true)
        func cell(_ e: String) -> [Int]? { board.slot(for: e).map { [$0.column, $0.row] } }
        let right = EmojiBoard.columns - 1, bottom = EmojiBoard.rows - 1
        XCTAssertEqual([cell("😀"), cell("🐄"), cell("⬅️"), cell("🔔")], [[0, 0], [right, 0], [3, bottom - 1], [right, bottom]])
        XCTAssertEqual(board.slot(for: "😀")?.lastUsed, t, "\"last used\" travels with it")
    }

    func testGluingTheRosesMovesOnlyThePlacedArrows() {
        let middle = EmojiBoard.rows - 2, t = Date(timeIntervalSince1970: 5)
        var board = EmojiBoard(slots: [
            EmojiSlot(emoji: "⬅️", column: 4, row: middle, lastUsed: t),
            EmojiSlot(emoji: "➡️", column: 6, row: middle, lastUsed: t),
            EmojiSlot(emoji: "🚗", column: 12, row: 0, lastUsed: t),
        ])
        board.relocateArrowBlock()
        XCTAssertEqual(board.slots.map { [$0.column, $0.row] }, [[3, middle], [5, middle], [12, 0]])
        XCTAssertNil(board.slot(for: "⬆️"), "one taken off by hand stays off")
    }

    func testAKeyedArrowAlsoKeepsItsPlainTwinOffTheBoard() {
        let keyed = EmojiPickerPolicy.keyedEmoji([.optionShift: [32: "↖"]])
        var board = EmojiBoard()
        board.place(EmojiCatalog.plainArrows, keyed: Set(keyed.keys))
        XCTAssertNil(board.slot(for: "↖\u{FE0E}"))
        XCTAssertEqual(board.slots.count, EmojiCatalog.plainArrows.count - 1)
        XCTAssertTrue(board.slots.allSatisfy { $0.column < 15 && $0.row > EmojiBoard.rows / 2 }, "all in the bottom-left corner")
    }

    func testTheArrowCornerIsCompassRosesAroundEmptyCentres() {
        var board = EmojiBoard(slots: [
            EmojiSlot(emoji: "⬅️", column: 0, row: 0, lastUsed: Date(timeIntervalSince1970: 42)),
            EmojiSlot(emoji: "🚗", column: 1, row: EmojiBoard.rows - 2, lastUsed: Date(timeIntervalSince1970: 7)),
        ])
        board.arrangeArrowBlock(catalog: catalog, keyed: ["👉", "🔼", "🔽", "↗", "↗\u{FE0E}"])
        func cell(_ e: String) -> [Int]? { board.slot(for: e).map { [$0.column, $0.row] } }
        let bottom = EmojiBoard.rows - 1, middle = bottom - 1, top = bottom - 2
        // Blue rose centred on (5, middle): each arrow points away from the hole.
        XCTAssertEqual(["↖️", "⬆️", "⬅️", "➡️", "↙️", "⬇️", "↘️"].map(cell),
                       [[3, top], [4, top], [3, middle], [5, middle], [3, bottom], [4, bottom], [5, bottom]])
        XCTAssertEqual(["↖\u{FE0E}", "↑", "←", "→", "↙\u{FE0E}", "↓", "↘\u{FE0E}"].map(cell),
                       [[0, top], [1, top], [0, middle], [2, middle], [0, bottom], [1, bottom], [2, bottom]])
        XCTAssertEqual(["👆", "👈", "👇"].map(cell), [[8, top], [7, middle], [8, bottom]])
        XCTAssertNil(board.slot(column: 1, row: middle), "the plain rose's centre is empty")
        XCTAssertTrue(EmojiBoard.isReserved(column: 4, row: middle), "and stays empty: the blue one's too")
        XCTAssertTrue(EmojiBoard.isReserved(column: 6, row: middle), "the gap before the hands")
        XCTAssertEqual(cell("↔\u{FE0E}"), [8, bottom - 3])
        XCTAssertEqual(cell("↩\u{FE0E}"), [0, bottom - 4], "plain curved one right above its blue twin")
        XCTAssertEqual(cell("↩️"), [0, bottom - 3])
        XCTAssertEqual(board.slot(for: "⬅️")?.lastUsed, Date(timeIntervalSince1970: 42), "it moved, its history did not")
        XCTAssertNil(board.slot(for: "↗\u{FE0E}"), "keyed: its cell stays empty")
        XCTAssertNil(board.slot(column: 2, row: top))
        XCTAssertNotNil(cell("🚗"), "what sat in the block moved out of it")
        XCTAssertFalse(EmojiBoard.isReserved(column: cell("🚗")![0], row: cell("🚗")![1]))
        board.use("🍕", group: 3)
        board.use("🔙", region: .arrows)
        XCTAssertFalse(EmojiBoard.isReserved(column: cell("🔙")![0], row: cell("🔙")![1]), "other arrows grow around the block")
    }

    func testTheOldBoardIsLaidOutAgainKeepingEachRegionsShape() {
        let at = Date(timeIntervalSince1970: 5)
        let old = [
            EmojiSlot(emoji: "😀", column: 0, row: 0, lastUsed: at),
            EmojiSlot(emoji: "😃", column: 1, row: 0, lastUsed: at),
            EmojiSlot(emoji: "🦒", column: 19, row: 0, lastUsed: at),
            EmojiSlot(emoji: "🍕", column: 0, row: 9, lastUsed: at),
            EmojiSlot(emoji: "🔔", column: 19, row: 9, lastUsed: at),
            EmojiSlot(emoji: "⬇️", column: 18, row: 9, lastUsed: at),
        ]
        let board = EmojiBoard.relaid(old, columns: 20, rows: 10, catalog: catalog)
        func cell(_ e: String) -> [Int]? { board.slot(for: e).map { [$0.column, $0.row] } }
        XCTAssertEqual(cell("😀"), [0, 0])
        XCTAssertEqual(cell("😃"), [1, 0])
        XCTAssertEqual(cell("🦒"), [EmojiBoard.columns - 1, 0], "moved with its corner")
        XCTAssertEqual(cell("🔔"), [EmojiBoard.columns - 1, EmojiBoard.rows - 1])
        XCTAssertEqual(cell("⬇️"), [4, EmojiBoard.rows - 1], "arrows to their own corner")
        XCTAssertEqual(cell("🍕"), [0, (EmojiBoard.rows - 1) / 2])
        XCTAssertEqual(board.slot(for: "😀")?.lastUsed, at)
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
        XCTAssertLessThanOrEqual(alone.frame.width, retina.width / 2, "never more than half the retina's width")
        XCTAssertLessThanOrEqual(alone.frame.height, retina.height / 2, "nor half its height")
        XCTAssertGreaterThan(alone.scale, 1)
        XCTAssertEqual(alone.frame.maxX, retina.maxX)
        XCTAssertEqual(alone.frame.minY, retina.minY)
        let side = EmojiPickerPlacement.frame(retinaFrame: retina, externalFrames: [external], mouseLocation: NSPoint(x: 100, y: 100))
        XCTAssertEqual(side.frame, external, "full screen on the external")
        XCTAssertGreaterThan(side.scale, 1.4)
        let mouseThere = EmojiPickerPlacement.frame(retinaFrame: retina, externalFrames: [external], mouseLocation: NSPoint(x: 2000, y: 500))
        XCTAssertTrue(retina.contains(mouseThere.frame), "never under the cursor")
        XCTAssertLessThanOrEqual(mouseThere.frame.width, retina.width / 2)
        XCTAssertLessThanOrEqual(mouseThere.frame.height, retina.height / 2)
        let small = EmojiPickerPlacement.frame(retinaFrame: NSRect(x: 0, y: 0, width: 1512, height: 700), externalFrames: [], mouseLocation: nil)
        XCTAssertLessThanOrEqual(small.frame.height, 350, "a short screen: the height cap wins")
        XCTAssertEqual(small.frame.width / small.frame.height, alone.frame.width / alone.frame.height, accuracy: 0.01, "same proportions")
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

    func testASecondOptionStillHeldFiresOnTheTimerCheck() {
        var d = OptionDoubleTap()
        _ = tap(&d, at: 0)
        _ = d.flagsChanged(keyCode: 58, optionDown: true, optionAlone: true, at: 0.2)
        XCTAssertTrue(d.isSecondPressDown, "the tap thread should schedule a check")
        XCTAssertFalse(d.secondPressHeld(at: 0.3), "too early — still a tap in the making")
        XCTAssertTrue(d.secondPressHeld(at: 0.2 + OptionDoubleTap.secondHoldFire))
        XCTAssertFalse(d.flagsChanged(keyCode: 58, optionDown: false, optionAlone: false, at: 1.0),
                       "letting go afterwards does not toggle it shut again")
    }

    func testAHeldSecondOptionDoesNotFireWhenTypedWithOrAlone() {
        var d = OptionDoubleTap()
        _ = d.flagsChanged(keyCode: 58, optionDown: true, optionAlone: true, at: 0)
        XCTAssertFalse(d.isSecondPressDown, "a first press is not a second one")
        XCTAssertFalse(d.secondPressHeld(at: 1.0))
        d = OptionDoubleTap()
        _ = tap(&d, at: 0)
        _ = d.flagsChanged(keyCode: 58, optionDown: true, optionAlone: true, at: 0.2)
        d.interrupt()
        XCTAssertFalse(d.secondPressHeld(at: 0.5), "⌥ + a key — an emoji typed right after a tap")
    }

    func testSlowTapsHoldsRightOptionAndTypingDoNotFire() {
        var d = OptionDoubleTap()
        _ = tap(&d, at: 0); XCTAssertFalse(tap(&d, at: 1.0), "too far apart")
        d = OptionDoubleTap()
        _ = tap(&d, at: 0); XCTAssertFalse(tap(&d, at: 0.2, hold: 0.6), "a held second ⌥ is the timer check's to fire, never the release's")
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
            .init(emoji: "𒑳", count: 30, last: 600),
            .init(emoji: "🧑🏾‍💻", count: 2, last: 600),
        ], catalog: catalog, keyed: ["🍑"])
        XCTAssertEqual(board.slot(for: "🦒"), giraffe, "already placed: untouched")
        XCTAssertEqual(board.slot(for: "😀").map { [$0.column, $0.row] }, [0, 0], "most used takes the anchor")
        XCTAssertEqual(board.slot(for: "😃").map { [$0.column, $0.row] }, [1, 0])
        XCTAssertNil(board.slot(for: "🍑"), "keyed")
        XCTAssertNil(board.slot(for: "𒑳"), "not an emoji the catalogue knows")
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
