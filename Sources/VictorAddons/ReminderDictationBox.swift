import AppKit

/// 🎙️ ⌘⌃M with nothing to mail: nothing selected and a clipboard nobody touched
/// in the last `ReminderMail.clipboardFreshness` seconds. Instead of guessing,
/// a large text box opens in the middle of the screen under the pointer, ready
/// for Walkie Talkie to dictate into. ⏎ mails it as a 🔔 reminder, ⇧⏎ (or ⌥⏎)
/// breaks the line, Esc drops it.
///
/// **It grows with the words.** One line of big type to start with, wider as the
/// line lengthens up to `maxWidthFraction` of the screen, then taller as it
/// wraps — always re-centred on the screen's middle, so the text stays where
/// the eye already is.
///
/// **It does not close when it loses focus**, unlike `TranscriptPicker`: a
/// dictation overlay that takes the key window for a moment would otherwise
/// throw away a sentence half spoken. Only ⏎ and Esc end it.
///
/// **Held ⌘⌃M (2026-11-13)** opens the same box on purpose, whatever the
/// clipboard holds, with the screen under the pointer already captured (before
/// the box existed, so the box is not in it) and mailed inline under the words.
///
/// Opens on the screen the pointer is on, never pinned to the Retina — that one
/// is what the room's projector shows.
@MainActor
final class ReminderDictationBox: NSObject, NSTextViewDelegate {

    private final class BoxPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private let font = NSFont.systemFont(ofSize: 36, weight: .regular)
    private let hintFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let pad: CGFloat = 28
    private let hintGap: CGFloat = 10
    private let minTextWidth: CGFloat = 520
    private let maxWidthFraction: CGFloat = 0.7
    private let maxHeightFraction: CGFloat = 0.7

    private var panel: BoxPanel?
    private var textView: NSTextView?
    private var scroll: NSScrollView?
    private var hint: NSTextField?
    private var screen: NSScreen?
    private var onSend: ((String, ReminderMail.Clipping.Image?) -> Void)?
    /// The screen captured by a **held** ⌘⌃M, mailed with the words. With one
    /// attached, ⏎ on an empty box sends the picture alone.
    private var image: ReminderMail.Clipping.Image?

    var isShowing: Bool { panel != nil }

    /// Open the box (or bring it back to the front if it is already open — a
    /// second ⌘⌃M must not throw away what was dictated so far).
    ///
    /// An open box keeps the screenshot it already has: a second capture would
    /// be a picture of the box itself.
    func show(prefill: String = "", image: ReminderMail.Clipping.Image? = nil,
              onSend: @escaping (String, ReminderMail.Clipping.Image?) -> Void) {
        self.onSend = onSend
        if let panel {
            if !prefill.isEmpty { textView?.string = prefill; relayout() }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(textView)
            return
        }
        self.image = image
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.physical.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        self.screen = screen

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        content.layer?.cornerRadius = 22
        content.layer?.borderWidth = 1.5
        content.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.8).cgColor

        let textView = NSTextView()
        textView.font = font
        textView.textColor = NSColor(white: 0.96, alpha: 1)
        textView.insertionPointColor = .systemOrange
        textView.alignment = .center
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor(white: 0.96, alpha: 1),
                                     .paragraphStyle: centered()]
        textView.delegate = self

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = textView

        let hint = NSTextField(labelWithString: image == nil
            ? "🔔 dictează · ⏎ trimite · ⇧⏎ rând nou · esc renunță"
            : "🔔 + 📸 ecranul · ⏎ trimite · ⇧⏎ rând nou · esc renunță")
        hint.font = hintFont
        hint.textColor = NSColor(white: 0.6, alpha: 1)
        hint.alignment = .center

        content.addSubview(scroll)
        content.addSubview(hint)

        let panel = BoxPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content

        self.panel = panel
        self.textView = textView
        self.scroll = scroll
        self.hint = hint
        textView.string = prefill
        relayout()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func close() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        textView?.delegate = nil
        textView = nil
        scroll = nil
        hint = nil
        onSend = nil
        image = nil
        // Hand the focus back to whatever app was in front before ⌘⌃M.
        NSApp.deactivate()
    }

    // MARK: Keys

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) { relayout() }

    /// ⏎ — also reachable from `GET /test/reminder-dictation/submit`.
    func submit() {
        let text = textView?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty || image != nil else { NSSound.beep(); return }
        let send = onSend, image = image
        close()
        send?(text, image)
    }

    // MARK: Layout

    private func centered() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }

    /// Width follows the longest line (clamped), height follows the wrapped
    /// text (clamped, then it scrolls); the panel is re-centred every time.
    private func relayout() {
        guard let panel, let textView, let scroll, let hint,
              let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        let maxTextWidth = visible.width * maxWidthFraction - 2 * pad
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        let lines = textView.string.components(separatedBy: "\n")
        let longest = lines.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 0
        let textWidth = min(max(ceil(longest) + 12, minTextWidth), maxTextWidth)

        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.frame.size.width = textWidth
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var textHeight = lineHeight
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            textHeight = max(lineHeight, ceil(lm.usedRect(for: tc).height))
        }
        let hintHeight = ceil(hint.intrinsicContentSize.height)
        let maxTextHeight = visible.height * maxHeightFraction - 2 * pad - hintGap - hintHeight
        let shownTextHeight = min(textHeight, maxTextHeight)

        let width = textWidth + 2 * pad
        let height = pad + shownTextHeight + hintGap + hintHeight + pad
        hint.frame = NSRect(x: pad, y: pad, width: textWidth, height: hintHeight)
        scroll.frame = NSRect(x: pad, y: pad + hintHeight + hintGap, width: textWidth, height: shownTextHeight)
        textView.frame.size.height = max(textHeight, shownTextHeight)
        textView.scrollRangeToVisible(textView.selectedRange())

        panel.setFrame(NSRect(x: (visible.midX - width / 2).rounded(),
                              y: (visible.midY - height / 2).rounded(),
                              width: width, height: height), display: true)
    }
}
