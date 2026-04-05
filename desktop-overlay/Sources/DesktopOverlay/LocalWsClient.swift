import Foundation

/// Connects to the local wispr-flow WebSocket server (ws://127.0.0.1:PORT).
/// Receives emoji messages and relays them via the provided callback.
/// Reconnects automatically with exponential backoff on disconnect.
class LocalWsClient: NSObject, URLSessionWebSocketDelegate {
    private let port: Int
    private let onEmoji: (String, Int) -> Void

    private var session: URLSession!
    private var wsTask: URLSessionWebSocketTask?
    private var reconnecting = false
    private var backoffSeconds: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 30.0

    init(port: Int? = nil, onEmoji: @escaping (String, Int) -> Void) {
        let port = port ?? LocalWsClient.defaultPort()
        self.port = port
        self.onEmoji = onEmoji
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    static func defaultPort() -> Int {
        if let val = ProcessInfo.processInfo.environment["WS_SERVER_PORT"],
           let port = Int(val) { return port }
        return 8765
    }

    func connect() {
        reconnecting = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return }
        wsTask = session.webSocketTask(with: url)
        wsTask?.resume()
    }

    func disconnect() {
        reconnecting = true  // prevent auto-reconnect
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        backoffSeconds = 1.0
        overlayInfo("Local WS connected on port \(port)")
        receive()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { scheduleReconnect() }
    }

    // MARK: - Private

    private func receive() {
        wsTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message { self?.handle(text) }
                self?.receive()
            case .failure:
                self?.scheduleReconnect()
            }
        }
    }

    /// Exposed for testing: feed a raw JSON string as if received from the server.
    func simulateMessage(_ text: String) { handle(text) }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "emoji", let emoji = json["emoji"] as? String {
            let count = json["count"] as? Int ?? 1
            onEmoji(emoji, count)
        }
    }

    private func scheduleReconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        let delay = backoffSeconds
        backoffSeconds = min(backoffSeconds * 2, maxBackoff)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }
}
