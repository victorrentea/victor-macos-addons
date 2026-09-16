import AppKit

/// The ⌘⇧V bezel: one remembered clip at a time, centred, Flycut-shaped.
///
/// **It never takes focus.** The panel is `.nonactivatingPanel` and is ordered
/// front regardless, and every key that drives it arrives through
/// `EventTapManager` — the same way the ⌥ cheat-sheet and the ⌃P crosshair
/// work. That is not a detail: the gesture ends by posting ⌘V into *whatever
/// app you were typing in*, and an accessory app that activated itself to read
/// a keystroke would have to hand focus back first and hope the right window
/// took it. Not activating means the target never changed.
///
/// **One clip fills the bezel**, as in Flycut, rather than a scrolling list:
/// the picker is walked with the shortcut itself (hold ⌘⇧, tap V again) and
/// what you are looking for is recognised in one glance, at a size a list
/// cannot give it. For images that size is Victor's: a quarter of the screen's
/// area, centred — big enough to tell two screenshots of the same IDE apart,
/// which is the case that made this feature necessary.
@MainActor
final class ClipboardHistoryOverlay {

    private final class BezelPanel: NSPanel {
        init() {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            ignoresMouseEvents = true
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        }
    }

    private var panel: BezelPanel?
    private var entries: [ClipboardEntry] = []
    private var index = 0
    /// True when the overlay was opened by the hotkey, i.e. with a hand on ⌘⇧:
    /// releasing ⌘ commits and the clip is **pasted**. False when it was opened
    /// from the menu, where there is no modifier to release, nothing is holding
    /// the previous app's focus, and the honest outcome is "it is on your
    /// clipboard" — see `commit()`.
    private var pastesOnCommit = false

    var isShowing: Bool { panel != nil }
    /// Whether letting go of ⌘ finishes this bezel — true only for the one the
    /// hotkey opened. See `pastesOnCommit`.
    var commitsOnCommandRelease: Bool { pastesOnCommit }

    // MARK: - Open / close

    /// - Parameter pastes: see `pastesOnCommit`.
    func open(pastes: Bool) {
        entries = ClipboardHistoryStore.shared.snapshot
        guard !entries.isEmpty else {
            overlayInfo("📋 clipboard history is empty")
            NSSound(named: "Funk")?.play()
            return
        }
        pastesOnCommit = pastes
        // Opening on clip #1 — the current clipboard — is deliberate and is what
        // makes a double-tap of ⌘⇧V a plain paste: the first press shows you
        // what a ⌘V would have done, and every further V steps back in time.
        index = 0
        render()
    }

    /// Step through the list. Wraps, because the list is short and a walk that
    /// dead-ends at the oldest clip makes you release and start again.
    func next() {
        guard isShowing, !entries.isEmpty else { return }
        index = (index + 1) % entries.count
        render()
    }

    func previous() {
        guard isShowing, !entries.isEmpty else { return }
        index = (index - 1 + entries.count) % entries.count
        render()
    }

    /// The digit keys: 1…9 jump straight to that clip. Out-of-range digits are
    /// ignored rather than clamped — pressing 8 on a six-clip history should do
    /// nothing, not silently pick the last one.
    func select(number: Int) {
        guard isShowing, entries.indices.contains(number - 1) else { return }
        index = number - 1
        render()
    }

    /// ⌫ — forget this clip and stay open on the next one. The one destructive
    /// key here, and the reason it is not ⌘⌫ or anything requiring a second
    /// hand: both hands are already holding the shortcut.
    func deleteHighlighted() {
        guard isShowing, entries.indices.contains(index) else { return }
        ClipboardHistoryStore.shared.remove(entries[index])
        entries = ClipboardHistoryStore.shared.snapshot
        guard !entries.isEmpty else { close(); return }
        index = min(index, entries.count - 1)
        render()
    }

    /// Releasing ⌘ (or ⏎) takes the clip.
    func commit() {
        guard isShowing, entries.indices.contains(index) else { close(); return }
        let entry = entries[index]
        let shouldPaste = pastesOnCommit
        close()

        DispatchQueue.global(qos: .userInitiated).async {
            guard ClipboardHistoryStore.shared.place(entry) else {
                overlayError("📋 that clip's file is gone — nothing pasted")
                return
            }
            guard shouldPaste else {
                overlayInfo("📋 clip \(entry.isImage ? "image" : "text") → clipboard")
                return
            }
            // The hand is still coming off ⌘⇧ at this exact moment, and a ⌘V
            // posted into that gets the live modifiers merged in — it would
            // arrive as ⌘⇧V (paste-and-match-style in half the apps on this
            // Mac, and this app's own shortcut in the other half, i.e. an
            // endless re-open). `waitForModifiersReleased` is exactly this
            // trap, found once already by ⌘⌃S; see `KeySimulator`.
            KeySimulator.waitForModifiersReleased()
            KeySimulator.cmdV()
        }
    }

