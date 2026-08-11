import AppKit
import XCTest
@testable import VictorAddons

/// Not an assertion — a darkroom. Renders the real ⌥ / ⌥⇧ sheets to PNG so the
/// drawing can be looked at instead of reasoned about.
final class KeymapSheetDumpTests: XCTestCase {
    func testDumpSheets() throws {
        let out = ProcessInfo.processInfo.environment["KEYMAP_DUMP_DIR"]
        try XCTSkipIf(out == nil, "set KEYMAP_DUMP_DIR to dump the sheets")
        let renderer = KeymapOverlayRenderer()
        for (name, shift) in [("option", false), ("option-shift", true)] {
            let image = renderer.render(outputs: EmojiKeyLayer.snapshot(shift: shift).bindings)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("could not encode \(name)")
                continue
            }
            try png.write(to: URL(fileURLWithPath: out! + "/sheet-\(name).png"))
        }
    }
}
