import AppKit
import AVFoundation
import Foundation

/// Plays a downloaded video **in-process**, in a borderless window that covers
/// the **built-in Retina** screen and sits above everything else on it — and
/// manages its lifetime: a new play **replaces** the previous one, and the
/// player is **auto-killed ~60s after playback starts** so a snippet left
/// running doesn't linger on the projected screen.
///
/// **Why no IINA any more (2026-09-24).** Until today the clip was handed to
/// IINA and its window was dragged onto the Retina through the Accessibility
/// API, then `AXFullScreen`ed there. In the room, with the Retina mirrored to
/// the projector and the ASUS made primary, that dance failed three times out
/// of three (`IINA never confirmed fullscreen`, 7 s each): IINA opened on the
/// **main** display — the ASUS — and the repeated fullscreen requests left
/// Spaces mid-transition, during which macOS swallows every click
/// ("I lost the ability to click, apparently" is in the transcript). The
/// external player bought seeking, fullscreen and a rewind-at-end, all of
/// which AVFoundation gives in-process, without a second app whose window
/// placement we do not own. So:
///
/// 1. **Which screen: the built-in one, always.** `VideoPlayer.pickScreen`
///    prefers `CGDisplayIsBuiltin`, then a name containing "Built-in", and only
///    then whatever macOS calls main (lid closed, no built-in at all). The
///    window is given that screen's `frame` verbatim — no AX coordinate flip,
///    no Spaces fullscreen, no waiting for a confirmation.
///
/// 2. **Above every other window.** `.screenSaver` level with
///    `canJoinAllSpaces` + `fullScreenAuxiliary`, so it shows over a
///    full-screen deck and over the magnifier's PiP lens, on whichever Space the
///    Retina is showing.
///
/// 3. **The end: rewind and pause.** At the last frame the player seeks back
///    to the snippet's start second and pauses — **SPACE replays** it, ESC or
///    the tablet closes it. A replay re-arms the auto-kill so it gets a full
///    window of its own.
///
/// 4. **Subtitles, when a clip has them.** A `<name>.srt` sidecar is parsed
///    (`SRTSubtitles`) and drawn as an outlined caption over the picture —
///    at the bottom, or at the top for a cue tagged `{\an8}`, in the colour of
///    its `<font color=…>` tag (white when untagged). No backdrop box.
///
/// 5. **The cursor is never hidden by us.** `setHiddenUntilMouseMoves` at most
///    — it restores itself on the first movement, so there is no hide/show
///    pair that an error path could leave unbalanced.
final class VideoPlayer {
    static let shared = VideoPlayer()

    /// Seconds after which the player is force-closed (0 disables auto-kill).
    var autoKillAfter: TimeInterval = 60

    private var autoKill: DispatchWorkItem?
    private var window: VideoWindow?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// The app that had focus before the clip took it, given it back on close.
    private var previousApp: NSRunningApplication?

    /// 📱 What the tablet's video page needs to stay pinned: a play counts as
    /// **active** from the moment playback is asked for until the clip runs
    /// out, the window goes away, or the auto-kill fires.
    private var activeSince: Date?
    private var activeId: String?
    private var activeDeadline: Date?
    /// The clip reached its end and was rewound+paused: the window is still up
    /// (SPACE replays it) but nothing is playing, which for the tablet is over.
    private var atEndPaused = false
    private var startSeconds = 0

