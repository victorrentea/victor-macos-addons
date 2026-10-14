import AppKit

/// **Ported from Walkie Talkie on 2026-10-14** (`walkie-talkie`
/// `Sources/WalkieTalkie/LiveCaptionBand.swift` at `2af0f51`), as is. Victor:
/// *"Copy from the Walkie Talkie into the Mac OS addons the way that I've
/// implemented live captions … the same engine, the same technique"*. The one
/// thing that differs is **which screen**: Walkie pins the band to the Retina;
/// here it opens on the screen the pointer is on when 🎬 Live Captions is
/// switched on — *"so I can enable captions on another monitor, not on the
/// first one"* — and the caller passes it in (`setOpen(_:on:)`). Everything
/// below is Walkie's own history and still describes the drawing exactly;
/// a fix to the motion belongs in both copies.
///
/// **The live caption as a film subtitle across the top of the screen**
/// (2026-09-26). Victor: *"pui subtitrarea live pe o bandă de înălțime 80 px pe
/// partea de sus a ecranului ca o subtitrare. font alb cu bordură/shadow negru
/// … ideal textul să se miște uniform smooth de la dreapta spre stânga, în ciuda
/// cuvintelor din transcriere care se modifică live … ochiul să urmărească lin
/// textul. Îl scoți așadar din tooltip."*
///
/// One borderless, click-through panel, `bandHeight` tall, pinned to the top
/// of the Retina (since 2026-10-05; the pointer's screen before) — under the menu
/// bar, so neither covers the other. White text with a black outline and a
/// soft shadow, and since 2026-09-28 a backdrop (below).
///
/// **Two lines that roll up, not a line that scrolls left** (2026-09-28).
/// Victor: *"We need to work a bit on the subtitles. Not very happy with how
/// they look, scrolling text to the left. When new text is added onto the
/// right, that's okay. But then when a full line is filled up, a second line
/// should be written below the first one. The first one should stay at the
/// maximum of eighty percent of the screen width. And then when the second
/// line gets full as well, it pushes up the first line out of screen,
/// basically. And on silence, there is no fade coming from the left, but
/// instead, the whole line is pushed up after sufficient time to read it.
/// Also, in case there is a break in the speech that results in a new
/// sentence being started, I'd like to have that other sentence starting on
/// the second line, therefore initiating a new line, even if the first line
/// isn't entirely full. But then once it's on the second line, even if under
/// a correction the sentence is merged with the previous one, it still
/// remains on the second line. And corrections still are smooth. The font
/// should be also slightly less bold and twenty percent smaller."*
///
/// - **Two slots, a line ≤ `maxLineShare` (80 %) of the band's width.** Words
///   are appended on the right of the current line; a word that would take the
///   line past 80 % starts the next line. When a third line is needed the top
///   one glides up and out (`lineGlide`, the same exponential ease as the
///   reflow, fading as it crosses the band's top edge) and the second takes its
///   slot. Nothing scrolls sideways any more, and **the eraser is gone**.
///   **In that order** (Victor, same day: *"când ar trebui să apară rândul 3,
///   atunci rândul 1 iese în sus, și după ce rândul 2 devine 1, atunci începe
///   să apară și rândul '3' pe poziția 2"*): line 1 starts leaving the frame
///   the word that needs line 3 arrives; line 2 glides up; only once it has
///   landed does the new line's entry front start. Words that arrive during
///   the glide wait on the new line, unrevealed — none is dropped or shown
///   early. Generally: **a line's letters come in only while it, and every
///   line above it, stands still** (`landed`), so a silence roll-up holds a
///   word said mid-glide the same way (a word already half in finishes as
///   its line rides up). Line 1 never leaves while line 2 is still filling.
/// - **Each line is centred on the band** — an assumption, not his words: it
///   keeps his standing rule *"the visible text remains ~centered at all
///   times"* (2026-09-26 07:50) and is how film subtitles sit. So a line
///   still re-centres by half of each word's ink as it grows (the feed-forward
///   ease of batch 5, now per line); it never travels further than that.
/// - **Silence lifts a line after a read time**: `readTime = max(readMin 3 s,
///   readPerWord 0.3 s × words on the line)` — an assumption (he said *"after
///   sufficient time to read it"*). The clock is silence: it starts at the last
///   new word (a gentle batch correction does not restart it, as it did not
///   wake the eraser), and after a line has left it restarts for the next one,
///   so the line that just moved up is given its own read time in its new
///   place. When both are gone the band stays up, empty, as it did after a
///   full wipe, and closes with the sentence.
/// - **A new sentence starts a new line.** The live engine commits a segment
///   at a VAD pause (1.5 s); a commit whose last word ends a sentence (`.`,
///   `?`, `!`, `…`) marks the next word to start a new line even if the current
///   one is short (`breakBefore`). A commit with no terminal punctuation is a
///   pause inside the sentence and changes nothing.
/// - **A new voice starts a new line** (2026-10-14, addons only — a dictation
///   has one voice): `setText(…, speakers:)` names the committed words where
///   the batch correction's diarization heard a different speaker, and the
///   line holding one is split there after the fact (`split(atSpeakers:)`) —
///   the one exception to the sticky lines below.
/// - **Lines are sticky per word.** Each word carries the line it was placed
///   on through every revision (the LCS alignment carries it, as it carries
///   the x); a correction's new words take the line of the words they replace,
///   so a batch correction that merges two sentences leaves the second one
///   where it is. A correction re-flows only inside its own line (and may make
///   that line wider than 80 % — it is never re-wrapped).
/// - **Font: 30.4 pt semibold** (38 bold before: 20 % smaller, one weight
///   lighter; medium was too thin under the 9 % black outline on video),
///   outline and shadow kept.
///
/// **A grey backdrop, and the band dodges the pointer** (2026-09-28). Victor:
/// *"pune o margine de 10x pe toate direcțiile de fundal gri semitransparent în
/// jurul textului subtitrării. În plus, câtă vreme mouse-ul este peste
/// subtitrarea de sus, ea să fugă jos (revine sus când mouse-ul iese din zona
/// subtitrării)"*.
/// - **Backdrop**: a rounded rect (radius `backdropRadius` 8), grey at 45 %,
///   `backdropPad` 10 pt around the union of the lines' text boxes on all four
///   sides — *"10x"* read as 10 pt (an assumption). It follows the text as the
///   eye sees it: widening with the ink, growing a line down when line 2
///   begins, shrinking when a line leaves — continuous motion followed frame
///   by frame, jumps eased (τ `lineGlide`); it fades out when the band empties.
/// - **Dodge**: while the pointer is inside the backdrop at the top, the band
///   **jumps** to the bottom of the same screen — in one frame, no pan, no fade
///   (Victor, same day: *"flip top/bottom should be without pan, sudden. no
///   animation"*) — the backdrop the same `edgeGap`
///   from the bottom edge as it was from the top (the block then grows upward).
///   It jumps back up once the pointer has been out of the top backdrop
///   (grown by `dodgeSlack` 12 pt) for `dodgeDebounce` 0.25 s — enter at once,
///   leave with hysteresis, so it cannot flap. The pointer is read every frame
///   (`NSEvent.mouseLocation`, what the chip rides on); `POST /test/live-caption
///   {"pointer": {"x", "y"}}` stands in for it at a desk (`null` gives it back).
///
/// **Corrections are a swap** (2026-09-26, unchanged): the replaced words fade
/// out where they stood (ghosts), the rest of their line glides to its new
/// layout, the new words fade in in a faded yellow that returns to white.
///
/// **Words enter letter by letter** (2026-09-27, unchanged). Victor: *"the
/// entering text at right should fade in character by character (the same way
/// it fades out at the left) ⇒ with less 'shocks' to the move."* An appended
/// word is swept by a front with a soft edge (`softEdge`) from its first letter
/// to its last at `revealSpeed`, one opacity per glyph (a `destinationIn`
/// mask). Its line makes room for it only as far as its ink has come in
/// (`appear`), so the re-centring moves with the letters.
final class LiveCaptionBand {