    /// Esc, or any key that is not part of the gesture: the clipboard is left
    /// exactly as it was.
    func cancel() { close() }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        entries = []
    }

    // MARK: - Drawing

    private func render() {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        let screen = screenUnderCursor()
        let visible = screen.visibleFrame

        let body: NSView = entry.isImage
            ? imageView(for: entry, screen: screen)
            : textView(for: entry, visible: visible)

        let footer = footerView(for: entry, width: body.frame.width)
        let hint = label(text: "V next  ·  ↑↓ walk  ·  1–9 jump  ·  ⌫ forget  ·  ⏎ paste  ·  Esc",
                         font: .systemFont(ofSize: 11),
                         color: NSColor(white: 0.5, alpha: 1), width: body.frame.width)

        let pad: CGFloat = 18, gap: CGFloat = 10
        let width = body.frame.width + 2 * pad
        let height = pad + body.frame.height + gap + footer.frame.height + 4 + hint.frame.height + pad

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.97).cgColor
        content.layer?.cornerRadius = 16

        var y = height - pad - body.frame.height
        body.setFrameOrigin(NSPoint(x: pad, y: y))
        y -= gap + footer.frame.height
        footer.setFrameOrigin(NSPoint(x: pad, y: y))
        y -= 4 + hint.frame.height
        hint.setFrameOrigin(NSPoint(x: pad, y: y))
        content.addSubview(body)
        content.addSubview(footer)
        content.addSubview(hint)

        let panel = self.panel ?? BezelPanel()
        panel.contentView = content
        panel.setFrame(NSRect(x: visible.midX - width / 2,
                              y: visible.midY - height / 2,
                              width: width, height: height),
                       display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// **A quarter of the screen's area, centred** — Victor's size for this.
    ///
    /// A quarter of the *area*, not of the width: the box keeps the clip's own
    /// aspect ratio and lands at half the screen's width and half its height
    /// for a full-screen capture, which is the common case here (⌃P).
    ///
    /// It never scales *up* past 1:1. A copied 120×40 button would become a
    /// wall of interpolation at a quarter of a retina, and the size of a clip
    /// is itself information — a tiny image should look tiny.
    private func imageView(for entry: ClipboardEntry, screen: NSScreen) -> NSView {
        guard case .image(let pixelWidth, let pixelHeight, _) = entry.kind,
              pixelWidth > 0, pixelHeight > 0 else {
            return label(text: "(unreadable image)", font: .systemFont(ofSize: 14),
                         color: .systemRed, width: 400)
        }
        let backing = max(1, screen.backingScaleFactor)
        let natural = NSSize(width: CGFloat(pixelWidth) / backing, height: CGFloat(pixelHeight) / backing)
        let visible = screen.visibleFrame
        let targetArea = visible.width * visible.height / 4
        let factor = min(1, sqrt(targetArea / (natural.width * natural.height)))
        let size = NSSize(width: (natural.width * factor).rounded(),
                          height: (natural.height * factor).rounded())

        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        // Loaded here and released with the panel — this is the only moment an
        // image from the history exists in memory (and it is the downscaled
        // copy, not the clip itself). See `ClipboardHistoryStore`.
        view.image = NSImage(contentsOf: ClipboardHistoryStore.shared.displayURL(for: entry))
        return view
    }

    private func textView(for entry: ClipboardEntry, visible: NSRect) -> NSView {
        guard case .text(let string) = entry.kind else { return NSView() }
        let width = min(860, visible.width * 0.5)
        let field = NSTextField(wrappingLabelWithString: ClipboardHistoryPolicy.preview(string))
        field.font = .systemFont(ofSize: 17)
        field.textColor = NSColor(white: 0.95, alpha: 1)
        field.drawsBackground = false
        field.isBezeled = false
        field.isSelectable = false
        field.preferredMaxLayoutWidth = width
        let fitted = field.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        field.frame = NSRect(x: 0, y: 0, width: width, height: fitted.height)
        return field
    }

    /// `3 / 40` on the left, `12 minutes ago` plus the clip's own measure on the
    /// right. The **when** is the whole provenance line: which app a clip came
    /// from is Flycut's answer to a question Victor does not ask — two copies
    /// out of the same editor are told apart by *when*, not by *where*.
    private func footerView(for entry: ClipboardEntry, width: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 18))
        let counter = label(text: "\(index + 1) / \(entries.count)",
                            font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                            color: NSColor.systemYellow.withAlphaComponent(0.9), width: width / 2)
        let measure: String
        switch entry.kind {
        case .image(let w, let h, let bytes):
            measure = "🖼️ \(w)×\(h) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        case .text(let string):
            measure = "📋 \(string.count) chars"
        }
        let age = ClipboardHistoryPolicy.age(Date().timeIntervalSince(entry.copiedAt))
        let right = label(text: "\(age)  ·  \(measure)", font: .systemFont(ofSize: 12),
                          color: NSColor(white: 0.62, alpha: 1), width: width)
        right.alignment = .right
        right.frame = NSRect(x: width - right.frame.width, y: 0, width: right.frame.width, height: row.frame.height)
        counter.frame = NSRect(x: 0, y: 0, width: counter.frame.width, height: row.frame.height)
        row.addSubview(counter)
        row.addSubview(right)
        return row
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

    /// The screen the eye is on, not the built-in one: the retina is what the
    /// room's projector mirrors, and a bezel holding the last thing Victor
    /// copied is not always something the room should read.
    private func screenUnderCursor() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
