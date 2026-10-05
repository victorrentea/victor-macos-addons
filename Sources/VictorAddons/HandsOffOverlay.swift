import AppKit

/// "Hands off the keyboard" — the amber frame an agent raises around every
/// screen while it is driving the mouse and keyboard, plus four pulsing 🔒 in
/// the corners. *Who* is driving and *what* it does is read by hovering a lock
/// (since 2026-09-28; before that it was a caption pinned to the bottom centre
/// of every screen — see `showTip`).
///
/// It exists because synthetic input cannot be delivered politely. An agent
/// that clicks a menu has to bring the app forward and physically move the
/// pointer, so whatever Victor was typing lands in the wrong window and
/// whatever he was dragging jumps. There is no way to make that invisible; the
/// next best thing is to make it *legible* — you can see, without asking, that
/// the machine is not yours for a moment, and you can see the instant it is
/// yours again.
///
/// The frame is drawn on **every** screen rather than the cursor's: automation
/// moves the pointer, and a warning that migrates between displays while you're
/// looking at the other one is a warning you miss precisely when it matters.
///
/// Release is announced twice, on purpose — the frame flashes green for half a
/// second and a short sound plays. Victor is usually not looking at the screen
/// while he waits (that is the whole reason he asked for this), so the ear has
/// to carry the "go" and the eye confirms it.
@MainActor
final class HandsOffOverlay {
    private(set) var session: HandsOffSession?

    private var framePanels: [NSPanel] = []
    /// ✋ The four 🔒 per screen, each in its **own small panel** since
    /// 2026-09-26 — the only part of the overlay that takes clicks. Two clicks
    /// on them (since 2026-09-28) are Victor taking the machine back
    /// (`takeover`); hovering one shows the explanation. The frame stays
    /// click-through: only the corners changed meaning.
    private var lockPanels: [NSPanel] = []
    private var lockViews: [HandsOffLockView] = []
    /// Per lock, in the same order as `lockPanels`: which screen, which corner.
    private var lockPlaces: [(screen: Int, corner: HandsOffCorner, screenFrame: NSRect)] = []
    private var lockClicks = HandsOffLockClicks()
    /// The one explanation panel (there is only ever one pointer), shown beside
    /// the hovered lock. nil until first needed.
    private var tipPanel: NSPanel?
    /// Which lock the tip is showing for; nil = hidden (or fading out).
    private var tipLockIndex: Int?
    private var tipText = ""
    private var tipHint = false
    /// Bumped on every show/hide so a fade-out that finishes after a new show
    /// does not order the fresh tip out.
    private var tipGeneration = 0
    private var tipHideWork: DispatchWorkItem?
    private var hintExpiryWork: DispatchWorkItem?
    /// Who holds the locks — registered by `hands-off run` so a takeover can
    /// stop it. nil for `hands-off start`, the guard hook and the auto-raise.
    private(set) var holder: HandsOffHolder?
    private var takeoverMachine = HandsOffTakeoverMachine()
    private var escapeChord = HandsOffDoublePress()
    private let takeoverRed = NSColor.systemRed
    /// Basso — a low, final thud: "stopped", distinct from the release Tink.
    private let takeoverSound = NSSound(named: NSSound.Name("Basso"))
    static let takeoverCaption = "✋ Victor took control — stopping the agent"
    /// The second line of the tip after one click on a 🔒.
    static let armHint = "Click again to take over"
    private var watchdog: Timer?

