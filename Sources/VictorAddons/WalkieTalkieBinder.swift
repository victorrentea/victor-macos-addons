import AppKit

/// ⌘⌃D — point Walkie Talkie at the terminal Victor is looking at, so everything
/// he dictates from then on is typed straight into that session.
///
/// **Why this key lives here and not in the relay.** The relay is started per
/// session and is not running most of the time; this app is a login item and is
/// always up. A binding shortcut that only worked once the relay was already
/// running would need the trip into a terminal that the whole feature exists to
/// remove. So Addons owns the key, and starting the relay is part of what the
/// key does.
///
/// It is deliberately the *only* owner: the relay has its own event tap, and two
/// taps claiming ⌘⌃D would both fire on one press — a bind followed by a second
/// bind, or worse, a bind of whatever the first one left in front.
///
/// **What it talks to** is the relay's loopback control surface, the same
/// 8917–8919 the Chrome inspector uses. Several relays can be up at once, each
/// holding the first free port; this takes the **first that answers** rather
/// than posting to all of them the way the extension does. Binding is not a
/// broadcast — pointing every relay on the machine at one terminal would mean
/// every dictation arriving there two or three times.
enum WalkieTalkieBinder {

    /// Where the relay listens, in the order it claims the ports.
    private static let ports = [8917, 8918, 8919]

    private static let appPath = "/Applications/Walkie Talkie.app"

    /// The picture the bind banner wears instead of the word `walkie`.
    ///
    /// Bundled rather than taken from the installed app's icon: the relay is an
    /// accessory with no icon worth showing at 40pt, and this is a drawing of the
    /// thing the app is named after — which is what makes it readable at a glance
    /// from across a room.
    static let icon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "walkie-talkie", withExtension: "png",
                                          subdirectory: "Resources")
                ?? Bundle.module.url(forResource: "walkie-talkie", withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    /// One press. Returns what to put in front of Victor.
    ///
    /// Runs off the main thread — it is HTTP and, in the cold case, an app
    /// launch it waits on.
    static func bindFrontmostTerminal() -> String {
        if let bound = post("/bind") { return describe(bound) }

        // Nothing listening: the relay is not running, which for this key is not
        // an error but the ordinary first press of the day.
        guard launchRelay() else { return "⚠️ Walkie Talkie isn't installed" }
        guard waitForListener() else { return "⚠️ Walkie Talkie didn't come up" }

        guard let bound = post("/bind") else {
            return "⚠️ nothing bindable in front — click into a terminal first"
        }
        return describe(bound)
    }

    private static func describe(_ bound: [String: Any]) -> String {
        // **No `walkie:` in front of it.** The banner carries the app's own
        // picture now (see `StatusBanner.showNow(icon:)`), which says who is
        // talking in the space of a glyph instead of seven characters of prefix
        // repeated on a pill that is only up for three seconds.
        //
        // **The folder, and the app's name only when there is no folder.**
        // `label` is the relay's own name for the target, and for a terminal
        // inside an editor that name is the *editor* — so the banner read
        // `walkie: started in IntelliJ IDEA` while the panel it had just grabbed
        // was plainly in `petclinic`, which is the one thing the sentence is
        // there to say. The chip beside the cursor has always preferred the
        // folder; this is the same preference, one banner later.
        let label = (bound["folder"] as? String) ?? (bound["label"] as? String) ?? "?"
        // Pressed again on the session it was already pointed at: the relay has
        // ended. Said as a full stop rather than as a destination — a destination
        // means "words go here", and there is now nowhere for them to go.
        //
        // **And with nothing after it.** The folder was there by symmetry with the
        // start banner, where it answers "which session did it grab?" — a question
        // worth a panel. Stopping has no such question: there is one relay, he
        // just ended it, and naming the repo invites a second reading ("stopped
        // *for that folder*") of something that has no per-folder half at all.
        if (bound["stopped"] as? Bool) == true {
            return "stopped"
        }
        let guarded = (bound["guarded"] as? Bool) ?? true
        // **`walkie: started in petclinic@main`.** Two banners a few seconds
        // apart — this one and the relay's own — now read as one sentence about
        // one thing, which is why both say the app's name and the same word for
        // the same event. The folder is the answer to "which session did it
        // grab?"; the tab's title and its `ttysNNN` used to ride along here and
        // said *which device file*, a question Victor has never once asked at
        // this moment.
        //
        // **The guard's absence is spelled out rather than glyphed.** For targets
        // the relay cannot interrogate before it types — VS Code, IntelliJ — a
        // dictation is pasted into whatever holds the caret and cannot be refused
        // at a shell prompt. Binding is the moment that fact can still change
        // what Victor does about it, so it is said in words here and nowhere
        // else on screen — and it survives the shortening for exactly that
        // reason: it is a warning, not a label.
        let caveat = guarded ? "" : " — no shell guard"
        return "started in \(label)\(caveat)"
    }

    /// **`-g`, and the whole feature depends on it.** The relay decides what to
    /// bind by asking which app is frontmost, so an `open` that brought anything
    /// forward would make the very launch that enables the bind also spoil it.
    /// The relay is an accessory app with no window to show, so there is nothing
    /// lost by starting it in the background.
    private static func launchRelay() -> Bool {
        guard FileManager.default.fileExists(atPath: appPath) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-a", appPath]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The relay opens its listener a moment after launch — after the single
    /// instance check, the outbox and the event tap. Polled rather than slept
    /// on, so a warm start costs the first 100ms and not a fixed second.
    private static func waitForListener() -> Bool {
        for _ in 0..<50 {
            if get("/target") != nil { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func post(_ path: String) -> [String: Any]? { request(path, method: "POST") }
    private static func get(_ path: String) -> [String: Any]? { request(path, method: "GET") }

    /// First port that answers wins. A relay that is up but refuses (409, no
    /// bindable app in front) is still *the* relay — the loop stops looking, so
    /// a refusal is reported rather than silently retried against a second one
    /// that would refuse identically.
    private static func request(_ path: String, method: String) -> [String: Any]? {
        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = 3

            var answered = false
            var body: [String: Any]?
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { data, response, _ in
                defer { done.signal() }
                guard let http = response as? HTTPURLResponse else { return }
                answered = true
                guard http.statusCode == 200, let data = data else { return }
                body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }.resume()
            _ = done.wait(timeout: .now() + 4)

            if answered { return body }
        }
        return nil
    }
}
