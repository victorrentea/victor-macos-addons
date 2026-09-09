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

    private func showPanel() {
        guard let screen = ScreenCaptureFlash.builtInScreen else { return }

        // Wide enough to hold a long sentence in two lines, inset enough that the
        // text is never hard against a projector's edge (or lost to overscan).
        let width = screen.frame.width * 0.86
        let height = screen.frame.height * 0.20
        let frame = NSRect(x: screen.frame.minX + (screen.frame.width - width) / 2,
                           y: screen.frame.minY + screen.frame.height * 0.06,
                           width: width,
                           height: height)

        let panel = NSPanel(contentRect: frame,
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
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.frame = NSRect(origin: .zero, size: frame.size)
        label.autoresizingMask = [.width, .height]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.addSubview(label)
        panel.contentView = view
        panel.orderFrontRegardless()

        self.panel = panel
        self.label = label
        render()
    }

    private func render() {
        guard let label, let screen = ScreenCaptureFlash.builtInScreen else { return }

        // Read from the back of a room, on whatever the projector is doing to the
        // contrast — so: sized off the screen rather than a fixed point size, and
        // painted the way subtitles have always been painted, white with a black
        // outline and a shadow under it. A translucent plate behind the text was
        // the obvious alternative and is worse: it is a permanent grey slab over
        // the bottom fifth of the slide even while nobody is saying anything.
        let size = max(28, screen.frame.height * 0.036)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = size * 0.18
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.05)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.12

        label.attributedStringValue = NSAttributedString(string: standing, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
            // Negative width means stroke *and* fill — a positive one would
            // draw the outline only and leave hollow letters.
            .strokeColor: NSColor.black,
            .strokeWidth: -3.5,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])
        // An empty band is nothing at all, not an empty box: the panel stays up
        // (it costs nothing and re-creating it would flicker) but with no text
        // there is nothing to see.
        label.isHidden = standing.isEmpty
    }
}
