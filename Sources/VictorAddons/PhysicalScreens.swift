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

/// 🪞 The invisible screen **Victor Mirror** creates (`victor-mirror`, another
/// process since 2026-10-26). Recognised by the vendor it declares, which any
/// process can read, so nothing here needs to talk to it.
enum VirtualDesktop {
    static let vendorID: UInt32 = 0xF00D
    static func isVirtual(_ id: CGDirectDisplayID) -> Bool { CGDisplayVendorNumber(id) == vendorID }
}

/// Where the 🪞 screen belongs: past the rightmost physical screen, top edges
/// aligned. Victor Mirror parks it there itself; `DisplayArrangementManager`
/// puts it there too when it closes up the home layout, in the same
/// transaction, so the two never move it back and forth. Same code in both
/// apps, same tests.
enum VirtualDesktopPlacement {
    /// `nil` when `virtual` is already there.
    static func origin(virtual: CGRect, physical: [CGRect]) -> CGPoint? {
        guard let last = physical.max(by: { $0.maxX < $1.maxX }) else { return nil }
        let target = CGPoint(x: last.maxX, y: last.minY)
        return virtual.origin == target ? nil : target
    }
}