    /// 38 × 0.8 (2026-09-28: *"twenty percent smaller"*).
    static let fontSize: CGFloat = 30.4
    /// Bold before 2026-09-28 (*"slightly less bold"*).
    static let fontWeight: NSFont.Weight = .semibold
    /// A line never grows past this share of the band's width by appending.
    static let maxLineShare: CGFloat = 0.8
    /// Above the first line's box and below the second's: the backdrop's
    /// padding and `edgeGap`.
    private static let padTop: CGFloat = 12
    private static let padBottom: CGFloat = 12
    /// Line box to line box.
    static let linePitch: CGFloat = (TickerView.lineHeight + 3).rounded(.up)
    /// Two lines and the padding (80 pt for one 38 pt line before 2026-09-28).
    static let bandHeight: CGFloat = padTop + linePitch + TickerView.lineHeight + padBottom
    /// **The backdrop** (2026-09-28): 10 pt around the text on every side.
    static let backdropPad: CGFloat = 10
    static let backdropRadius: CGFloat = 8
    static let backdropColour = NSColor(calibratedWhite: 0.15, alpha: 0.45)
    /// The backdrop's distance from the screen edge it sits against.
    static let edgeGap: CGFloat = padTop - backdropPad
    /// **The dodge** (2026-09-28): leave-check margin and debounce.
    static let dodgeSlack: CGFloat = 12
    static let dodgeDebounce: CFTimeInterval = 0.25

    private static let vMax: CGFloat = 700
    /// **Elastic, not a ramp** (Victor, 2026-09-26: *"o mișcare elastică
    /// blândă"*): a line's re-centring approaches its target exponentially with
    /// this time constant.
    private static let ease: CGFloat = 0.45
    /// **A replacement is a swap in three overlapping beats** (Victor,
    /// 2026-09-26): the old words fade out over the first half of `swap`, the
    /// rest of the line glides elastically to make room (`reflow`), and the
    /// new words fade in over the second half — *"fadeout + fadein = durata
    /// glisare text în noua poziție"*. Once in, a new word is a faded yellow
    /// that returns to white over `correctionFade`.
    static let swap: CFTimeInterval = 1.0
    static let correctionFade: CFTimeInterval = 1.6
    /// The glide's time constant: 95 % of the way in three of these ≈ `swap`.
    static let reflow: CGFloat = 0.26
    /// **A line rolling up** (2026-09-28): an exponential ease like the
    /// reflow's, a little quicker (τ 0.2 s), because the next line waits for it
    /// — it has landed once within `landed` of its slot (1 pt), ~0.7 s.
    static let lineGlide: CGFloat = 0.2
    static let landed: CGFloat = 0.03
    /// **The read time a line is given in silence** (2026-09-28, assumed):
    /// `max(readMin, readPerWord × its words)`.
    static let readMin: CFTimeInterval = 3.0
    static let readPerWord: CFTimeInterval = 0.3
    static func readTime(words: Int) -> CFTimeInterval { max(readMin, readPerWord * Double(words)) }
    /// **The segment still being spoken is provisional and looks it** (Victor,
    /// 2026-09-26: *"faded progresiv in"*): its words are drawn from this
    /// opacity at the newest up to solid at the committed boundary.
    static let provisionalFloor: CGFloat = 0.4
    /// How fast the provisional gradient eases toward its target (batch 5).
    static let fadeIn: CGFloat = 0.22
    /// **The entry front** (2026-09-27): a letter fades in over the soft edge
    /// (160 / 320 = 0.5 s) and its right neighbour starts ~0.07 s later; a
    /// burst the front has not reached yet is caught up within
    /// `revealCatchUp` seconds, never faster than 0.7 `vMax`. The soft edge was
    /// the eraser's (`eraseEdge`) until the eraser went (2026-09-28).
    static let softEdge: CGFloat = 160
    static let revealSpeed: CGFloat = 320
    static let revealCatchUp: CGFloat = 0.8

