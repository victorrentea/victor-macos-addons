import AppKit

/// The screens Victor can actually see: `NSScreen.screens` minus 🪞 `VirtualDesktop`'s
/// invisible one.
///
/// That screen exists only to be shared in Zoom/Teams, so anything drawn on it is
/// broadcast to the room without Victor ever seeing it — the keymap, banners, the
/// break timer all landed there once it went live (2026-10-05). Every overlay picks
/// its screens from here; only `VirtualDesktop` and `ShareZoom` (which film it) and
/// the `screencapture -D` numbering (which counts it) read the raw list.
extension NSScreen {
    static var physical: [NSScreen] {
        screens.filter { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return true }
            return !VirtualDesktop.isVirtual(id.uint32Value)
        }
    }
}

/// Same filter for the CoreGraphics display lists.
func physicalDisplayIDs(_ ids: some Sequence<CGDirectDisplayID>) -> [CGDirectDisplayID] {
    ids.filter { !VirtualDesktop.isVirtual($0) }
}
