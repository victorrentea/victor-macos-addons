import Foundation

/// The one door from this app to **Victor Effects** (`victor-effects`), the
/// separate menu-bar app (🎆) that owns every desktop effect and the soundboard
/// playback since the 2026-09 split.
///
/// Why a proxy and not a move of the port: seven local clients point at
/// `127.0.0.1:55123` — the IntelliJ plugin's baked default, the VS Code
/// extension, `hands-off.sh`, the Chrome extension, the prompt-capture hook,
/// the test scripts — plus `adb reverse tcp:55123` on the tablet's USB link and
/// the Railway relay. Moving them is a marketplace release and a dozen edits;
/// one loopback hop on `/sound/play` (~1 ms) is invisible next to the tablet's
/// own Wi-Fi RTT. So addons keeps 55123 and forwards the effect/sound routes to
/// 55124 verbatim.
///
/// Everything here runs on the **server queue**, never the main thread: a slow
/// or absent effects app must not be able to freeze the menu bar. The one
/// exception is the `/ping` merge, which reaches into the main thread for the
/// addons half through `pingExtras` (a `main.sync` that only reads state).
enum EffectsProxy {
    /// Where the effects app listens. Env first (a test can point this at a
    /// stub), then a `UserDefaults` override, then the default port.
    static var baseURL: String {
        let env = ProcessInfo.processInfo.environment["VICTOR_EFFECTS_URL"] ?? ""
        if !env.isEmpty { return env }
        if let stored = UserDefaults.standard.string(forKey: "Effects.baseURL"), !stored.isEmpty {
            return stored
        }
        return "http://127.0.0.1:55124"
    }

    /// Ephemeral on purpose: no cookie jar, no disk cache, no credential store
    /// shared with anything else in the process. `waitsForConnectivity = false`
    /// so a stopped effects app fails in milliseconds instead of parking the
    /// request until the timeout.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    /// A shorter clock for `/ping`: the tablet pings every 5 s and a merged
    /// answer that arrives late is worse than one that says `effectsUp:false`.
    private static let pingTimeout: TimeInterval = 1.5

    // MARK: - Forwarding

    /// Forward one request verbatim and hand back the effects app's own status,
    /// content type and body. `/ping` is special — see `mergedPing`.
    ///
    /// Never call on the main thread: it blocks on a semaphore, and the `/ping`
    /// branch does its own `DispatchQueue.main.sync`.
    static func forward(_ pathAndQuery: String,
                        body: String = "",
                        pingExtras: (() -> String)? = nil) -> (status: Int, contentType: String, body: String) {
        if pathAndQuery == "/ping" || pathAndQuery.hasPrefix("/ping?") {
            let extras = pingExtras.map { collect in DispatchQueue.main.sync { collect() } } ?? ""
            let effects = get(pathAndQuery, body: body, timeout: pingTimeout)?.body
            return (200, "application/json", mergedPing(effectsJSON: effects, extras: extras))
        }
        guard let answer = get(pathAndQuery, body: body, timeout: session.configuration.timeoutIntervalForRequest) else {
            // The tablet reads a 404 on `/sound/play/<file>` as "the Mac does not
            // know this sound" and falls back to its own speaker — exactly the
            // behaviour wanted when the effects app is not running. Everything
            // else says "temporarily unavailable" instead.
            if pathAndQuery.hasPrefix("/sound/play/") {
                return (404, "application/json", "{\"ok\":false,\"reason\":\"effects-down\"}")
            }
            return (503, "application/json", "{\"ok\":false,\"reason\":\"effects-down\"}")
        }
        return answer
    }

    /// Fire-and-forget: a hotkey, a participant's emoji, a training-end tick.
    /// Nothing waits for the answer and nothing reports a failure — the effect
    /// either happens on the other screen or it does not, and a log line about
    /// it during a workshop is noise.
    static func fire(_ pathAndQuery: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = get(pathAndQuery, body: "", timeout: session.configuration.timeoutIntervalForRequest)
        }
    }

    /// Is the effects app answering right now? Only used for diagnostics.
    static func isUp() -> Bool {
        get("/ping", body: "", timeout: pingTimeout) != nil
    }

    // MARK: - The /ping merge

    /// Splice the two halves of `/ping` into the single object the tablet reads.
    ///
    /// The effects app knows `soundsHash`, `tilesHash` and its own version; this
    /// app knows the Mac's clock, its LAN addresses, the phone's battery, the
    /// lock state and whether the 🏁 sequence is armed. `MacLink` on the tablet
    /// parses ONE object, so the two are concatenated rather than nested — no
    /// tablet change was needed for the split.
    ///
    /// `extras` is a fragment that already starts with a comma (see
    /// `TabletHttpServer.onPingExtras`). With the effects app down the answer
    /// still says `ok`, with an **empty** `soundsHash`: `MacLink.refreshSyncState`
    /// returns early on an empty hash, so the tablet shows no amber
    /// "Mac is stale" dot, and its `/sound/play` then gets a 404 and plays
    /// locally. Degrading, not breaking.
    static func mergedPing(effectsJSON: String?, extras: String) -> String {
        guard let raw = effectsJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("{"), raw.hasSuffix("}") else {
            return "{\"ok\":true,\"soundsHash\":\"\",\"effectsUp\":false\(extras)}"
        }
        let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty {
            return "{\"ok\":true,\"soundsHash\":\"\",\"effectsUp\":false\(extras)}"
        }
        return "{\(inner)\(extras),\"effectsUp\":true}"
    }

    // MARK: - Plumbing

    /// One synchronous GET against the effects app. `nil` on any transport
    /// failure (not running, port closed, timed out) — an HTTP error status is
    /// NOT a failure here: it is the effects app's own answer and is passed
    /// through so the caller sees the real 404/503.
    private static func get(_ pathAndQuery: String,
                            body: String,
                            timeout: TimeInterval) -> (status: Int, contentType: String, body: String)? {
        let path = pathAndQuery.hasPrefix("/") ? pathAndQuery : "/" + pathAndQuery
        // The path arrives already percent-encoded (it came off the wire);
        // re-encoding it here would double every %XX.
        guard let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if !body.isEmpty {
            req.httpMethod = "POST"
            req.httpBody = body.data(using: .utf8)
        }

        var result: (status: Int, contentType: String, body: String)?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, _ in
            defer { done.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "text/plain; charset=utf-8"
            result = (http.statusCode, type, String(data: data ?? Data(), encoding: .utf8) ?? "")
        }.resume()
        // +0.5 s over the request timeout: the semaphore is the backstop for a
        // task that never calls back at all, not the timeout itself.
        _ = done.wait(timeout: .now() + timeout + 0.5)
        return result
    }
}