    private let borderWidth: CGFloat = 6
    private let amber = NSColor.systemOrange
    private let free = NSColor.systemGreen
    /// 🔒 in all four corners, breathing slowly. The border says "something is
    /// happening"; the locks say *what you must not do* — hands off the mouse
    /// and the keyboard until they are gone. Four of them because Victor's eye
    /// is somewhere unpredictable on a 2-screen desk, and a corner is the one
    /// place no app puts content he was reading.
    private let lockGlyph = "🔒"
    private let lockSize: CGFloat = 64
    private let lockInset: CGFloat = 24
    /// Never fully opaque and never fully gone: at the bottom of the pulse the
    /// lock is still legible, so a glance that lands in the dark half of the
    /// cycle still answers the question.
    private let lockAlphaRange: (min: Float, max: Float) = (0.35, 0.95)
    /// One slow breath ≈ 2.4 s round trip. Fast blinking reads as an error the
    /// eye wants to dismiss; this reads as "still running".
    private let lockPulseDuration: CFTimeInterval = 1.2
    /// The "why" used to ride the cursor like a tooltip (failed: an agent whips
    /// the pointer across the screen, so the text was never where Victor's eye
    /// was), then sat as an amber pill at the bottom centre of every screen.
    /// Since 2026-09-28 it is shown **only on hover over a 🔒** — Victor: *"You
    /// shouldn't stick this badge of orange text on the bottom when you take
    /// over the control of my machine, but on hover, I should see that."* The
    /// pill covered the bottom of whatever he was watching the agent do, for the
    /// whole run, to answer a question he asks only sometimes. Same plate, same
    /// size as the pill, so it reads the same.
    private let captionFontSize: CGFloat = 26
    private let hintFontSize: CGFloat = 18
    /// ≤ 150 ms in, ~300 ms of grace before it goes: a pointer wobbling off the
    /// lock's edge and back must not make it flicker.
    private let tipFadeIn: TimeInterval = 0.12
    private let tipHideGrace: TimeInterval = 0.3
    private let releaseChime = NSSound(named: NSSound.Name("Tink"))

    /// **Cu capacul închis, ochii lui sunt oricum în altă parte — rămâne doar
    /// bătaia inimii.**
    ///
    /// Victor, 2026-09-22: *"acum aud heartbeat-uri și niște bip-uri de la
    /// protecția de ecran să nu ating. Dacă am capacul închis, nu sunt necesare
    /// acele bip-uri. Ajunge doar heartbeat-ul cu capacul închis, șansele să
    /// miști mouse-ul sunt foarte mici."*
    ///
    /// Ce a declanșat-o: calea *anunțată* presupunea că un Tink e rar, fiindcă
    /// un agent cere mâinile o dată și le ține. Rig-urile de capturi din
    /// `walkie-talkie` au spart presupunerea — fiecare captură de câteva secunde
    /// e propriul `hands-off run`, deci zeci de Tink-uri pe oră. E exact
    /// enervarea pentru care există deja `silent` pe calea auto-ridicată, ajunsă
    /// pe cealaltă cale.
    ///
    /// Se taie doar **sunetul**, și doar cu capacul închis. Rama chihlimbarie,
    /// lacătele și badge-ul rămân neatinse pe orice ecran extern: contractul e
    /// vizual, iar ăsta nu se negociază. Iar cât lucrează un agent cu capacul
    /// închis, `LidAwake` bate oricum la fiecare 10 secunde — deci tăcerea asta
    /// nu lasă mașina fără nicio dovadă că e ocupată, doar scoate al doilea
    /// sunet care spunea același lucru.
    /// `nonisolated`: e o funcție pură, fără stare, iar testele o cheamă din
    /// afara actorului principal.
    nonisolated static func shouldChime(silent: Bool, lidClosed: Bool) -> Bool {
        !silent && !lidClosed
    }

    var isActive: Bool { session != nil }
    /// True when the frame went up by itself, because `SyntheticInputWatch` saw
    /// software posting mouse/keyboard events. Kept apart from an announced
    /// session so the announced label ("✋ claude — click pe Restart") is never
    /// overwritten by the anonymous one the tap can produce.
    private(set) var isAutoRaised = false

    // MARK: - Public API

