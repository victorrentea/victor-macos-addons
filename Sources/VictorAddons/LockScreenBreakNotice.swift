import AppKit

/// ☕️🔒 The break's countdown, kept on the **lock screen** of every display.
///
/// Victor locks the Mac when he walks out for the break, and from that moment the
/// room's projector shows the lock screen instead of the ☕️ watch: nobody can read
/// when to be back. macOS itself draws WhatsApp's notifications there, on top of the
/// lock screen, so the same place can carry ours — a notification-like card with the
/// time left and the finish time, on **every** screen, for as long as the break runs
/// and the Mac stays locked.
///
/// **How it gets above the lock screen.** An ordinary window — even at
/// `.screenSaver` or `Int32.max` level — is hidden by the lock: the lock screen lives
/// in its own SkyLight *space* with an absolute level above every user space. SkyLight
/// lets a process create a space of its own, give it an absolute level and move
/// windows into it. Level **400** is the one the system's own notifications use on the
/// lock screen (`kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`; 300 is the
/// lock itself). Same calls as Lakr233/SkyLightWindow, loaded with `dlsym` like
/// `ZoomLensCursorFence`'s SkyLight calls: if a future macOS drops a symbol, the card
/// simply never appears — nothing crashes, and the break watch is unaffected.
///
/// **Only while locked.** That space is above everything, unlocked too, so the cards
/// are built on lock and torn down on unlock (an `orderOut` + `orderFront` could land
/// a window back in the user's space instead). While unlocked the watch itself is on
/// screen and a second copy of it would be noise.
///
/// **Every screen, the 🪞 one included.** Unlike the overlays that go through
/// `NSScreen.physical`, this one wants the shared screen too: it is meant for every
/// participant, the remote ones as much as the room.
final class LockScreenBreakNotice {

    /// What the card says; nil means "no break to announce" (no watch, the ⏱️ Timer,
    /// or the ☕ "UNTIL BREAK" vote — a break due is not a break the room is on).
    struct Content: Equatable {
        var digits: String      // "06:12"
        var finish: String      // "16:29"
        var flag: String        // "🇷🇴"
        var paused: Bool
    }

    /// Polled once a second while locked. Set by AppDelegate to the break watch.
    var content: (() -> Content?)?

    private var cards: [Card] = []
    private var builtFor: [NSRect] = []
    private var timer: Timer?
    private var locked = false
    /// `/test/break/lock-notice`: show without a lock, on the given screens only.
    private var previewScreens: [NSScreen]?
    private var previewUntil = Date.distantPast
    private var previewContent: Content?

    /// Fed from `ScreenLockMonitor.onChange` (main thread).
    func setLocked(_ isLocked: Bool) {
        locked = isLocked
        sync()
    }

    /// Headless preview: show the cards for `seconds` without locking, on `screens`
    /// (the external ones, so test UI never lands on the projected retina). Uses the
    /// live break if one runs, otherwise `fallback`.
    func preview(on screens: [NSScreen], seconds: TimeInterval, fallback: Content) -> String {
        previewScreens = screens
        previewUntil = Date().addingTimeInterval(seconds)
        previewContent = fallback
        sync()
        return diagnosticsJSON
    }

    var diagnosticsJSON: String {
        "{\"locked\":\(locked),\"cards\":\(cards.count),\"skylight\":\(SkyLightLockSpace.shared != nil)," +
        "\"preview\":\(previewScreens != nil)}"
    }

    // MARK: - State

    private var previewing: Bool { previewScreens != nil && Date() < previewUntil }

    private func sync() {
        if !previewing { previewScreens = nil; previewContent = nil }
        let active = locked || previewing
        if active {
            if timer == nil {
                let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sync() }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
        } else {
            timer?.invalidate(); timer = nil
        }
        let shown: Content? = active ? (content?() ?? (previewing ? previewContent : nil)) : nil
        guard let shown else { tearDown(); return }
        let screens = locked ? NSScreen.screens : (previewScreens ?? [])
        let frames = screens.map(\.frame)
        if frames != builtFor { build(on: screens) }
        cards.forEach { $0.show(shown) }
    }

    private func build(on screens: [NSScreen]) {
        tearDown()
        guard let space = SkyLightLockSpace.shared else {
            NSLog("☕🔒 SkyLight lock-screen space unavailable — no break card on the lock screen")
            return
        }
        cards = screens.map { Card(screen: $0, space: space) }
        builtFor = screens.map(\.frame)
        NSLog("☕🔒 break card on the lock screen of \(cards.count) display(s)")
    }

