import AppKit
import ApplicationServices

/// **Every link this app opens goes to Victor's own browser, in his own
/// profile** — never to whatever Chrome happens to be in front.
///
/// The Mac routinely runs more than one Chrome: the Playwright skills
/// (`linkedin-web`, `whatsapp-web`, `gmail-web`) launch the *same* app bundle
/// with `channel: 'chrome'` and a `--user-data-dir` of their own, and the
/// MCP browser does the same. Those instances are signed into nothing. There
/// are also three profiles inside the real Chrome (`Default` = Victor,
/// `Profile 4` = Emma, `Profile 6` = Work), and only `Default` is the Google
/// account every link this app opens belongs to.
///
/// Both of the old routes picked the wrong one, and for the same reason: they
/// asked *the front-most thing* rather than *the right thing*.
///
/// - `open -a "Google Chrome" <url>` hands the URL to LaunchServices, which
///   resolves the bundle to whichever instance it likes — a browser automation
///   window that came up a minute ago is as good an answer as the real one.
/// - `tell application "Google Chrome"` addresses a bundle id too, and the
///   AppleScript then *chose a window by screen position* and made a tab in it,
///   so a Playwright window (or Emma's) parked under the mouse won the link.
///
/// The fix is to stop naming the app and start naming **the process and the
/// profile**:
///
/// - The URL is delivered by running Chrome's binary with
///   `--profile-directory=Default`. A second launch of Chrome does not start a
///   second browser: it hands its command line to whoever owns the singleton
///   lock **in that user-data-dir** and exits. So the routing is done by
///   Chrome, through the filesystem, and it cannot land anywhere but the real
///   profile. A Playwright instance holds a lock in *its own* directory and
///   never sees the URL. When no Chrome is running, the same command starts
///   one — no special case.
/// - The geometry (which window to raise, where to put it) goes through the
///   **Accessibility API against one pid**, the way `TerminalTiler` already
///   talks to Terminal, so a window can only be found and moved inside the
///   official instance. It also needs no Apple Events grant, which is what
///   made the AppleScript path fragile after every re-sign.
enum OfficialChrome {

    static let bundleID = "com.google.Chrome"
    static let binaryPath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    /// Victor's own profile inside the real Chrome — `victorrentea@gmail.com`,
    /// the account Gmail / Calendar / the notes doc all live in. Naming it is
    /// half the point of this type: without it a link lands in whichever
    /// profile window Chrome last had in front, which is a coin toss between
    /// three accounts.
    static let profileDirectory = "Default"

    /// The default user-data-dir. An instance running out of any *other*
    /// directory is by definition not the browser Victor is logged into.
    static var defaultUserDataDir: String {
        NSHomeDirectory() + "/Library/Application Support/Google/Chrome"
    }

    // MARK: - Which process is the real one

    /// The running Chrome that owns the default user-data-dir, or `nil` when
    /// Chrome is not running at all.
    ///
    /// Told apart by its command line: everything that automates Chrome passes
    /// `--user-data-dir=…` (Playwright's persistent contexts, the MCP browser,
    /// the summary PDF renderer). The real one passes nothing — or, if some
    /// launcher ever spells it out, spells out exactly the default path.
    static func runningApp() -> NSRunningApplication? {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if instances.count == 1 { return instances.first }
        return instances.first { isOfficial(pid: $0.processIdentifier) }
    }

    private static func isOfficial(pid: pid_t) -> Bool {
        guard let dir = userDataDir(ofPid: pid) else { return true }
        return normalized(dir) == normalized(defaultUserDataDir)
    }

    /// `--user-data-dir` off a process's argv, `nil` when it passes none.
    private static func userDataDir(ofPid pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ww", "-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let line = String(data: data, encoding: .utf8) else { return nil }
        guard let range = line.range(of: "--user-data-dir=") else { return nil }
        // Chrome's argv is space-separated and the path may be quoted; the flag
        // runs to the next space, which is good enough for the paths every
        // launcher here actually uses (none of them contain one).
        let rest = line[range.upperBound...]
        let value = rest.prefix { !$0.isWhitespace }
        return String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - Delivering the URL

    /// Hand the URL to the real profile. `newWindow` asks Chrome for a window
    /// of its own instead of a tab in the last active one.
    ///
    /// Fire-and-forget: the process spawned here forwards the command line to
    /// the running browser and exits within a few hundred milliseconds, and
    /// when there is no running browser it *becomes* one.
    static func open(_ url: String, newWindow: Bool = false) {
        var args = ["--profile-directory=\(profileDirectory)"]
        if newWindow { args.append("--new-window") }
        args.append(url)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            // The binary moved or the disk is unhappy — better a link in some
            // browser than no link at all.
            overlayError("Chrome binary failed (\(error)) — falling back to open -a")
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            fallback.arguments = ["-a", "Google Chrome", url]
            try? fallback.run()
        }
    }

    // MARK: - Windows (Accessibility, one pid only)