    /// Claim the machine. Calling it again while active replaces the label and
    /// restarts the watchdog — an agent doing three things in a row should show
    /// the third, not keep announcing the first.
    ///
    /// `holderPid` is the `hands-off run` wrapper registering itself so a
    /// takeover can stop it. A `begin` **without** one keeps the current holder
    /// while that process is still alive: a wrapper whose command itself calls
    /// `hands-off start` for a sub-step is still the thing to stop.
    func begin(agent: String?, what: String?, ttl: TimeInterval?, holderPid: pid_t? = nil) {
        let fresh = HandsOffSession(agent: agent, what: what, ttl: ttl, startedAt: Date())
        session = fresh
        isAutoRaised = false
        if let holderPid, holderPid > 1 {
            holder = HandsOffHolder(holderPid: holderPid, holderStamp: ProcessStamp.of(holderPid),
                                    childPid: nil, childStamp: nil)
        } else if let current = holder, !HandsOffKiller.isSame(pid: current.holderPid, stamp: current.holderStamp) {
            holder = nil
        }
        HandsOffGate.shared.locksUp = true

        if framePanels.isEmpty {
            lockClicks.reset()
            buildFrames()
        }
        setBorder(color: amber)
        refreshTip()
        startWatchdog()
        let who = holder.map { " holder \($0.holderPid)" } ?? ""
        overlayInfo("Hands off: \(fresh.label) (ttl \(Int(fresh.ttl))s)\(who)")
    }

    /// `hands-off run` tells us the pid of the command it just started (it can
    /// only know it after the locks are up, which is the order that matters).
    /// Refused unless the caller is the registered holder — one wrapper cannot
    /// point a takeover at another's child.
    func attach(holderPid: pid_t, childPid: pid_t) -> Bool {
        guard session != nil, var current = holder, current.holderPid == holderPid, childPid > 1 else { return false }
        current.childPid = childPid
        current.childStamp = ProcessStamp.of(childPid)
        holder = current
        overlayInfo("Hands off: holder \(holderPid) runs child \(childPid) (pgid \(getpgid(childPid)))")
        return true
    }

    /// Raise the locks with nobody having asked — `SyntheticInputWatch` caught
    /// a process posting input. It says the process's name rather than a task,
    /// because that is all a tap can honestly know.
    ///
    /// An **announced** session always wins: an agent that took the trouble to
    /// say what it is doing must not have its label replaced by "Terminal".
    func beginAuto(agent: String, ttl: TimeInterval) {
        guard session == nil || isAutoRaised else { return }
        // Victor just took the machine back: the killed command's last
        // synthetic events must not put the locks straight back up over the
        // red ✋ that says he has it.
        guard !takeoverMachine.isTakingOver else { return }
        begin(agent: agent, what: "îți mișcă mouse-ul/tastatura", ttl: ttl)
        isAutoRaised = true
    }

    /// Keep an auto-raised frame alive while the synthetic input keeps coming.
    /// Deliberately not a second `begin`: that would rebuild the badge and write
    /// a log line every single second of a long automation run.
    func refreshAuto(agent: String, ttl: TimeInterval) {
        guard isAutoRaised, let current = session else { return }
        let refreshed = HandsOffSession(agent: agent, what: current.what, ttl: ttl, startedAt: Date())
        session = refreshed
        if tipText != refreshed.label { refreshTip() }
    }

    /// Give it back. Safe to call when nothing is active — an agent that ends
    /// twice (retry, cleanup handler) must not be an error path.
    ///
    /// `silent` is for the auto-raised path: that one goes up and down in bursts
    /// as a script works, and a chime per burst would become the annoyance the
    /// whole feature exists to avoid. An announced release stays audible —
    /// Victor is usually not looking at the screen while he waits for it.
    ///
    /// …unless the lid is shut: see `shouldChime`.
    func end(expired: Bool = false, silent: Bool = false) {
        guard session != nil else { return }
        let wasAuto = isAutoRaised
        session = nil
        holder = nil
        isAutoRaised = false
        HandsOffGate.shared.locksUp = false
        watchdog?.invalidate(); watchdog = nil
        lockClicks.reset()
        hideTip(after: 0)
        flashFreeAndDismiss()
        if Self.shouldChime(silent: silent, lidClosed: LidAwake.isLidClosed()) { releaseChime?.play() }
        overlayInfo(expired ? "Hands off: released by watchdog"
                            : (wasAuto ? "Hands off: synthetic input stopped" : "Hands off: released"))
    }

