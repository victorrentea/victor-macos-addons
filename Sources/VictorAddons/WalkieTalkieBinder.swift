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
        let label = (bound["label"] as? String) ?? "?"
        let address = (bound["address"] as? String) ?? ""
        // Pressed again on the session it was already pointed at: the relay has
        // ended. Said as a full stop rather than as another arrow — the arrow
        // means "words go here", and there is now nowhere for them to go.
        //
        // **And with nothing after it.** The folder was there by symmetry with the
        // bind banner, where it answers "which session did it grab?" — a question
        // worth a panel. Stopping has no such question: there is one relay, he
        // just ended it, and naming the repo invites a second reading ("stopped
        // *for that folder*") of something that has no per-folder half at all.
        if (bound["stopped"] as? Bool) == true {
            return "🎙️ relay stopped"
        }
        let guarded = (bound["guarded"] as? Bool) ?? true
        // **`🎙️ → petclinic@main · ✳ fixing the tax bug`.** The mic already says
        // "what you say", so the word *dictation* beside it was the glyph again
        // in letters; the arrow says "goes to", which is the whole message. It is
        // also the shape every other banner in this app uses, and the shape this
        // one had before it briefly grew a pin.
        //
        // The relay's own chip keeps 📍 — that one sits beside the cursor with no
        // arrow and no room for one, and has to say *this is a place* on its own.
        //
        // **The guard's absence is spelled out rather than glyphed.** For targets
        // the relay cannot interrogate before it types — VS Code, IntelliJ — a
        // dictation is pasted into whatever holds the caret and cannot be refused
        // at a shell prompt. Binding is the moment that fact can still change
        // what Victor does about it, so it is said in words here and nowhere
        // else on screen.
        let caveat = guarded ? "" : " — no shell guard"
        guard let title = bound["title"] as? String, !title.isEmpty else {
            return "🎙️ → \(label) · \(address)\(caveat)"
        }
        return "🎙️ → \(label) · \(title)\(caveat)"
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
