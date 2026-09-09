import AppKit

/// 💬📺 A subtitle band across the bottom of the projected screen, carrying the
/// live transcription the way a film carries subtitles — on demand, off by
/// default: **⌘⌃U** (taught on the ⌘⌃ cheat-sheet as "subtitles"), or
/// `GET /test/captions`. No menu row, deliberately — the menu is not a second
/// cheat-sheet, and a band you can see is its own feedback that it is on.
///
/// **It is on the built-in Retina on purpose**, which is the one overlay in this
/// app that wants to be there: the Retina is what a venue projector mirrors, and
/// this is drawn *for the room*, not for the trainer. Everything else in here
/// stays off it (see the project rules) precisely so that the room's screen holds
/// only what the room is meant to read — and this is that.
///
/// **What it shows is rewritten as more voice comes in.** Whisper transcribes in
/// 12 s chunks that overlap by 2 s, and the newer chunk heard those shared
/// seconds with a sentence of right-context behind them where the older one heard
/// them at its own cut edge — so the seam is repaired by dropping the overlap off
/// the tail *already on screen* and letting the better-informed reading replace
/// it. Words the room has already read can therefore change. All of that
/// (including why a one-word match is never a seam) lives in `CaptionStream`,
/// which is pure and unit-tested; this class is the plumbing around it.
///
/// **The file is read forward, never re-read.** Each tick consumes only the bytes
/// appended since the last one, and only up to the last complete line in them —
/// whisper appends `text + "\n"` in one call, but a tick landing inside that
/// write would otherwise put half a word on the projector. Turning the band on
/// starts from the file's *current* size, so it opens empty and fills as people
/// talk, rather than dumping the morning onto the screen.
final class LiveCaptions {

    /// One tick per second: fast enough that a line lands on screen as soon as
    /// whisper writes it, slow enough to be free. Nothing arrives faster anyway —
    /// a chunk is 12 s, or one silence flush.
    private static let tickInterval: TimeInterval = 1.0

    /// Clear the band after this long with nothing new. Comfortably longer than
    /// one 12 s chunk, so an ordinary pause mid-thought does not blank the room's
    /// screen — but short enough that a sentence from before the coffee break is
    /// never still sitting there.
    private static let idleClearSeconds: TimeInterval = 25

    private let transcriptionFolder: URL

    private(set) var isOn = false

    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?

    /// Byte offset in today's transcript that has already been shown.
    private var consumedOffset: UInt64 = 0
    private var currentFile: URL?

    private var standing = ""
    private var lastGrewAt = Date()

    init(transcriptionFolder: URL) {
        self.transcriptionFolder = transcriptionFolder
    }

    // MARK: - On / off

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard !isOn else { return }
        isOn = true
        standing = ""
        lastGrewAt = Date()
        // Start from the end of the file: the band opens empty and fills with
        // what gets said from now on.
        let file = TranscriptTail.todayFile(in: transcriptionFolder)
        currentFile = file
        consumedOffset = TranscriptTail.size(of: file)

