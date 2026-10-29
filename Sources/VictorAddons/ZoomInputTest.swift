import AppKit
import ScreenCaptureKit

/// `/test/zoom-input` — drives the 🔍/🔎 zoom gestures with **real** HID events, posted
/// by this app (it holds Accessibility; an agent's shell does not), so they cross the
/// same two taps a hand would: the ⌥+scroll HID tap and the session tap.
///
/// - `do=click` — ⌥ + wheel click at the pointer, the `ZoomEngine` flip.
/// - `do=record-start` / `do=record-stop` — `ZoomScrollRecorder`: a hand's ⌥+scroll and
///   the magnifier's factor, written to a JSON file.
/// - `do=scroll&lines=N&n=K` — K ⌥+scroll events of N lines each (notched wheel).
/// - `do=move&dx=N&n=K` — K mouse moves of N points right each, from where the pointer
///   is; answers where it started and ended, so `ZoomPointerSpeed`'s scaling can be read
///   off (desktop distance × factor = glass distance).
/// - `do=shot&display=<name part>&path=<png>` — a ScreenCaptureKit screenshot of that
///   display **with the cursor** (`showsCursor`), written asynchronously. The one capture
///   that shows whether the real cursor is up beside ShareZoom's drawn one;
///   `screencapture -C` draws it even while hidden.
///
/// The magnifier ignores synthetic scrolls, so this proves the routing, not that a
/// physical ⌥+scroll no longer reaches `AXVisualSupportAgent` — the tap list does that.
enum ZoomInputTest {
    static func run(_ q: [String: String]) -> String {
        let src = CGEventSource(stateID: .hidSystemState)
        switch q["do"] {
        case "record-start":
            return ZoomScrollRecorder.shared.start()
        case "record-stop":
            return ZoomScrollRecorder.shared.stop()
        case "click":
            let at = CGEvent(source: nil)?.location ?? .zero
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: at,
                                      mouseButton: .center) else { continue }
                e.flags = [.maskAlternate]
                e.post(tap: .cghidEventTap)
                usleep(20_000)
            }
            return "{\"posted\":\"⌥ + wheel click\"}"
        case "scroll":
            let lines = Int32(q["lines"] ?? "1") ?? 1
            let n = Int(q["n"] ?? "1") ?? 1
            DispatchQueue.global().async {
                for _ in 0..<n {
                    guard let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1,
                                          wheel1: lines, wheel2: 0, wheel3: 0) else { continue }
                    e.flags = [.maskAlternate]
                    e.post(tap: .cghidEventTap)
                    usleep(30_000)
                }
            }
            return "{\"posting\":\(n),\"lines\":\(lines)}"
        case "move":
            let dx = Double(q["dx"] ?? "10") ?? 10
            let n = Int(q["n"] ?? "20") ?? 20
            let start = CGEvent(source: nil)?.location ?? .zero
            for _ in 0..<n {
                let at = CGEvent(source: nil)?.location ?? .zero
                guard let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                                      mouseCursorPosition: CGPoint(x: at.x + dx, y: at.y),
                                      mouseButton: .left) else { continue }
                e.setDoubleValueField(.mouseEventDeltaX, value: dx)
                e.setDoubleValueField(.mouseEventDeltaY, value: 0)
                e.post(tap: .cghidEventTap)
                usleep(30_000)
            }
            usleep(100_000)
            let end = CGEvent(source: nil)?.location ?? .zero
            return "{\"start\":[\(start.x),\(start.y)],\"end\":[\(end.x),\(end.y)],\"posted\":\(Double(n) * dx)}"
        case "shot":
            let part = q["display"] ?? "DELL"
            let path = q["path"] ?? "/tmp/zoom-shot.png"
            guard #available(macOS 14.0, *) else { return "{\"error\":\"macOS 14+\"}" }
            Task { await shot(displayNamed: part, to: path) }
            return "{\"shooting\":\"\(path)\"}"
        default:
            return "{\"error\":\"do=click|scroll|move|shot\"}"
        }
    }

    @available(macOS 14.0, *)
    private static func shot(displayNamed part: String, to path: String) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screen = await MainActor.run {
                NSScreen.physical.first { $0.localizedName.contains(part) }
                    .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
            }
            guard let id = screen, let display = content.displays.first(where: { $0.displayID == id }) else {
                overlayError("🧪 zoom-input shot: no display matching \(part)")
                return
            }
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            overlayError("🧪 zoom-input shot failed: \(error)")
        }
    }
}
