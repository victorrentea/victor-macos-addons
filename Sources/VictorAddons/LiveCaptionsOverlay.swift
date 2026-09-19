import AppKit

/// **The subtitle band across the bottom of the room's screen** (2026-09-19).
///
/// A caption panel, not a transcript window: it holds the last couple of lines
/// and nothing else. The transcript already exists, all day, in
/// `TRANSCRIPTION_FOLDER`; what this is for is the person in the third row who
/// missed a word.
///
/// ## Two colours, because a partial is a guess
///
/// Scribe's realtime socket sends `partial_transcript` while he is still
/// talking and **rewrites it as it goes** — measured 2026-09-19 on one clip:
/// `label on the tool` → `label of the tooltip` → `label on the tool tip` →
/// `label of the tooltip`, four different sentences over two seconds. Drawn in
/// the same ink as the settled text, that reads as the screen glitching. Drawn
/// dimmer, it reads as what it is: the words are still arriving. The room learns
/// the convention in one sentence and then stops noticing it.
///
/// ## Why the retina and not the main screen
///
/// `AddonsOverlayPanel`'s reason, and it is the whole reason this app has a
/// `findRetinaScreen` at all: at a venue the **ASUS is made primary**
/// (`DisplayArrangementManager`) while the projector mirrors the **built-in**
/// display, so "the main screen" is exactly the screen the room cannot see.
final class LiveCaptionsOverlay {

    /// How much of the screen's width the band takes. Wide, because a caption
    /// that wraps every six words is a caption nobody can read at a distance.
    private static let widthFraction: CGFloat = 0.86
    /// Off the bottom edge. Clear of a projector's own overscan and of anything
    /// a slide puts in its last inch.
    private static let bottomMargin: CGFloat = 64
    /// **Two lines' worth of characters, near enough.** The band is *read at a
    /// glance from the back of a room*; a paragraph up there is not a caption,
    /// it is homework nobody asked for. Older sentences fall off the front,
    /// which is the same trade every subtitle track makes.
    private static let maxCharacters = 190

    private var panel: NSPanel?
    private var label: NSTextField?

    /// The settled words, oldest first, already clipped to `maxCharacters`.
    private var committed = ""
    /// The sentence still being revised.
    private var partial = ""

    // MARK: - Lifecycle

    func show() {
        guard panel == nil else { return }
        let screen = AppDelegate.findRetinaScreen()
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        // Click-through and on every Space: it is drawn over whatever he is
        // teaching from, and a caption that eats a click on a slide is a
        // caption that gets turned off after the first demo.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]

        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        box.layer?.cornerRadius = 18

        let label = NSTextField(labelWithString: "")
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        box.addSubview(label)

        panel.contentView = box
        panel.orderFrontRegardless()
        self.panel = panel
        self.label = label
        layout(on: screen)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        label = nil
        committed = ""
        partial = ""
    }

    var isVisible: Bool { panel != nil }

    // MARK: - Words

    /// A segment Scribe has stopped revising: it joins the settled text and the
    /// partial is cleared, because the next one starts from nothing.
    func commit(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { partial = ""; return render() }
        committed = Self.clip(committed.isEmpty ? words : committed + " " + words)
        partial = ""
        render()
    }

    /// The sentence in flight. Replaces whatever was there — it is one guess
    /// superseding another, never an addition.
    func update(partial text: String) {
        partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
        render()
    }

    /// What the band says before the first word arrives, and after a failure.
    /// The band **stays up** with a message rather than going blank: a subtitle
    /// area that empties looks identical to a room that has gone quiet.
    func say(_ message: String) {
        committed = message
        partial = ""
        render()
    }

    // MARK: - Drawing

    private func render() {
        guard let label = label, let panel = panel else { return }
        let screen = AppDelegate.findRetinaScreen()
        let size = max(28, screen.frame.height * 0.030)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)

        let text = NSMutableAttributedString()
        if !committed.isEmpty {
            text.append(NSAttributedString(string: committed, attributes: [
                .font: font, .foregroundColor: NSColor.white,
            ]))
        }
        if !partial.isEmpty {
            if !committed.isEmpty { text.append(NSAttributedString(string: " ")) }
            // **55 %.** Dark enough to read from the back, light enough that the
            // eye can tell at a glance which half of the line is still moving.
            text.append(NSAttributedString(string: partial, attributes: [
                .font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            ]))
        }
        label.attributedStringValue = text
        layout(on: screen)
        _ = panel
    }

    private func layout(on screen: NSScreen) {
        guard let panel = panel, let label = label else { return }
        let pad: CGFloat = 26
        let width = screen.frame.width * Self.widthFraction
        let textWidth = width - pad * 2
        label.preferredMaxLayoutWidth = textWidth
        let textHeight = label.sizeThatFits(NSSize(width: textWidth,
                                                   height: .greatestFiniteMagnitude)).height
        let height = max(textHeight, 1) + pad * 1.4
        let frame = NSRect(x: screen.frame.minX + (screen.frame.width - width) / 2,
                           y: screen.frame.minY + Self.bottomMargin,
                           width: width, height: height)
        panel.setFrame(frame, display: true)
        label.frame = NSRect(x: pad, y: pad * 0.7, width: textWidth, height: textHeight)
    }

    /// Keep the tail. Cut on a word so the band never opens mid-syllable.
    private static func clip(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let tail = String(text.suffix(maxCharacters))
        guard let space = tail.firstIndex(of: " ") else { return tail }
        return String(tail[tail.index(after: space)...])
    }
}
