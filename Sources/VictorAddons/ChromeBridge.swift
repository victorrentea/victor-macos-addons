import CoreGraphics
import Foundation
import Network

/// Pushes the "dictation is happening" window to the Chrome extension, which
/// pauses every audible tab and resumes exactly those when it closes.
///
/// **Why a push, and why its own port.** The extension must react on the front
/// edge of a Mouse-5 press, so polling it from Chrome would have to be fast
/// enough to be wasteful — a WebSocket the Mac writes to costs nothing while
/// idle and arrives instantly. It does *not* reuse `LocalWebSocketServer`
/// (:8765) because that one's client count is the classroom participant count
/// shown in the menu bar; a browser attaching there would inflate it mid-course.
///
/// **Why the keepalive ping.** An MV3 service worker is torn down after ~30s
/// idle, which would silently drop the bridge between dictations. Traffic on an
/// open socket resets that timer, so the app pings every 20s — one tiny frame,
/// three times a minute, is what keeps the worker resident.
///
/// The state is also sent to each client the moment it connects, so a worker
/// that *was* torn down comes back knowing whether it owes a resume.
final class ChromeBridge {
    static let port: UInt16 = 8766
    private static let keepAliveInterval: TimeInterval = 20

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    /// What each client says it can do, from the `hello` it sends on connect.
    /// **A connected Chrome is not a capable one**: an unpacked extension is not
    /// reloaded by rebuilding the app, so an old service worker stays on this
    /// socket and drops any message type it has never heard of. Before the
    /// handshake, `focusOrOpen` read "someone is listening" as "someone will
    /// handle this", took the extension branch, and ⌘⌃F did nothing at all until
    /// the extension was reloaded by hand. Now an unannounced feature simply
    /// falls back to the old path.
    private var features: [UUID: Set<String>] = [:]
    private var keepAliveTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.chrome-bridge", qos: .userInitiated)
    /// Current window state, mirrored to every client. Queue only.
    private var active = false
    /// Bumped on every edge so a client can tell a fresh event from the state
    /// replay it gets on connect.
    private var seq = 0

    func start() {
        queue.async { [weak self] in self?.startListener() }
    }

