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
final class RailwayBridgeClient: NSObject, URLSessionWebSocketDelegate {
    private let baseURL: String        // e.g. "wss://interact.victorrentea.ro"
    private let token: String
    private weak var server: TabletHttpServer?

    private lazy var session: URLSession =
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.railway-bridge", qos: .utility)
    private var stopped = false
    private var reconnectScheduled = false

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
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.handleRequest(text)
                }
                self.receive()   // re-arm for the next frame
            case .failure:
                self.scheduleReconnect()
            }
        }
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
            self.sendResponse(id: id, status: result.status,
                              contentType: result.contentType, body: result.body)
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

    private func scheduleReconnect() {
        queue.async { [weak self] in
            guard let self, !self.stopped, !self.reconnectScheduled else { return }
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
        scheduleReconnect()
    }

    /// A rejected handshake (e.g. HTTP 403 when the token is missing/wrong on
    /// Railway) surfaces here, not via didClose. Logged so a token mismatch is
    /// visible rather than a silent retry loop.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            NSLog("[RailwayBridge] connection failed (\(error.localizedDescription)) — check BRIDGE_TOKEN match; reconnecting")
        }
        scheduleReconnect()
    }
}