    /// A window of the official instance. `frame` is in the global
    /// **top-left-origin** point space — `CGDisplayBounds`' space, which is also
    /// what AX reads and writes, so no conversion happens on the way in or out.
    struct Window {
        let element: AXUIElement
        let frame: CGRect
    }

    /// Every normal window of the real Chrome, front-most first (AX orders them
    /// that way). Empty when Chrome is not running, when Accessibility has not
    /// been granted, or when the only Chromes running are automation ones.
    static func windows() -> [Window] {
        guard let app = runningApp() else { return [] }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &raw) == .success,
              let elements = raw as? [AXUIElement] else { return [] }
        return elements.compactMap { el in
            guard let pos = axValue(of: el, kAXPositionAttribute, type: .cgPoint, as: CGPoint.self),
                  let size = axValue(of: el, kAXSizeAttribute, type: .cgSize, as: CGSize.self),
                  size.width > 200, size.height > 100 else { return nil }
            return Window(element: el, frame: CGRect(origin: pos, size: size))
        }
    }

    /// The window Chrome would call its front one — the one a plain
    /// `open <url>` lands a tab in.
    static func focusedWindow() -> Window? {
        guard let app = runningApp() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &raw) == .success,
           let value = raw,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            let el = value as! AXUIElement
            if let pos = axValue(of: el, kAXPositionAttribute, type: .cgPoint, as: CGPoint.self),
               let size = axValue(of: el, kAXSizeAttribute, type: .cgSize, as: CGSize.self) {
                return Window(element: el, frame: CGRect(origin: pos, size: size))
            }
        }
        return windows().first
    }

    /// The front-most official window whose centre sits on `screen`, or `nil`
    /// when Chrome has none there.
    static func window(on screen: NSScreen) -> Window? {
        let box = topLeftRect(of: screen.frame)
        return windows().first { box.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    /// Make this the window Chrome hands the next URL to: main, raised, and the
    /// app in front. All three are needed — raising alone reorders the window
    /// without telling Chrome which browser is active, and Chrome picks the
    /// *last activated* browser of the profile when a command line arrives.
    static func focus(_ window: Window) {
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        runningApp()?.activate(options: [])
    }

    static func setFrame(_ window: Window, to rect: CGRect) {
        guard rect.width.isFinite, rect.height.isFinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return }
        var origin = rect.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
        }
        var size = rect.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value)
        }
    }

    /// Cocoa rect (bottom-left origin, y up) → AX/CoreGraphics rect (top-left
    /// origin, y down), measured from the top of the primary display. The same
    /// flip `TerminalWindowPlacement` documents for AppleScript bounds.
    static func topLeftRect(of rect: CGRect) -> CGRect {
        let primary = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main ?? NSScreen.screens[0]).frame
        return CGRect(x: rect.minX, y: primary.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// Poll for a window that was not in `known` — a `--new-window` Chrome has
    /// to actually draw before it can be placed. Answers on the main queue.
    static func awaitNewWindow(besides known: [Window], timeout: TimeInterval = 3.0,
                               then handler: @escaping (Window?) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            var found: Window?
            while Date() < deadline {
                let now = windows()
                if let fresh = now.first(where: { candidate in
                    !known.contains { CFEqual($0.element, candidate.element) }
                }) {
                    found = fresh
                    break
                }
                Thread.sleep(forTimeInterval: 0.08)
            }
            DispatchQueue.main.async { handler(found) }
        }
    }

    // MARK: - Test hook

    /// What this type currently believes, as JSON — every Chrome running, which
    /// one it picked, and the official windows with the screen each sits on.
    /// Read-only: `GET /test/chrome/windows`, the way to check the pick without
    /// opening a tab on the projector.
    static func debugJSON() -> String {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let official = runningApp()?.processIdentifier
        let all = instances.map { app -> String in
            let pid = app.processIdentifier
            let dir = userDataDir(ofPid: pid) ?? "(default)"
            return "{\"pid\":\(pid),\"userDataDir\":\"\(escape(dir))\",\"official\":\(pid == official)}"
        }
        let wins = windows().map { w -> String in
            let screen = NSScreen.screens.first {
                topLeftRect(of: $0.frame).contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
            }
            return "{\"x\":\(Int(w.frame.minX)),\"y\":\(Int(w.frame.minY))," +
                   "\"w\":\(Int(w.frame.width)),\"h\":\(Int(w.frame.height))," +
                   "\"screen\":\"\(escape(screen?.localizedName ?? "?"))\"}"
        }
        return "{\"chromes\":[\(all.joined(separator: ","))]," +
               "\"officialPid\":\(official.map(String.init) ?? "null")," +
               "\"windows\":[\(wins.joined(separator: ","))]}"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func axValue<T>(of el: AXUIElement, _ attr: String,
                                   type: AXValueType, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(axValue, type, out) else { return nil }
        return out.pointee
    }
}