    private func startListener() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            overlayError("ChromeBridge: failed to bind port \(Self.port)")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: overlayInfo("🎵 Dictation bridge on ws://127.0.0.1:\(Self.port)")
            case .failed(let e): overlayError("ChromeBridge failed: \(e)")
            default: break
            }
        }
        l.start(queue: queue)
        startKeepAlive()
    }

    /// Flip the window. Safe to call from any thread; a repeat of the current
    /// state is dropped so the extension never sees a spurious resume.
    func setActive(_ value: Bool) {
        queue.async { [weak self] in
            guard let self, self.active != value else { return }
            self.active = value
            self.seq += 1
            self.broadcast(self.stateJSON())
            overlayInfo(value ? "⏸️ dictation → pause audible Chrome tabs" : "▶️ dictation over → resume them")
        }
    }

    /// Ask the extension to publish a fresh feedback form for `session`.
    ///
    /// Fire-and-forget, and deliberately so: the extension answers by calling
    /// `/link/publish` on the HTTP server rather than by replying here, because
    /// the work takes many seconds and an MV3 worker may be torn down and
    /// resurrected in the middle of it — a reply channel would have to survive
    /// that, an HTTP call from whatever worker is alive at the end does not.
    ///
    /// Returns false when no Chrome is listening, which is the one failure
    /// worth surfacing in the menu: everything else shows up as a link that
    /// arrives, or does not.
    @discardableResult
    func publishFeedbackForm(session: String) -> Bool {
        var listeners = 0
        queue.sync {
            listeners = self.connections.count
            guard listeners > 0 else { return }
            self.seq += 1
            self.broadcast("{\"type\":\"publish-feedback-form\",\"session\":\(Self.jsonString(session)),\"seq\":\(self.seq)}")
        }
        overlayInfo(listeners > 0
            ? "📝 asked Chrome to publish the feedback form for \(session)"
            : "📝 no Chrome extension connected — feedback form not requested")
        return listeners > 0
    }

    /// How to recognise a tab this app would rather return to than duplicate.
    ///
    /// `match` is deliberately coarse — a host — because Chrome's match patterns
    /// cannot see a query string, and every distinction that matters here lives
    /// in one ("Gmail, but not a compose"; "the YouTube tab of *this* mix").
    /// `contains` / `notContains` do that half, in the extension, against the
    /// whole URL.
    struct TabSpec {
        let match: [String]
        var contains: String? = nil
        var notContains: String? = nil
        /// Play the tab's media if it is sitting paused — ⌘⌃F only. "Carry on
        /// from where it stopped" is the opposite of the random-track URL that
        /// key opens when the mix is not up yet.
        var resume: Bool = false
        /// Do the whole thing **without showing anything** — ⌘⌃F only. The tab
        /// is found or created in an existing window with `active: false`, is
        /// never activated, and its window is never raised or moved. A key that
        /// asks for background music must not put a browser on the projector,
        /// and `screen` below is ignored for the same reason: nothing is placed
        /// because nothing is meant to be looked at.
        var background: Bool = false
    }

    /// Ask the extension to go to the tab already showing this page.
    ///
    /// `url` is what to open when nothing matches, and it need not be the page
    /// searched for: ⌘⌃F looks for the focus mix but opens it at a random track.
    /// Passing `nil` makes this a **probe** — go there if it exists, otherwise do
    /// nothing — which is how ⌘⌃F answers instantly and only then spends a
    /// second reading YouTube for a URL it may not need.
    ///
    /// `screen` is where the window should end up, in the global top-left-origin
    /// point space (`OfficialChrome.topLeftRect`), which is also the space
    /// Chrome reports and accepts window bounds in. **The move is done by Chrome,
    /// not over Accessibility**, because only the extension knows which window
    /// the tab was in; the app would have to guess from "whatever is focused a
    /// moment later", and that guess is wrong exactly when the extension found
    /// nothing.
    ///
    /// Fire-and-forget, like `publishFeedbackForm`. The caller learns only
    /// whether a Chrome was listening, which is the one thing it must branch
    /// on — `false` means fall back to opening the URL the old way.
    @discardableResult
    func focusOrOpen(_ spec: TabSpec, url: String?, on screen: CGRect) -> Bool {
        var listeners = 0
        queue.sync {
            listeners = self.features.values.count { $0.contains("focus-or-open") }
            guard listeners > 0 else { return }
            self.seq += 1
            let patterns = spec.match.map(Self.jsonString).joined(separator: ",")
            var json = "{\"type\":\"focus-or-open\",\"match\":[\(patterns)]," +
                       "\"url\":\(url.map(Self.jsonString) ?? "null")," +
                       "\"resume\":\(spec.resume),\"background\":\(spec.background)," +
                       "\"screen\":{\"left\":\(Int(screen.minX)),\"top\":\(Int(screen.minY))," +
                       "\"width\":\(Int(screen.width)),\"height\":\(Int(screen.height))}"
            if let c = spec.contains { json += ",\"contains\":\(Self.jsonString(c))" }
            if let n = spec.notContains { json += ",\"notContains\":\(Self.jsonString(n))" }
            json += ",\"seq\":\(self.seq)}"
            self.broadcast(json)
        }
        return listeners > 0
    }

    /// Ask the extension to reload itself — `chrome.runtime.reload()`, which
    /// re-reads an unpacked extension from disk.
    ///
    /// This is the way a change to `chrome-extension/` gets applied. Nothing
    /// outside the browser can do it: `chrome://extensions` is off limits to
    /// extensions (including the automation one), and codex refuses browser
    /// control outright, so the click was landing on Victor. The extension is
    /// the one thing already inside Chrome with the right — it just has to be
    /// asked. Bootstrapping is the catch: a build that *introduces* this command
    /// still needs one manual reload before the running worker understands it.
    ///
    /// Returns false when no client advertises it — a worker too old to know how.
    @discardableResult
    func reloadExtension() -> Bool {
        var listeners = 0
        queue.sync {
            listeners = self.features.values.count { $0.contains("reload") }
            guard listeners > 0 else { return }
            self.seq += 1
            self.broadcast("{\"type\":\"reload\",\"seq\":\(self.seq)}")
        }
        overlayInfo(listeners > 0
            ? "🔄 asked the Chrome extension to reload itself"
            : "🔄 no Chrome extension able to reload itself — reload it by hand once")
        return listeners > 0
    }

    /// True while at least one Chrome extension is on the socket.
    var hasClients: Bool { queue.sync { !connections.isEmpty } }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    // MARK: - Internals

    private func stateJSON() -> String {
        "{\"type\":\"dictation\",\"active\":\(active),\"seq\":\(seq)}"
    }

    private func accept(_ conn: NWConnection) {
        let id = UUID()
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                overlayInfo("🎵 Dictation bridge: Chrome connected (\(self.connections.count) total)")
                // Replay the current state: a worker that was torn down mid
                // dictation learns it still owes a resume.
                self.send(self.stateJSON(), to: conn)
                self.drain(conn, id: id)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: id)
                self.features.removeValue(forKey: id)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// The frames must be read, or the connection stalls once its receive buffer
    /// fills. The only one worth a second glance is the `hello` a worker sends on
    /// connect, listing the message types it understands.
    private func drain(_ conn: NWConnection, id: UUID) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                switch msg["type"] as? String {
                case "hello":
                    let advertised = Set(msg["features"] as? [String] ?? [])
                    self.queue.async {
                        guard self.connections[id] != nil else { return }
                        self.features[id] = advertised
                        overlayInfo("🧩 Chrome extension speaks: \(advertised.sorted().joined(separator: ", "))")
                    }
                case "log":
                    // A service worker's console is only readable by opening
                    // DevTools on it, by hand, in Chrome — which is exactly the
                    // kind of click this whole day was about removing. Mirrored
                    // here, `tail /tmp/victor-macos-addons.log` shows both halves
                    // of the app interleaved, which is also the only way to see
                    // the order they happened in.
                    let text = msg["text"] as? String ?? ""
                    if msg["level"] as? String == "error" {
                        overlayError("🧩 \(text)")
                    } else {
                        overlayInfo("🧩 \(text)")
                    }
                default:
                    break
                }
            }
            self.drain(conn, id: id)
        }
    }

    private func startKeepAlive() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.keepAliveInterval,
                   repeating: Self.keepAliveInterval, leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self, !self.connections.isEmpty else { return }
            self.broadcast("{\"type\":\"ping\"}")
        }
        keepAliveTimer = t
        t.resume()
    }

    private func broadcast(_ text: String) {
        for conn in connections.values { send(text, to: conn) }
    }

    private func send(_ text: String, to conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        conn.send(content: text.data(using: .utf8), contentContext: context,
                  isComplete: true, completion: .contentProcessed { _ in })
    }
}
