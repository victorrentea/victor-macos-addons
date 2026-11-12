import AppKit
import Foundation

/// 🧠 How much attention the room has left, as a pure function of the clock.
///
/// An audience lasts about an hour and a quarter between breaks (the same rhythm
/// that turns ⏱️ Resumed yellow), so the battery is full when a break ends and
/// drains linearly to empty over `span`. Past empty it stays at zero and counts
/// how long the room has been running on nothing — that is when it blinks red.
enum BrainEnergy {
    static let defaultSpan: TimeInterval = 75 * 60
    /// A reference older than this belongs to another day: the battery goes idle
    /// instead of blinking red all morning over yesterday's last break.
    static let staleAfter: TimeInterval = 12 * 3600

    enum State: Equatable {
        /// No break today and no manual refill: nothing to measure yet.
        case idle
        /// `level` in 0...1, `remaining` seconds until empty.
        case draining(level: Double, remaining: TimeInterval)
        /// Empty for `overdue` seconds.
        case depleted(overdue: TimeInterval)
    }

    /// The moment the battery was last full: the later of the end of the last
    /// break and a manual refill. One in the future (clock change) or older than
    /// `staleAfter` counts as none.
    static func reference(breakEndedAt: Date?, refilledAt: Date?, now: Date) -> Date? {
        [breakEndedAt, refilledAt].compactMap { $0 }.filter { d in
            let age = now.timeIntervalSince(d)
            return age >= 0 && age <= staleAfter
        }.max()
    }

    static func state(reference: Date?, now: Date, span: TimeInterval = defaultSpan) -> State {
        guard let reference, span > 0 else { return .idle }
        let elapsed = max(0, now.timeIntervalSince(reference))
        if elapsed >= span { return .depleted(overdue: elapsed - span) }
        let remaining = span - elapsed
        return .draining(level: remaining / span, remaining: remaining)
    }

    /// The minutes are a guess about a room, not a measurement — hence "about"
    /// (Victor, 2026-11-12: *"înainte de timpul rămas spune aproximativ"*).
    static func describe(_ state: State) -> String {
        switch state {
        case .idle:
            return "No break yet today"
        case let .draining(level, remaining):
            return "\(Int((level * 100).rounded()))% · about \(minutes(remaining)) left"
        case let .depleted(overdue):
            return overdue < 60 ? "Empty — break now" : "Empty for \(minutes(overdue)) — break now"
        }
    }

    static func minutes(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded(.up))
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}

enum BrainBatterySettings {
    static let enabledKey = "BrainBattery.enabled"
    static let refilledAtKey = "BrainBattery.refilledAt"

    /// 👩🏻‍💻 Extras › 🧠 Show Brain Battery — on by default.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var refilledAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: refilledAtKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: refilledAtKey) }
    }
}

/// The picture: drawn to read as **the macOS battery** sitting next to it — a
/// thin translucent rounded outline, a faint nub, a rounded fill inset from it —
/// except the fill is the pink of the 🧠 emoji, with a small 🧠 on top: vivid
/// over the charge left, faded over the part spent. Empty, it alternates
/// between a solid red battery and a red outline (`blinkOn`, toggled by the caller).
enum BrainBatteryIcon {
    static let brainPink = NSColor(srgbRed: 0.97, green: 0.62, blue: 0.71, alpha: 1)
    static let alarmRed = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    static let size = NSSize(width: 30, height: 16)