        overlayInfo("💬📺 subtitles on")
        showPanel()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        label = nil
        standing = ""
        overlayInfo("💬📺 subtitles off")
    }

    /// Feed one line in as if whisper had just written it — the headless twin of
    /// somebody talking, for `GET /test/captions/say`. It goes through exactly
    /// the same seam as a real line, so what it proves is the real path; what it
    /// skips is only the file.
    func inject(_ text: String) {
        guard isOn else { return }
        let line = TranscriptTail.stripSpeaker(text)
        guard !line.isEmpty else { return }
        standing = CaptionStream.merge(standing: standing, incoming: line)
        lastGrewAt = Date()
        render()
    }

    // MARK: - Reading forward

    private func tick() {
        // Past midnight the day file changes under us; start the new one from its
        // beginning rather than from an offset that belonged to another file.
        let file = TranscriptTail.todayFile(in: transcriptionFolder)
        if file != currentFile {
            currentFile = file
            consumedOffset = 0
        }

        let size = TranscriptTail.size(of: file)
        // Truncated or replaced — anything but "grew" means the offset is a lie.
        if size < consumedOffset { consumedOffset = size }

        if size > consumedOffset, let appended = readAppended(from: file, at: consumedOffset, upTo: size) {
            consumedOffset += UInt64(appended.consumedBytes)
            let lines = TranscriptTail.parse(appended.text)
            for line in lines where !line.text.isEmpty {
                // Logged only when a seam was actually collapsed, which is the
                // one thing here that looks identical working and broken: a band
                // that has quietly stopped seaming reads as whisper stuttering,
                // and nothing else would ever say otherwise. Per-line logging
                // would be five lines a minute of "nothing happened".
                let seam = CaptionStream.overlapWordCount(
                    standing: CaptionStream.words(standing),
                    incoming: CaptionStream.words(CaptionStream.stripSpeakerGlyph(line.text)))
                if seam > 0 { overlayInfo("💬📺 rewrote \(seam) word(s) of the tail") }
                standing = CaptionStream.merge(standing: standing, incoming: line.text)
            }
            if !lines.isEmpty {
                lastGrewAt = Date()
                render()
            }
        }

        if !standing.isEmpty, Date().timeIntervalSince(lastGrewAt) > Self.idleClearSeconds {
            standing = ""
            render()
        }
    }

    /// The bytes between `offset` and `end`, cut back to the last newline in
    /// them.
    private func readAppended(from file: URL, at offset: UInt64, upTo end: UInt64) -> (text: String, consumedBytes: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        guard let data = try? handle.read(upToCount: Int(end - offset)) else { return nil }
        return Self.completeLines(in: data)
    }

    /// The **finished** lines in `data`, and how many bytes of it they account
    /// for — which is how far the caller may advance its offset.
    ///
    /// A tick can land in the middle of whisper's write. Everything after the
    /// last newline is therefore a line still being written: it is left in the
    /// file for the next tick rather than put on the projector as half a word.
    /// `nil` means there is not one complete line yet, so the offset does not
    /// move at all — the alternative, consuming the fragment now and the rest
    /// next time, cuts the sentence in two at a byte boundary that may not even
    /// be a character boundary.
    static func completeLines(in data: Data) -> (text: String, consumedBytes: Int)? {
        guard !data.isEmpty, let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        let complete = data[data.startIndex...lastNewline]
        guard let text = String(data: complete, encoding: .utf8) else { return nil }
        return (text, complete.count)
    }

    // MARK: - The band

    /// **The plate is full-width and flush to the bottom edge, and it grows
    /// upward** — the shape Victor drew in red over a screenshot rather than one
    /// this picked: a 10 %-tall strip along the bottom with one line in it, and
    /// the same strip 27 % tall once several lines had accumulated. So the two
    /// numbers below are measured off his drawing, not chosen.
    ///
    /// Growing *upward* out of a fixed bottom edge is what keeps the newest words
    /// at a constant height. A plate that grew downward, or one centred on a fixed
    /// middle, would slide the line being read out from under the eye every time
    /// a new one arrived.
    private static let minPlateFraction: CGFloat = 0.10
    private static let maxPlateFraction: CGFloat = 0.28

    private func showPanel() {
        guard let screen = ScreenCaptureFlash.builtInScreen else { return }

        let panel = NSPanel(contentRect: bottomStrip(on: screen, height: screen.frame.height * Self.minPlateFraction),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let label = NSTextField(labelWithString: "")
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.alignment = .left
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true

        let view = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        // The 50 % black plate Victor asked for, in as many words. The earlier
        // build painted outlined text on nothing, on the argument that a plate is
        // a permanent grey slab over the bottom of the slide — that argument only
        // ever applied to a plate that is *always there*, and this one is not: it
        // is hidden outright while nobody is talking, and it is the thing that
        // makes a long, wrapping, self-correcting transcript readable over a slide
        // rather than a smear of outlines.
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        view.addSubview(label)
        panel.contentView = view
        panel.orderFrontRegardless()

        self.panel = panel
        self.label = label
        render()
    }

    private func bottomStrip(on screen: NSScreen, height: CGFloat) -> NSRect {
        NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height)
    }

    private func render() {
        guard let panel, let label, let screen = ScreenCaptureFlash.builtInScreen else { return }

        // Read from the back of a room, on whatever the projector is doing to the
        // contrast — so sized off the screen rather than a fixed point size.
        let size = max(28, screen.frame.height * 0.036)
        let padX = screen.frame.width * 0.03
        let padY = size * 0.45
        let textWidth = screen.frame.width - 2 * padX
        let maxTextHeight = screen.frame.height * Self.maxPlateFraction - 2 * padY

        // **Trimmed by measured height, not by a character count.** How much text
        // fits is a question about the font, this screen's width and where the
        // words happen to wrap; a character count answers a different question
        // every time one of those changes. So words come off the *front* until
        // what is left fits the tallest plate allowed — the newest words are the
        // ones the room needs, and they are the ones that survive.
        var shown = CaptionStream.words(standing)
        var attributed = attributedCaption(shown.joined(separator: " "), size: size)
        while shown.count > 1,
              height(of: attributed, width: textWidth) > maxTextHeight {
            shown.removeFirst()
            attributed = attributedCaption(shown.joined(separator: " "), size: size)
        }

        let textHeight = standing.isEmpty ? 0 : height(of: attributed, width: textWidth)
        let plateHeight = min(screen.frame.height * Self.maxPlateFraction,
                              max(screen.frame.height * Self.minPlateFraction, textHeight + 2 * padY))

        panel.setFrame(bottomStrip(on: screen, height: plateHeight), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: NSSize(width: screen.frame.width, height: plateHeight))

        label.attributedStringValue = attributed
        // Sat on the plate's floor, so a second and third line push up into the
        // space the plate has just grown into rather than dragging the first line
        // down past the bottom edge.
        label.frame = NSRect(x: padX, y: padY, width: textWidth, height: ceil(textHeight))

        // Nothing to say, nothing on screen — the plate is not a permanent
        // fixture on the room's slide, it appears with the words and goes with
        // them. The panel itself stays up: re-creating it would flicker.
        panel.alphaValue = standing.isEmpty ? 0 : 1
        label.isHidden = standing.isEmpty
    }

    /// White, semibold, and still outlined even though it now sits on a plate:
    /// the plate is only half opaque, so a bright slide still comes through it,
    /// and the outline is what stops a light patch from eating a word. Lighter
    /// than it was when the text was drawn on nothing — a heavy stroke over a
    /// dark plate reads as a smudge.
    private func attributedCaption(_ text: String, size: CGFloat) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = size * 0.14
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.04)

        let paragraph = NSMutableParagraphStyle()
        // **Left, not centred.** Film subtitles are centred because they are one
        // or two short lines; this plate is full-width and grows to six or more,
        // and centring those starts every line at a different x — so a room
        // reading live text has to hunt for the beginning of each one. Ragged on
        // the right is the cheaper of the two raggednesses.
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.12

        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
            // Negative width means stroke *and* fill; a positive one draws the
            // outline only and leaves hollow letters.
            .strokeColor: NSColor.black,
            .strokeWidth: -2.0,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])
    }

    /// How tall this text wraps at `width`. `.usesLineFragmentOrigin` is the part
    /// that matters — without it the rect comes back one line tall however much
    /// text is in it, and the plate never grows.
    private func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        return ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
}