    private let panel: NSPanel
    private let view = TickerView()
    /// `CADisplayLink` from macOS 14; a 60 Hz timer below it.
    private var displayLink: Any?
    private var lastTick: CFTimeInterval = 0
    private(set) var isOpen = false
    /// The visible frame of the screen the band opened on.
    private var screenFrame: NSRect = .zero
    /// Where the band is (dodging the pointer to the bottom, or at the top),
    /// the panel's y as drawn, and since when the pointer has been out.
    private var atBottom = false
    private var panelY: CGFloat = 0
    private var outSince: CFTimeInterval?
    /// `POST /test/live-caption {"pointer": {x, y}}`: the pointer as a desk
    /// test places it, in screen points; nil reads the real one. Cleared when
    /// the band closes.
    var testPointer: NSPoint? { didSet { pointerSetAt = CACurrentMediaTime() } }
    /// When the test pointer last moved, and how long after it the band last
    /// flipped (ms): one frame going down, the debounce plus one frame going up.
    private var pointerSetAt: CFTimeInterval?
    private var flipLagMs: Double?
    /// The clock's frame interval and the view's draw time, smoothed (ms) —
    /// for `GET /test/state`, to tell a slow frame from a slow route.
    private var frameMs: Double = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: Self.bandHeight),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
    }

    // MARK: - Open / close

    /// Opens the band across the top of `screen`, empty, or fades it out.
    ///
    /// **The screen is the caller's** (addons, 2026-10-14): the one under the
    /// pointer when the switch was flipped, so the captions go wherever Victor
    /// was when he turned them on. Walkie always used the Retina instead.
    func setOpen(_ open: Bool, on screen: NSScreen? = nil) {
        guard open != isOpen else { return }
        isOpen = open
        if open {
            let mouse = NSEvent.mouseLocation
            let screen = screen
                ?? NSScreen.physical.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            guard let screen else { isOpen = false; return }
            let v = screen.visibleFrame
            screenFrame = v
            atBottom = false; outSince = nil; flipLagMs = nil
            panelY = v.maxY - Self.bandHeight
            panel.setFrame(NSRect(x: v.minX, y: panelY, width: v.width, height: Self.bandHeight),
                           display: false)
            view.reset()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            startLink()
        } else {
            stopLink()
            testPointer = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
                self.view.reset()
            })
        }
    }

    /// For `GET /test/state`: `open`, and the ticker's numbers.
    func describe() -> [String: Any] {
        var out = view.describe()
        out["open"] = isOpen
        let o = panel.frame.origin
        let rect: (NSRect) -> [String: Double] = { r in
            ["x": Double(r.minX + o.x), "y": Double(r.minY + o.y), "w": Double(r.width), "h": Double(r.height)]
        }
        out["frameMs"] = (frameMs * 10).rounded() / 10
        out["flipLagMs"] = flipLagMs.map { $0 as Any } ?? NSNull()
        out["drawMs"] = (view.drawMs * 10).rounded() / 10
        out["position"] = atBottom ? "bottom" : "top"
        out["frame"] = ["x": Double(o.x), "y": Double(o.y), "w": Double(panel.frame.width), "h": Double(panel.frame.height)]
        out["screen"] = ["x": Double(screenFrame.minX), "y": Double(screenFrame.minY),
                         "w": Double(screenFrame.width), "h": Double(screenFrame.height)]
        out["backdrop"] = rect(view.backdrop)
        out["backdropTarget"] = view.backdropTarget.map { rect($0) as Any } ?? NSNull()
        out["backdropAlpha"] = Double(view.backdropAlpha)
        out["lineBoxes"] = view.lineBoxes().map { rect($0) }
        out["pointer"] = testPointer.map { ["x": Double($0.x), "y": Double($0.y), "test": true] as [String: Any] } ?? NSNull()
        return out
    }

    /// The whole sentence as the recogniser has it now, revisions included.
    /// `gentle`: a batch correction of words behind him — softer tint, and it
    /// does not count as him speaking again (the silence clock keeps running).
    /// `speakers`: indices of the committed words where a new voice begins
    /// (the batch model's diarization) — each starts a line of its own.
    func setText(committed: String, partial: String, gentle: Bool = false, speakers: [Int] = []) {
        guard isOpen else { return }
        let split: (String) -> [String] = { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        let c = split(committed)
        view.setWords(c + split(partial), committed: c.count, gentle: gentle, speakers: speakers)
    }

    // MARK: - The clock

    private func startLink() {
        guard displayLink == nil else { return }
        lastTick = 0
        if #available(macOS 14, *) {
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            displayLink = timer
        }
    }

    private func stopLink() {
        if #available(macOS 14, *), let link = displayLink as? CADisplayLink { link.invalidate() }
        (displayLink as? Timer)?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard lastTick > 0 else { return }
        frameMs += ((now - lastTick) * 1000 - frameMs) * 0.1
        // A frame after a stall (a hidden Space, a debugger) is clamped so
        // nothing leaps; it merely catches up.
        let dt = CGFloat(min(now - lastTick, 1.0 / 20))
        view.advance(dt: dt, now: now, vMax: Self.vMax, ease: Self.ease)
        dodge(dt: dt, now: now)
    }

    private func flipped(_ now: CFTimeInterval) {
        flipLagMs = testPointer != nil ? pointerSetAt.map { ((now - $0) * 1000 * 10).rounded() / 10 } : nil
    }

    /// **The band gets out of the pointer's way** (2026-09-28): into the
    /// backdrop at the top → the bottom; out of it (plus `dodgeSlack`) for
    /// `dodgeDebounce` → back to the top. Each flip is one frame (*"sudden. no
    /// animation"*); at the bottom the panel then follows the backdrop's own
    /// eased growth so its bottom edge stays put.
    private func dodge(dt: CGFloat, now: CFTimeInterval) {
        let v = screenFrame
        guard v.width > 0 else { return }
        let topY = v.maxY - Self.bandHeight
        let pointer = testPointer ?? NSEvent.mouseLocation
        let zone = view.backdropTarget.map { $0.offsetBy(dx: v.minX, dy: topY) }
        if !atBottom {
            if let zone, zone.contains(pointer) { atBottom = true; outSince = nil; flipped(now) }
        } else if let zone, zone.insetBy(dx: -Self.dodgeSlack, dy: -Self.dodgeSlack).contains(pointer) {
            outSince = nil
        } else if let since = outSince {
            if now - since >= Self.dodgeDebounce { atBottom = false; outSince = nil; flipped(now) }
        } else {
            outSince = now
        }
        // At the bottom the backdrop keeps `edgeGap` from the bottom edge,
        // whatever its height: the block grows upward there.
        panelY = atBottom ? v.minY + Self.edgeGap - view.backdrop.minY : topY
        if abs(panel.frame.origin.y - panelY) >= 0.25 {
            panel.setFrameOrigin(NSPoint(x: v.minX, y: panelY.rounded()))
        }
    }

    // MARK: - The view

    /// Draws up to two lines of subtitle text (plus the ones rolling out).
    fileprivate final class TickerView: NSView {
        /// One line on the band. `slot` is where it is drawn (0 top, 1 below,
        /// negative above the band while rolling out), easing toward
        /// `slotTarget`; `anchor` is the x of its first word, easing toward
        /// the centred position like the single line's did.
        struct Line {
            let id: Int
            var anchor: CGFloat = 0
            var velocity: CGFloat = 0
            var lastGoal: CGFloat?
            var slot: CGFloat
            var slotTarget: CGFloat
            /// Why it began: `first`, `full` (the 80 % wrap), `sentence` or
            /// `speaker` (a new voice, split out of a line by a correction).
            let reason: String
        }
        /// A line pushed out, drawn from a snapshot while it glides up and fades.
        struct Leaving {
            var line: Line
            var words: [(word: String, x: CGFloat, alpha: CGFloat, fill: NSColor)]
        }

        private var words: [String] = []
        /// Words at the head of `words` that have rolled out of the band.
        private var dropped = 0
        /// The visible lines, top first (at most two once an update settles).
        private var lines: [Line] = []
        private var leaving: [Leaving] = []
        private var nextLineId = 0
        /// Per visible word (`words[dropped + k]`): the id of its line — sticky
        /// across revisions — where it belongs inside that line, and where it
        /// is drawn right now (the second eases toward the first, `reflow`).
        private var lineOf: [Int] = []
        private var target: [CGFloat] = []
        private var shown: [CGFloat] = []
        private var widths: [CGFloat] = []
        /// **When a word replaced one already on screen**, by absolute index:
        /// invisible for the first half of `swap`, fading in over the second,
        /// then a faded yellow returning to white (*"corecțiile din spate să
        /// apară cu un galben șters și să facă fade înapoi la alb"*).
        private var bornAt: [Int: CFTimeInterval] = [:]
        /// The words a correction removed, fading out where they stood (x
        /// relative to their line's anchor) while their line reflows. `front`:
        /// the entry front a word replaced mid-entry had, frozen.
        private var ghosts: [(word: String, x: CGFloat, line: Int, since: CFTimeInterval, front: CGFloat?)] = []
        private var now: CFTimeInterval = CACurrentMediaTime()
        private var correctionsShown = 0
        private var lifts = 0
        /// `words[..<committed]` are frozen by the server; the rest is provisional.
        private var committed = 0
        /// **The next word starts a new line** (2026-09-28): the absolute index
        /// after a commit that ended a sentence. Used by an appended word only.
        private var breakBefore: Int?
        /// Per visible word: how solid it is drawn now, and where that is heading.
        private var opacity: [CGFloat] = []
        private var opacityTarget: [CGFloat] = []
        /// **Where the entry front is inside each visible word** (2026-09-27),
        /// in points from the word's left edge; `nil` once it is in.
        private var reveal: [CGFloat?] = []
        /// The last new word (not a gentle correction) and the last line to
        /// roll out: the silence clock runs from the later of the two.
        private var lastWordsAt: CFTimeInterval = CACurrentMediaTime()
        private var lastLiftAt: CFTimeInterval = 0
        /// Per word drawn letter by letter in the last frame: each glyph's
        /// opacity under the entry front. For `GET /test/state` only.
        private var glyphAlphas: [[CGFloat]] = []
        /// **The backdrop** (2026-09-28), in view points: as drawn, where it is
        /// heading (nil while no text shows), its target last frame, and how
        /// visible it is.
        private(set) var backdrop: NSRect = .zero
        private(set) var backdropTarget: NSRect?
        private var lastBackdropTarget: NSRect?
        private(set) var backdropAlpha: CGFloat = 0
        private static let spaceWidth = NSAttributedString(string: " ", attributes: fillAttributes).size().width

        /// **How far each visible word has come in**, 0…1: its revealed ink,
        /// the share of its width its line's centring counts.
        private var appear: [CGFloat] {
            reveal.indices.map { k in
                guard let r = reveal[k], k < widths.count else { return 1 }
                return Self.ink(r, width: widths[k])
            }
        }

        /// The mean opacity over `0…width` of a front at `r` with the soft
        /// edge: ∫ clamp((r − x)/e, 0, 1) dx / width. C¹ in `r`, so the
        /// centring built on it has no velocity step at a word's start or end.
        private static func ink(_ r: CGFloat, width: CGFloat) -> CGFloat {
            let e = LiveCaptionBand.softEdge
            func h(_ y: CGFloat) -> CGFloat { y <= 0 ? 0 : y <= e ? y * y / (2 * e) : y - e / 2 }
            guard width > 0 else { return 1 }
            return min(1, max(0, (h(r) - h(r - width)) / width))
        }

        /// The entry front's opacity for a glyph of visible word `k` centred at
        /// `x` (from the word's left edge).
        private func revealed(_ k: Int, at x: CGFloat) -> CGFloat {
            guard k < reveal.count, let r = reveal[k] else { return 1 }
            return min(1, max(0, (r - x) / LiveCaptionBand.softEdge))
        }

        override var isFlipped: Bool { false }
        override var wantsUpdateLayer: Bool { false }

        /// **Three passes, because one is muddy.** A single attributed string
        /// with fill + stroke + shadow draws the stroke pass *over* the fill,
        /// shadow included, and the white comes out grey (seen on the first
        /// screenshot, 2026-09-26). So: the shadow under everything, the black
        /// outline (a positive `strokeWidth` is stroke only, centred on the
        /// glyph edge), then the fill on top covering the inner half.
        private static let font = NSFont.systemFont(ofSize: LiveCaptionBand.fontSize, weight: LiveCaptionBand.fontWeight)
        private static let shadowAttributes: [NSAttributedString.Key: Any] = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return [.font: font, .foregroundColor: NSColor.black, .shadow: shadow]
        }()
        private static let strokeAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.black, .strokeColor: NSColor.black, .strokeWidth: 9.0,
        ]
        private static let fillAttributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        /// The faded yellow a correction starts from — and the softer one a
        /// batch correction starts from (*"corecțiile intră blând, atenuat"*).
        private static let correctionColour = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.45, alpha: 1)
        private static let gentleColour = NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.78, alpha: 1)
        /// Absolute indices of the words born gentle.
        private var gentleBorn = Set<Int>()
        static let lineHeight = NSAttributedString(string: "Ag", attributes: fillAttributes).size().height

        private var maxLineWidth: CGFloat { LiveCaptionBand.maxLineShare * bounds.width }

        /// The visible-word range of each line, by line index (lines are in
        /// order and `lineOf` never decreases).
        private func ranges() -> [Range<Int>] {
            var out: [Range<Int>] = []
            var k = 0
            for line in lines {
                let start = k
                while k < lineOf.count, lineOf[k] == line.id { k += 1 }
                out.append(start..<k)
            }
            return out
        }

        /// Each visible line's text box as the eye sees it now — from its first
        /// letter to the end of its ink, the trailing space left out — in view
        /// points. Lines with nothing drawn yet are left out.
        func lineBoxes() -> [NSRect] {
            let rs = ranges()
            let a = appear
            var out: [NSRect] = []
            for (i, r) in rs.enumerated() {
                guard let first = r.first, let last = r.last else { continue }
                let start = lines[i].anchor + shown[first]
                let end = lines[i].anchor + visibleWidth(r) - Self.spaceWidth * (last < a.count ? a[last] : 1)
                guard end - start >= 1 else { continue }
                out.append(NSRect(x: start, y: y(forSlot: lines[i].slot), width: end - start, height: Self.lineHeight))
            }
            return out
        }

        /// The backdrop follows the text box union: its continuous motion (ink
        /// coming in, a line gliding up) edge by edge, frame by frame; a jump
        /// (a line added or gone, a correction) eased at `lineGlide`.
        private func updateBackdrop(dt: CGFloat) {
            let boxes = lineBoxes()
            let k = 1 - exp(-dt / LiveCaptionBand.lineGlide)
            let target = boxes.isEmpty ? nil
                : boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }.insetBy(dx: -LiveCaptionBand.backdropPad, dy: -LiveCaptionBand.backdropPad)
            backdropTarget = target
            backdropAlpha += ((target == nil ? 0 : 1) - backdropAlpha) * k
            if backdropAlpha < 0.005 { backdropAlpha = 0 }
            guard let t = target else { lastBackdropTarget = nil; return }
            if backdrop == .zero || backdropAlpha < 0.05 && lastBackdropTarget == nil {
                backdrop = t; lastBackdropTarget = t; return
            }
            let last = lastBackdropTarget ?? t
            func follow(_ drawn: CGFloat, _ goal: CGFloat, _ was: CGFloat) -> CGFloat {
                let moved = goal - was
                let fed = abs(moved) <= 20 ? moved : 0
                let next = drawn + fed + (goal - drawn - fed) * k
                return abs(goal - next) < 0.3 ? goal : next
            }
            let x0 = follow(backdrop.minX, t.minX, last.minX), x1 = follow(backdrop.maxX, t.maxX, last.maxX)
            let y0 = follow(backdrop.minY, t.minY, last.minY), y1 = follow(backdrop.maxY, t.maxY, last.maxY)
            backdrop = NSRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
            lastBackdropTarget = t
        }

        /// Per line: it and every line above it stand in their slots.
        private func landedLines() -> [Bool] {
            var ok = true
            return lines.map { l in
                ok = ok && abs(l.slot - l.slotTarget) < LiveCaptionBand.landed
                return ok
            }
        }

        /// A line's width in the layout its words are heading for, and as the
        /// eye sees it now (each appended word counted as far as it has come in).
        private func targetWidth(_ r: Range<Int>) -> CGFloat {
            guard let last = r.last else { return 0 }
            return target[last] + widths[last]
        }
        private func visibleWidth(_ r: Range<Int>) -> CGFloat {
            guard let last = r.last else { return 0 }
            var end = shown[last] + widths[last]
            let a = appear
            for k in r where k < a.count { end -= (1 - a[k]) * widths[k] }
            return end
        }

        /// Where a line's anchor belongs for its visible text to sit centred.
        private func centredAnchor(_ r: Range<Int>, current: CGFloat) -> CGFloat {
            guard let first = r.first else { return current }
            let start = shown[first]
            let end = visibleWidth(r)
            return bounds.width / 2 - (start + end) / 2
        }

        /// What `GET /test/state` reports, for an assertion at a desk.
        func describe() -> [String: Any] {
            // `opacity` is what the eye sees of each word: its solidity times
            // the ink the entry front has revealed (1 once it is in).
            let a = appear
            let seen = opacity.indices.map { $0 < a.count ? opacity[$0] * a[$0] : opacity[$0] }
            let rs = ranges()
            let still = landedLines()
            let lineDescs: [[String: Any]] = lines.indices.map { i in
                let r = rs[i], l = lines[i]
                let vis = visibleWidth(r)
                let start = r.first.map { shown[$0] } ?? 0
                return ["id": l.id, "slot": Double(l.slot), "slotTarget": Double(l.slotTarget),
                        "first": dropped + r.lowerBound, "words": r.count,
                        "text": r.map { words[dropped + $0] }.joined(separator: " "),
                        "anchor": Double(l.anchor), "velocity": Double(l.velocity),
                        "width": Double(targetWidth(r)), "visibleWidth": Double(vis),
                        "centre": Double(l.anchor + (start + vis) / 2),
                        "opacity": r.map { Double(((($0 < seen.count ? seen[$0] : 1)) * 100).rounded() / 100) },
                        "readTime": LiveCaptionBand.readTime(words: r.count), "reason": l.reason,
                        "landed": still[i]]
            }
            let index = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($1.id, $0) })
            let silent = now - max(lastWordsAt, lastLiftAt)
            let liftIn: Any = rs.first.map { LiveCaptionBand.readTime(words: $0.count) - silent } ?? NSNull()
            return ["words": words.count, "dropped": dropped, "committed": committed,
                    "lines": lineDescs, "lineOf": lineOf.map { index[$0] ?? -1 },
                    "leaving": leaving.map { ["id": $0.line.id, "slot": Double($0.line.slot), "words": $0.words.count] as [String: Any] },
                    "lifts": lifts, "breakBefore": breakBefore.map { $0 as Any } ?? NSNull(),
                    "bandWidth": Double(bounds.width), "bandHeight": Double(bounds.height),
                    "maxLineWidth": Double(maxLineWidth), "linePitch": Double(LiveCaptionBand.linePitch),
                    "fontSize": Double(LiveCaptionBand.fontSize), "fontWeight": "semibold",
                    "velocity": Double(lines.map { abs($0.velocity) }.max() ?? 0),
                    "appear": a.map { Double(($0 * 100).rounded() / 100) },
                    "widths": widths.map { Double(($0 * 10).rounded() / 10) },
                    "reflowing": Double(zip(shown, target).map { abs($0 - $1) }.max() ?? 0),
                    "corrections": correctionsShown, "correcting": bornAt.keys.sorted(), "ghosts": ghosts.map { $0.word },
                    "opacity": seen.map { Double(($0 * 100).rounded() / 100) },
                    "reveal": reveal.map { r -> Any in r.map { Double($0.rounded()) } ?? NSNull() },
                    "revealSpeed": Double(LiveCaptionBand.revealSpeed),
                    "readMin": LiveCaptionBand.readMin, "readPerWord": LiveCaptionBand.readPerWord,
                    "idleFor": Double(now - lastWordsAt), "silentFor": Double(silent), "liftIn": liftIn,
                    "glyphAlphas": glyphAlphas.map { $0.map { Double(($0 * 100).rounded() / 100) } }]
        }

        func reset() {
            words = []
            dropped = 0
            lines = []; leaving = []; nextLineId = 0
            lineOf = []; target = []; shown = []; widths = []
            bornAt = [:]
            gentleBorn = []
            ghosts = []
            correctionsShown = 0
            lifts = 0
            committed = 0
            breakBefore = nil
            opacity = []; opacityTarget = []
            reveal = []
            lastWordsAt = CACurrentMediaTime()
            lastLiftAt = 0
            glyphAlphas = []
            backdrop = .zero; backdropTarget = nil; lastBackdropTarget = nil; backdropAlpha = 0
            needsDisplay = true
        }

        private static func endsSentence(_ word: String) -> Bool {
            guard let last = word.last(where: { !"\"'”’»)]".contains($0) }) else { return false }
            return ".?!…".contains(last)
        }

        func setWords(_ new: [String], committed newCommitted: Int, gentle: Bool = false, speakers: [Int] = []) {
            guard new != words || newCommitted != committed else { return split(atSpeakers: speakers) }
            let oldCommitted = committed
            committed = min(newCommitted, new.count)
            // **A commit that ends a sentence** (2026-09-28): the next word
            // starts a new line. A gentle batch correction is not a pause.
            if !gentle, committed > oldCommitted, committed > 0, Self.endsSentence(new[committed - 1]) {
                breakBefore = committed
            }
            retarget()
            guard new != words else { return split(atSpeakers: speakers) }
            let old = words
            let stamp = CACurrentMediaTime()
            if !gentle { lastWordsAt = stamp }
            // A gentle correction while every line has already rolled out:
            // nothing on screen to correct, and nothing to show.
            if gentle, lines.isEmpty, !old.isEmpty {
                words = new; dropped = new.count
                bornAt = [:]; gentleBorn = []; ghosts = []
                lineOf = []; target = []; shown = []; widths = []; opacity = []; opacityTarget = []; reveal = []
                return
            }
            // A revision that reaches back past what has already rolled out:
            // the lines on the band roll out too, and the new words start a
            // fresh top line. Nothing of the old lines is carried into it
            // (batch 5, LC7).
            let oldDropped = dropped
            var pairs: [(Int, Int)] = []
            var freshAll = old.isEmpty
            if !old.isEmpty, new.count <= dropped {
                liftAll()
                dropped = 0
                freshAll = true
            }
            var oldVisible: [String] = []
            if !freshAll {
                // **Aligned, not compared by index**: a recogniser that turns
                // "cinci sute" into "500" shifts every later word one place.
                // The whole sentence is aligned, so a revision among the words
                // already gone moves `dropped` with it instead of pulling one
                // of them back onto the band.
                let all = Self.align(old, new)
                var newDropped = min(dropped, new.count)
                if dropped > 0 {
                    let p = all.last(where: { $0.0 < oldDropped })
                    let q = all.first(where: { $0.0 >= oldDropped })
                    let lower = p.map { $0.1 + 1 } ?? 0
                    let guess = p.map { $0.1 + 1 + (oldDropped - 1 - $0.0) } ?? oldDropped
                    newDropped = max(lower, min(guess, q?.1 ?? new.count, new.count))
                }
                oldVisible = Array(old.dropFirst(oldDropped))
                dropped = newDropped
                pairs = all.filter { $0.0 >= oldDropped && $0.1 >= newDropped }.map { ($0.0 - oldDropped, $0.1 - newDropped) }
            }
            let newVisible = Array(new.dropFirst(dropped))
            var carried: [Int: CFTimeInterval] = [:]
            var carriedX: [Int: CGFloat] = [:]
            var carriedOpacity: [Int: CGFloat] = [:]
            var carriedReveal: [Int: CGFloat?] = [:]
            var carriedGentle = Set<Int>()
            var lineOfNew = [Int?](repeating: nil, count: newVisible.count)
            for (o, n) in pairs {
                if let at = bornAt[oldDropped + o] { carried[dropped + n] = at }
                if gentleBorn.contains(oldDropped + o) { carriedGentle.insert(dropped + n) }
                if o < shown.count { carriedX[n] = shown[o] }
                if o < opacity.count { carriedOpacity[n] = opacity[o] }
                if o < reveal.count { carriedReveal[n] = reveal[o] }
                if o < lineOf.count { lineOfNew[n] = lineOf[o] }
            }
            let matchedOld = Set(pairs.map { $0.0 })
            let matchedNew = Set(pairs.map { $0.1 })
            // Every old word no longer there fades out where it stood.
            for o in oldVisible.indices where !matchedOld.contains(o) && o < shown.count && o < lineOf.count {
                ghosts.append((oldVisible[o], shown[o], lineOf[o], stamp, o < reveal.count ? reveal[o] : nil))
            }
            let lastMatchedNew = pairs.last?.1 ?? -1
            let lastMatchedOld = pairs.last?.0 ?? -1
            // Past the last aligned pair: words are corrections only if they
            // *replaced* something — old words were there and are now gone.
            let tailReplaced = lastMatchedOld < oldVisible.count - 1
            var appended = Set<Int>()
            for n in newVisible.indices where !matchedNew.contains(n) {
                guard n < lastMatchedNew || tailReplaced else { appended.insert(n); continue }
                carried[dropped + n] = stamp
                if gentle { carriedGentle.insert(dropped + n) }
                correctionsShown += 1
            }
            // **A correction's words take the line of the words they replace**
            // (2026-09-28): the r-th new word of a gap takes the line of the
            // r-th old word of the same gap (the last one's, past its end); a
            // pure insertion takes the line of the word before it, or after it
            // at the very start.
            var prev = (-1, -1)
            for (o, n) in pairs + [(oldVisible.count, newVisible.count)] {
                let gapOld = Array((prev.0 + 1)..<max(prev.0 + 1, o))
                let gapNew = Array((prev.1 + 1)..<max(prev.1 + 1, n))
                for (r, j) in gapNew.enumerated() where !appended.contains(j) {
                    if !gapOld.isEmpty, let g = gapOld.last, g < lineOf.count {
                        lineOfNew[j] = lineOf[min(gapOld[min(r, gapOld.count - 1)], lineOf.count - 1)]
                    } else if j > 0, let l = lineOfNew[j - 1] {
                        lineOfNew[j] = l
                    } else if o < lineOf.count {
                        lineOfNew[j] = lineOf[o]
                    } else {
                        lineOfNew[j] = lines.last?.id
                    }
                }
                prev = (o, n)
            }
            widths = newVisible.map { Self.width(of: $0) }
            // Lines left with no word (a correction took them all) go; the
            // rest close up.
            let used = Set(lineOfNew.compactMap { $0 })
            lines.removeAll { !used.contains($0.id) }
            // **Appended words flow** (2026-09-28): onto the line of the word
            // before them, until a word would take that line past 80 % of the
            // band, or the word is the first after a sentence's commit — then
            // a new line.
            var lineWidth: [Int: CGFloat] = [:]
            for (j, l) in lineOfNew.enumerated() { if let l, !appended.contains(j) { lineWidth[l, default: 0] += widths[j] } }
            var opened: Set<Int> = []
            for j in appended.sorted() {
                let current: Int? = j > 0 ? lineOfNew[j - 1] : nil
                let w = widths[j]
                var reason: String?
                if let c = current {
                    let filled = lineWidth[c, default: 0]
                    if dropped + j == breakBefore, filled > 0 { reason = "sentence" }
                    else if filled > 0, filled + w > maxLineWidth { reason = "full" }
                } else {
                    reason = lines.isEmpty ? "first" : (dropped + j == breakBefore ? "sentence" : "full")
                }
                var line = current ?? lines.last?.id ?? -1
                if let reason {
                    let l = Line(id: nextLineId, slot: CGFloat(lines.count), slotTarget: CGFloat(lines.count), reason: reason)
                    nextLineId += 1
                    lines.append(l)
                    opened.insert(l.id)
                    line = l.id
                }
                lineOfNew[j] = line
                lineWidth[line, default: 0] += w
            }
            if let b = breakBefore, b < dropped + newVisible.count, appended.contains(b - dropped) || b < dropped { breakBefore = nil }
            bornAt = carried
            gentleBorn = carriedGentle
            words = new
            lineOf = lineOfNew.map { $0 ?? (lines.last?.id ?? 0) }
            // The new layout, per line; each word starts where its old self
            // was drawn, or in place if it is new.
            target = []
            var x: CGFloat = 0
            for k in widths.indices {
                if k == 0 || lineOf[k] != lineOf[k - 1] { x = 0 }
                target.append(x); x += widths[k]
            }
            shown = target.indices.map { carriedX[$0] ?? target[$0] }
            retarget()
            // A carried word keeps the opacity it had and eases from there; a
            // new one starts at its target: an appended word's fade-in is the
            // entry front's, and a correction has its own swap.
            opacity = target.indices.map { carriedOpacity[$0] ?? opacityTarget[$0] }
            // **An appended word enters behind the front** (2026-09-27): at 0,
            // or one word-width behind the word before it while that one is
            // still coming in, so a burst is one continuous edge — across a
            // line break too.
            var fronts: [CGFloat?] = []
            for n in target.indices {
                if let c = carriedReveal[n] { fronts.append(c); continue }
                guard appended.contains(n) else { fronts.append(nil); continue }
                if n > 0, let prev = fronts[n - 1] { fronts.append(min(0, prev - widths[n - 1])) }
                else { fronts.append(0) }
            }
            reveal = fronts
            // More than two lines: the top ones roll out.
            while lines.count > 2 { lift() }
            // Every line heads for its slot; a line opened by this update is
            // placed there (its words are still invisible), centred, at rest.
            let rs = ranges()
            for i in lines.indices {
                lines[i].slotTarget = CGFloat(i)
                if opened.contains(lines[i].id) {
                    lines[i].slot = CGFloat(i)
                    lines[i].anchor = centredAnchor(rs[i], current: bounds.width / 2)
                    lines[i].velocity = 0
                }
                // A jump of the goal made here (a correction) is eased; only
                // its motion from frame to frame (a word coming in) is fed
                // forward — so the goal is re-read in the new layout.
                lines[i].lastGoal = centredAnchor(rs[i], current: lines[i].anchor)
            }
            needsDisplay = true
            split(atSpeakers: speakers)
        }

        /// **A new voice starts a new line** (2026-10-14). Victor: *"break the
        /// line of the live captions when … you detect a different voice"*.
        /// The voices come from the batch correction's diarization, so they
        /// arrive on words already on screen — the one place a line is split
        /// after the fact, against the sticky-line rule: the words from the
        /// new voice on leave their line for one of their own, right below,
        /// gliding from where they stood (the new line starts at the old one's
        /// slot and anchor), and a third line lifts the top one as usual.
        /// Already split (the boundary is a line start) → nothing, so the same
        /// indices can come with every update.
        private func split(atSpeakers speakers: [Int]) {
            var opened = false
            for b in speakers.sorted() {
                let j = b - dropped
                guard j > 0, j < lineOf.count, lineOf[j] == lineOf[j - 1],
                      let at = lines.firstIndex(where: { $0.id == lineOf[j] }) else { continue }
                let old = lines[at]
                lines.insert(Line(id: nextLineId, anchor: old.anchor, slot: old.slot,
                                  slotTarget: old.slotTarget, reason: "speaker"), at: at + 1)
                for k in j..<lineOf.count where lineOf[k] == old.id { lineOf[k] = nextLineId }
                nextLineId += 1
                opened = true
            }
            guard opened else { return }
            target = []
            var x: CGFloat = 0
            for k in widths.indices {
                if k == 0 || lineOf[k] != lineOf[k - 1] { x = 0 }
                target.append(x); x += widths[k]
            }
            while lines.count > 2 { lift() }
            let rs = ranges()
            for i in lines.indices {
                lines[i].slotTarget = CGFloat(i)
                lines[i].lastGoal = centredAnchor(rs[i], current: lines[i].anchor)
            }
            needsDisplay = true
        }

        /// **The top line rolls out** (2026-09-28): its words leave the
        /// visible arrays (a snapshot draws them gliding up and fading), every
        /// line below moves up one slot.
        private func lift() {
            guard let top = lines.first else { return }
            var m = 0
            while m < lineOf.count, lineOf[m] == top.id { m += 1 }
            var snap: [(word: String, x: CGFloat, alpha: CGFloat, fill: NSColor)] = []
            let a = appear
            for k in 0..<m {
                let (fill, alpha) = look(k)
                snap.append((words[dropped + k], shown[k], alpha * (k < a.count ? a[k] : 1), fill))
            }
            var out = top
            out.slotTarget = top.slotTarget - 1
            for i in leaving.indices { leaving[i].line.slotTarget -= 1 }
            leaving.append(Leaving(line: out, words: snap))
            lines.removeFirst()
            for i in lines.indices { lines[i].slotTarget = CGFloat(i) }
            for k in 0..<m { bornAt[dropped + k] = nil; gentleBorn.remove(dropped + k) }
            dropped += m
            lineOf.removeFirst(m); target.removeFirst(m); shown.removeFirst(m); widths.removeFirst(m)
            opacity.removeFirst(min(m, opacity.count)); opacityTarget.removeFirst(min(m, opacityTarget.count))
            reveal.removeFirst(min(m, reveal.count))
            ghosts.removeAll { $0.line == top.id }
            if let b = breakBefore, b < dropped { breakBefore = nil }
            lifts += 1
            lastLiftAt = CACurrentMediaTime()
        }

        private func liftAll() { while !lines.isEmpty { lift() } }

        /// Where each visible word's opacity is heading: solid once committed,
        /// then a ramp down to `provisionalFloor` at the newest word.
        private func retarget() {
            let visible = max(0, words.count - dropped)
            let open = max(0, words.count - committed)
            opacityTarget = (0..<visible).map { k in
                let i = dropped + k
                guard i >= committed else { return 1 }
                let rank = CGFloat(i - committed + 1) / CGFloat(open)   // 1/open … 1
                return 1 - (1 - LiveCaptionBand.provisionalFloor) * rank
            }
            if opacity.count != opacityTarget.count {
                opacity = opacityTarget.indices.map { $0 < opacity.count ? opacity[$0] : opacityTarget[$0] }
            }
        }

        /// Longest common subsequence of two short word lists, as index pairs.
        /// **Words match on their stem, case-folded**: a commit that turns
        /// `world, how` into `world. How` has not changed a word, only the
        /// recogniser's punctuation and capitals — never a correction.
        static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
            guard !a.isEmpty, !b.isEmpty else { return [] }
            let sa = a.map { stem($0).lowercased() }, sb = b.map { stem($0).lowercased() }
            let w = b.count + 1
            var dp = [Int](repeating: 0, count: (a.count + 1) * w)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    dp[i * w + j] = sa[i] == sb[j] ? dp[(i + 1) * w + j + 1] + 1 : max(dp[(i + 1) * w + j], dp[i * w + j + 1])
                }
            }
            var out: [(Int, Int)] = []
            var i = 0, j = 0
            while i < a.count, j < b.count {
                if sa[i] == sb[j] { out.append((i, j)); i += 1; j += 1 }
                else if dp[(i + 1) * w + j] >= dp[i * w + j + 1] { i += 1 } else { j += 1 }
            }
            return out
        }

        private static func stem(_ word: String) -> Substring {
            var s = Substring(word)
            while let last = s.last, last.isPunctuation { s = s.dropLast() }
            return s
        }

        /// A word's advance, trailing space included.
        private static func width(of word: String) -> CGFloat {
            NSAttributedString(string: word + " ", attributes: fillAttributes).size().width
        }

        func advance(dt: CGFloat, now: CFTimeInterval, vMax: CGFloat, ease: CGFloat) {
            self.now = now
            // The lines' slots: rolling up, and out.
            let kg = 1 - exp(-dt / LiveCaptionBand.lineGlide)
            for i in lines.indices {
                let d = lines[i].slotTarget - lines[i].slot
                lines[i].slot += abs(d) < 0.002 ? d : d * kg
            }
            for i in leaving.indices {
                let d = leaving[i].line.slotTarget - leaving[i].line.slot
                leaving[i].line.slot += abs(d) < 0.002 ? d : d * kg
            }
            leaving.removeAll { $0.line.slot <= -0.995 || abs($0.line.slot - $0.line.slotTarget) < 0.002 && $0.line.slotTarget < 0 }
            // **Silence rolls the top line out after its read time**
            // (2026-09-28); the next one's time starts when it has moved up.
            if let r = ranges().first {
                let silent = now - max(lastWordsAt, lastLiftAt)
                if silent >= LiveCaptionBand.readTime(words: r.count) { lift() }
            }
            defer { updateBackdrop(dt: dt); needsDisplay = true }
            guard !lines.isEmpty, !widths.isEmpty else { return }
            // The reflow: every word eases toward its place in the new layout
            // and toward how solid it should be, and the entry front moves
            // through the words coming in — all before the anchors move.
            let k = 1 - exp(-dt / LiveCaptionBand.reflow)
            for i in shown.indices {
                let d = target[i] - shown[i]
                shown[i] += abs(d) < 0.3 ? d : d * k
            }
            let kf = 1 - exp(-dt / LiveCaptionBand.fadeIn)
            for i in opacity.indices where i < opacityTarget.count {
                let d = opacityTarget[i] - opacity[i]
                opacity[i] += abs(d) < 0.005 ? d : d * kf
            }
            // **The entry front**: every word still coming in advances by the
            // same step, so a burst stays one continuous edge; faster only to
            // clear a backlog within `revealCatchUp`, never past 0.7 `vMax`.
            // **Only in a line that stands still** (2026-09-28): a word not yet
            // begun in a line still gliding into place, or under one that is,
            // waits. One already half in finishes, riding its line up.
            let rs = ranges()
            let still = landedLines()
            var moving = [Bool](repeating: false, count: reveal.count)
            for (i, r) in rs.enumerated() where !still[i] {
                for k in r where k < moving.count { moving[k] = (reveal[k] ?? 1) <= 0 }
            }
            if let last = reveal.indices.last(where: { reveal[$0] != nil && !moving[$0] }), let r = reveal[last] {
                let backlog = max(0, widths[last] - r)
                let v = min(0.7 * vMax, max(LiveCaptionBand.revealSpeed, backlog / LiveCaptionBand.revealCatchUp))
                for i in reveal.indices where !moving[i] {
                    guard let r = reveal[i] else { continue }
                    let next = r + v * dt
                    reveal[i] = i < widths.count && next >= widths[i] + LiveCaptionBand.softEdge ? nil : next
                }
            }
            // **Each line's anchor tracks its centred position** (batch 5,
            // per line since 2026-09-28): the goal's own motion since the last
            // frame is fed forward, what is left of the gap (a correction's
            // jump) eases; never faster than `vMax`.
            for i in lines.indices {
                let goal = centredAnchor(rs[i], current: lines[i].anchor)
                let fed = lines[i].lastGoal.map { goal - $0 } ?? 0
                lines[i].lastGoal = goal
                var step = fed + (goal - lines[i].anchor - fed) * (1 - exp(-dt / ease))
                step = max(-vMax * dt, min(vMax * dt, step))
                if abs(goal - lines[i].anchor) < 0.3 { step = goal - lines[i].anchor }
                lines[i].velocity = abs(step) / max(dt, 0.0001)
                lines[i].anchor += step
            }
            let fadeOut = LiveCaptionBand.swap / 2
            ghosts.removeAll { now - $0.since >= fadeOut }
            for (i, at) in bornAt where now - at > LiveCaptionBand.swap + LiveCaptionBand.correctionFade { bornAt[i] = nil }
        }

        /// The fill colour and the opacity of visible word `k`: its swap fade-in
        /// if it is a correction, times how solid it is. The entry front is not
        /// in it: `draw` applies it per word or per glyph.
        private func look(_ k: Int) -> (NSColor, CGFloat) {
            var alpha = k < opacity.count ? opacity[k] : 1
            var colour = NSColor.white
            if let at = bornAt[dropped + k] {
                let t = now - at
                let half = LiveCaptionBand.swap / 2
                alpha *= CGFloat(min(1, max(0, (t - half) / half)))
                let warm = CGFloat(min(1, max(0, (t - LiveCaptionBand.swap) / LiveCaptionBand.correctionFade)))
                let start = gentleBorn.contains(dropped + k) ? Self.gentleColour : Self.correctionColour
                colour = start.blended(withFraction: warm, of: .white) ?? .white
            }
            return (colour, alpha)
        }

        /// How the entry front treats visible word `k`: `whole(a)` — 1 once it
        /// is in, 0 before the front reaches it; `glyphs` — the soft edge
        /// crosses it, so each letter gets its own opacity.
        private enum Entry { case whole(CGFloat), glyphs }
        private func entry(_ k: Int) -> Entry {
            guard k < reveal.count, let r = reveal[k] else { return .whole(1) }
            return r <= 0 ? .whole(0) : .glyphs
        }

        /// Each letter's x inside `word` (from its left edge), and one past the
        /// last: the typesetter's own caret offsets, so a word drawn whole and
        /// the same word's letters land on the same pixels, kerning included.
        private static func glyphEdges(of word: String) -> [CGFloat] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: fillAttributes))
            let ns = word as NSString
            var edges: [CGFloat] = []
            var i = word.startIndex
            while i < word.endIndex {
                let u = i.utf16Offset(in: word)
                edges.append(CTLineGetOffsetForStringIndex(line, u, nil))
                i = word.index(after: i)
            }
            edges.append(CTLineGetOffsetForStringIndex(line, ns.length, nil))
            return edges
        }

        /// A word drawn as one translucent group: the three passes inside a
        /// transparency layer at `alpha`. With `glyphAlpha`, **letter by
        /// letter** (2026-09-26 14:20): once the three passes are in the layer,
        /// each letter's column is multiplied by its own opacity
        /// (`destinationIn`). One layer for the word rather than one per letter,
        /// because a letter's black outline reaches past its edge and, drawn
        /// after its left neighbour, would bite into that neighbour's white.
        private func drawWord(_ word: String, at: NSPoint, fill: NSColor, alpha: CGFloat,
                              glyphAlpha: ((CGFloat) -> CGFloat)? = nil) {
            guard alpha > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
            var columns: [(x0: CGFloat, x1: CGFloat, a: CGFloat)] = []
            if let glyphAlpha {
                let edges = Self.glyphEdges(of: word)
                guard edges.count > 1 else { return }
                // The first and last columns reach out to cover the shadow and
                // outline beyond the letters; anything the columns miss would
                // stay at full opacity.
                let reach: CGFloat = 40
                var alphas: [CGFloat] = []
                for j in 0..<(edges.count - 1) {
                    let a = glyphAlpha((edges[j] + edges[j + 1]) / 2)
                    alphas.append(a)
                    let x0 = j == 0 ? edges[j] - reach : edges[j]
                    let x1 = j == edges.count - 2 ? edges[j + 1] + reach : edges[j + 1]
                    columns.append((at.x + x0, at.x + x1, a))
                }
                glyphAlphas.append(alphas)
                guard alphas.contains(where: { $0 * alpha > 0.01 }) else { return }
            }
            let faded = alpha < 0.999 || !columns.isEmpty
            if faded { ctx.saveGState(); ctx.setAlpha(alpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            NSAttributedString(string: word, attributes: Self.shadowAttributes).draw(at: at)
            NSAttributedString(string: word, attributes: Self.strokeAttributes).draw(at: at)
            var attrs = Self.fillAttributes
            attrs[.foregroundColor] = fill
            NSAttributedString(string: word, attributes: attrs).draw(at: at)
            if !columns.isEmpty {
                ctx.saveGState()
                ctx.setBlendMode(.destinationIn)
                for c in columns {
                    ctx.setFillColor(NSColor.black.withAlphaComponent(c.a).cgColor)
                    ctx.fill(CGRect(x: c.x0, y: bounds.minY, width: c.x1 - c.x0, height: bounds.height))
                }
                ctx.restoreGState()
            }
            if faded { ctx.endTransparencyLayer(); ctx.restoreGState() }
        }

        /// The y a line in `slot` is drawn at (0 is the top slot; a negative
        /// slot is above the band, rolling out).
        private func y(forSlot slot: CGFloat) -> CGFloat {
            bounds.height - LiveCaptionBand.padTop - Self.lineHeight - slot * LiveCaptionBand.linePitch
        }

        private(set) var drawMs: Double = 0
        override func draw(_ dirtyRect: NSRect) {
            let began = CACurrentMediaTime()
            defer { drawMs += ((CACurrentMediaTime() - began) * 1000 - drawMs) * 0.1 }
            glyphAlphas = []
            if backdropAlpha > 0.01, backdrop.width > 0 {
                LiveCaptionBand.backdropColour.withAlphaComponent(LiveCaptionBand.backdropColour.alphaComponent * backdropAlpha).setFill()
                NSBezierPath(roundedRect: backdrop, xRadius: LiveCaptionBand.backdropRadius,
                             yRadius: LiveCaptionBand.backdropRadius).fill()
            }
            // The lines rolling out: a snapshot, fading as they cross the top.
            for l in leaving {
                let fade = min(1, max(0, 1 + l.line.slot))
                guard fade > 0.01 else { continue }
                let y = y(forSlot: l.line.slot)
                for w in l.words {
                    drawWord(w.word, at: NSPoint(x: l.line.anchor + w.x, y: y), fill: w.fill, alpha: w.alpha * fade)
                }
            }
            guard !lines.isEmpty, !widths.isEmpty else { return }
            let rs = ranges()
            var slotOf = [CGFloat](repeating: 0, count: widths.count)
            var anchorOf = [CGFloat](repeating: 0, count: widths.count)
            for (i, r) in rs.enumerated() { for k in r { slotOf[k] = lines[i].slot; anchorOf[k] = lines[i].anchor } }
            // The settled words first, in three passes so a word's fill never
            // sits under its neighbour's shadow; then the ghosts and the words
            // fading in, each as its own translucent group. The one to three
            // words the entry front is sweeping are lettered; the ones it has
            // not reached are not drawn.
            var fading: [(String, NSPoint, NSColor, CGFloat)] = []
            var lettered: [(String, NSPoint, NSColor, CGFloat, Int)] = []
            for pass in 0..<3 {
                for k in widths.indices where dropped + k < words.count {
                    let word = words[dropped + k]
                    let at = NSPoint(x: anchorOf[k] + shown[k], y: y(forSlot: slotOf[k]))
                    var (fill, alpha) = look(k)
                    switch entry(k) {
                    case .whole(let a): alpha *= a
                    case .glyphs:
                        if pass == 0 { lettered.append((word, at, fill, alpha, k)) }
                        continue
                    }
                    if alpha < 0.999 { if pass == 0 { fading.append((word, at, fill, alpha)) }; continue }
                    switch pass {
                    case 0: NSAttributedString(string: word, attributes: Self.shadowAttributes).draw(at: at)
                    case 1: NSAttributedString(string: word, attributes: Self.strokeAttributes).draw(at: at)
                    default:
                        var attrs = Self.fillAttributes
                        attrs[.foregroundColor] = fill
                        NSAttributedString(string: word, attributes: attrs).draw(at: at)
                    }
                }
            }
            let fadeOut = LiveCaptionBand.swap / 2
            for g in ghosts {
                guard let line = lines.first(where: { $0.id == g.line }) else { continue }
                let alpha = CGFloat(1 - min(1, (now - g.since) / fadeOut))
                let at = NSPoint(x: line.anchor + g.x, y: y(forSlot: line.slot))
                if let r = g.front {
                    guard r > 0 else { continue }
                    drawWord(g.word, at: at, fill: .white, alpha: alpha) { x in
                        min(1, max(0, (r - x) / LiveCaptionBand.softEdge))
                    }
                } else {
                    drawWord(g.word, at: at, fill: .white, alpha: alpha)
                }
            }
            for (word, at, fill, alpha) in fading { drawWord(word, at: at, fill: fill, alpha: alpha) }
            for (word, at, fill, alpha, k) in lettered {
                drawWord(word, at: at, fill: fill, alpha: alpha) { [unowned self] x in self.revealed(k, at: x) }
            }
        }
    }
}
