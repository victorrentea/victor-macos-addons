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

    func testExternalScreenToRightUsesLeftEdgeAtHalfWidth() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: 1728, y: 0, width: 1920, height: 1080)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame.minX, external.minX, accuracy: 0.001)
        XCTAssertEqual(frame.width, external.width * 0.5, accuracy: 0.001)
        XCTAssertEqual(frame.midY, external.midY, accuracy: 0.001)
    }

    func testExternalScreenToLeftUsesRightEdge() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame.maxX, external.maxX, accuracy: 0.001)
        XCTAssertEqual(frame.width, external.width * 0.5, accuracy: 0.001)
        XCTAssertEqual(frame.midY, external.midY, accuracy: 0.001)
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

    func testExternalScreenAboveUsesBottomEdge() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: 0, y: 1117, width: 1920, height: 1080)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame.minY, external.minY, accuracy: 0.001)
        XCTAssertEqual(frame.midX, external.midX, accuracy: 0.001)
    }

    func testExternalScreenBelowUsesTopEdge() {
        let retina = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let external = NSRect(x: 0, y: -1080, width: 1920, height: 1080)
        let frame = KeymapOverlayPlacement.frame(
            retinaFrame: retina,
            externalFrames: [external],
            imageAspectRatio: 1298.0 / 398.0
        )

        XCTAssertEqual(frame.maxY, external.maxY, accuracy: 0.001)
        XCTAssertEqual(frame.midX, external.midX, accuracy: 0.001)
    }

    func testHoldCoordinatorShowsAfterDelayAndHidesOnOptionRelease() {
        var shown: [KeymapModifier] = []
        var hideCount = 0
        let coordinator = KeymapHoldCoordinator(
            delay: 1.0,
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

    func testHoldCoordinatorDefaultDelayIsSevenTenthsOfASecond() {
        var scheduledDelay: TimeInterval?
        let coordinator = KeymapHoldCoordinator(
            schedule: { delay, _ in scheduledDelay = delay },
            cancelScheduled: {},
            show: { _ in },
            hide: {}
        )

        coordinator.modifierFlagsChanged(option: true, shift: false)

        XCTAssertEqual(scheduledDelay ?? -1, 0.7, accuracy: 0.001)
    }

    func testHoldCoordinatorSwitchesVisibleLayerWhenShiftChanges() {
        var shown: [KeymapModifier] = []
        let coordinator = KeymapHoldCoordinator(
            delay: 1.0,
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
            delay: 1.0,
            schedule: { _, fire in scheduled = fire },
            cancelScheduled: { didCancel = true },
            show: { _ in },
            hide: { hideCount += 1 }
        )

        coordinator.modifierFlagsChanged(option: true, shift: false)
        coordinator.keyDownWhileOptionHeld()
        scheduled?()

        XCTAssertTrue(didCancel)
        XCTAssertEqual(hideCount, 1)
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

        let optionURL = outputDir.appendingPathComponent("keymap-overlay-option-swift.png")
        let optionShiftURL = outputDir.appendingPathComponent("keymap-overlay-option-shift-swift.png")
        try writePNG(option, to: optionURL)
        try writePNG(optionShift, to: optionShiftURL)
        print(String(format: "Generated two keymap overlay images in %.3fs", elapsed))
        print("Rendered keymap overlay previews:")
        print(optionURL.path)
        print(optionShiftURL.path)
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
