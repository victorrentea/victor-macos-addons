import Cocoa

/// The words on the bottom-left pill's buttons (2026-11-03).
///
/// **An enum, not free text** (Victor: *"labelurile butoanelor să fie enumuri"*):
/// every pill in the app draws from one vocabulary, so the same decision reads
/// the same way on every pill, and a new pill cannot invent a fifth word for
/// "no".
enum BannerAction: String, CaseIterable {
    case send = "Send"
    case cancel = "Cancel"
    case drop = "Drop"
    case keep = "Keep"
    case undo = "Undo"
    case start = "Start"
    case later = "Later"
    case open = "Open"
    case dismiss = "Dismiss"
    case snooze = "Snooze"
    case snoozeHour = "Snooze 1h"
    /// The 👂/🔋 pill: stops the battery recording until the charger is back.
    case stopUntilAC = "Stop (until AC)"

    var title: String { rawValue }

    /// A picture right after the word, where one says it faster (Victor: *"drop
    /// să aibă un 🗑️, iar send … un glyph de avion de hârtie"*).
    enum Glyph: Equatable {
        case emoji(String)
        /// An SF Symbol, tinted like the title.
        case symbol(String)
    }

    var glyph: Glyph? {
        switch self {
        case .drop: return .emoji("🗑️")
        case .send: return .symbol("paperplane.fill")
        case .snoozeHour: return .emoji("⏱️")
        case .stopUntilAC: return .emoji("❌")
        default: return nil
        }
    }

    /// The button's whole title: the word, a space, the glyph (after the word,
    /// Victor: *"emojiul să fie după label"*).
    func attributedTitle(font: NSFont, color: NSColor) -> NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color,
                                                    .paragraphStyle: centred]
        let out = NSMutableAttributedString(string: title, attributes: attrs)
        switch glyph {
        case .emoji(let e)?:
            out.append(NSAttributedString(string: " " + e, attributes: attrs))
        case .symbol(let name)?:
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: title)?
                .withSymbolConfiguration(config) {
                let att = NSTextAttachment()
                att.image = img
                // Sit the symbol on the text's optical centre, not its baseline.
                att.bounds = NSRect(x: 0, y: (font.capHeight - img.size.height) / 2,
                                    width: img.size.width, height: img.size.height)
                out.append(NSAttributedString(string: " ", attributes: attrs))
                out.append(NSAttributedString(attachment: att))
            }
        case nil:
            break
        }
        // An attachment carries no paragraph style of its own: re-centre the lot.
        out.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: out.length))
        return out
    }
}

/// One button in the pill's right-hand column.
///
/// Drawn by hand rather than an `NSButton`: the top button carries the
/// countdown **as its own background** — the bar fills left to right behind
/// the label as the auto-action approaches — and a bezel cannot be filled.
/// The shape is the standard macOS push button's: a rounded rectangle, a hair
/// border, the title centred.
final class BannerButtonView: NSView {
    static let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    static var cornerRadius: CGFloat { BottomLeftBanner.Style.cornerRadius }
    static let horizontalPadding: CGFloat = 14
    static let minWidth: CGFloat = 76
    static let progressColor = NSColor.systemOrange.withAlphaComponent(0.75)

    var onPress: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let fill = CALayer()
    private let progressLayer = CALayer()
    private var pressed = false
    private var hovered = false
    private var isDark = true
    private(set) var action: BannerAction?
    private(set) var progress: CGFloat = 0

    override init(frame: NSRect) {
        BackgroundCursor.enable()
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.addSublayer(fill)
        layer?.addSublayer(progressLayer)
        progressLayer.backgroundColor = Self.progressColor.cgColor
        label.font = Self.font
        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Width that fits the longest of `actions` — one column width for both
    /// buttons, so they line up as a pair.
    static func width(for actions: [BannerAction]) -> CGFloat {
        let widest = actions.map { a -> CGFloat in
            let probe = NSTextField(labelWithAttributedString: a.attributedTitle(font: font, color: .white))
            probe.sizeToFit()
            return ceil(probe.frame.width)
        }.max() ?? 0
        return max(minWidth, widest + 2 * horizontalPadding)
    }

    func configure(_ action: BannerAction, textColor: NSColor, isDark: Bool) {
        self.action = action
        self.isDark = isDark
        label.attributedStringValue = action.attributedTitle(font: Self.font, color: textColor)
        hovered = false
        applyColors()
        setProgress(0)
        needsLayout = true
    }

    /// Rest and hover shades. Hover is brighter and gets a stronger edge — the
    /// "this is a button" cue, alongside the pointing hand.
    private func applyColors() {
        let fillAlpha: CGFloat = isDark ? (hovered ? 0.32 : 0.16) : (hovered ? 0.16 : 0.07)
        let edgeAlpha: CGFloat = isDark ? (hovered ? 0.6 : 0.28) : (hovered ? 0.4 : 0.18)
        let base: NSColor = isDark ? .white : .black
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = base.withAlphaComponent(fillAlpha).cgColor
        layer?.borderColor = base.withAlphaComponent(edgeAlpha).cgColor
        CATransaction.commit()
    }

    // MARK: Hover — pointing hand + highlight.
    //
    // The panel is non-activating and never key, so cursor rects are never
    // consulted; an always-active tracking area sets the cursor itself, and
    // again on every move, since the app underneath may reset it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func cursorUpdate(with _: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyColors()
        NSCursor.pointingHand.set()
        super.mouseEntered(with: event)   // the pill still pauses its countdown
    }

    override func mouseMoved(with _: NSEvent) {
        if hovered { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyColors()
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }

    /// 0…1 of the auto-action's countdown, drawn behind the title.
    func setProgress(_ p: CGFloat) {
        progress = max(0, min(1, p))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.frame = NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        progressLayer.frame = NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
        CATransaction.commit()
        label.sizeToFit()
        label.frame = NSRect(x: 0, y: (bounds.height - label.frame.height) / 2,
                             width: bounds.width, height: label.frame.height)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with _: NSEvent) {
        pressed = true
        layer?.opacity = 0.6
    }

    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            // The pill leaves on a press, and a view that is gone never gets
            // its mouseExited: hand the arrow back now.
            hovered = false
            NSCursor.arrow.set()
            onPress?()
        }
    }

    /// A right-click on a button is still the pill's right-click.
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)   // up the responder chain to the pill
    }
}

/// Lets this app change the cursor while another app is frontmost.
///
/// The pill lives in a non-activating panel, so the app is almost never
/// active while the pointer is on a button, and the window server ignores a
/// background app's `NSCursor.set()`. `SetsCursorInBackground` on our own
/// connection is the switch that lifts that — private SkyLight API, the one
/// Hammerspoon and the window managers use, looked up at run time so a future
/// macOS without it only loses the hand.
enum BackgroundCursor {
    private static var done = false

    static func enable() {
        guard !done else { return }
        done = true
        typealias MainConn = @convention(c) () -> Int32
        typealias SetProp = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let h = dlopen(nil, RTLD_NOW),
              let c = dlsym(h, "_CGSDefaultConnection"),
              let sp = dlsym(h, "CGSSetConnectionProperty") else {
            overlayInfo("🖱️ background cursor: SkyLight symbols not found")
            return
        }
        let cid = unsafeBitCast(c, to: MainConn.self)()
        let err = unsafeBitCast(sp, to: SetProp.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        overlayInfo("🖱️ background cursor enabled (err \(err))")
    }
}
