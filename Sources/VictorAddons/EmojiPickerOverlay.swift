import AppKit

/// 😀 left ⌥ tapped twice (`OptionDoubleTap`) — the emoji picker for every
/// emoji that is **not** on a key.
///
/// Opens exactly where the ⌥ cheat-sheet does (`KeymapOverlayPlacement`): the
/// right-hand external screen when there is one the mouse is not on, otherwise
/// small in the retina's bottom-right corner. Same layout in both, scaled up on
/// the external one, so what the eye learns on one screen holds on the other.
///
/// Three zones, top to bottom:
/// - **search field + why.** Typing searches English and Romanian names and
///   keywords; beside the small field, why the selected one matched.
/// - **name line.** What the hovered / selected emoji is called, en · ro.
///   **Why** it matched sits beside the field: the word each typed word was
///   found in, the matched letters in yellow, and whether it is the name, a
///   keyword or a crowd synonym (~).
/// - **the board.** Empty at first; every emoji you use lands on it and stays
///   in that cell forever (`EmojiBoard`), so it is a map learnt by position,
///   never scrolled. Nothing on a ⌥ / ⌥⇧ / ⌃⌥ key ever appears on it. Clickable.
///   **While searching, the matches take the board over**, best in the centre
///   and selected, the rest in rings around it (Victor, 2026-10-04 — it
///   replaced a one-row strip beside the field, where ½ never made the cut);
///   an empty field brings the saved board back. A keyed emoji may show up
///   among the matches, with its chord printed under it.
///
/// **Focus: it never takes it** (2026-10-04). Victor types emoji into
/// ScreenBrush's text mode, and ScreenBrush drops out of text mode the moment
/// it stops being the active app — which the first version did on every open,
/// by activating itself so its search box could have the keyboard. So the
/// panel cannot become key and the app is never activated: while it is up,
/// the event tap swallows each keystroke and hands it here
/// (`EmojiPickerKey`), the way the ⌘⇧V bezel is driven, and a click on the
/// non-activating panel does not move focus either. A pick types the emoji as
/// one synthetic keystroke carrying the string (`keyboardSetUnicodeString`)
/// into whatever still has focus — ScreenBrush's text box, a document's
/// caret. Not pasted, so the clipboard and the ⌘⇧V history are left alone.
/// (Before that: a key-taking non-activating panel lost the keyboard to
/// PowerPoint in 0.3 s; activating fixed that and broke ScreenBrush.)
///
/// **Two ways in.** Left ⌥ ×2 opens it until a pick, Esc, a click outside or
/// ⌥ ×2 again — the search lives here. **⌃⇧ held** opens it only while held,
/// the soundboard's gesture: hold, click a tile, let go (`EmojiPickerHold`).
final class EmojiPickerController: NSObject {
    private let retinaScreenProvider: () -> NSScreen
    private let catalog: EmojiCatalog
    private var panel: EmojiPickerPanel?
    private var field: NSTextField?
    private var hint: NSTextField?
    private var grid: EmojiBoardView?
    private var nameLine: NSTextField?
    private var keyed: [String: String] = [:]
    private var query = ""
    private var memory = EmojiQueryMemory()
    private var scale: CGFloat = 1
    private var clickMonitor: Any?
    /// Tells the event tap whether to route keystrokes here. Called with
    /// false *before* a pick is typed, so the tap lets that keystroke through.
    var onOpenChanged: ((Bool) -> Void)?

    init(retinaScreenProvider: @escaping () -> NSScreen, catalog: EmojiCatalog = .shared) {
        self.retinaScreenProvider = retinaScreenProvider
        self.catalog = catalog
    }

    static let slideInDuration: TimeInterval = 0.20

