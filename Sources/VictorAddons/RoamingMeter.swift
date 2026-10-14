import AppKit
import CoreWLAN
import Darwin
import Foundation

/// The pure half of the 📶 roaming meter: what it says, and when it shows.
///
/// Asked for 14 Oct 2026, after the laptop emptied the roaming allowance through
/// the hotspot with no warning reaching anyone. **The phone decides** whether
/// the hotspot is still allowed (`RoamingGuard.kt` in `victor-phone-addons`
/// keeps the last 1 GB out of its reach), because only the phone knows it is
/// roaming right now. This side only shows the number, and keeps it moving
/// between the phone's 5-minute answers by subtracting what this Mac itself
/// has pulled through the hotspot since the phone's reading.
enum RoamingMeterPolicy {

    /// The phone's reading is only trusted for the 20-minute poll's span and a
    /// bit; after that the estimate is shown as one (`~`).
    static let freshFor: TimeInterval = 30 * 60
    static let orangeUnder: Int64 = 3_000_000_000
    static let redUnder: Int64 = 1_500_000_000

    enum Tint: Equatable { case normal, orange, red }

    struct Display: Equatable {
        let title: String
        let tint: Tint
    }

    /// What is left now: the phone's number minus this Mac's hotspot bytes since.
    static func estimate(_ r: RoamingWarningPolicy.Reading, macBytesSince: Int64) -> Int64 {
        max(0, r.remaining - max(0, macBytesSince))
    }

    /// Shown while on the hotspot — unless a fresh reading says the phone is
    /// on its home network, where the hotspot costs nothing against the plan.
    static func visible(onHotspot: Bool, reading r: RoamingWarningPolicy.Reading?, now: Date) -> Bool {
        guard onHotspot else { return false }
        guard let r, now.timeIntervalSince(r.readAt) < freshFor else { return true }
        return r.roamingNow
    }

    static func display(_ r: RoamingWarningPolicy.Reading?, macBytesSince: Int64, now: Date) -> Display {
        guard let r else { return Display(title: "📶 ?", tint: .orange) }
        let left = estimate(r, macBytesSince: macBytesSince)
        let stale = now.timeIntervalSince(r.readAt) >= freshFor
        let icon = r.hotspotBlocked || left < r.reserve ? "📵" : "📶"
        let tint: Tint = left < redUnder ? .red : left < orangeUnder ? .orange : .normal
        return Display(title: "\(icon) \(stale ? "~" : "")\(String(format: "%.1f", Double(left) / 1e9)) GB", tint: tint)
    }
}

/// Bytes through one interface, summed across samples. `if_data` counters are
/// 32-bit and wrap at 4 GiB — a single afternoon on the hotspot — so this keeps
/// its own 64-bit total from deltas taken every few seconds, far below a wrap.
struct InterfaceByteCounter {
    private(set) var total: Int64 = 0
    private var last: UInt32?
    /// (when, total) — enough to answer "since the phone's reading" for 2 hours.
    private var history: [(Date, Int64)] = []

    mutating func add(sample: UInt32?, at now: Date, counting: Bool) {
        defer { last = sample }
        guard let sample, let last else { return }
        if counting { total += Int64(sample &- last) }   // wraps the right way
        history.append((now, total))
        history.removeAll { now.timeIntervalSince($0.0) > 2 * 3600 }
    }

    /// Counted since `date`; everything we hold when the date is older than that.
    func since(_ date: Date) -> Int64 {
        guard let base = history.first(where: { $0.0 >= date }) else { return 0 }
        return total - base.1
    }

    static func read(_ name: String) -> UInt32? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == name,
                  ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            return data.pointee.ifi_ibytes &+ data.pointee.ifi_obytes
        }
        return nil
    }
}

/// 📶 The menu bar meter: `📶 3.2 GB` of roaming left, only while the Mac is on
/// the phone's hotspot. Orange under 3 GB, red under 1.5 GB, 📵 once the
/// phone's 1 GB reserve is reached (the phone then refuses the hotspot itself).
final class RoamingMeter: NSObject, NSMenuDelegate {
    static let autosaveName = "roamingMeter"
    /// Pinned near the clock on first appearance, like 🖥️ (see TartVMIndicator).
    static let preferredPosition = 260
    private static let hotspotSSID = "victor"
    private static let interface = "en0"
    private static let sampleEvery: TimeInterval = 5
    /// While on the hotspot the number matters; ask the phone more often than the
    /// 20-minute background poll.
    private static let askPhoneEvery: TimeInterval = 5 * 60

    private let monitor: PhoneRoamingMonitor
    private var counter = InterfaceByteCounter()
    private var onHotspot = false
    private var lastAskedAt = Date.distantPast
    private var timer: Timer?
    private var statusItem: NSStatusItem?

    init(monitor: PhoneRoamingMonitor) {
        self.monitor = monitor
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleEvery, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    /// Also called after every phone poll, so a new reading shows at once.
    func refresh() { render() }

    private func tick() {
        let now = Date()
        let ssid = CWWiFiClient.shared().interface(withName: Self.interface)?.ssid()
        let was = onHotspot
        onHotspot = ssid == Self.hotspotSSID
        counter.add(sample: InterfaceByteCounter.read(Self.interface), at: now, counting: onHotspot)
        if onHotspot, !was || now.timeIntervalSince(lastAskedAt) > Self.askPhoneEvery {
            lastAskedAt = now
            monitor.pollNow()
        }
        render()
    }

    private func render() {
        let now = Date()
        let r = monitor.reading
        guard RoamingMeterPolicy.visible(onHotspot: onHotspot, reading: r, now: now) else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
            if UserDefaults.standard.object(forKey: positionKey) == nil {
                UserDefaults.standard.set(Self.preferredPosition, forKey: positionKey)
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = Self.autosaveName
            item.isVisible = true
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
            overlayInfo("📶 roaming meter shown (on '\(Self.hotspotSSID)')")
        }
        let since = r.map { counter.since($0.readAt) } ?? 0
        let d = RoamingMeterPolicy.display(r, macBytesSince: since, now: now)
        let color: NSColor? = switch d.tint {
        case .normal: nil
        case .orange: .systemOrange
        case .red: .systemRed
        }
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: d.title,
            attributes: color.map { [.foregroundColor: $0] } ?? [:])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ s: String) {
            let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let gb = RoamingWarningPolicy.gb
        if let r = monitor.reading {
            let since = counter.since(r.readAt)
            let time = DateFormatter.localizedString(from: r.readAt, dateStyle: .none, timeStyle: .short)
            info("Roaming left: \(gb(RoamingMeterPolicy.estimate(r, macBytesSince: since))) of \(gb(r.limit))")
            info("Phone said \(gb(r.remaining)) at \(time) · this Mac pulled \(gb(since)) since")
            info("Resets \(DateFormatter.localizedString(from: r.nextReset, dateStyle: .medium, timeStyle: .none))")
            info(r.hotspotBlocked
                 ? "📵 Under the phone's \(gb(r.reserve)) reserve — it refuses the hotspot"
                 : "The phone refuses the hotspot under \(gb(r.reserve)) left, while roaming")
        } else {
            info("The phone has not answered yet")
        }
        menu.addItem(.separator())
        let ask = NSMenuItem(title: "Ask the phone now", action: #selector(askNow), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)
    }

    @objc private func askNow() {
        lastAskedAt = Date()
        monitor.pollNow()
    }
}
