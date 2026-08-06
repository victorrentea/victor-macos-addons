import AppKit
import XCTest
@testable import VictorAddons

final class KeymapOverlayTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: KeymapOverlaySettings.enabledKey)
        super.tearDown()
    }

    func testEmojiOverlaySettingDefaultsToEnabledAndPersists() {
        XCTAssertTrue(KeymapOverlaySettings.isEnabled)
        KeymapOverlaySettings.isEnabled = false
        XCTAssertFalse(KeymapOverlaySettings.isEnabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: KeymapOverlaySettings.enabledKey))
    }

    func testModifierMapFindsOptionAndOptionShiftLayers() throws {
        let keylayout = """
        <keyboard>
          <modifierMap id="f4" defaultIndex="7">
            <keyMapSelect mapIndex="3">
              <modifier keys="anyOption"/>
            </keyMapSelect>
            <keyMapSelect mapIndex="4">
              <modifier keys="anyShift caps? anyOption command?"/>
            </keyMapSelect>
          </modifierMap>
        </keyboard>
        """

        XCTAssertEqual(try KeymapLayoutParser.modifierMapIndex(in: keylayout, modifier: .option), "3")
        XCTAssertEqual(try KeymapLayoutParser.modifierMapIndex(in: keylayout, modifier: .optionShift), "4")
    }

    func testExternalScreenToRightFillsEntireExternalScreen() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame, external)
    }

    func testExternalScreenToLeftFillsEntireExternalScreen() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame, external)
    }

    func testNoExternalScreenUsesRetinaBottomRightAtOneThirdWidth() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame.maxX, retina.maxX, accuracy: 0.001)
        XCTAssertEqual(frame.minY, retina.minY, accuracy: 0.001)
        XCTAssertEqual(frame.width, retina.width / 3.0, accuracy: 0.001)
    }

    func testExternalScreenAboveFillsEntireExternalScreen() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: 0, y: 1117, width: 1920, height: 1080)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame, external)
    }

    func testExternalScreenBelowFillsEntireExternalScreen() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: 0, y: -1080, width: 1920, height: 1080)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame, external)
    }

    func testMouseOnExternalFallsBackToRetinaCornerInsteadOfCoveringIt() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        // Cursor is on the external screen — the overlay must NOT land under it,
        // so it falls back to the single-monitor retina bottom-right corner.
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0,
            mouseLocation: CGPoint(x: 2500, y: 500)
        )

        XCTAssertEqual(frame.maxX, retina.maxX, accuracy: 0.001)
        XCTAssertEqual(frame.minY, retina.minY, accuracy: 0.001)
        XCTAssertEqual(frame.width, retina.width / 3.0, accuracy: 0.001)
    }

    func testMouseOnRetinaStillFillsTheExternalScreen() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        // Cursor is on the retina — external placement (the normal case) is kept.
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0,
            mouseLocation: CGPoint(x: 800, y: 500)
        )

        XCTAssertEqual(frame, external)
    }

    func testTwoExternalsPrefersTheRightmostScreen() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        // Victor's 3-monitor home rig: retina + two externals. The cheat-sheet
        // lands on the RIGHT monitor (order in the array must not matter).
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [left, right],
            imageAspectRatio: 1298.0 / 398.0,
            mouseLocation: CGPoint(x: 800, y: 500)
        )

        XCTAssertEqual(frame, right)
    }

    func testMouseOnRightmostExternalFallsBackToTheOtherExternal() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let left = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        // Cursor on the (preferred) right external → overlay goes to the left
        // external, never the one under the mouse.
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [left, right],
            imageAspectRatio: 1298.0 / 398.0,
            mouseLocation: CGPoint(x: 2500, y: 500)
        )

        XCTAssertEqual(frame, left)
    }

    func testHoldCoordinatorShowsAfterDelayAndHidesOnOptionRelease() {
        var shown: [KeymapModifier] = []
        var hideCount = 0
        let coordinator = KeymapHoldCoordinator(
            delayProvider: { 1.0 },
            schedule: { _, fire in fire() },
            cancelScheduled: {},
            show: { shown.append($0) },
            hide: { hideCount += 1 }
        )

        coordinator.modifierFlagsChanged(option: true, shift: false)
        XCTAssertEqual(shown, [.option])

        coordinator.modifierFlagsChanged(option: false, shift: false)
        XCTAssertEqual(hideCount, 1)
    }

    func testDelayIsShorterWithMultipleMonitors() {
        // Single monitor: overlay covers the only screen → longer hold.
        XCTAssertEqual(KeymapHoldCoordinator.delay(monitorCount: 1), 1.0, accuracy: 0.001)
        // Multi-monitor: overlay lands on a secondary screen → quicker.
        XCTAssertEqual(KeymapHoldCoordinator.delay(monitorCount: 2), 0.3, accuracy: 0.001)
        XCTAssertEqual(KeymapHoldCoordinator.delay(monitorCount: 3), 0.3, accuracy: 0.001)
    }

    func testHoldCoordinatorSchedulesUsingDelayProvider() {
        var scheduledDelay: TimeInterval?
        let coordinator = KeymapHoldCoordinator(
            delayProvider: { 0.3 },
            schedule: { delay, _ in scheduledDelay = delay },
            cancelScheduled: {},
            show: { _ in },
            hide: {}
        )

        coordinator.modifierFlagsChanged(option: true, shift: false)

        XCTAssertEqual(scheduledDelay ?? -1, 0.3, accuracy: 0.001)
    }

    func testHoldCoordinatorSwitchesVisibleLayerWhenShiftChanges() {
        var shown: [KeymapModifier] = []
        let coordinator = KeymapHoldCoordinator(
            delayProvider: { 1.0 },
            schedule: { _, fire in fire() },
            cancelScheduled: {},
            show: { shown.append($0) },
            hide: {}
        )

        coordinator.modifierFlagsChanged(option: true, shift: false)
        coordinator.modifierFlagsChanged(option: true, shift: true)

        XCTAssertEqual(shown, [.option, .optionShift])
    }

    func testHoldCoordinatorCancelsAndHidesWhenKeyPressedWhileOptionHeld() {
        var didCancel = false
        var hideCount = 0
        var scheduled: (() -> Void)?
        let coordinator = KeymapHoldCoordinator(
            delayProvider: { 1.0 },
            schedule: { _, fire in scheduled = fire },
            cancelScheduled: { didCancel = true },
            show: { _ in },
            hide: { hideCount += 1 }
        )

        coordinator.modifierFlagsChanged(option: true, shift: false)
        coordinator.keyDownWhileModifierHeld()
        scheduled?()

        XCTAssertTrue(didCancel)
        XCTAssertEqual(hideCount, 1)
    }

    func testSheetResolvesOptionLayersAndTheCommandControlShortcutSheet() {
        XCTAssertEqual(KeymapHoldCoordinator.sheet(option: true, shift: false, command: false, control: false), .option)
        XCTAssertEqual(KeymapHoldCoordinator.sheet(option: true, shift: true, command: false, control: false), .optionShift)
        XCTAssertEqual(KeymapHoldCoordinator.sheet(option: false, shift: false, command: true, control: true), .commandControl)
        // ⇧ doesn't split the ⌘⌃ sheet — there is only one of it.
        XCTAssertEqual(KeymapHoldCoordinator.sheet(option: false, shift: true, command: true, control: true), .commandControl)
    }

    func testSheetShowsNothingForMixedOrIncompleteModifiers() {
        // ⌘⌃⌥ is Dark Mode, not a cheat-sheet.
        XCTAssertNil(KeymapHoldCoordinator.sheet(option: true, shift: false, command: true, control: true))
        // ⌥ with ⌘ (or ⌃) alone is a shortcut prefix, not the character layer.
        XCTAssertNil(KeymapHoldCoordinator.sheet(option: true, shift: false, command: true, control: false))
        XCTAssertNil(KeymapHoldCoordinator.sheet(option: true, shift: false, command: false, control: true))
        // Half of ⌘⌃ isn't ⌘⌃.
        XCTAssertNil(KeymapHoldCoordinator.sheet(option: false, shift: false, command: true, control: false))
        XCTAssertNil(KeymapHoldCoordinator.sheet(option: false, shift: false, command: false, control: true))
        XCTAssertNil(KeymapHoldCoordinator.sheet(option: false, shift: false, command: false, control: false))
    }

    func testHoldCoordinatorShowsCommandControlSheetAfterSameDelay() {
        var shown: [KeymapModifier] = []
        var scheduledDelay: TimeInterval?
        var hideCount = 0
        let coordinator = KeymapHoldCoordinator(
            delayProvider: { 0.3 },
            schedule: { delay, fire in scheduledDelay = delay; fire() },
            cancelScheduled: {},
            show: { shown.append($0) },
            hide: { hideCount += 1 }
        )

        coordinator.modifierFlagsChanged(option: false, shift: false, command: true, control: true)
        XCTAssertEqual(shown, [.commandControl])
        XCTAssertEqual(scheduledDelay ?? -1, 0.3, accuracy: 0.001)

        // Releasing ⌘ leaves a bare ⌃ — no sheet, so it goes away.
        coordinator.modifierFlagsChanged(option: false, shift: false, command: false, control: true)
        XCTAssertEqual(hideCount, 1)
    }

    func testCommandControlLabelsCoverTheBoundKeysWithOneWordEach() {
        // a c e g k l q r s t z — the ⌘⌃ branches in EventTapManager / the menu —
        // plus w, which is Wispr Flow's own ⌘⌃W and is on the sheet for reference
        // only (the tap's ⌃W whip branch excludes Cmd, so we never intercept it),
        // and MINUS v: ⌘⌃V is still bound to the emotional paste but is off the
        // sheet, so "paste" points at exactly one key.
        XCTAssertEqual(CommandControlShortcuts.boundKeyCodes, [0, 8, 14, 5, 40, 37, 12, 15, 1, 17, 13, 6])
        XCTAssertEqual(CommandControlShortcuts.labels[17], "terminal")
        XCTAssertEqual(CommandControlShortcuts.labels[8], "claude")
        XCTAssertEqual(CommandControlShortcuts.labels[6], "zoom")
        XCTAssertEqual(CommandControlShortcuts.labels[14], "email")
        // K / L answer with a pictogram and G with the Gmail mark — a picture is
        // read faster than the word for it.
        XCTAssertEqual(CommandControlShortcuts.labels[40], "📕")
        XCTAssertEqual(CommandControlShortcuts.labels[37], "📅")
        XCTAssertNil(CommandControlShortcuts.labels[5])
        XCTAssertEqual(CommandControlShortcuts.artworkNames[5], "gmail-logo")
        for (code, word) in CommandControlShortcuts.labels {
            XCTAssertFalse(word.contains(" "), "key \(code) label '\(word)' must be a single word")
        }
    }

    func testCornerAccentsMarkOnlyKeysThatAreActuallyBound() {
        XCTAssertEqual(CommandControlShortcuts.accents[14], "@")   // E — email
        XCTAssertEqual(CommandControlShortcuts.accents[6], "🔗")   // Z — Zoom link
        // An accent on an unbound key would decorate a dimmed, meaningless key.
        for code in CommandControlShortcuts.accents.keys {
            XCTAssertTrue(CommandControlShortcuts.boundKeyCodes.contains(code),
                          "key \(code) carries an accent but nothing is bound to it")
        }
    }

    func testArtworkShipsInTheBundleSoTheSheetNeverDrawsAnEmptyKey() {
        // No bundle argument: the default resolves to VictorAddons' own bundle,
        // which is where the artwork ships — not the test target's.
        let images = CommandControlShortcuts.artworkImages()
        for (code, name) in CommandControlShortcuts.artworkNames {
            XCTAssertNotNil(images[code], "artwork '\(name)' (key \(code)) is missing from the bundle")
        }
    }

    func testPictogramLabelsAreDrawnBigButWordsCarryingAnEmojiAreNot() {
        XCTAssertTrue(KeymapOverlayRenderer.isPictogram("📕"))
        XCTAssertTrue(KeymapOverlayRenderer.isPictogram("📅"))
        XCTAssertFalse(KeymapOverlayRenderer.isPictogram("wispr🎙️"))
        XCTAssertFalse(KeymapOverlayRenderer.isPictogram("zoom"))
        XCTAssertFalse(KeymapOverlayRenderer.isPictogram(""))
    }

    func testWordFontShrinksAsTheWordGrows() {
        XCTAssertEqual(KeymapOverlayRenderer.wordFontSize("tile"), 26, accuracy: 0.001)
        XCTAssertEqual(KeymapOverlayRenderer.wordFontSize("claude"), 22, accuracy: 0.001)
        XCTAssertEqual(KeymapOverlayRenderer.wordFontSize("terminal"), 18, accuracy: 0.001)
        XCTAssertEqual(KeymapOverlayRenderer.wordFontSize("calendar"), 18, accuracy: 0.001)
        XCTAssertGreaterThan(KeymapOverlayRenderer.wordFontSize("tile"),
                             KeymapOverlayRenderer.wordFontSize("supercalifragilistic"))

        // Every real WORD label must fit inside a key's 86pt of usable width.
        // Pictograms are exempt: they are drawn at a fixed large size in the
        // payload area, not run through wordFontSize.
        let usableWidth: CGFloat = 86
        for (code, word) in CommandControlShortcuts.labels where !KeymapOverlayRenderer.isPictogram(word) {
            let font = NSFont.boldSystemFont(ofSize: KeymapOverlayRenderer.wordFontSize(word))
            let width = (word as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, usableWidth, "'\(word)' (key \(code)) overflows its key: \(width)")
        }
    }

    func testWordStyleDimsUnboundKeysAndKeepsBoundOnesBright() throws {
        // T (row 1, x 450) is bound; Y (row 1, x 550) is not.
        let image = KeymapOverlayRenderer().render(outputs: [17: "terminal"], style: .word, scale: 1.0)
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            XCTFail("Could not inspect rendered image")
            return
        }

        // Sample the top border of each key — bound draws it opaque, unbound faint.
        // Row 101 is the outer half of the 3px stroke — nothing else paints it,
        // so its alpha IS the border's alpha.
        let boundEdge = bitmap.colorAt(x: 500, y: 101)?.alphaComponent ?? 0
        let unboundEdge = bitmap.colorAt(x: 600, y: 101)?.alphaComponent ?? 0
        XCTAssertGreaterThan(boundEdge, 0.9)
        XCTAssertLessThan(unboundEdge, boundEdge)
    }

    func testOptionOutputsKeepOnlyValuesDifferentFromStoredMacDefaults() {
        let outputs = [
            21: "¢",
            0: "😀",
            41: "…",
        ]

        XCTAssertEqual(KeymapOverlayOutputFilter.customOutputs(from: outputs, modifier: .option), [0: "😀"])
    }

    func testOptionShiftOutputsKeepOnlyValuesDifferentFromStoredMacDefaults() {
        let outputs = [
            21: "›",
            0: "😀",
        ]

        XCTAssertEqual(KeymapOverlayOutputFilter.customOutputs(from: outputs, modifier: .optionShift), [0: "😀"])
    }

    func testRendererSuppressesRequestedPunctuationBaseLabels() {
        XCTAssertEqual(KeymapOverlayRenderer.visibleBaseLabel(";"), "")
        XCTAssertEqual(KeymapOverlayRenderer.visibleBaseLabel("'"), "")
        XCTAssertEqual(KeymapOverlayRenderer.visibleBaseLabel("\\"), "")
        XCTAssertEqual(KeymapOverlayRenderer.visibleBaseLabel("["), "")
        XCTAssertEqual(KeymapOverlayRenderer.visibleBaseLabel("]"), "")
        XCTAssertEqual(KeymapOverlayRenderer.visibleBaseLabel("a"), "A")
    }

    func testRenderedImageOmitsRomanianDiacriticKeyButtonsEntirely() throws {
        let image = KeymapOverlayRenderer().render(outputs: [:], scale: 1.0)
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            XCTFail("Could not inspect rendered image")
            return
        }

        XCTAssertEqual(bitmap.colorAtLogicalPoint(x: 1098, y: 148)?.alphaComponent ?? 1, 0, accuracy: 0.001, "[ key should be transparent")
        XCTAssertEqual(bitmap.colorAtLogicalPoint(x: 1198, y: 148)?.alphaComponent ?? 1, 0, accuracy: 0.001, "] key should be transparent")
        XCTAssertEqual(bitmap.colorAtLogicalPoint(x: 1038, y: 248)?.alphaComponent ?? 1, 0, accuracy: 0.001, "; key should be transparent")
        XCTAssertEqual(bitmap.colorAtLogicalPoint(x: 1138, y: 248)?.alphaComponent ?? 1, 0, accuracy: 0.001, "' key should be transparent")
        XCTAssertEqual(bitmap.colorAtLogicalPoint(x: 1238, y: 248)?.alphaComponent ?? 1, 0, accuracy: 0.001, "\\ key should be transparent")
    }

    func testOverlayWindowStartsAtVisibleOpacityWithNoFade() {
        let window = KeymapOverlayWindow()

        // No initial fade — the window is at full visible opacity from creation.
        XCTAssertEqual(window.alphaValue, KeymapOverlayWindow.visibleOpacity, accuracy: 0.001)
        XCTAssertEqual(KeymapOverlayWindow.visibleOpacity, 1.0, accuracy: 0.001)
    }

    func testOverlayWindowDisplaysAtVisibleOpacityWithNoFade() {
        let window = KeymapOverlayWindow()
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let frame = NSRect(x: 0, y: 0, width: 10, height: 10)

        window.display(image: image, frame: frame)

        XCTAssertEqual(window.alphaValue, KeymapOverlayWindow.visibleOpacity, accuracy: 0.001)
    }

    func testRenderedImageKeepsBackgroundAndKeyGapsTransparent() throws {
        let image = KeymapOverlayRenderer().render(outputs: [:], scale: 1.0)
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            XCTFail("Could not inspect rendered image")
            return
        }

        XCTAssertEqual(bitmap.colorAt(x: 1297, y: 397)?.alphaComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(bitmap.colorAt(x: 98, y: 48)?.alphaComponent ?? 1, 0, accuracy: 0.001)
    }

    func testRenderedKeysHaveSlightlyRoundedCorners() throws {
        let image = KeymapOverlayRenderer().render(outputs: [:], scale: 1.0)
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            XCTFail("Could not inspect rendered image")
            return
        }

        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertGreaterThan(bitmap.colorAt(x: 12, y: 12)?.alphaComponent ?? 0, 0.9)
    }

    func testRenderPreviewImagesWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["RENDER_KEYMAP_OVERLAY_PREVIEW"] == "1" else {
            throw XCTSkip("Set RENDER_KEYMAP_OVERLAY_PREVIEW=1 to render preview PNGs")
        }
        let outputDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYMAP_OVERLAY_PREVIEW_DIR"] ?? FileManager.default.currentDirectoryPath)
        guard let name = KeymapLayoutLocator.activeLayoutName(),
              let url = KeymapLayoutLocator.keylayoutURL(named: name) else {
            XCTFail("Could not locate active .keylayout")
            return
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let renderer = KeymapOverlayRenderer()
        let started = CFAbsoluteTimeGetCurrent()
        let option = renderer.render(outputs: try KeymapLayoutParser.outputs(in: text, modifier: .option))
        let optionShift = renderer.render(outputs: try KeymapLayoutParser.outputs(in: text, modifier: .optionShift))
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let commandControl = renderer.render(
            outputs: CommandControlShortcuts.labels,
            style: .word,
            artwork: CommandControlShortcuts.artworkImages(),
            accents: CommandControlShortcuts.accents
        )

        let optionURL = outputDir.appendingPathComponent("keymap-overlay-option-swift.png")
        let optionShiftURL = outputDir.appendingPathComponent("keymap-overlay-option-shift-swift.png")
        let commandControlURL = outputDir.appendingPathComponent("keymap-overlay-command-control-swift.png")
        try writePNG(option, to: optionURL)
        try writePNG(optionShift, to: optionShiftURL)
        try writePNG(commandControl, to: commandControlURL)
        print(String(format: "Generated two keymap overlay images in %.3fs", elapsed))
        print("Rendered keymap overlay previews:")
        print(optionURL.path)
        print(optionShiftURL.path)
        print(commandControlURL.path)
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "KeymapOverlayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG"])
        }
        try png.write(to: url)
    }
}

private extension NSBitmapImageRep {
    func colorAtLogicalPoint(x: Int, y: Int) -> NSColor? {
        colorAt(x: x, y: y)
    }
}