    /// Read-only snapshot for `/hands-off/state`, so the behaviour can be
    /// asserted from a script instead of from a screenshot.
    func stateJSON() -> String {
        guard let session else { return "{\"active\":false}" }
        let remaining = Int(session.remaining(at: Date()).rounded())
        let escaped = session.label.replacingOccurrences(of: "\"", with: "\\\"")
        var holderJSON = ""
        if let holder {
            holderJSON = ",\"holderPid\":\(holder.holderPid)"
            if let child = holder.childPid { holderJSON += ",\"childPid\":\(child)" }
        }
        return "{\"active\":true,\"agent\":\"\(session.agent)\",\"label\":\"\(escaped)\",\"remainingSec\":\(remaining)\(holderJSON)}"
    }

    // MARK: - ✋ Takeover

    /// Victor takes the machine back: two clicks on the 🔒 (`lockClicked`),
    /// ⌃⌘⎋ twice, or the test route. In this order, because the wrapper reads them in this order:
    ///
    /// 1. the marker file (`~/.victor-addons/hands-off.takeover`) — written
    ///    first, so a wrapper whose child dies before SIGUSR1 lands still finds
    ///    out *why*;
    /// 2. SIGUSR1 to the `hands-off run` wrapper, SIGTERM to its child's process
    ///    group, SIGKILL 3 s later to whatever ignored it;
    /// 3. the locks drop at once (`/hands-off/state` says `active:false`) while
    ///    the panels turn red with ✋ for ~2 s, with a Basso, then fade — and,
    ///    when the tip is up beside the clicked lock, it turns red and says so.
    ///
    /// No green flash and no Tink: green means "the agent gave it back", and
    /// that is not what happened.
    @discardableResult
    func takeover(source: HandsOffTakeoverSource, markerURL: URL? = nil) -> String {
        let now = Date()
        guard takeoverMachine.request(locksUp: session != nil, at: now) else {
            let reason = session == nil ? "no-locks" : "already-taking-over"
            return "{\"ok\":false,\"reason\":\"\(reason)\"}"
        }
        let label = session?.label
        let agent = session?.agent

        // A holder whose process is gone, or whose pid now belongs to someone
        // else, is not signalled — see `ProcessStamp`.
        var live = holder
        if let h = live, !HandsOffKiller.isSame(pid: h.holderPid, stamp: h.holderStamp) { live = nil }
        if var h = live, let child = h.childPid, !HandsOffKiller.isSame(pid: child, stamp: h.childStamp) {
            h.childPid = nil; h.childStamp = nil; live = h
        }

        let markerJSON = HandsOffTakeoverMarker.json(at: now, source: source, label: label, agent: agent, holder: live)
        let markerAt = markerURL ?? HandsOffTakeoverMarker.url
        let wrote = HandsOffTakeoverMarker.write(markerJSON, to: markerAt)

        let ownPid = ProcessInfo.processInfo.processIdentifier
        let plan = HandsOffKillPlan.make(holder: live,
                                         childPgid: live?.childPid.map { getpgid($0) }.flatMap { $0 > 0 ? $0 : nil },
                                         holderPgid: live.map { getpgid($0.holderPid) }.flatMap { $0 > 0 ? $0 : nil },
                                         ownPid: ownPid, ownPgid: getpgid(ownPid))
        let signalled = HandsOffKiller.execute(plan)
        overlayInfo("✋ Hands off: TAKEOVER by Victor (\(source.rawValue)) at \(HandsOffTakeoverMarker.localTime(now)) — was '\(label ?? "?")'; \(signalled); marker \(wrote ? markerAt.path : "NOT written")")

        // Drop the locks now; keep the panels for the red beat.
        session = nil
        holder = nil
        isAutoRaised = false
        HandsOffGate.shared.locksUp = false
        watchdog?.invalidate(); watchdog = nil
        lockClicks.reset()
        showTakeoverAndDismiss()
        takeoverSound?.stop()
        takeoverSound?.play()

        let targets = plan.terminate.map { "\"\(HandsOffKiller.describe($0))\"" }.joined(separator: ",")
        let notified = plan.notify.map { String($0) } ?? "null"
        return "{\"ok\":true,\"source\":\"\(source.rawValue)\",\"notified\":\(notified),\"terminated\":[\(targets)],\"marker\":\(wrote ? "\"\(markerAt.path)\"" : "null")}"
    }

    /// ⌃⌘⎋ from the event tap (hardware only, already filtered there). Two
    /// within a second = takeover; the first one only arms.
    func handleEscapeChord() {
        guard session != nil else { return }
        if escapeChord.press(at: Date()) {
            takeover(source: .keyboard)
        } else {
            overlayInfo("Hands off: ⌃⌘⎋ once — press again within 1s to take control")
        }
    }

    // MARK: - 🔒 clicks and hover

    /// A **real** click on lock `index` (the synthetic ones never get here),
    /// or the `/test/hands-off/click` hook. The first click only arms and says
    /// so in the tip; the second, on any lock, within 1.5 s, is the takeover.
    @discardableResult
    func lockClicked(index: Int, source: HandsOffTakeoverSource, markerURL: URL? = nil) -> String {
        guard session != nil, !takeoverMachine.isTakingOver else { return "{\"ok\":false,\"reason\":\"no-locks\"}" }
        let now = Date()
        switch lockClicks.click(at: now) {
        case .takeover:
            return takeover(source: source, markerURL: markerURL)
        case .armed:
            overlayInfo("Hands off: 🔒 clicked once — click again within \(HandsOffLockClicks.window)s to take control")
            tipHideWork?.cancel(); tipHideWork = nil
            showTip(at: index)
            hintExpiryWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.lockClicks.isArmed(at: Date()) else { return }
                    self.lockClicks.reset()
                    self.refreshTip()
                }
            }
            hintExpiryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + HandsOffLockClicks.window + 0.05, execute: work)
            return tipStateJSON(outcome: "armed")
        }
    }

    /// Pointer entered / left lock `index`.
    func lockHover(index: Int, inside: Bool) {
        if inside {
            tipHideWork?.cancel(); tipHideWork = nil
            showTip(at: index)
        } else if tipLockIndex == index {
            hideTip(after: tipHideGrace)
        }
    }

    /// Test hooks: the lock at `corner` of screen `screen` (NSScreen order).
    func lockIndex(screen: Int, corner: HandsOffCorner) -> Int? {
        lockPlaces.firstIndex { $0.screen == screen && $0.corner == corner }
    }

    /// Read-only: what the tip and the arming look like right now.
    func tipStateJSON(outcome: String? = nil) -> String {
        var obj: [String: Any] = [
            "active": session != nil,
            "armed": lockClicks.isArmed(at: Date()),
            "frames": framePanels.count,
            "locks": lockPanels.count,
        ]
        if let outcome { obj["outcome"] = outcome }
        var tip: [String: Any] = ["visible": tipLockIndex != nil]
        if let i = tipLockIndex, i < lockPlaces.count, let panel = tipPanel {
            tip["screen"] = lockPlaces[i].screen
            tip["corner"] = lockPlaces[i].corner.code
            tip["text"] = tipText
            tip["hint"] = tipHint
            let f = panel.frame
            tip["frame"] = [Int(f.minX), Int(f.minY), Int(f.width), Int(f.height)]
            tip["ignoresMouseEvents"] = panel.ignoresMouseEvents
            tip["canBecomeKey"] = panel.canBecomeKey
        }
        obj["tip"] = tip
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Tip (the "why", on hover)

    /// Shows (or updates) the tip beside lock `index`: the session label, plus
    /// "Click again to take over" while a first click is armed.
    private func showTip(at index: Int) {
        guard let session, index < lockPanels.count, index < lockPlaces.count else { return }
        let hint = lockClicks.isArmed(at: Date())
        let place = lockPlaces[index]
        let maxWidth = min(720, place.screenFrame.width * 0.45)
        let content = Self.makeTipView(text: session.label, hint: hint ? Self.armHint : nil,
                                       color: amber, fontSize: captionFontSize, hintSize: hintFontSize,
                                       maxWidth: maxWidth)
        let origin = HandsOffTipPlacement.origin(lockFrame: lockPanels[index].frame, corner: place.corner,
                                                 tipSize: content.frame.size, screenFrame: place.screenFrame)
        let panel = tipPanel ?? makeTipPanel()
        tipPanel = panel
        let wasShown = tipLockIndex != nil
        // Size taken before `contentView =`, which resizes the view to the
        // panel's current frame (a stale 10×10 tip, seen live on 2026-09-28).
        let size = content.frame.size
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.contentView = content
        tipLockIndex = index
        tipText = session.label
        tipHint = hint
        tipGeneration += 1
        if !wasShown {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = tipFadeIn
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    /// Re-renders a visible tip (new label, hint expired). Hidden stays hidden.
    private func refreshTip() {
        if let i = tipLockIndex { showTip(at: i) }
    }

    private func hideTip(after delay: TimeInterval) {
        tipHideWork?.cancel(); tipHideWork = nil
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let panel = self.tipPanel, self.tipLockIndex != nil else { return }
                self.tipLockIndex = nil
                self.tipGeneration += 1
                let generation = self.tipGeneration
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = self.tipFadeIn
                    panel.animator().alphaValue = 0
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.tipGeneration == generation else { return }
                        panel.orderOut(nil)
                    }
                }
            }
        }
        if delay <= 0 {
            work.perform()
        } else {
            tipHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Never takes a click, never becomes key, never activates the app: it is
    /// read, not used — and it must not steal a keystroke Victor or the agent
    /// is typing into the app underneath.
    private func makeTipPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    /// The plate: the old bottom pill's look (amber, 12 pt corners, white
    /// semibold text) with an optional smaller second line. Sized to its text,
    /// never wider than `maxWidth`. Shared by the live tip and the preview.
    static func makeTipView(text: String, hint: String?, color: NSColor, fontSize: CGFloat,
                            hintSize: CGFloat, maxWidth: CGFloat) -> NSView {
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: para,
        ])
        if let hint {
            let hintPara = NSMutableParagraphStyle()
            hintPara.alignment = .left
            hintPara.paragraphSpacingBefore = 4
            body.append(NSAttributedString(string: "\n" + hint, attributes: [
                .font: NSFont.systemFont(ofSize: hintSize, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                .paragraphStyle: hintPara,
            ]))
        }
        let field = NSTextField(wrappingLabelWithString: "")
        field.attributedStringValue = body
        field.backgroundColor = .clear
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.maximumNumberOfLines = 5
        let pad = NSSize(width: 40, height: 20)
        let maxText = maxWidth - pad.width
        field.preferredMaxLayoutWidth = maxText
        var t = field.sizeThatFits(NSSize(width: maxText, height: 1000))
        t.width = min(ceil(t.width), maxText)
        t.height = ceil(t.height)
        field.frame = NSRect(x: pad.width / 2, y: pad.height / 2, width: t.width, height: t.height)
        let plate = NSView(frame: NSRect(x: 0, y: 0, width: t.width + pad.width, height: t.height + pad.height))
        plate.wantsLayer = true
        plate.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        plate.layer?.cornerRadius = 12
        plate.addSubview(field)
        return plate
    }

    // MARK: - Frame

    private func buildFrames() {
        for (screenIndex, screen) in NSScreen.physical.enumerated() {
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            // Click-through: the frame must never eat the click Victor makes
            // the moment he decides to take the machine back anyway.
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            // The border is drawn on the panel's own layer rather than as a
            // filled shape so the middle stays genuinely transparent — a
            // translucent wash over the whole screen would make the app
            // underneath harder to read for exactly as long as you most want to
            // watch what the agent is doing to it.
            view.layer?.borderWidth = borderWidth
            view.layer?.cornerRadius = 12
            view.layer?.borderColor = amber.cgColor
            panel.contentView = view
            panel.orderFrontRegardless()
            framePanels.append(panel)
            addCornerLocks(on: screen, index: screenIndex)
        }
    }

    /// Four semi-transparent padlocks, one per corner, each pulsing on its own
    /// layer — and, since 2026-09-26, each in its **own small clickable panel**.
    /// They are built and torn down together with the frame (same `build`, same
    /// dismiss), so there is still no second lifecycle to leak.
    ///
    /// The top two sit **below the menu bar** rather than 24 pt from the screen
    /// edge: on a notched display the bar is 37 pt tall, and a clickable lock
    /// overlapping the app menu would swallow the very click an agent is making.
    private func addCornerLocks(on screen: NSScreen, index screenIndex: Int) {
        let box = lockSize * 1.4
        let origins = Self.lockOrigins(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                       box: box, inset: lockInset)
        for (origin, corner) in zip(origins, HandsOffCorner.allCases) {
            let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: box, height: box)),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            // The one place the overlay takes clicks: this is the stop button.
            panel.ignoresMouseEvents = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = HandsOffLockView(frame: NSRect(origin: .zero, size: NSSize(width: box, height: box)),
                                        glyph: lockGlyph, glyphSize: lockSize)
            let lockIndex = lockPanels.count
            view.onClick = { [weak self] in self?.lockClicked(index: lockIndex, source: .click) }
            view.onHover = { [weak self] inside in self?.lockHover(index: lockIndex, inside: inside) }
            view.startPulse(min: lockAlphaRange.min, max: lockAlphaRange.max, duration: lockPulseDuration)
            panel.contentView = view
            panel.orderFrontRegardless()
            lockPanels.append(panel)
            lockViews.append(view)
            lockPlaces.append((screen: screenIndex, corner: corner, screenFrame: screen.frame))
        }
    }

    /// Bottom-left, bottom-right, top-left, top-right, in global coordinates.
    /// `nonisolated` + pure so the menu-bar clearance is tested, not eyeballed.
    nonisolated static func lockOrigins(screenFrame f: NSRect, visibleFrame v: NSRect,
                                        box: CGFloat, inset: CGFloat) -> [CGPoint] {
        // Menu bar height on this screen (0 when it auto-hides): the gap
        // between the top of the screen and the top of the usable area.
        let menuBar = max(0, f.maxY - v.maxY)
        let topInset = max(inset, menuBar + 8)
        let left = f.minX + inset, right = f.maxX - box - inset
        let bottom = f.minY + inset, top = f.maxY - box - topInset
        return [CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom),
                CGPoint(x: left, y: top), CGPoint(x: right, y: top)]
    }

    private func setBorder(color: NSColor) {
        for panel in framePanels {
            panel.contentView?.layer?.borderColor = color.cgColor
        }
    }

    /// Green for half a second, then gone. The colour change and the fade are
    /// separate beats deliberately: green arriving *while the frame is still
    /// there* is what reads as "released", where fading amber straight out
    /// reads as "something closed" and could just as well be a crash.
    private func flashFreeAndDismiss() {
        guard !framePanels.isEmpty else { return }
        setBorder(color: free)
        let panels = framePanels + lockPanels
        framePanels = []
        lockPanels = []
        lockViews = []
        lockPlaces = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                for panel in panels { panel.animator().alphaValue = 0 }
            } completionHandler: {
                for panel in panels { panel.orderOut(nil) }
            }
        }
    }

    /// The red beat: border, the tip (if it is up beside the clicked lock) and
    /// all four corners turn red, the 🔒 become ✋ and stop breathing — one unmistakable "you have it" — then the
    /// whole thing fades after `redStateDuration`. The panels are detached from
    /// the overlay at once, so a new `begin` during these two seconds builds a
    /// fresh amber frame instead of recolouring a dying one.
    private func showTakeoverAndDismiss() {
        setBorder(color: takeoverRed)
        for view in lockViews { view.showTakeover(red: takeoverRed) }
        for panel in lockPanels { panel.ignoresMouseEvents = true }

        // The tip Victor was reading when he clicked turns into the answer.
        // Detached like the rest, so the next session builds a fresh one.
        tipHideWork?.cancel(); tipHideWork = nil
        hintExpiryWork?.cancel(); hintExpiryWork = nil
        var dying: [NSPanel] = []
        if let i = tipLockIndex, let panel = tipPanel, i < lockPanels.count, i < lockPlaces.count {
            let place = lockPlaces[i]
            let content = Self.makeTipView(text: Self.takeoverCaption, hint: nil, color: takeoverRed,
                                           fontSize: captionFontSize, hintSize: hintFontSize,
                                           maxWidth: min(720, place.screenFrame.width * 0.45))
            let origin = HandsOffTipPlacement.origin(lockFrame: lockPanels[i].frame, corner: place.corner,
                                                     tipSize: content.frame.size, screenFrame: place.screenFrame)
            let size = content.frame.size
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
            panel.contentView = content
            panel.alphaValue = 1
            dying.append(panel)
            tipPanel = nil
        } else if let panel = tipPanel {
            panel.orderOut(nil)
        }
        tipLockIndex = nil
        tipGeneration += 1

        let panels = framePanels + lockPanels + dying
        framePanels = []
        lockPanels = []
        lockViews = []
        lockPlaces = []
        DispatchQueue.main.asyncAfter(deadline: .now() + HandsOffTakeoverMachine.redStateDuration) { [weak self] in
            self?.takeoverMachine.finish()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                for panel in panels { panel.animator().alphaValue = 0 }
            } completionHandler: {
                for panel in panels { panel.orderOut(nil) }
            }
        }
    }

    // MARK: - Preview (test hook)

    /// Draws one corner lock + its hover tip + a stretch of border over a
    /// light "document" or a dark "IDE" backdrop, into a PNG — in the normal
    /// 🔒 state and in the red ✋ takeover state, side by side. The only way to
    /// look at the takeover without taking one over the projected screen.
    func renderPreview(dark: Bool, to path: String) -> Bool {
        let size = NSSize(width: 1100, height: 360)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).cgColor

        // A few "lines of text" so legibility over content is judged, not over a void.
        for i in 0..<9 {
            let line = NSTextField(labelWithString: "    func takeover(source: HandsOffTakeoverSource) -> String {  // line \(i + 1)")
            line.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
            line.textColor = dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.2, alpha: 1)
            line.frame = NSRect(x: 20, y: size.height - 40 - CGFloat(i) * 34, width: size.width - 40, height: 22)
            root.addSubview(line)
        }

        let half = size.width / 2
        for (i, taken) in [false, true].enumerated() {
            let pane = NSView(frame: NSRect(x: CGFloat(i) * half + 10, y: 10, width: half - 20, height: size.height - 20))
            pane.wantsLayer = true
            pane.layer?.borderWidth = borderWidth
            pane.layer?.cornerRadius = 12
            pane.layer?.borderColor = (taken ? takeoverRed : amber).cgColor
            root.addSubview(pane)

            let box = lockSize * 1.4
            let lock = HandsOffLockView(frame: NSRect(x: 14, y: pane.frame.height - box - 14, width: box, height: box),
                                        glyph: lockGlyph, glyphSize: lockSize)
            if taken { lock.showTakeover(red: takeoverRed) }
            pane.addSubview(lock)

            // The hover tip beside the lock: armed (label + hint) in the normal
            // pane, the red "took control" answer in the takeover pane.
            let tip = Self.makeTipView(text: taken ? Self.takeoverCaption : "✋ claude — click pe Restart to Update",
                                       hint: taken ? nil : Self.armHint,
                                       color: taken ? takeoverRed : amber,
                                       fontSize: captionFontSize * 0.75, hintSize: hintFontSize * 0.75,
                                       maxWidth: pane.frame.width - box - 50)
            let o = HandsOffTipPlacement.origin(lockFrame: lock.frame, corner: .topLeft, tipSize: tip.frame.size,
                                                screenFrame: pane.bounds)
            tip.frame.origin = o
            pane.addSubview(tip)
        }

        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                if session.isExpired(at: Date()) { self.end(expired: true) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}
