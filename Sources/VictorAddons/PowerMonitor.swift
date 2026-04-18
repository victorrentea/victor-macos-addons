import Foundation
import IOKit.ps

class PowerMonitor {
    var onSwitchToBattery: (() -> Void)?
    var onSwitchToAC: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var lastIsAC: Bool?

    func start() {
        lastIsAC = Self.isOnAC()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().powerSourceChanged()
        }, ctx) else { return }
        runLoopSource = src.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        overlayInfo("PowerMonitor started, on AC: \(Self.isOnAC())")
    }

    private func powerSourceChanged() {
        let isAC = Self.isOnAC()
        guard isAC != lastIsAC else { return }
        lastIsAC = isAC
        overlayInfo("Power source changed: AC=\(isAC)")
        if isAC { onSwitchToAC?() } else { onSwitchToBattery?() }
    }

    static func isOnAC() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as! [CFTypeRef]
        for src in list {
            if let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return true
    }
}
