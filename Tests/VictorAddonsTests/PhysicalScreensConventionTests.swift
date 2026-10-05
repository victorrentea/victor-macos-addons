import XCTest

/// Overlays pick their screens from `NSScreen.physical`, never `NSScreen.screens`.
///
/// **Why a test that reads the source.** 🪞 `VirtualDesktop`'s screen is invisible
/// to Victor and shared to the room; a new overlay written the obvious way —
/// `for screen in NSScreen.screens` — compiles, works on his desk, and broadcasts to
/// Zoom whatever he thinks only he can see. That is how the keymap and the banners
/// landed there on 2026-10-05. Nothing at runtime can tell the mistake apart.
final class PhysicalScreensConventionTests: XCTestCase {

    /// Files that must see the virtual screen, or only read the **primary** screen
    /// (`screens.first`) to flip coordinates.
    private static let allowed: Set<String> = [
        "PhysicalScreens.swift",   // the filter itself
        "VirtualDesktop.swift",    // creates and fills it
        "ShareZoom.swift",         // films every screen, the virtual one included
        "KnownDisplays.swift",     // names displays by id
        "DisplayNameCache.swift",  // idem
        "MenuBarManager.swift",    // only the screen under the pointer / the primary
    ]

    func testOverlaysNeverEnumerateTheVirtualScreen() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VictorAddons")
        var offenders: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name.hasSuffix(".swift") && !Self.allowed.contains(name) {
            let src = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for (i, line) in src.components(separatedBy: "\n").enumerated()
            where line.contains("NSScreen.screens")
                && !line.contains("NSScreen.screens.first?.")
                && !line.contains("NSScreen.screens.first else")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                offenders.append("\(name):\(i + 1)")
            }
        }
        XCTAssertEqual(offenders, [], "use NSScreen.physical — NSScreen.screens includes 🪞 VirtualDesktop's shared screen")
    }
}
