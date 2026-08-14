import AppKit

/// The ⌘⌃V modal: the last minute of speech, cleaned, offered at five lengths.
/// Click one (or press its digit) and it goes to the clipboard; the panel closes.
///
/// Centred on the screen the cursor is on rather than on a fixed display — the
/// built-in Retina is what a venue projector mirrors, so a panel pinned there
/// would put a minute of transcript on the wall in front of the room.
@MainActor
final class TranscriptPicker: NSObject {

    /// Borderless panel that may become key, so the digit / arrow keys work.
    /// (Same shape as `CountryPicker`'s; this app is an accessory with no Dock
    /// icon, so it must activate to receive keystrokes at all.)
    private final class PickerPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        var onKeyDown: ((NSEvent) -> Bool)?
        var onResignKey: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if onKeyDown?(event) == true { return }
            super.keyDown(with: event)
        }
        override func resignKey() { super.resignKey(); onResignKey?() }
    }

    /// One rung of the ladder. Draws its own hover highlight — a row you can
    /// click has to say so before you click it.
    private final class SegmentCard: NSView {
        let index: Int
        var onClick: ((Int) -> Void)?
        var isHighlighted = false { didSet { refreshFill() } }
        private var hovering = false { didSet { refreshFill() } }

        init(index: Int, frame: NSRect) {
            self.index = index
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 8
            refreshFill()
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeAlways],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }
        override func mouseUp(with event: NSEvent) { onClick?(index) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

        private func refreshFill() {
            guard !isChosen else { return }   // the flash owns the fill
            let alpha: CGFloat = (hovering || isHighlighted) ? 0.16 : 0.05
            layer?.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
            layer?.borderWidth = isHighlighted ? 1.5 : 0
            layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
        }

        private var isChosen = false

        /// The confirmation flash: a fast rise to a bright amber and a slow decay
        /// back, over `TranscriptPicker.flashDuration`.
        ///
        /// Pressing `4` is a blind gesture — the eye is on the row it wants, the
        /// finger is on a number, and nothing on screen connects the two. Without
        /// this, the panel simply vanishes and you are left trusting that the
        /// digit you pressed was the row you meant. The asymmetry is what makes
        /// it read as a flash rather than a fade: it arrives at once and leaves
        /// slowly, so the row is unmistakable at the instant of the press and the
        /// glow is still there while the panel closes underneath it.
        func flashChosen() {
            isChosen = true
            guard let layer else { return }
            let rest = NSColor(white: 1, alpha: 0.16).cgColor
            let bright = NSColor.systemYellow.withAlphaComponent(0.6).cgColor

            let fill = CAKeyframeAnimation(keyPath: "backgroundColor")
            fill.values = [rest, bright, bright, rest]
            fill.keyTimes = [0, 0.12, 0.28, 1]
            fill.duration = TranscriptPicker.flashDuration
            fill.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // The panel is torn down at the end of this, so what the layer
            // settles back to never matters — but leaving it lit for the whole
            // duration is what keeps the glow visible until the very last frame.
            layer.backgroundColor = bright
            layer.borderWidth = 2
            layer.borderColor = NSColor.systemYellow.cgColor
            layer.add(fill, forKey: "chosen")
        }

        /// The rows that were NOT picked step back so the chosen one is the only
        /// thing left to look at.
        func dimUnchosen() {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.25
            fade.duration = TranscriptPicker.flashDuration * 0.45
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer?.add(fade, forKey: "dim")
        }
    }

    /// How long the confirmation flash runs before the panel closes. A second is
    /// long for a confirmation and deliberately so — this is the one moment that
    /// tells you the digit you pressed hit the row you meant.
    static let flashDuration: CFTimeInterval = 1.0

    private var panel: PickerPanel?
    private var cards: [SegmentCard] = []
    private var segments: [String] = []
    private var highlighted = 0
    private var onPick: ((String) -> Void)?
    /// Set the moment a row is picked: the panel is still on screen for the
    /// length of the flash, but it is no longer a menu.
    private var isDismissing = false

    private let pad: CGFloat = 16
    private let gap: CGFloat = 10
    private let cardPad: CGFloat = 12
    private let badgeWidth: CGFloat = 26
    private let textFont = NSFont.systemFont(ofSize: 14)

    // MARK: Present

    func present(segments: [String], note: String?, onPick: @escaping (String) -> Void) {
        close()
        guard !segments.isEmpty else { return }
        self.segments = segments
        self.onPick = onPick
        self.highlighted = 0
        self.isDismissing = false

        let screen = screenUnderCursor()
        // 820, not 760: measured, two lines of 14 pt system text hold ~203
        // characters at the narrower width and ~223 at this one. The distiller
        // is asked for 180 and lands nearer 205, so the extra 60 pt is the
        // difference between "two lines, as asked" and an occasional third.
        let width = min(820, screen.frame.width * 0.62)
        let innerWidth = width - 2 * pad
        let textWidth = innerWidth - 2 * cardPad - badgeWidth - 8

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.98).cgColor
        content.layer?.cornerRadius = 14

        let header = label(text: "🎙️ Ultimul minut — ce copiez?",
                           font: .systemFont(ofSize: 15, weight: .semibold),
                           color: NSColor(white: 0.95, alpha: 1), width: innerWidth)
        let hintText = note.map { "\($0)  ·  1–\(min(9, segments.count)) / ↑↓ ⏎ · Esc" }
            ?? "1–\(min(9, segments.count)) / ↑↓ ⏎ · Esc"
        let hint = label(text: hintText, font: .systemFont(ofSize: 11),
                         color: NSColor(white: 0.55, alpha: 1), width: innerWidth)

        cards = segments.enumerated().map { index, text in
            makeCard(index: index, text: text, innerWidth: innerWidth, textWidth: textWidth)
        }

        // Lay out bottom-up in flipped-free AppKit coordinates: total height
        // first, then walk down from the top placing each card.
        let cardsHeight = cards.reduce(0) { $0 + $1.frame.height } + CGFloat(max(0, cards.count - 1)) * gap
        let headerBlock = header.frame.height + 4 + hint.frame.height + gap
        let totalHeight = pad + headerBlock + cardsHeight + pad

        content.frame = NSRect(x: 0, y: 0, width: width, height: totalHeight)
        var y = totalHeight - pad - header.frame.height
        header.setFrameOrigin(NSPoint(x: pad, y: y))
        y -= 4 + hint.frame.height
        hint.setFrameOrigin(NSPoint(x: pad, y: y))
        y -= gap
        content.addSubview(header)
        content.addSubview(hint)
        for card in cards {
            y -= card.frame.height
            card.setFrameOrigin(NSPoint(x: pad, y: y))
            content.addSubview(card)
            y -= gap
        }

        let panel = PickerPanel(contentRect: content.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }
        // Clicking away is a dismissal — the picker interrupts whatever was
        // being typed, so it must never be something you have to fight off.
        panel.onResignKey = { [weak self] in self?.close() }
        self.panel = panel

        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2,
                                     y: frame.midY - totalHeight / 2))
        applyHighlight()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        let wasShowing = panel != nil
        panel?.onResignKey = nil
        panel?.onKeyDown = nil
        panel?.orderOut(nil)
        panel = nil
        cards = []
        segments = []
        onPick = nil
        // Hand focus back. Presenting had to `activate` — an accessory app gets
        // no keystrokes otherwise, so the digit shortcuts would be dead — but
        // the next thing that happens after a pick is ⌘V into the app that had
        // focus when the hotkey was pressed, and leaving a menu-bar app frontmost
        // would send that paste nowhere.
        if wasShowing { NSApp.deactivate() }
    }

    var isShowing: Bool { panel != nil }

    // MARK: Build

    private func makeCard(index: Int, text: String, innerWidth: CGFloat, textWidth: CGFloat) -> SegmentCard {
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = textFont
        body.textColor = NSColor(white: 0.93, alpha: 1)
        body.isSelectable = false
        body.drawsBackground = false
        body.isBezeled = false
        body.preferredMaxLayoutWidth = textWidth
        body.frame.size = NSSize(width: textWidth,
                                 height: body.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height)

        // The caption says what KIND of thing this row is ("prompt gata de dat
        // unui agent"), not how long it is. The rows are five different things
        // now, not five lengths of one thing, and a word count answers the
        // question nobody is asking. The `└` ties it to the text above it.
        let caption = TranscriptDistiller.kind(at: index).map { "└ \($0)" }
            ?? "\(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count) cuvinte"
        let meta = label(text: caption, font: .systemFont(ofSize: 10),
                         color: NSColor(white: 0.5, alpha: 1), width: textWidth)

        let height = cardPad + body.frame.height + 3 + meta.frame.height + cardPad
        let card = SegmentCard(index: index, frame: NSRect(x: 0, y: 0, width: innerWidth, height: height))

        // Digit shortcuts only go to 9; past that the badge shows the number as
        // a plain ordinal rather than promising a key that does nothing.
        let badge = label(text: index < 9 ? "\(index + 1)" : "·",
                          font: .monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                          color: NSColor.systemYellow.withAlphaComponent(0.9), width: badgeWidth)
        badge.setFrameOrigin(NSPoint(x: cardPad, y: height - cardPad - badge.frame.height))
        body.setFrameOrigin(NSPoint(x: cardPad + badgeWidth + 8, y: height - cardPad - body.frame.height))
        meta.setFrameOrigin(NSPoint(x: cardPad + badgeWidth + 8, y: cardPad))

        card.addSubview(badge)
        card.addSubview(body)
        card.addSubview(meta)
        card.onClick = { [weak self] i in self?.pick(i) }
        return card
    }

    private func label(text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.drawsBackground = false
        field.isBezeled = false
        field.frame.size = NSSize(width: width,
                                  height: field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        return field
    }

    private func screenUnderCursor() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Interaction

    /// Returns true when the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:  // Esc
            close()
            return true
        case 36, 76:  // Return, keypad Enter
            pick(highlighted)
            return true
        case 125:  // ↓
            highlighted = min(highlighted + 1, segments.count - 1)
            applyHighlight()
            return true
        case 126:  // ↑
            highlighted = max(highlighted - 1, 0)
            applyHighlight()
            return true
        default:
            guard let chars = event.charactersIgnoringModifiers, let digit = Int(chars),
                  (1...9).contains(digit), digit <= segments.count else { return false }
            pick(digit - 1)
            return true
        }
    }

    private func applyHighlight() {
        for (i, card) in cards.enumerated() { card.isHighlighted = (i == highlighted) }
    }

    private func pick(_ index: Int) {
        guard !isDismissing, segments.indices.contains(index) else { return }
        isDismissing = true

        // The clipboard is written NOW, not after the flash. The animation is
        // feedback, not a step in the work — and a second of it is exactly long
        // enough that a fast hand would otherwise ⌘V an empty answer.
        onPick?(segments[index])

        for (i, card) in cards.enumerated() {
            if i == index { card.flashChosen() } else { card.dimUnchosen() }
        }
        // Nothing must be pickable while the flash runs: a second press would
        // copy a second thing over the one just confirmed on screen.
        panel?.onKeyDown = { [weak self] event in
            // …except Esc, which is the one key that should still get you out
            // of a panel you are looking at.
            guard event.keyCode == 53 else { return true }
            self?.close()
            return true
        }
        panel?.onResignKey = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDuration) { [weak self] in
            self?.close()
        }
    }
}