    static func image(for state: BrainEnergy.State, blinkOn: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state: state, blinkOn: blinkOn)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Brain battery: " + BrainEnergy.describe(state)
        return image
    }

    static func draw(state: BrainEnergy.State, blinkOn: Bool) {
        // Proportions of the system battery: ~25×12 pt body, 1 pt hairline, the
        // fill inset 2 pt with its own rounding, a nub a third of the height.
        let body = NSRect(x: 1, y: 2, width: 25, height: 12)
        let nub = NSRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4)
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        let inner = body.insetBy(dx: 2, dy: 2)

        var level = 0.0
        var depleted = false
        switch state {
        case .idle: break
        case let .draining(l, _): level = l
        case .depleted: depleted = true
        }

        let stroke: NSColor = depleted ? alarmRed : NSColor.labelColor.withAlphaComponent(0.4)
        stroke.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        (depleted ? alarmRed : NSColor.labelColor.withAlphaComponent(0.4)).setFill()
        NSBezierPath(roundedRect: nub, xRadius: 0.75, yRadius: 0.75).fill()

        let fillWidth: CGFloat = depleted ? (blinkOn ? inner.width : 0) : max(level > 0 ? 2 : 0, inner.width * level)
        if fillWidth > 0 {
            (depleted ? alarmRed : brainPink).setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height),
                         xRadius: 1.75, yRadius: 1.75).fill()
        }

        let emoji = NSAttributedString(string: "🧠", attributes: [.font: NSFont.systemFont(ofSize: 8.5)])
        let es = emoji.size()
        let origin = NSPoint(x: body.midX - es.width / 2, y: body.midY - es.height / 2 + 0.3)
        let splitX = inner.minX + fillWidth
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: NSRect(x: 0, y: 0, width: splitX, height: size.height))
        emoji.draw(at: origin)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.clip(to: NSRect(x: splitX, y: 0, width: size.width - splitX, height: size.height))
        ctx.setAlpha(depleted ? 0.9 : 0.3)
        emoji.draw(at: origin)
        ctx.restoreGState()
    }
}

/// 🧠 **Brain battery** (2026-11-12) — its own menu bar item beside 💬, so the
/// room's remaining attention is read at a glance, never behind a click.
///
/// Refills by itself when a ☕ break ends (`breakEndedAt`, the same instant
/// ⏱️ Resumed counts from); **Refill now** in its menu covers the start of the
/// day or a break taken without the timer. Shown while 👩🏻‍💻 Extras ›
/// 🧠 Show Brain Battery is ticked (default on).
final class BrainBatteryIndicator: NSObject, NSMenuDelegate {
    private let breakEndedAt: () -> Date?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let statusRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var tick: Timer?
    private var blinkTimer: Timer?
    private var blinkOn = true
    private(set) var state: BrainEnergy.State = .idle

    init(breakEndedAt: @escaping () -> Date?) {
        self.breakEndedAt = breakEndedAt
        super.init()
        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())
        let refill = NSMenuItem(title: "Refill now", action: #selector(refillNow), keyEquivalent: "")
        refill.target = self
        menu.addItem(refill)
        menu.delegate = self
    }

    /// Shows or hides the item; called at launch and from the Extras tick.
    func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            statusItem = item
            tick = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
            refresh()
        } else if !visible, let item = statusItem {
            tick?.invalidate(); tick = nil
            blinkTimer?.invalidate(); blinkTimer = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    /// Re-reads the clock; also called the moment a break ends, so the refill
    /// shows at once instead of on the next 10 s tick.
    func refresh() {
        guard statusItem != nil else { return }
        let now = Date()
        let reference = BrainEnergy.reference(breakEndedAt: breakEndedAt(),
                                              refilledAt: BrainBatterySettings.refilledAt, now: now)
        state = BrainEnergy.state(reference: reference, now: now)
        if case .depleted = state {
            if blinkTimer == nil {
                blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.draw()
                }
            }
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = true
        }
        statusRow.title = "🧠 " + BrainEnergy.describe(state)
        draw()
    }

    private func draw() {
        statusItem?.button?.image = BrainBatteryIcon.image(for: state, blinkOn: blinkOn)
        statusItem?.button?.toolTip = "Brain battery: " + BrainEnergy.describe(state)
    }

    @objc private func refillNow() {
        BrainBatterySettings.refilledAt = Date()
        refresh()
    }
}
