import AppKit

/// **The subtitle band across the bottom of the room's screen.**
///
/// A caption panel, not a transcript window: it holds the last couple of lines
/// and nothing else. The transcript already exists, all day, in
/// `TRANSCRIPTION_FOLDER`; what this is for is the person in the third row who
/// missed a word.
///
/// ## This band has stood on this screen before, and the geometry is restored
///
/// A live-subtitle feature shipped on 2026-09-09 (`LiveCaptions` +
/// `CaptionStream`, on ⌘⌃U) and was deleted the same day — *"remove the feature
/// of subtitles completely. thoroughly. leave no trace."* (`c9a6141`). **What
/// was wrong with it was never the band, it was the source.** `mlx-whisper`
/// transcribes in 12 s chunks, so a line reached the screen twelve to twenty
/// seconds after it was spoken, and a subtitle that arrives after the sentence
/// is over is not a subtitle. `4dba31a` has the measurement that says it out
/// loud: switched on at 19:26:51, off at 19:27:08 — seventeen seconds in which
/// no line could possibly have landed. Scribe v2 Realtime (~1 s end to end) is
/// that one defect fixed; everything below is the part that was already right.
///
/// **So these numbers are measured off Victor's drawing, not chosen here.** He
/// drew the band in red over a screenshot: a strip along the bottom, **full
/// width, flush to the edge**, about a tenth of the screen tall with one line in
/// it and a bit over a quarter once several had accumulated. Re-deriving a
/// centred rounded card from first principles would throw away the one part of
/// the removed feature that had already been through his hands.
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

    /// **Full width, flush to the bottom edge, growing upward.** Both fractions
    /// come off Victor's red drawing (see above).
    ///
    /// Growing *upward* out of a fixed floor is what keeps the newest words at a
    /// constant height. A plate that grew downward, or one centred on a fixed
    /// middle, slides the line currently being read out from under an eye that
    /// is already there, every time another line arrives.
    private static let minPlateFraction: CGFloat = 0.10
    private static let maxPlateFraction: CGFloat = 0.28

    /// **55 %.** Dark enough to read from the back, light enough that the eye
    /// can tell at a glance which half of the line is still moving.
    private static let partialInk: CGFloat = 0.55

    /// A ceiling on what is **kept**, never on what is **shown** — the band
    /// trims itself by measured height in `render`. This exists only so that an
    /// hour of talking does not grow one string without end: every partial
    /// repaints the whole band, so a `committed` nobody ever cut would make each
    /// repaint walk more words than the last one did. Set far above anything
    /// that can fit on the plate, precisely so it can never be the thing doing
    /// the visible trimming.
    private static let keptCharacters = 600

    private var panel: NSPanel?
    private var label: NSTextField?

    /// The settled words, oldest first.
    private var committed = ""
    /// The sentence still being revised.
    private var partial = ""

    // MARK: - Lifecycle

    func show() {
        guard panel == nil else { return }
        let screen = AppDelegate.findRetinaScreen()
        let panel = NSPanel(contentRect: Self.bottomStrip(on: screen,
                                                          height: screen.frame.height * Self.minPlateFraction),
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

        let box = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        box.wantsLayer = true
        // **The 50 % black plate Victor asked for, in as many words**, and
        // square-cornered because it runs the full width of the screen — a
        // rounded card is a card, and this is a strip along an edge. An earlier
        // build painted outlined text on nothing, arguing that a plate is a
        // permanent grey slab over the bottom of the slide; that argument only
        // ever held for a plate that is *always there*, and this one is only up
        // while the switch is on.
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor

        let label = NSTextField(labelWithString: "")
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .left
        label.lineBreakMode = .byWordWrapping
        // No line cap: the plate's own height ceiling is the limit, and it is
        // expressed in screen fractions rather than in lines.
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        box.addSubview(label)

        panel.contentView = box
        panel.orderFrontRegardless()
        self.panel = panel
        self.label = label
        render()
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
        committed = Self.keepTail(committed.isEmpty ? words : committed + " " + words)
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

        // Read from the back of a room, through whatever the projector is doing
        // to the contrast — so sized off the screen's height rather than pinned
        // to a point size that means something different on every display.
        let size = max(28, screen.frame.height * 0.036)
        let padX = screen.frame.width * 0.03
        let padY = size * 0.45
        let textWidth = screen.frame.width - 2 * padX
        let maxTextHeight = screen.frame.height * Self.maxPlateFraction - 2 * padY

        var settled = Self.words(committed)
        var flight = Self.words(partial)
        // Before the first word lands: an ellipsis rather than a void, in the
        // partial's dim ink because nothing has settled yet. An empty black bar
        // on the screen the room is watching is indistinguishable from a
        // rendering bug, and the plate is up from the moment the switch is
        // flipped — a switch has to answer at once.
        if settled.isEmpty && flight.isEmpty { flight = ["…"] }

        // **Trimmed by measured height, never by a character count.** How much
        // text fits is a question about this font, this screen's width and where
        // the words happen to wrap; a character count answers a different
        // question every time one of those three moves. Words come off the
        // *front*, and off the settled half first: the newest words are the ones
        // the room needs, and the sentence still in flight is the newest there
        // is.
        var text = Self.band(settled: settled, flight: flight, size: size)
        while settled.count + flight.count > 1,
              Self.height(of: text, width: textWidth) > maxTextHeight {
            if !settled.isEmpty { settled.removeFirst() } else { flight.removeFirst() }
            text = Self.band(settled: settled, flight: flight, size: size)
        }

        let textHeight = Self.height(of: text, width: textWidth)
        let plateHeight = min(screen.frame.height * Self.maxPlateFraction,
                              max(screen.frame.height * Self.minPlateFraction, textHeight + 2 * padY))

        label.attributedStringValue = text
        panel.setFrame(Self.bottomStrip(on: screen, height: plateHeight), display: true)
        panel.contentView?.frame = NSRect(origin: .zero,
                                          size: NSSize(width: screen.frame.width, height: plateHeight))
        // Sat on the plate's floor, so a second and third line push up into the
        // room the plate has just grown rather than dragging the first line down
        // past the bottom edge of the screen.
        label.frame = NSRect(x: padX, y: padY, width: textWidth, height: ceil(textHeight))
    }

    /// The two inks in one string: settled words solid, the sentence in flight
    /// at `partialInk`.
    private static func band(settled: [String], flight: [String], size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !settled.isEmpty {
            out.append(NSAttributedString(string: settled.joined(separator: " "),
                                          attributes: attributes(size: size, ink: 1)))
        }
        if !flight.isEmpty {
            if out.length > 0 {
                out.append(NSAttributedString(string: " ", attributes: attributes(size: size, ink: 1)))
            }
            out.append(NSAttributedString(string: flight.joined(separator: " "),
                                          attributes: attributes(size: size, ink: partialInk)))
        }
        return out
    }

    /// White, semibold, and **still outlined even though it sits on a plate**:
    /// the plate is only half opaque, so a bright slide comes through it, and the
    /// outline is what stops a light patch from eating a word.
    private static func attributes(size: CGFloat, ink: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = size * 0.14
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.04)

        let paragraph = NSMutableParagraphStyle()
        // **Left, not centred.** Film subtitles are centred because they are one
        // or two short lines; this plate is full-width and grows to several, and
        // centring those starts every line at a different x — so a room reading
        // live text has to hunt for the beginning of each one. Ragged on the
        // right is the cheaper of the two raggednesses.
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.12

        return [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(ink),
            .strokeColor: NSColor.black,
            // Negative width means stroke *and* fill; a positive one draws the
            // outline only and leaves hollow letters.
            .strokeWidth: -2.0,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ]
    }

    private static func bottomStrip(on screen: NSScreen, height: CGFloat) -> NSRect {
        NSRect(x: screen.frame.minX, y: screen.frame.minY,
               width: screen.frame.width, height: height)
    }

    /// How tall this text wraps at `width`. `.usesLineFragmentOrigin` is the part
    /// that matters — without it the rect comes back one line tall however much
    /// text is in it, and the plate never grows.
    private static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        return ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// Keep the tail. Cut on a word so the kept text never opens mid-syllable.
    private static func keepTail(_ text: String) -> String {
        guard text.count > keptCharacters else { return text }
        let tail = String(text.suffix(keptCharacters))
        guard let space = tail.firstIndex(of: " ") else { return tail }
        return String(tail[tail.index(after: space)...])
    }
}
