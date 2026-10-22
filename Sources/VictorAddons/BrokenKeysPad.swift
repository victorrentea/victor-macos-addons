import AppKit

/// 🩹 F2 → a mini keyboard of the keys that are dead on the physical keyboard
/// (the `~ 1 Q A Z` column, since 2026-10-08), centred on the mouse, each one
/// typed into the app in front by clicking it. The second way in, next to the
/// right ⌘⌥ stand-ins in `EventTapManager`; this one needs no chord to learn.
///
/// The keys sit where they sit on the real (ANSI) keyboard — the row stagger is
/// the true one in key units: `~` at 0 and `1` at 1 on the number row, Q at 1.5
/// (Tab is 1.5u), A at 1.75 (Caps Lock is 1.75u), Z at 2.25 (left Shift is
/// 2.25u). The hand reaches for them by memory, so the pad keeps the memory.
///
/// **Lifetime:** gone by itself 5 s after the mouse was last on it. The pad
/// opens *under* the pointer, so being under the pointer only counts once the
/// pointer has moved (or a key was clicked) — otherwise an F2 pressed and
/// forgotten would stay up forever. F2 again or a click elsewhere closes it.
///
/// The panel never takes focus (`nonactivatingPanel`, never key), so the app
/// underneath keeps its caret and the clicked key lands there. A modifier held
/// while clicking rides along: ⇧ gives `~ ! Q A Z`, and ⌘ gives ⌘Q / ⌘A / ⌘Z,
/// three shortcuts the dead keys had taken away too.
@MainActor
final class BrokenKeysPad {

    struct Key {
        let code: CGKeyCode
        let plain: String
        let shifted: String
        /// Left edge, in key units from the left of the number row.
        let column: CGFloat
        let row: Int
    }

    static let keys: [Key] = [
        Key(code: 0x32, plain: "`", shifted: "~", column: 0, row: 0),
        Key(code: 0x12, plain: "1", shifted: "!", column: 1, row: 0),
        Key(code: 0x0C, plain: "q", shifted: "Q", column: 1.5, row: 1),
        Key(code: 0x00, plain: "a", shifted: "A", column: 1.75, row: 2),
        Key(code: 0x06, plain: "z", shifted: "Z", column: 2.25, row: 3),
    ]

    static let unit: CGFloat = 48
    static let gap: CGFloat = 6
    static let inset: CGFloat = 10
    static let idleClose: TimeInterval = 5

    private var panel: BrokenKeysPadPanel?
    private var padView: BrokenKeysPadView?
    private var ticker: Timer?
    private var outsideClick: Any?
    private var spawnPoint: NSPoint = .zero
    private var engaged = false
    private var lastOnPad = Date()

    nonisolated init() {}

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { close() } else { show(at: NSEvent.mouseLocation) }
    }

    /// `center` in global Cocoa points — the mouse for F2, any point for the
    /// test hook, so a test never has to move the pointer.
    func show(at center: NSPoint) {
        close()
        let size = Self.padSize
        let screen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        let frame = NSRect(origin: origin, size: size)
        let panel = BrokenKeysPadPanel(frame: frame)
        let view = BrokenKeysPadView(frame: NSRect(origin: .zero, size: size))
        view.onType = { [weak self] key in self?.type(key) }
        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
        self.padView = view

        spawnPoint = NSEvent.mouseLocation
        engaged = false
        lastOnPad = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close("(click elsewhere)") }
        }
        overlayInfo("BrokenKeysPad: shown at \(Int(center.x)),\(Int(center.y))")
    }

    func close(_ why: String = "") {
        if panel != nil { overlayInfo("BrokenKeysPad: closed \(why)") }
        ticker?.invalidate()
        ticker = nil
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        panel?.orderOut(nil)
        panel = nil
        padView = nil
    }

    private func tick() {
        guard let panel, let padView else { return }
        let mouse = NSEvent.mouseLocation
        let inside = NSMouseInRect(mouse, panel.frame, false)
        if inside, mouse != spawnPoint { engaged = true }
        if inside, engaged { lastOnPad = Date() }

        let local = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        padView.hovered = inside ? padView.keyIndex(at: local) : nil

        if Date().timeIntervalSince(lastOnPad) > Self.idleClose { close("(idle)") }
    }

    private func type(_ key: Key) {
        engaged = true
        lastOnPad = Date()
        let held = KeySimulator.heldModifiers()
        let text = held.contains(.maskShift) ? key.shifted : key.plain
        let utf16 = Array(text.utf16)
        overlayInfo("BrokenKeysPad: typing \(text) (keycode \(key.code), flags \(held.rawValue)) into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = held
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static var padSize: NSSize {
        let columns = keys.map { $0.column }.max()! + 1
        let rows = CGFloat(keys.map { $0.row }.max()! + 1)
        return NSSize(width: 2 * inset + columns * unit - gap, height: 2 * inset + rows * unit - gap)
    }

    /// Key frame in the pad's (flipped: row 0 on top) view coordinates.
    static func frame(of key: Key) -> NSRect {
        NSRect(x: inset + key.column * unit, y: inset + CGFloat(key.row) * unit,
               width: unit - gap, height: unit - gap)
    }
}

/// Clicked without ever taking focus — same recipe as `EmojiPickerPanel`.
final class BrokenKeysPadPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        // Set explicitly, not left at the default: a clear, non-opaque window
        // lets clicks fall through to the app underneath, and the pad's
        // first build swallowed none of them (2026-10-23).
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The plate and the keycaps, drawn in one view: five keys do not earn five views.
final class BrokenKeysPadView: NSView {
    var onType: ((BrokenKeysPad.Key) -> Void)?
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed: Int? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func keyIndex(at point: NSPoint) -> Int? {
        // `point` comes in unflipped (Cocoa, y up) from the controller.
        let flipped = NSPoint(x: point.x, y: bounds.height - point.y)
        return BrokenKeysPad.keys.firstIndex { BrokenKeysPad.frame(of: $0).contains(flipped) }
    }

    private func keyIndex(of event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return BrokenKeysPad.keys.firstIndex { BrokenKeysPad.frame(of: $0).contains(p) }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = keyIndex(of: event)
        overlayInfo("BrokenKeysPad: mouseDown on key \(pressed.map(String.init) ?? "none")")
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let index = pressed, keyIndex(of: event) == index else { return }
        onType?(BrokenKeysPad.keys[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()

        for (index, key) in BrokenKeysPad.keys.enumerated() {
            let rect = BrokenKeysPad.frame(of: key)
            let fill: NSColor = index == pressed ? .controlAccentColor
                : index == hovered ? NSColor(white: 0.36, alpha: 1) : NSColor(white: 0.22, alpha: 1)
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

            // A real keycap: a letter shows once, uppercase; a symbol key shows
            // its shifted glyph over the plain one.
            if key.plain.uppercased() == key.shifted {
                draw(key.shifted, size: 20, in: rect)
            } else {
                let top = NSRect(x: rect.minX, y: rect.minY + 2, width: rect.width, height: rect.height / 2)
                let bottom = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: rect.height / 2)
                draw(key.shifted, size: 15, in: top)
                draw(key.plain, size: 15, in: bottom)
            }
        }
    }

    private func draw(_ text: String, size: CGFloat, in rect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let s = string.size()
        string.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
    }
}
