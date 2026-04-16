import Foundation
import Network

class LocalWebSocketServer {
    static let port: UInt16 = 8765

    // Called when emoji received — triggers in-process animation
    var onEmoji: ((String, Int) -> Void)?
    // Called when client count changes (dispatch to main by caller)
    var onClientCountChanged: ((Int) -> Void)?
    // Called when session_started or session_ended message received
    var onSessionMessage: (([String: Any]) -> Void)?

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var lastSlide: [String: Any]? = nil
    private let queue = DispatchQueue(label: "ws-server", qos: .utility)

    func start() {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            overlayInfo("Failed to create WS listener")
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewConnection(conn)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                overlayInfo("WS server listening on ws://127.0.0.1:\(Self.port)")
            case .failed(let error):
                overlayInfo("WS server failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
    }

    func pushSlide(_ event: [String: Any]) {
        lastSlide = event
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        queue.async { [weak self] in
            self?.broadcast(text)
        }
    }

    func pushSlidesViewed(_ slides: [[String: Any]]) {
        let msg: [String: Any] = ["type": "slides_viewed", "slides": slides]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        queue.async { [weak self] in
            self?.broadcast(text)
        }
    }

    func pushGitFileOpened(url: String, branch: String, file: String) {
        let msg: [String: Any] = ["type": "git_file_opened", "url": url, "branch": branch, "file": file]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        queue.async { [weak self] in
            self?.broadcast(text)
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        let id = UUID()
        connections[id] = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                overlayInfo("WS client connected (\(self?.connections.count ?? 0) total)")
                let count = self?.connections.count ?? 0
                DispatchQueue.main.async { self?.onClientCountChanged?(count) }
                // Send last slide state as welcome
                if let slide = self?.lastSlide,
                   let data = try? JSONSerialization.data(withJSONObject: slide),
                   let text = String(data: data, encoding: .utf8) {
                    self?.send(text, to: conn)
                }
                self?.receiveMessages(from: conn, id: id)
            case .failed, .cancelled:
                self?.removeConnection(id: id)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func receiveMessages(from conn: NWConnection, id: UUID) {
        conn.receiveMessage { [weak self] data, context, isComplete, error in
            if let error = error {
                overlayInfo("WS receive error: \(error)")
                self?.removeConnection(id: id)
                return
            }
            guard let context = context,
                  let metadata = context.protocolMetadata.first as? NWProtocolWebSocket.Metadata else {
                // No WebSocket frame yet — if stream ended, it's a disconnect
                if isComplete {
                    self?.removeConnection(id: id)
                } else if self?.connections[id] != nil {
                    self?.receiveMessages(from: conn, id: id)
                }
                return
            }
            // WebSocket close frame = clean disconnect
            if metadata.opcode == .close {
                self?.removeConnection(id: id)
                return
            }
            if metadata.opcode == .text, let data = data,
               let text = String(data: data, encoding: .utf8) {
                self?.handleText(text, from: id)
            }
            // Continue receiving
            if self?.connections[id] != nil {
                self?.receiveMessages(from: conn, id: id)
            }
        }
    }

    private func handleText(_ text: String, from senderID: UUID) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "display_emoji":
            let emoji = json["emoji"] as? String ?? ""
            let count = json["count"] as? Int ?? 1
            // In-process: directly trigger animation
            DispatchQueue.main.async { [weak self] in
                self?.onEmoji?(emoji, count)
            }
            // Also relay to other clients
            broadcast(text, except: senderID)
        case "session_started", "session_ended":
            overlayInfo("WS server received: \(type)")
            // Forward session lifecycle events to AppDelegate
            DispatchQueue.main.async { [weak self] in
                self?.onSessionMessage?(json)
            }
        case "ping":
            break  // ignore keep-alive
        default:
            overlayInfo("WS server ignored unknown message type: \(type)")
        }
    }

    private func send(_ text: String, to conn: NWConnection) {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func broadcast(_ text: String, except excludedID: UUID? = nil) {
        for (id, conn) in connections {
            if id == excludedID { continue }
            send(text, to: conn)
        }
    }

    private func removeConnection(id: UUID) {
        connections.removeValue(forKey: id)
        overlayInfo("WS client disconnected (\(connections.count) remaining)")
        let count = connections.count
        DispatchQueue.main.async { [weak self] in
            self?.onClientCountChanged?(count)
        }
    }
}