    private func tearDown() {
        cards.forEach { $0.close() }
        cards = []
        builtFor = []
    }

    // MARK: - Geometry (pure)

    /// The card on one screen: centred horizontally, a little above the middle —
    /// the lock screen keeps its clock at the top and the password field at the
    /// bottom, and the wallpaper between them is free. Sized off the screen width so
    /// it reads from the back of the room on the projector, capped on big monitors.
    static func cardFrame(in screen: NSRect) -> NSRect {
        let w = min(screen.width * 0.40, 820)
        let h = (w * 0.46).rounded()
        return NSRect(x: (screen.midX - w / 2).rounded(),
                      y: (screen.minY + screen.height * 0.52 - h / 2).rounded(),
                      width: w.rounded(), height: h)
    }

    /// The bottom line: when to be back, or that the watch is held.
    static func subtitle(_ c: Content) -> String {
        c.paused ? "⏸ paused" : "back at \(c.flag) \(c.finish)".replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: - One display

    private final class Card {
        let window: NSWindow
        let header = NSTextField(labelWithString: "☕️ BREAK")
        let digits = NSTextField(labelWithString: "")
        let line = NSTextField(labelWithString: "")
        var last: Content?

        init(screen: NSScreen, space: SkyLightLockSpace) {
            let frame = LockScreenBreakNotice.cardFrame(in: screen.frame)
            window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.canBecomeVisibleWithoutLogin = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
            window.sharingType = .readOnly

            let h = frame.height
            let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
            root.layer?.cornerRadius = h * 0.12
            root.layer?.borderWidth = 2
            root.layer?.borderColor = NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 0.9).cgColor

            func place(_ f: NSTextField, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                       mono: Bool, centerY: CGFloat) {
                f.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : .systemFont(ofSize: size, weight: weight)
                f.textColor = color
                f.alignment = .center
                f.lineBreakMode = .byClipping
                let lineH = ceil(size * 1.25)
                f.frame = NSRect(x: 0, y: (centerY - lineH / 2).rounded(), width: frame.width, height: lineH)
                root.addSubview(f)
            }
            place(header, size: h * 0.11, weight: .semibold, color: .init(white: 0.85, alpha: 1),
                  mono: false, centerY: h * 0.83)
            place(digits, size: h * 0.40, weight: .bold,
                  color: NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1),
                  mono: true, centerY: h * 0.50)
            place(line, size: h * 0.13, weight: .medium, color: .white, mono: false, centerY: h * 0.16)
            window.contentView = root

            space.adopt(window)
            window.orderFrontRegardless()
        }

        func show(_ c: Content) {
            guard c != last else { return }
            last = c
            digits.stringValue = c.digits
            line.stringValue = LockScreenBreakNotice.subtitle(c)
        }

        func close() { window.orderOut(nil); window.close() }
    }
}

/// The process's own SkyLight space at the lock-screen notifications' absolute
/// level. Created once, lazily, and kept: an empty space shows nothing. nil when the
/// private symbols are missing.
final class SkyLightLockSpace {
    static let shared: SkyLightLockSpace? = SkyLightLockSpace()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`; the lock is 300.
    private static let notificationsAtLockLevel: Int32 = 400

    private let connection: Int32
    private let space: Int32
    private let add: AddWindowsAndRemoveFromSpaces

    private init?() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let pMain = dlsym(h, "SLSMainConnectionID"),
              let pCreate = dlsym(h, "SLSSpaceCreate"),
              let pLevel = dlsym(h, "SLSSpaceSetAbsoluteLevel"),
              let pShow = dlsym(h, "SLSShowSpaces"),
              let pAdd = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return nil }
        let main = unsafeBitCast(pMain, to: MainConnectionID.self)
        let create = unsafeBitCast(pCreate, to: SpaceCreate.self)
        let setLevel = unsafeBitCast(pLevel, to: SpaceSetAbsoluteLevel.self)
        let show = unsafeBitCast(pShow, to: ShowSpaces.self)
        add = unsafeBitCast(pAdd, to: AddWindowsAndRemoveFromSpaces.self)
        connection = main()
        space = create(connection, 1, 0)
        guard space != 0 else { return nil }
        _ = setLevel(connection, space, Self.notificationsAtLockLevel)
        _ = show(connection, [space] as CFArray)
    }

    func adopt(_ window: NSWindow) {
        _ = add(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