    var isVisible: Bool { panel != nil }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        guard panel == nil else { return }
        keyed = EmojiPickerPolicy.liveKeyedEmoji()
        memory = EmojiQueryMemoryStore.memory
        query = ""
        let retina = retinaScreenProvider()
        let retinaID = Self.screenID(retina)
        let externals = NSScreen.screens.filter { Self.screenID($0) != retinaID }.map(\.frame)
        let placed = EmojiPickerPlacement.frame(retinaFrame: retina.frame, externalFrames: externals,
                                                mouseLocation: NSEvent.mouseLocation)
        build(frame: placed.frame, scale: placed.scale)
        guard let panel else { return }
        onOpenChanged?(true)
        // A click anywhere outside the panel dismisses it, like any popover.
        // Clicks on the panel itself are local events and never reach this.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        // victor-effects' soundboard entrance: in from the right edge, fading
        // in as it slides, 0.20 s ease-out.
        let target = placed.frame
        panel.setFrame(target.offsetBy(dx: target.width, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        overlayInfo("EmojiPicker: opened \(Int(placed.frame.width))×\(Int(placed.frame.height)) @\(placed.scale)x, \(keyed.count) keyed emoji hidden")
    }

    func close(then typing: String? = nil) {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        onOpenChanged?(false)
        guard let typing else { return }
        // Under the ⌃⇧ hold a keystroke would arrive as a ⌃⇧ chord, so first
        // try to write the text straight into the focused text box — the
        // emoji is there on the click, ⌃⇧ still down (Victor: "să nu fie
        // nevoie să ridic Control Shift"). Only with no modifier held is the
        // keystroke the better tool: it works in every app, AX does not.
        if KeySimulator.heldModifiers().isEmpty {
            Self.type(typing)
        } else if FocusedTextInsertion.insert(typing) {
            overlayInfo("EmojiPicker: inserted through Accessibility, modifiers still held")
        } else {
            overlayInfo("EmojiPicker: focused element refused AX insertion — typing once the modifiers are up")
            Self.typeOnceModifiersAreUp(typing, attemptsLeft: 250)
        }
    }

    /// The fallback when AX insertion is refused: typed only when no modifier
    /// is physically down, since a pick made under the ⌃⇧ hold would otherwise
    /// reach the app merged with the held keys — ⌃⇧ plus a character is a
    /// shortcut, not text. Polled on main (20 ms, up to 5 s), never blocking.
    private static func typeOnceModifiersAreUp(_ text: String, attemptsLeft: Int) {
        guard !KeySimulator.heldModifiers().isEmpty, attemptsLeft > 0 else {
            type(text)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            typeOnceModifiersAreUp(text, attemptsLeft: attemptsLeft - 1)
        }
    }

    // MARK: - Building

    private func build(frame: NSRect, scale s: CGFloat) {
        scale = s
        let panel = EmojiPickerPanel(frame: frame)
        let W = frame.width, H = frame.height
        // Tight margins (Victor, 2026-10-04: *"mai redu borderul"*): every
        // point of the retina corner the plate keeps is one the tiles don't
        // get. `EmojiPickerPlacement.chrome` must add up to the same.
        let pad = EmojiPickerPlacement.pad * s

        // Full screen on an external: square edges, nothing to round. (Not
        // `s > 1`: the retina corner is scaled too when it is the only screen.)
        let fullScreen = NSScreen.screens.contains { $0.frame == frame }
        let root = EmojiPickerBackground(frame: NSRect(origin: .zero, size: frame.size), radius: fullScreen ? 0 : 8 * s)  // tight margins: a big radius would cut the corner tiles
        panel.contentView = root

        // Top bar: the search box on the left, matches to its right.
        let barHeight = EmojiPickerPlacement.barHeight * s
        let barY = H - pad - barHeight
        // Small (Victor, 2026-10-04: *"fă căsuța text mică"*): a few words fit,
        // and the match explanation beside it gets the room.
        let fieldWidth = 150 * s
        let box = NSView(frame: NSRect(x: pad, y: barY + (barHeight - 32 * s) / 2, width: fieldWidth, height: 32 * s))
        box.wantsLayer = true
        box.layer?.backgroundColor = EmojiPickerStyle.fieldBackground.cgColor
        box.layer?.cornerRadius = 9 * s
        root.addSubview(box)

        // A label, not an editable field: the text comes from the event tap.
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 17 * s)
        field.lineBreakMode = .byTruncatingHead
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: 10 * s, y: (box.frame.height - fieldHeight) / 2, width: fieldWidth - 20 * s, height: fieldHeight)
        box.addSubview(field)

