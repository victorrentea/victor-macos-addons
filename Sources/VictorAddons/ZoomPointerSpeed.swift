import Foundation
import IOKit.hidsystem

/// 🔎 Slows the mouse down by the zoom factor while `ShareZoom` magnifies, so a small
/// move on the table is a small move on the glass. Without it, at 4× the drawn cursor
/// crossed the picture four times as fast and the slice ran off left and right under
/// the hand (Victor, 2026-10-27: *"la o mișcare mică pe masă îmi fuge foarte rău"*).
///
/// **How: the pointer services' `HIDPointerResolution`**, raised to `factor` × what it
/// was — the knob LinearMouse turns. The HID system divides every move by the device's
/// resolution *before* the acceleration curve, so the curve Victor is used to stays
/// intact and only its scale changes. The other way that exists, decoupling the mouse
/// from the cursor and warping it ourselves (`ZoomLensCursorFence`), gets **raw**
/// deltas with no curve at all, and no constant over them ever felt right (2026-09-23).
///
/// **It outlives a crash**: the property is the device's until it reconnects. So a
/// marker in `UserDefaults` says "raised", and the next launch puts it back.
final class ZoomPointerSpeed {

    /// The HID default when a device publishes none: 400 dpi, as an IOFixed.
    static let defaultResolution = 400 << 16
    private static let key = kIOHIDPointerResolutionKey as CFString
    private static let marker = "ZoomPointerSpeed.raised"

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.zoom-pointer-speed", qos: .userInteractive)
    private let client = ZoomPointerSpeed.monitorClient() ?? IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    /// Each raised service and the resolution it had. Touched only on `queue`.
    private var original: [(service: IOHIDServiceClient, resolution: Int)] = []
    /// The factor last written, on main: `follow` runs at 120 Hz and the factor eases.
    private var written: CGFloat = 1

    init() {
        if UserDefaults.standard.bool(forKey: Self.marker) {
            overlayInfo("🔎 pointer resolution left raised by the last run — reset to the default")
            queue.async { [self] in
                for s in pointerServices() { IOHIDServiceClientSetProperty(s, Self.key, Self.defaultResolution as CFNumber) }
                UserDefaults.standard.set(false, forKey: Self.marker)
            }
        }
    }

    /// Main thread, every zoom tick. Writes only when the factor moved by 3 % or more,
    /// or reached 1 — a few IPCs per wheel notch, none while the zoom holds still.
    func follow(factor: CGFloat) {
        let k = max(factor, 1)
        guard k == 1 ? written != 1 : abs(k / written - 1) >= 0.03 else { return }
        written = k
        queue.async { [self] in apply(k) }
    }

    func restore() { follow(factor: 1) }

    private func apply(_ k: CGFloat) {
        if original.isEmpty {
            guard k > 1 else { return }
            original = pointerServices().map {
                ($0, (IOHIDServiceClientCopyProperty($0, Self.key) as? NSNumber)?.intValue ?? Self.defaultResolution)
            }
            UserDefaults.standard.set(true, forKey: Self.marker)
        }
        var refused = 0
        for (service, resolution) in original {
            let value = k > 1 ? Int((CGFloat(resolution) * k).rounded()) : resolution
            if !IOHIDServiceClientSetProperty(service, Self.key, value as CFNumber) { refused += 1 }
        }
        if refused > 0 { overlayError("🔎 pointer resolution refused by \(refused)/\(original.count) device(s) at \(k)×") }
        if k == 1 {
            overlayInfo("🔎 pointer speed restored on \(original.count) device(s)")
            original = []
            UserDefaults.standard.set(false, forKey: Self.marker)
        }
    }

    /// A *simple* client — the only kind the SDK declares — may read a property but
    /// not set one (`IOHIDServiceClientSetProperty` → false, measured 2026-10-27). A
    /// *monitor* client may, with no entitlement; its constructor is exported, not
    /// declared, hence `dlsym`. Type 1 = `kIOHIDEventSystemClientTypeMonitor`.
    private static func monitorClient() -> IOHIDEventSystemClient? {
        typealias Create = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<IOHIDEventSystemClient>?
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(iokit, "IOHIDEventSystemClientCreateWithType") else { return nil }
        return unsafeBitCast(create, to: Create.self)(kCFAllocatorDefault, 1, nil)?.takeRetainedValue()
    }

    /// Every mouse — on this Mac, the M650 alone. The built-in trackpad publishes no
    /// mouse service, and is left out on purpose: its resolution reads back empty, so
    /// "restoring" it would mean guessing the 400 dpi default for a device that may
    /// not use it.
    private func pointerServices() -> [IOHIDServiceClient] {
        guard let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }
        return all.filter { IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0 }
    }
}
