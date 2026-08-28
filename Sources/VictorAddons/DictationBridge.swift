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
final class DictationBridge {
    static let port: UInt16 = 8766
    private static let keepAliveInterval: TimeInterval = 20

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var keepAliveTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.dictation-bridge", qos: .userInitiated)
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
            overlayError("DictationBridge: failed to bind port \(Self.port)")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: overlayInfo("🎵 Dictation bridge on ws://127.0.0.1:\(Self.port)")
            case .failed(let e): overlayError("DictationBridge failed: \(e)")
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
                self.drain(conn)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: id)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// We never act on what Chrome says — but the frames must be read, or the
    /// connection stalls once its receive buffer fills.
    private func drain(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] _, _, _, error in
            guard error == nil else { return }
            self?.drain(conn)
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