        let hintX = box.frame.maxX + 16 * s
        let hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 13 * s)
        hint.textColor = EmojiPickerStyle.header
        hint.lineBreakMode = .byTruncatingTail
        let hintHeight = hint.intrinsicContentSize.height
        hint.frame = NSRect(x: hintX, y: barY + (barHeight - hintHeight) / 2, width: W - hintX - pad, height: hintHeight)
        root.addSubview(hint)

        // Name line under the bar.
        let nameHeight = EmojiPickerPlacement.nameHeight * s
        let nameLine = NSTextField(labelWithString: "")
        nameLine.font = .systemFont(ofSize: 13 * s)
        nameLine.textColor = EmojiPickerStyle.dim
        nameLine.lineBreakMode = .byTruncatingTail
        nameLine.frame = NSRect(x: pad + 4 * s, y: barY - nameHeight, width: W - 2 * pad, height: nameHeight)
        nameLine.allowsDefaultTighteningForTruncation = true
        root.addSubview(nameLine)

        // The board fills the rest.
        let gridTop = nameLine.frame.minY
        var board = EmojiBoardStore.boardSeedingOnce(catalog: catalog, keyed: Set(keyed.keys))
        board.removeKeyed(Set(keyed.keys))
        EmojiBoardStore.board = board
        let grid = EmojiBoardView(frame: NSRect(x: pad, y: pad, width: W - 2 * pad, height: gridTop - pad),
                                  board: board, catalog: catalog, scale: s)
        grid.keyed = keyed
        grid.onPick = { [weak self] entry in self?.pick(entry) }
        grid.onFocus = { [weak self] entry in self?.showName(entry) }
        grid.onRemove = { [weak self] emoji in
            var board = EmojiBoardStore.board
            board.remove(emoji)
            EmojiBoardStore.board = board
            self?.grid?.board = board
            self?.showName(self?.grid?.selectedEntry)
        }
        root.addSubview(grid)

        self.panel = panel
        self.field = field
        self.hint = hint
        self.grid = grid
        self.nameLine = nameLine
        refreshQuery()
    }

    /// The name line says what the emoji is; while searching, the slot right
    /// of the box says why it matched (Victor, 2026-10-04: the explanation
    /// goes there, in place of the key hints and the match count).
    private func showName(_ entry: EmojiEntry?) {
        guard let nameLine, let hint else { return }
        hint.stringValue = ""
        guard let entry else { nameLine.stringValue = ""; return }
        let font = NSFont.systemFont(ofSize: 13 * scale)
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: EmojiPickerStyle.dim]
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let line = NSMutableAttributedString()
            for (index, match) in catalog.explain(trimmed, entry).enumerated() {
                if index > 0 { line.append(NSAttributedString(string: "  +  ", attributes: dim)) }
                // A crowd synonym reads as "~word": near the meaning, not its name.
                if match.source == .synonym { line.append(NSAttributedString(string: "~", attributes: dim)) }
                for (offset, letter) in match.word.enumerated() {
                    let lit = match.matched.contains(offset)
                    line.append(NSAttributedString(string: String(letter), attributes: [
                        .font: lit ? NSFont.boldSystemFont(ofSize: 13 * scale) : font,
                        .foregroundColor: lit ? EmojiPickerStyle.chord : NSColor.white,
                    ]))
                }
                if match.romanian { line.append(NSAttributedString(string: " 🇷🇴", attributes: dim)) }
                switch match.source {
                case .name: line.append(NSAttributedString(string: " (nume)", attributes: dim))
                case .keyword: line.append(NSAttributedString(string: " (cuvânt-cheie)", attributes: dim))
                case .synonym: break
                }
            }
            if let remembered = memory.reason(trimmed, entry.emoji) {
                line.append(NSAttributedString(string: "  ·  ales de \(remembered.pick.count)× pentru „\(remembered.query)”", attributes: [
                    .font: font, .foregroundColor: EmojiPickerStyle.chord,
                ]))
            }
            hint.attributedStringValue = line
        }
        var text = "\(entry.emoji)  \(entry.name)"
        if !entry.nameRo.isEmpty, entry.nameRo != entry.name { text += "  ·  \(entry.nameRo)" }
        if let chord = keyed[EmojiPickerPolicy.normalized(entry.emoji)] { text += "    — e deja pe \(chord)" }
        nameLine.attributedStringValue = NSAttributedString(string: text, attributes: dim)
    }

    // MARK: - Picking

    private func pick(_ entry: EmojiEntry) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            memory.record(query: trimmed, emoji: entry.emoji)
            EmojiQueryMemoryStore.memory = memory
        }
        if keyed[EmojiPickerPolicy.normalized(entry.emoji)] == nil {
            var board = EmojiBoardStore.board
            board.use(entry)
            EmojiBoardStore.board = board
        }
        close(then: entry.emoji)
    }

    static func type(_ text: String) {
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        for event in [down, up] {
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard (from the event tap)

    /// What typing `query` would do — for the test hook.
    func search(_ text: String) {
        query = text
        refreshQuery()
    }

    func handle(_ key: EmojiPickerKey) {
        guard isVisible else { return }
        switch key {
        case .escape, .passThrough:
            close()
        case .enter:
            if let entry = grid?.selectedEntry { pick(entry) }
        case .backspace:
            if !query.isEmpty { query.removeLast(); refreshQuery() }
        case .left:
            grid?.move(dx: -1, dy: 0)
        case .right:
            grid?.move(dx: 1, dy: 0)
        case .up:
            grid?.move(dx: 0, dy: -1)
        case .down:
            grid?.move(dx: 0, dy: 1)
        case .text(let typed):
            query += typed
            refreshQuery()
        case .ignore:
            break
        }
    }

    private func refreshQuery() {
        guard let field, let grid else { return }
        let font = NSFont.systemFont(ofSize: 17 * scale)
        if query.isEmpty {
            field.attributedStringValue = NSAttributedString(string: "🔍 caută", attributes: [
                .foregroundColor: EmojiPickerStyle.dim, .font: font,
            ])
        } else {
            // A drawn caret: the label is not a real text field, but it should
            // still read as one being typed into.
            let text = NSMutableAttributedString(string: query, attributes: [.foregroundColor: NSColor.white, .font: font])
            text.append(NSAttributedString(string: "▏", attributes: [.foregroundColor: EmojiPickerStyle.hoverRing, .font: font]))
            field.attributedStringValue = text
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let results = trimmed.isEmpty ? nil
            : memory.reorder(catalog.search(trimmed, limit: EmojiBoard.columns * EmojiBoard.rows), for: trimmed)
        grid.results = results
        showName(grid.selectedEntry)
    }

    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Puts text at the caret of whatever text box has focus, through the
/// Accessibility API — no keystroke, so the modifiers physically held at the
/// time cannot turn it into a shortcut. Setting `kAXSelectedText` replaces the
/// selection (an empty one at the caret) the way typing would.
///
/// Verified rather than trusted: some elements report success and do nothing,
/// so when the value is readable it must actually have changed; only an
/// element whose value cannot be read at all is taken at its word. A `false`
/// means "type it instead", never "it's done".
enum FocusedTextInsertion {
    private static let messagingTimeout: Float = 0.3

    static func insert(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let before = value(of: element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        guard let before else { return true }
        return value(of: element) != before
    }

    private static func value(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}

/// ⌃⇧ held → the picker, for as long as it is held (Victor, 2026-10-04: *"poate
/// să apară și la ctrl+shift ținute apăsat?"*) — the soundboard's hold-and-click.
///
/// Same patience as the ⌥ cheat-sheet (`KeymapHoldCoordinator.delay`): a ⌃⇧
/// that is the start of a shortcut is over long before it, and any key pressed
/// under it cancels — that hold was a shortcut, not a question. Letting go
/// closes a picker this hold opened; one opened by ⌥ ×2 is not its to close.
final class EmojiPickerHold {
    private let delay: () -> TimeInterval
    private let open: () -> Bool
    private let close: () -> Void
    private var pending: DispatchWorkItem?
    private var spent = false
    private(set) var openedByHold = false

    /// `open` returns whether it actually opened (false when ⌥ ×2 already had).
    init(delay: @escaping () -> TimeInterval, open: @escaping () -> Bool, close: @escaping () -> Void) {
        self.delay = delay
        self.open = open
        self.close = close
    }

    func held(_ down: Bool) {
        if down {
            guard pending == nil, !openedByHold, !spent else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.openedByHold = self.open()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay(), execute: work)
        } else {
            pending?.cancel()
            pending = nil
            spent = false
            if openedByHold { openedByHold = false; close() }
        }
    }

    /// A key went down while ⌃⇧ were held.
    func keyPressed() {
        pending?.cancel()
        pending = nil
        spent = true
    }
}

/// Where the picker goes and how big it is drawn there.
enum EmojiPickerPlacement {
    /// The plate's margin, the search bar's and the name line's heights, in
    /// points at scale 1 — shared with `EmojiPickerController.build`, so the
    /// corner is exactly as tall as what it holds.
    static let pad: CGFloat = 4
    static let barHeight: CGFloat = 40
    static let nameHeight: CGFloat = 20
    static var chrome: CGFloat { 2 * pad + barHeight + nameHeight }
    /// The most of the retina's width, and of its height, the corner panel takes.
    static let maxShare: CGFloat = 0.5

    /// The screen choice is the ⌥ cheat-sheet's, so both appear in the same
    /// place. On an external screen it takes the **whole screen**, like the
    /// cheat-sheet (Victor: "full screen, nu fereastră"), and everything —
    /// cells, fonts, spacing — grows by `scale` together. On the retina it
    /// sits in the bottom-right corner, small enough to leave the projected
    /// slide readable: 1× when an external is plugged in, 1.3× when the
    /// retina is the only screen.
    ///
    /// The corner is 25% wider than it was (0.45 of the retina, was 0.36;
    /// Victor, 2026-10-04) at the same cell size, which is where the board's
    /// five extra columns came from; on the external the same board fills the
    /// screen.
    static func frame(retinaFrame: NSRect, externalFrames: [NSRect], mouseLocation: CGPoint?) -> (frame: NSRect, scale: CGFloat) {
        let target = KeymapOverlayPlacement.frame(retinaFrame: retinaFrame, externalFrames: externalFrames,
                                                  imageAspectRatio: 1, mouseLocation: mouseLocation)
        if externalFrames.contains(target) {
            return (target, min(max(target.height / 620, 1), 2))
        }
        // Retina alone (no external to send it to): 30% bigger on both axes,
        // everything scaled together (Victor, 2026-10-04) — there is no other
        // screen to read it on, so it may take more of the slide. Then 40%
        // bigger again, tiles and type alike (*"increase size of emoji buttons
        // by 40%"*). Both **capped so the panel never takes more than half the
        // retina's width or half its height** (later the same night: *"să nu
        // treacă de 50% din h și 50% din w"*) — the scale shrinks as a whole,
        // so the panel keeps its proportions rather than squashing the board.
        let base = max(retinaFrame.width * 0.45, 590)
        // At scale 1: search bar and name line (`chrome`) plus `rows` square
        // cells — exactly as tall as the board needs, no dead band.
        let baseHeight = Self.chrome + (base - 2 * pad) / CGFloat(EmojiBoard.columns) * CGFloat(EmojiBoard.rows)
        let wanted: CGFloat = (externalFrames.isEmpty ? 1.3 : 1) * 1.4
        let scale = min(wanted, retinaFrame.width * maxShare / base, retinaFrame.height * maxShare / baseHeight)
        let width = (base * scale).rounded(.down)
        let height = (baseHeight * scale).rounded(.down)
        return (NSRect(x: retinaFrame.maxX - width, y: retinaFrame.minY, width: width, height: height), scale)
    }
}

/// The look of victor-effects' soundboard panel (right ⌘), on purpose: the
/// same near-black plate, the same grey tiles with 6 pt corners, the same
/// bright green ring on hover and red ring on press — two boards you click
/// from on the same desk should not speak two visual languages.
private enum EmojiPickerStyle {
    // Opaque where the soundboard is 0.94: a picker opened over a bright slide
    // showed the slide's text ghosting through the empty board.
    static let background = NSColor(white: 0.08, alpha: 1)
    static let border = NSColor(white: 1, alpha: 0.10)
    static let fieldBackground = NSColor(white: 0.22, alpha: 1)
    static let dim = NSColor(white: 0.70, alpha: 1)
    static let header = NSColor(white: 0.55, alpha: 1)
    static let tile = NSColor(white: 0.22, alpha: 1)
    static let emptyTile = NSColor(white: 0.13, alpha: 1)
    static let hoverRing = NSColor(srgbRed: 0.224, green: 1.0, blue: 0.078, alpha: 1)   // #39FF14, victor-effects TileView
    static let pressRing = NSColor(srgbRed: 1.0, green: 0.13, blue: 0.13, alpha: 1)     // #FF2121
    static let chord = NSColor(srgbRed: 1, green: 0.769, blue: 0, alpha: 1)             // the soundboard's amber star

    enum Ring { case none, hover, press }

    /// One tile: grey when it holds an emoji, darker when it is an empty cell
    /// of the board, with the green / red ring drawn just outside it.
    static func drawTile(_ rect: NSRect, filled: Bool, ring: Ring, scale s: CGFloat) {
        let tile = rect.insetBy(dx: 3 * s, dy: 3 * s)
        (filled ? Self.tile : emptyTile).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 6 * s, yRadius: 6 * s).fill()
        guard ring != .none else { return }
        let outline = NSBezierPath(roundedRect: tile.insetBy(dx: -1.5 * s, dy: -1.5 * s), xRadius: 7.5 * s, yRadius: 7.5 * s)
        outline.lineWidth = 3 * s
        (ring == .press ? pressRing : hoverRing).setStroke()
        outline.stroke()
    }

    static func emojiFont(_ size: CGFloat) -> NSFont {
        NSFont(name: "Apple Color Emoji", size: size) ?? .systemFont(ofSize: size)
    }

    static func drawEmoji(_ emoji: String, centeredIn rect: NSRect, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = EmojiPickerPolicy.isTextSymbol(emoji)
            ? [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white]
            : [.font: emojiFont(size)]
        let attributed = NSAttributedString(string: emoji, attributes: attributes)
        let bounds = attributed.size()
        attributed.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
    }
}

/// A panel that is clicked without ever taking focus — see
/// `EmojiPickerController`.
final class EmojiPickerPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
    }

    /// Never key: the app underneath keeps the keyboard (and ScreenBrush its
    /// text mode); keystrokes reach the picker through the event tap.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel's plate, drawn rather than set as a layer colour: a layer
/// background on a borderless clear window came out at roughly half its alpha,
/// and the slide behind showed straight through the board.
private final class EmojiPickerBackground: NSView {
    private let radius: CGFloat

    init(frame: NSRect, radius: CGFloat) {
        self.radius = radius
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        EmojiPickerStyle.background.setFill()
        path.fill()
        EmojiPickerStyle.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The board: `EmojiBoard.columns` × `rows` cells, drawn at whatever size the
/// panel gives it (square cells, centred), every placed emoji in its own cell.
final class EmojiBoardView: NSView {
    private let s: CGFloat
    private let catalog: EmojiCatalog
    /// The saved board — what is shown whenever nothing is being searched.
    var board: EmojiBoard {
        didSet { if results == nil { relayout(selecting: nil) } }
    }
    /// Search matches, best first; `nil` = no search, show `board`. While set,
    /// they *are* the board: laid out from the centre outwards
    /// (`EmojiBoard.searchLayout`), the best one selected in the middle.
    /// Clearing the search brings the saved board back, on the last one used.
    var results: [EmojiEntry]? {
        didSet {
            guard results != nil || oldValue != nil else { return }
            relayout(selecting: results == nil ? lastUsedIndex(board) : 0)
        }
    }
    /// The emoji already on a key, chord by emoji. Only search results can be
    /// keyed; they show the chord under them, since searching for one you
    /// forgot is on a key is exactly when the chord is worth seeing.
    var keyed: [String: String] = [:]
    /// What is drawn and clicked: `board`, or the results laid out as one.
    private var layout: EmojiBoard
    private var entries: [EmojiEntry?]
    var onPick: ((EmojiEntry) -> Void)?
    var onFocus: ((EmojiEntry?) -> Void)?
    /// The hover ✕ was clicked: take this emoji off the board.
    var onRemove: ((String) -> Void)?
    /// The tile showing its ✕, armed by resting on it (`deleteDelay`).
    private var deleteArmed: Int?
    private var deleteTimer: Timer?
    /// Long enough that sweeping the mouse across the board never flashes a
    /// row of ✕s; short enough to feel like a deliberate pause, not a wait.
    static let deleteDelay: TimeInterval = 0.8
    private var selected: Int?
    private var hovered: Int?
    private var pressed: Int?

    init(frame: NSRect, board: EmojiBoard, catalog: EmojiCatalog, scale: CGFloat) {
        s = scale
        self.catalog = catalog
        self.board = board
        layout = board
        entries = board.slots.map { catalog.entry(for: $0.emoji) }
        super.init(frame: frame)
        // Start on the one used last: ↵ straight away repeats it.
        selected = lastUsedIndex(board)
    }

    private func lastUsedIndex(_ board: EmojiBoard) -> Int? {
        board.slots.indices.max { board.slots[$0].lastUsed < board.slots[$1].lastUsed }
    }

    private func relayout(selecting index: Int?) {
        if let results {
            layout = EmojiBoard.searchLayout(results)
            entries = results.prefix(layout.slots.count).map { $0 }
        } else {
            layout = board
            entries = board.slots.map { catalog.entry(for: $0.emoji) }
        }
        selected = index.flatMap { layout.slots.indices.contains($0) ? $0 : nil }
        hovered = nil; pressed = nil; disarm()
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var cell: CGFloat {
        min(bounds.width / CGFloat(EmojiBoard.columns), bounds.height / CGFloat(EmojiBoard.rows))
    }

    private func rect(column: Int, row: Int) -> NSRect {
        let c = cell
        let left = (bounds.width - c * CGFloat(EmojiBoard.columns)) / 2
        let top = (bounds.height - c * CGFloat(EmojiBoard.rows)) / 2
        return NSRect(x: left + CGFloat(column) * c, y: top + CGFloat(row) * c, width: c, height: c)
    }

    private func rect(_ index: Int) -> NSRect {
        rect(column: layout.slots[index].column, row: layout.slots[index].row)
    }

    var selectedEntry: EmojiEntry? { selected.flatMap { entries[$0] } }

    /// Arrows jump to the nearest placed emoji in that direction — the board
    /// is sparse, and stepping through empty cells would be keystrokes for
    /// nothing. Off-axis distance costs double, so → stays on its row while
    /// the row has anything further right.
    func move(dx: Int, dy: Int) {
        guard !layout.slots.isEmpty else { return }
        guard let current = selected else { select(0); return }
        let from = layout.slots[current]
        let candidates = layout.slots.indices.filter { index in
            let slot = layout.slots[index]
            let along = (slot.column - from.column) * dx + (slot.row - from.row) * dy
            return along > 0
        }
        let best = candidates.min { a, b in cost(a, from: from, dx: dx, dy: dy) < cost(b, from: from, dx: dx, dy: dy) }
        if let best { select(best) }
    }

    private func cost(_ index: Int, from: EmojiSlot, dx: Int, dy: Int) -> Int {
        let slot = layout.slots[index]
        let along = abs((slot.column - from.column) * dx + (slot.row - from.row) * dy)
        let across = abs((slot.column - from.column) * dy) + abs((slot.row - from.row) * dx)
        return along + 2 * across
    }

    private func select(_ index: Int) {
        selected = index
        needsDisplay = true
        onFocus?(entries[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        // Every cell visible, empty ones darker: positions are the whole point
        // of this board, so the eye needs the lattice even where it's empty.
        let occupied = Set(layout.slots.map { $0.row * EmojiBoard.columns + $0.column })
        for row in 0..<EmojiBoard.rows {
            for column in 0..<EmojiBoard.columns where !occupied.contains(row * EmojiBoard.columns + column) {
                let r = rect(column: column, row: row)
                guard r.intersects(dirtyRect) else { continue }
                EmojiPickerStyle.drawTile(r, filled: false, ring: .none, scale: s)
            }
        }
        if layout.slots.isEmpty {
            let text = results != nil ? "" : "Aici apar emoji-urile pe care le folosești — fiecare rămâne unde aterizează.\nCaută sus și apasă ↵."
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14 * s), .foregroundColor: EmojiPickerStyle.header, .paragraphStyle: paragraph,
            ]
            let box = NSRect(x: 0, y: bounds.midY - 24 * s, width: bounds.width, height: 48 * s)
            (text as NSString).draw(in: box, withAttributes: attributes)
            return
        }
        // 15% over the old 0.72 (Victor, 2026-10-04): the glyph now reaches the
        // tile's edge on the retina corner, with room to spare on the external.
        let size = cell * 0.83
        for index in layout.slots.indices {
            let r = rect(index)
            guard r.intersects(dirtyRect) else { continue }
            let ring: EmojiPickerStyle.Ring = index == pressed ? .press : (index == (hovered ?? selected) ? .hover : .none)
            EmojiPickerStyle.drawTile(r, filled: true, ring: ring, scale: s)
            let emoji = layout.slots[index].emoji
            if results != nil, let chord = keyed[EmojiPickerPolicy.normalized(emoji)] {
                let label = r.height * 0.26
                let top = NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - label)
                EmojiPickerStyle.drawEmoji(emoji, centeredIn: top, size: size * 0.7)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: label * 0.85), .foregroundColor: EmojiPickerStyle.chord]
                let chordSize = (chord as NSString).size(withAttributes: attributes)
                (chord as NSString).draw(at: NSPoint(x: r.midX - chordSize.width / 2, y: r.maxY - label - 3 * s), withAttributes: attributes)
            } else {
                EmojiPickerStyle.drawEmoji(emoji, centeredIn: r, size: size)
            }
        }
        if let armed = deleteArmed, layout.slots.indices.contains(armed) {
            let x = deleteRect(armed)
            NSColor(srgbRed: 1.0, green: 0.13, blue: 0.13, alpha: 1).setFill()
            NSBezierPath(ovalIn: x).fill()
            let cross = NSBezierPath()
            let inset = x.insetBy(dx: x.width * 0.3, dy: x.height * 0.3)
            cross.move(to: NSPoint(x: inset.minX, y: inset.minY)); cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            cross.move(to: NSPoint(x: inset.maxX, y: inset.minY)); cross.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            cross.lineWidth = max(1.5, x.width * 0.12)
            cross.lineCapStyle = .round
            NSColor.white.setStroke()
            cross.stroke()
        }
    }

    /// The ✕: a red disc on the tile's top-right corner, half outside it, so it
    /// covers as little of the emoji as possible.
    private func deleteRect(_ index: Int) -> NSRect {
        let r = rect(index)
        let d = r.width * 0.34
        return NSRect(x: r.maxX - d * 0.8, y: r.minY - d * 0.2, width: d, height: d)
    }

    private func disarm() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        if deleteArmed != nil { deleteArmed = nil; needsDisplay = true }
    }

    private func index(at point: NSPoint) -> Int? {
        layout.slots.indices.first { rect($0).contains(point) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Reaching for the ✕ crosses the tile's edge — the disc hangs half
        // outside — and must not count as leaving the tile.
        if let armed = deleteArmed, deleteRect(armed).contains(point) { return }
        let hit = index(at: point)
        guard hit != hovered else { return }
        hovered = hit
        disarm()
        if let hit, results == nil {
            deleteTimer = Timer.scheduledTimer(withTimeInterval: Self.deleteDelay, repeats: false) { [weak self] _ in
                guard let self, self.hovered == hit else { return }
                self.deleteArmed = hit
                self.needsDisplay = true
            }
        }
        needsDisplay = true
        onFocus?(hit.flatMap { entries[$0] } ?? selectedEntry)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        disarm()
        needsDisplay = true
        onFocus?(selectedEntry)
    }

    /// Red on the press, the pick on the release — over the same tile, as on
    /// the soundboard; sliding off before letting go cancels. A press on the
    /// armed ✕ removes the emoji instead.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let armed = deleteArmed, deleteRect(armed).contains(point) {
            let emoji = layout.slots[armed].emoji
            disarm()
            onRemove?(emoji)
            return
        }
        pressed = index(at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let hit = index(at: convert(event.locationInWindow, from: nil))
        defer { pressed = nil; needsDisplay = true }
        if let hit, hit == pressed, let entry = entries[hit] { onPick?(entry) }
    }
}
