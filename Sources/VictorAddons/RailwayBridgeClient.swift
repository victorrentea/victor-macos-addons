import Foundation

/// Outbound WebSocket to the Railway **bridge** (`/ws/bridge/mac`) — the tablet's
/// last-resort transport when it can't reach the Mac on the LAN (public-Wi-Fi
/// client isolation / mDNS filtering) or over USB.
///
/// The tablet sends `bridge_request` frames (a `{method,path,body}` mirror of the
/// HTTP API) up to Railway; Railway forwards them here; this client runs each one
/// through `TabletHttpServer.respond` — the **same route table** that serves
/// LAN/USB HTTP — and returns a `bridge_response`. So every endpoint works over
/// the bridge with no per-endpoint code here.
///
/// Both the Mac and the tablet dial **out** to Railway, so neither needs an
/// inbound port. That's precisely what lets the bridge punch through the client
/// isolation and NAT that block direct device-to-device traffic on public Wi-Fi.
///
/// Auth: a shared token sent as the `X-Bridge-Token` header (kept out of the URL
/// so it never lands in access logs). Reconnects every 5 s on drop/failure.
///
/// Liveness: a ping every 15 s, and a socket that does not pong within 10 s is
/// dropped and redialled. Without it a socket can go dead without any callback
/// firing: seen on 2026-10-01, the add-on logged "connected" and still held an
/// established TCP flow to Railway a quarter of an hour later, while Railway
/// answered every tablet request with `mac-offline` — a fresh `/ws/bridge/mac`
/// connection, which kicks the previous Mac, did not even reach it. Nothing in
/// the old code would ever have noticed, so the relay stayed down until the
/// network itself dropped.
final class RailwayBridgeClient: NSObject, URLSessionWebSocketDelegate {
    private let baseURL: String        // e.g. "wss://interact.victorrentea.ro"
    private let token: String
    private weak var server: TabletHttpServer?

    private lazy var session: URLSession =
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    // userInitiated, not utility: every tablet press over the relay waits on this queue.
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.railway-bridge", qos: .userInitiated)
    private var stopped = false
    private var reconnectScheduled = false
    /// Bumped on every dial; a heartbeat armed for an older socket does nothing.
    private var generation = 0
    private var awaitingPong = false

    private static let heartbeatInterval: TimeInterval = 15
    private static let pongTimeout: TimeInterval = 10

    /// Fails (returns nil) when no token is configured — the bridge stays off
    /// rather than connecting unauthenticated.
    init?(baseURL: String, token: String, server: TabletHttpServer) {
        guard !token.isEmpty else {
            NSLog("[RailwayBridge] no bridge token configured — bridge disabled")
            return nil
        }
        self.baseURL = baseURL
        self.token = token
        self.server = server
    }

    func start() {
        queue.async { [weak self] in self?.connect() }
    }

    // MARK: - Connection

    private func connect() {
        guard !stopped else { return }
        let wsBase = baseURL
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
        guard let url = URL(string: "\(wsBase)/ws/bridge/mac") else {
            NSLog("[RailwayBridge] invalid base URL: \(baseURL)")
            return
        }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Bridge-Token")
        let t = session.webSocketTask(with: req)
        task = t
        generation += 1
        awaitingPong = false
        t.resume()
        receive(t)
        scheduleHeartbeat(generation)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handleRequest(text)
                }
                self.receive(t)   // re-arm for the next frame
            case .failure:
                self.scheduleReconnect(for: t)
            }
        }
    }

    // MARK: - Heartbeat

    private func scheduleHeartbeat(_ gen: Int) {
        queue.asyncAfter(deadline: .now() + Self.heartbeatInterval) { [weak self] in
            guard let self, !self.stopped, gen == self.generation, let t = self.task else { return }
            self.awaitingPong = true
            t.sendPing { [weak self] error in
                self?.queue.async {
                    guard let self, gen == self.generation else { return }
                    self.awaitingPong = false
                    if let error {
                        self.drop(t, "ping failed (\(error.localizedDescription))")
                    } else {
                        self.scheduleHeartbeat(gen)
                    }
                }
            }
            self.queue.asyncAfter(deadline: .now() + Self.pongTimeout) { [weak self] in
                guard let self, gen == self.generation, self.awaitingPong else { return }
                self.drop(t, "no pong in \(Int(Self.pongTimeout)) s")
            }
        }
    }

    /// Runs on `queue`.
    private func drop(_ t: URLSessionWebSocketTask, _ why: String) {
        NSLog("[RailwayBridge] \(why) — dead socket, redialling")
        t.cancel(with: .goingAway, reason: nil)
        scheduleReconnect(for: t)
    }

    // MARK: - Request handling

    private func handleRequest(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "bridge_request",
              let id = json["id"] as? String,
              let path = json["path"] as? String else {
            return
        }
        let body = json["body"] as? String ?? ""
        // respond() blocks on DispatchQueue.main.sync, so run it off the main
        // thread — our own utility queue.
        queue.async { [weak self] in
            guard let self, let server = self.server else { return }
            let result = server.respond(path: path, requestBody: body)
            // The relay carries a JSON envelope, so its body has to be text.
            // Nothing binary is expected to reach it: the tablet fetches tile
            // pictures over HTTP only, on purpose (`MacLink.reachBytes`), because
            // tens of kilobytes of PNG have no business crossing the internet
            // relay that exists for 200-byte control calls. A body that is not
            // UTF-8 therefore means a client took a path it was not meant to —
            // answered empty, exactly as before, rather than with mojibake.
            self.sendResponse(id: id, status: result.status,
                              contentType: result.contentType,
                              body: String(data: result.body, encoding: .utf8) ?? "")
        }
    }

    private func sendResponse(id: String, status: Int, contentType: String, body: String) {
        let payload: [String: Any] = [
            "type": "bridge_response",
            "id": id,
            "status": status,
            "contentType": contentType,
            "body": body,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in
            if let error { NSLog("[RailwayBridge] response send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Reconnect

    /// [t] is the socket that failed; a late callback from a socket already
    /// replaced must not tear down the live one.
    private func scheduleReconnect(for t: URLSessionTask) {
        queue.async { [weak self] in
            guard let self, !self.stopped, !self.reconnectScheduled else { return }
            if let current = self.task, current !== t { return }
            self.reconnectScheduled = true
            self.task = nil
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.reconnectScheduled = false
                self.connect()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        NSLog("[RailwayBridge] connected — tablet reachable via \(baseURL)/ws/bridge/mac")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        NSLog("[RailwayBridge] closed (code \(closeCode.rawValue)) — reconnecting")
        scheduleReconnect(for: webSocketTask)
    }

    /// A rejected handshake (e.g. HTTP 403 when the token is missing/wrong on
    /// Railway) surfaces here, not via didClose. Logged so a token mismatch is
    /// visible rather than a silent retry loop.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            NSLog("[RailwayBridge] connection failed (\(error.localizedDescription)) — check BRIDGE_TOKEN match; reconnecting")
        }
        scheduleReconnect(for: task)
    }
}
