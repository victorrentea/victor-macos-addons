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

    /// The 20% black wash over everything else while the bezel is up
    /// (2026-09-22, Victor's). The bezel is read in one glance and the glance
    /// has to land *in* it: over a bright IDE or a white browser page, a dark
    /// box in the middle is one more rectangle among twenty. Dimming the screen
    /// behind it is the cheapest way to say "this is the only thing on screen
    /// right now" — the same trick a Quick Look or a sheet plays.
    ///
    /// **20%, not more.** What is underneath still has to be legible: the
    /// window you are about to paste into is the context for choosing *which*
    /// clip, so the wash is a tint, not a curtain.
    ///
    /// It sits one level under the bezel and, like it, never takes focus and
    /// never takes a click — `ignoresMouseEvents`, so a scrim that somehow
    /// outlived its gesture could not trap the Mac (`ScreenBlackout` earns its
    /// click-through the same way).
    private final class ScrimPanel: NSPanel {
        static let opacity: CGFloat = 0.2

        init() {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            ignoresMouseEvents = true
            alphaValue = Self.opacity
            // One below the bezel: the wash covers the desktop, never the clip
            // it is there to set off.
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let content = NSView()
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.cgColor
            contentView = content
        }
    }

    private var panel: BezelPanel?
    /// Torn down in `close()` together with the bezel — the two are one piece of
    /// UI and must never be able to outlive each other.
    private var scrim: ScrimPanel?
    private var entries: [ClipboardEntry] = []
    private var index = 0
    /// True when the overlay was opened by the hotkey, i.e. with a hand on ⌘⇧:
    /// releasing ⌘ commits and the clip is **pasted**. False when it was opened
    /// from the menu, where there is no modifier to release, nothing is holding
    /// the previous app's focus, and the honest outcome is "it is on your
    /// clipboard" — see `commit()`.
    private var pastesOnCommit = false

    /// Set by `textView` while the body is being built and read by
    /// `statusRow` a moment later: true when the clip did not fit the box and
    /// what you are reading is its opening. It replaces a fixed character
    /// threshold (2026-09-21) — now that the box shows the text as it was
    /// copied, "is there more?" is a question about *this* box and *this* clip,
    /// not about a number of characters.
    private var textIsTruncated = false

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
        // Read the target while we are still on the main thread and the bezel is
        // still up — the paste itself runs on a background queue that sleeps
        // waiting for the hand to leave ⌘⇧. See `ClipboardPasteTarget`.
        let target = ClipboardPasteTarget.current()
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
            // ⌘V for everything except an image going into a Claude Code
            // prompt, which only ⌃V can carry — `ClipboardPasteKeystroke`.
            ClipboardPasteKeystroke.choose(isImage: entry.isImage,
                                           frontmostBundleID: target.bundleID,
                                           focusedWindowTitle: target.focusedWindowTitle).post()
        }
    }

    /// Esc, or any key that is not part of the gesture: the clipboard is left
    /// exactly as it was.
    func cancel() { close() }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        scrim?.orderOut(nil)
        scrim = nil
        entries = []
    }

    // MARK: - Drawing

    /// Put the wash up (or move it) under the bezel. Ordered front *before* the
    /// bezel is, every time, so the two arrive in the right order even on the
    /// first press.
    private func showScrim(covering frame: NSRect) {
        let scrim = self.scrim ?? ScrimPanel()
        scrim.setFrame(frame, display: false)
        scrim.orderFrontRegardless()
        self.scrim = scrim
    }

    private func render() {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        let screen = screenUnderCursor()
        let visible = screen.visibleFrame
        // **The whole screen, not `visibleFrame`**: the menu bar and the Dock
        // are part of what the bezel is asking you to stop looking at. Re-aimed
        // on every render because the bezel follows the cursor's screen, and a
        // wash left behind on the previous one would be a stain.
        showScrim(covering: screen.frame)

        // **The frame is the same for every clip** — one box, a quarter of the
        // screen's area, whatever is in it. Victor's, after walking a list of
        // mixed clips: sizing the panel to its contents made the whole thing
        // grow and shrink around its own centre on every press, so the first
        // line of a long text clip and of a short one were at different heights
        // and the eye had to find the words again each time. A fixed box means
        // an image is always in the same place and text always starts at the
        // same point; only the content changes.
        let box = bodyBox(on: screen)
        textIsTruncated = false
        let body: NSView = entry.isImage
            ? imageView(for: entry, in: box, screen: screen)
            : textView(for: entry, in: box)

        // **One line under the box, not two** (2026-09-17). The counter, the
        // legend and what-this-clip-is were a footer row plus a hint row, and
        // two rows of small grey text under a picture read as a paragraph you
        // are meant to *study*. Everything the bezel has to say fits on one
        // line: where you are and how to move on the left, what you are looking
        // at on the right.
        let status = statusRow(for: entry, width: box.width)

        let pad: CGFloat = 18, gap: CGFloat = 10
        let width = box.width + 2 * pad
        let height = pad + box.height + gap + status.frame.height + pad

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.97).cgColor
        content.layer?.cornerRadius = 16

        // The body view is placed inside the box rather than *being* it: an
        // image is centred in it, text hangs from its top-left corner.
        var y = height - pad - box.height
        body.setFrameOrigin(NSPoint(x: pad + (box.width - body.frame.width) / 2,
                                    y: entry.isImage
                                        ? y + (box.height - body.frame.height) / 2
                                        : y + box.height - body.frame.height))
        y -= gap + status.frame.height
        status.setFrameOrigin(NSPoint(x: pad, y: y))
        content.addSubview(body)
        content.addSubview(status)

        let panel = self.panel ?? BezelPanel()
        panel.contentView = content
        panel.setFrame(NSRect(x: visible.midX - width / 2,
                              y: visible.midY - height / 2,
                              width: width, height: height),
                       display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        // The bezel is the one piece of UI here nobody can screenshot on
        // demand — any keystroke dismisses it — so it says where it drew
        // itself. Cheap, once per press, and the only way to answer "it did
        // not appear" without taking the keyboard away from Victor.
        overlayInfo(String(format: "📋 clip %d/%d on screen %.0f×%.0f at %.0f,%.0f (panel %.0f×%.0f)",
                           index + 1, entries.count,
                           visible.width, visible.height,
                           panel.frame.origin.x, panel.frame.origin.y, width, height))
    }

    /// **The box every clip is drawn in: a quarter of the screen's area** —
    /// Victor's size — which is half the width by half the height of the
    /// screen the bezel is on. Constant for that screen, so the panel is the
    /// same rectangle in the same place for a 3000×2000 screenshot and for a
    /// two-word clip.
    private func bodyBox(on screen: NSScreen) -> NSSize {
        let visible = screen.visibleFrame
        return NSSize(width: (visible.width / 2).rounded(), height: (visible.height / 2).rounded())
    }

    /// The image, fitted inside the box with its aspect ratio kept and
    /// **never scaled up past 1:1** — a copied 120×40 button would otherwise
    /// become a wall of interpolation, and the size of a clip is itself
    /// information: a small image should look small.
    private func imageView(for entry: ClipboardEntry, in box: NSSize, screen: NSScreen) -> NSView {
        guard case .image(let pixelWidth, let pixelHeight, _) = entry.kind,
              pixelWidth > 0, pixelHeight > 0 else {
            return label(text: "(unreadable image)", font: .systemFont(ofSize: 14),
                         color: .systemRed, width: box.width)
        }
        let backing = max(1, screen.backingScaleFactor)
        let natural = NSSize(width: CGFloat(pixelWidth) / backing, height: CGFloat(pixelHeight) / backing)
        let factor = min(1, box.width / natural.width, box.height / natural.height)
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

    /// Text hangs from the **top** of the box, at the box's full width, and is
    /// cut off at its bottom rather than growing the panel: the first line has
    /// to land on the same pixel for every clip, which is the whole point of
    /// the fixed box.
    ///
    /// **It fills the box.** The line breaks are the ones that were copied (see
    /// `ClipboardHistoryPolicy.preview`) and the box takes as many lines as it
    /// has room for — `maximumNumberOfLines` counts *drawn* lines, so one long
    /// line that wraps four times spends four of them, which is exactly the
    /// accounting the box needs. The last line that fits gets the ellipsis;
    /// clipping the height alone would have sliced a row of glyphs in half and
    /// said nothing about there being more.
    ///
    /// **Behind the words, the icon of the app the text was copied from**, at
    /// 30% and centred on the box (2026-09-22). It is the fact Flycut puts in
    /// its footer, in the only form that does not cost a glance: nothing about
    /// a watermark asks to be read, and by the time the eye has taken in two
    /// lines of a stack trace it already knows the clip came out of the
    /// terminal. Centred rather than tucked in a corner because the text hangs
    /// from the top and leaves the middle of the box empty for short clips —
    /// which are exactly the ones whose words say least about where they came
    /// from. Nothing is drawn when the clip has no source app (the one picked
    /// up at launch) or the app is gone from the disk.
    private func textView(for entry: ClipboardEntry, in box: NSSize) -> NSView {
        guard case .text(let string) = entry.kind else { return NSView() }
        let font = NSFont.systemFont(ofSize: 17)
        let field = NSTextField(wrappingLabelWithString: ClipboardHistoryPolicy.preview(string))
        field.font = font
        field.textColor = NSColor(white: 0.95, alpha: 1)
        field.drawsBackground = false
        field.isBezeled = false
        field.isSelectable = false
        field.lineBreakMode = .byTruncatingTail
        field.preferredMaxLayoutWidth = box.width
        field.maximumNumberOfLines = 0
        // Measured uncapped first, because the honest answer to "is there more
        // of this clip?" is whether the whole of it would have overflowed the
        // box — and after the cap is set, nothing can overflow it any more.
        let full = field.sizeThatFits(NSSize(width: box.width, height: .greatestFiniteMagnitude))
        textIsTruncated = full.height > box.height + 1
        field.maximumNumberOfLines = max(1, Int(box.height / NSLayoutManager().defaultLineHeight(for: font)))
        let fitted = field.sizeThatFits(NSSize(width: box.width, height: .greatestFiniteMagnitude))
        field.frame = NSRect(x: 0, y: 0, width: box.width, height: min(fitted.height, box.height))

        // The container **is** the box, so the text keeps hanging from its top
        // (render() top-aligns a body the size of the box) and the watermark
        // gets the whole box to be centred in.
        let layered = NSView(frame: NSRect(origin: .zero, size: box))
        if let mark = watermark(for: entry, in: box) { layered.addSubview(mark) }
        field.setFrameOrigin(NSPoint(x: 0, y: box.height - field.frame.height))
        layered.addSubview(field)
        return layered
    }

    /// The source app's icon, washed out and centred on the box. Sized to a bit
    /// over half the box's short side: big enough to be recognised at a glance
    /// as a shape, small enough that the text keeps the box.
    private func watermark(for entry: ClipboardEntry, in box: NSSize) -> NSView? {
        guard let bundleID = entry.sourceBundleID, let icon = appIcon(bundleID) else { return nil }
        let side = (min(box.width, box.height) * 0.55).rounded()
        let view = NSImageView(frame: NSRect(x: ((box.width - side) / 2).rounded(),
                                             y: ((box.height - side) / 2).rounded(),
                                             width: side, height: side))
        view.image = icon
        view.imageScaling = .scaleProportionallyUpOrDown
        // Victor's number: 30% opaque. Enough to read the icon's silhouette and
        // its colour, far enough back that a line of text crossing it is still
        // the thing the eye lands on first.
        view.alphaValue = 0.3
        return view
    }

    /// Bundle id → icon, remembered for the run. `urlForApplication` is a
    /// LaunchServices lookup and this is called on every press of V, walking a
    /// list where the same few apps come round again and again. An id that
    /// resolves to nothing (app deleted since the copy) is remembered as such,
    /// so the miss is paid once too.
    private var iconCache: [String: NSImage?] = [:]

    private func appIcon(_ bundleID: String) -> NSImage? {
        if let hit = iconCache[bundleID] { return hit }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        iconCache[bundleID] = icon
        return icon
    }

    /// The one line under the box.
    ///
    /// **Left**: where you are in the list and how to move — `3 / 6` in the
    /// accent colour, then the legend. ⏎ and ⌫ are not on it although they
    /// work: the line is read at a glance with a hand holding ⌘⇧, and the keys
    /// that belong to that hold are V and the arrows (⏎ only duplicates letting
    /// go of ⌘, and nobody reaches for ⌫ mid-gesture).
    ///
    /// **Right**: only what the clip cannot say for itself. **When** it was
    /// copied is the whole of the provenance *in words* — Flycut spends a line
    /// of its footer naming the source app, which is the wrong question for two
    /// clips out of the same editor and, since 2026-09-22, an answer this bezel
    /// gives without words anyway (the watermark in `textView`). Nothing else is
    /// added, with one exception: a text clip the box could not hold prints its
    /// length, because then the count stops being trivia and becomes the one
    /// fact the panel cannot show — that these words are the opening of
    /// something much bigger.
    private func statusRow(for entry: ClipboardEntry, width: CGFloat) -> NSView {
        // Sized to their own text, not to the box: three labels share this line
        // and the two on the left are placed one after the other, so a label
        // that reports the box's width as its own pushes the next one off the
        // panel entirely.
        let counter = fittedLabel(text: "\(index + 1) / \(entries.count)",
                                  font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                  color: NSColor.systemYellow.withAlphaComponent(0.9))
        let hint = fittedLabel(text: "V next  ·  ↑↓ walk  ·  Esc",
                               font: .systemFont(ofSize: 11),
                               color: NSColor(white: 0.5, alpha: 1))

        // An image says nothing about itself. `🖼️ 3000×2000 · 142 KB` was there
        // on the theory that two screenshots of the same window are told apart
        // by their size; Victor, looking at it: *"mărimea pozei în px și kb nu
        // mă interesează"* (2026-09-17). You recognise a picture by looking at
        // it, and the picture is right there at a quarter of the screen.
        var facts = [ClipboardHistoryPolicy.age(Date().timeIntervalSince(entry.copiedAt))]
        if case .text(let string) = entry.kind, textIsTruncated {
            facts.append("\(string.count) chars")
        }
        let right = fittedLabel(text: facts.joined(separator: "  ·  "), font: .systemFont(ofSize: 12),
                                color: NSColor(white: 0.62, alpha: 1))

        let height = max(counter.frame.height, hint.frame.height, right.frame.height)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        counter.frame = NSRect(x: 0, y: 0, width: counter.frame.width, height: height)
        hint.frame = NSRect(x: counter.frame.width + 14, y: 0, width: hint.frame.width, height: height)
        right.frame = NSRect(x: max(hint.frame.maxX + 14, width - right.frame.width), y: 0,
                             width: right.frame.width, height: height)
        row.addSubview(counter)
        row.addSubview(hint)
        row.addSubview(right)
        return row
    }

    /// A label exactly as wide as its own text — what every label on the status
    /// line needs, since they sit next to each other.
    private func fittedLabel(text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.drawsBackground = false
        field.isBezeled = false
        field.sizeToFit()
        return field
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