    /// Launch (or replace) the player at `startSeconds`, covering the Retina.
    /// Returns **how many milliseconds it is scheduled to run** — the shorter of
    /// what is left of the clip and the auto-kill window — or nil if the file is
    /// missing. Same contract as `VideoSoundtrackPlayer.play`: the tablet holds
    /// its video page open for that long, and drains the ring on the tile.
    ///
    /// Main thread only (AVPlayer + NSWindow); every caller is an HTTP handler,
    /// which `TabletHttpServer` runs inside `DispatchQueue.main.sync`.
    @discardableResult
    func play(id: String, fileURL: URL, startSeconds: Int) -> Int? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            overlayError("VideoPlayer: file not found: \(fileURL.path)")
            return nil
        }
        // Replace: close any player already up so we never stack windows.
        stop()

        let start = max(0, startSeconds)
        self.startSeconds = start
        let screen = Self.targetScreen()
        let item = AVPlayerItem(url: fileURL)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        p.volume = 1

        let win = VideoWindow(screenFrame: screen.frame, player: p)
        win.onSpace = { [weak self] in self?.togglePause() }
        win.onEscape = { [weak self] in self?.stop() }
        if let srt = Self.sidecarSubtitle(for: fileURL) {
            win.subtitles = SRTSubtitles.parse(file: srt)
            overlayInfo("VideoPlayer: subtitles \(srt.lastPathComponent) (\(win.subtitles.count) cues)")
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in self?.reachedEnd() }
        if !win.subtitles.isEmpty {
            timeObserver = p.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
            ) { [weak win] t in win?.showSubtitle(at: CMTimeGetSeconds(t)) }
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        window = win
        player = p
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.setHiddenUntilMouseMoves(true)

        // Exact seek, then play: the manifest's start second IS the joke, and
        // a keyframe snap can land a scene away from it.
        p.seek(to: CMTime(seconds: Double(start), preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero) { [weak p] _ in
            p?.play()
        }

        overlayInfo("VideoPlayer: playing \(fileURL.lastPathComponent) from \(start)s on \(screen.localizedName) \(screen.frame)")
        scheduleAutoKill()
        let planned = plannedSeconds(fileURL: fileURL, startSeconds: start)
        activeSince = Date()
        activeId = id
        activeDeadline = Date().addingTimeInterval(planned)
        atEndPaused = false
        return Int(planned * 1000)
    }

    /// How long this play will actually last: what is left of the clip after the
    /// start second, capped by the auto-kill. Falls back to the auto-kill window
    /// when the file's duration can't be read — the cap is the only promise that
    /// holds for every clip anyway.
    private func plannedSeconds(fileURL: URL, startSeconds: Int) -> TimeInterval {
        let cap = autoKillAfter > 0 ? autoKillAfter : 600
        let d = AVURLAsset(url: fileURL).duration
        guard d.isNumeric else { return cap }
        let remaining = CMTimeGetSeconds(d) - Double(startSeconds)
        guard remaining > 0 else { return cap }
        return min(remaining, cap)
    }

    /// 📱 Is a clip on screen right now? The tablet asks this once a second
    /// while its video page is pinned, so it un-pins on whichever end comes
    /// first: the clip finishing, ESC, or the auto-kill.
    var isActive: Bool {
        guard activeSince != nil, !atEndPaused, window != nil else { return false }
        if let deadline = activeDeadline, Date() >= deadline { return false }
        return true
    }

    /// The half of `GET /video/state` that speaks for the picture. Same shape as
    /// `VideoSoundtrackPlayer.stateJSON` so the tablet parses one thing.
    func stateJSON() -> String {
        let active = isActive
        let remaining = active ? (activeDeadline.map { max(0, Int($0.timeIntervalSinceNow * 1000)) } ?? 0) : 0
        let id = activeId.map { "\"\($0)\"" } ?? "null"
        return "{\"playing\":\(active),\"kind\":\"video\",\"id\":\(id),\"remainingMs\":\(remaining)}"
    }

    /// Stop playback now (tablet stop / ESC / test hook / replace) and cancel the
    /// pending auto-kill. **The one exit**: every way a clip ends comes through
    /// here, so the window, the player, the observers and the focus are all put
    /// back in one place.
    func stop() {
        autoKill?.cancel()
        autoKill = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        if let window {
            window.orderOut(nil)
            window.close()
            self.window = nil
            // The deck underneath had the keyboard before the clip took it.
            previousApp?.activate()
        }
        previousApp = nil
        clearActive()
    }

    private func clearActive() {
        activeSince = nil
        activeId = nil
        activeDeadline = nil
        atEndPaused = false
    }

    // MARK: - Which screen

    /// The screen the clip goes on: the built-in Retina if there is one — it is
    /// what a venue projector mirrors — else what macOS calls main (lid closed).
    /// `NSScreen.main` / `screens[0]` follow the **primary** display, which at a
    /// venue is deliberately the ASUS (see `DisplayArrangementManager`).
    static func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        let candidates = screens.map { s in
            ScreenCandidate(
                isBuiltIn: (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                    .map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                name: s.localizedName,
                isMain: s == NSScreen.main
            )
        }
        if let i = pickScreen(candidates) { return screens[i] }
        return NSScreen.main ?? screens[0]
    }

    /// What `targetScreen` needs to know about a screen, so the choice can be
    /// unit-tested without an `NSScreen` (which cannot be constructed).
    struct ScreenCandidate: Equatable {
        var isBuiltIn: Bool
        var name: String
        var isMain: Bool
    }

    /// Pure half of `targetScreen`: index of the screen to use, or nil when the
    /// list is empty. Built-in first (`CGDisplayIsBuiltin`), then a name that
    /// says "Built-in" (the flag has been seen false for a built-in panel behind
    /// a DisplayLink dock), then main, then the first one.
    static func pickScreen(_ screens: [ScreenCandidate]) -> Int? {
        if let i = screens.firstIndex(where: { $0.isBuiltIn }) { return i }
        if let i = screens.firstIndex(where: { $0.name.localizedCaseInsensitiveContains("built-in") }) { return i }
        if let i = screens.firstIndex(where: { $0.isMain }) { return i }
        return screens.isEmpty ? nil : 0
    }

    // MARK: - Subtitles

    /// Subtitle sidecar extensions understood, in the order they win.
    private static let subtitleExtensions = ["srt"]

    /// The subtitle file sitting next to a clip under the same basename
    /// (`KLSdOY-6R_U.mp4` → `KLSdOY-6R_U.srt`), or nil when the clip has none.
    /// Sidecars, not a muxed track: the mp4s are downloaded artefacts that get
    /// re-fetched, so the subtitles must survive independently of them.
    static func sidecarSubtitle(for fileURL: URL) -> URL? {
        let base = fileURL.deletingPathExtension()
        return subtitleExtensions
            .map { base.appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - End of playback: rewind + pause, never advance

    /// The clip ran out: back to the start second and hold the frame, so SPACE
    /// replays it. Not `stop()`: the window stays up on purpose.
    private func reachedEnd() {
        guard let player else { return }
        player.pause()
        player.seek(to: CMTime(seconds: Double(startSeconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        atEndPaused = true
        overlayInfo("VideoPlayer: clip ended — rewound to \(startSeconds)s and paused (SPACE replays)")
    }

    /// SPACE. A replay after the end is a new play as far as everyone is
    /// concerned — its own auto-kill window, and the tablet's page pinned again.
    private func togglePause() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            return
        }
        if atEndPaused {
            atEndPaused = false
            activeSince = Date()
            activeDeadline = Date().addingTimeInterval(autoKillAfter)
            scheduleAutoKill()
        }
        player.play()
    }

    // MARK: - Lifetime

    private func scheduleAutoKill() {
        autoKill?.cancel()
        autoKill = nil
        guard autoKillAfter > 0 else { return }
        let after = autoKillAfter
        let work = DispatchWorkItem { [weak self] in
            self?.stop()
            overlayInfo("VideoPlayer: auto-closed player after \(Int(after))s")
        }
        autoKill = work
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
    }
}

// MARK: - The window

/// A borderless black window the size of one screen, showing an `AVPlayerLayer`
/// and, under it, a caption. Key so SPACE / ESC reach it.
final class VideoWindow: NSWindow {
    var onSpace: (() -> Void)?
    var onEscape: (() -> Void)?
    var subtitles: [SRTSubtitles.Cue] = []

    private let caption = NSTextField(labelWithString: "")
    /// The same text stroked thick and black, right under `caption`: the
    /// outline that keeps it readable with no backdrop box. A negative
    /// strokeWidth on one label draws a hairline, not an outline.
    private let captionOutline = NSTextField(labelWithString: "")
    private let playerLayer: AVPlayerLayer
    private let captionFont: NSFont

    init(screenFrame: CGRect, player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        captionFont = .systemFont(ofSize: max(36, screenFrame.height / 18), weight: .heavy)
        super.init(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above a full-screen app and the PiP magnifier lens, on every Space.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        // Pinned to the screen's own frame; `setFrame` after init because a
        // borderless window's contentRect is also its frame, but be explicit.
        setFrame(screenFrame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let layer = playerLayer
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)

        caption.alignment = .center
        for label in [captionOutline, caption] {
            label.drawsBackground = false
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byWordWrapping
            label.isHidden = true
            view.addSubview(label)
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: onSpace?()      // space
        case 53: onEscape?()     // esc
        default: super.keyDown(with: event)
        }
    }

    func showSubtitle(at seconds: Double) {
        guard let cue = SRTSubtitles.cue(at: seconds, in: subtitles) else {
            caption.isHidden = true
            captionOutline.isHidden = true
            return
        }
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        caption.attributedStringValue = NSAttributedString(string: cue.text, attributes: [
            .font: captionFont,
            .foregroundColor: Self.color(cue.color),
            .paragraphStyle: paragraph,
        ])
        captionOutline.attributedStringValue = NSAttributedString(string: cue.text, attributes: [
            .font: captionFont,
            .foregroundColor: NSColor.black,
            .strokeColor: NSColor.black,
            .strokeWidth: 22,
            .shadow: shadow,
            .paragraphStyle: paragraph,
        ])
        // Laid out against the picture itself, not the screen: on the 16:10
        // Retina a 16:9 clip is letterboxed, and "top" means the top of the video.
        let video = playerLayer.videoRect.isEmpty ? contentView?.bounds ?? frame : playerLayer.videoRect
        let width = video.width * 0.9
        let height = caption.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        let margin = video.height * 0.05
        let y = cue.top ? video.maxY - margin - height : video.minY + margin
        caption.frame = NSRect(x: video.minX + (video.width - width) / 2, y: y, width: width, height: height)
        captionOutline.frame = caption.frame
        caption.isHidden = false
        captionOutline.isHidden = false
    }

    /// A `<font color=…>` value: a few names, or `#RRGGBB`. White otherwise.
    static func color(_ value: String?) -> NSColor {
        guard let v = value?.lowercased() else { return .white }
        switch v {
        case "yellow": return NSColor(red: 1, green: 0.87, blue: 0, alpha: 1)
        case "red": return NSColor(red: 1, green: 0.2, blue: 0.15, alpha: 1)
        case "white": return .white
        default:
            guard v.hasPrefix("#"), v.count == 7, let rgb = Int(v.dropFirst(), radix: 16) else { return .white }
            return NSColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
    }
}

// MARK: - SRT

/// The subset of SubRip a training clip's sidecar uses: numbered cues,
/// `HH:MM:SS,mmm --> HH:MM:SS,mmm`, one or more lines of text, blank line.
/// Two styling tags are honoured, the rest stripped: `<font color="red">`
/// colours the cue, and the `{\an8}` position tag moves it to the top.
enum SRTSubtitles {
    struct Cue: Equatable {
        var start: Double
        var end: Double
        var text: String
        var color: String? = nil
        var top: Bool = false
    }

    static func parse(file: URL) -> [Cue] {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parse(raw)
    }

    static func parse(_ raw: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0].trimmingCharacters(in: .whitespaces)),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            let text = body
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
            guard !text.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, text: text,
                            color: fontColor(body), top: body.contains("{\\an8}")))
        }
        return cues
    }

    /// `HH:MM:SS,mmm` (a `.` is tolerated for the millisecond separator).
    static func seconds(_ stamp: String) -> Double? {
        let s = stamp.replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + sec
    }

    static func cue(at t: Double, in cues: [Cue]) -> Cue? {
        cues.first { $0.start <= t && t < $0.end }
    }

    static func text(at t: Double, in cues: [Cue]) -> String? {
        cue(at: t, in: cues)?.text
    }

    /// The `color` of the first `<font color=…>` tag, quotes optional.
    static func fontColor(_ body: String) -> String? {
        guard let r = body.range(of: #"<font[^>]*color\s*=\s*"?'?([#A-Za-z0-9]+)"#, options: .regularExpression)
        else { return nil }
        let tag = String(body[r])
        return tag.range(of: #"[#A-Za-z0-9]+$"#, options: .regularExpression).map { String(tag[$0]) }
    }
}
