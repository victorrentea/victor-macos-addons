import Foundation
import Network

/// Minimal HTTP server on port 55123 for tablet → Mac triggers.
class TabletHttpServer {
    static let port: UInt16 = 55123

    var onAlarmStart: (() -> Void)?
    var onAlarmStop: (() -> Void)?
    /// Generic effect handler: receives the effect name (e.g. "fireworks", "applause", "applause/stop")
    var onEffect: ((String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tablet-http", qos: .utility)

    func start() {
        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: tcpParams, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            overlayError("TabletHttpServer: failed to bind port \(Self.port)")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:   overlayInfo("Tablet HTTP server on :\(Self.port)")
            case .failed(let err): overlayError("TabletHttpServer failed: \(err)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, _ in
            let path = data.flatMap { String(data: $0, encoding: .utf8) }.map(Self.parsePath) ?? "/"
            DispatchQueue.main.async {
                switch path {
                case "/alarm/start": self?.onAlarmStart?()
                case "/alarm/stop":  self?.onAlarmStop?()
                default:
                    if path.hasPrefix("/effect/") {
                        let name = String(path.dropFirst("/effect/".count))
                        self?.onEffect?(name)
                    }
                }
            }
            let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private static func parsePath(_ request: String) -> String {
        let parts = request.split(separator: " ", maxSplits: 2)
        return parts.count > 1 ? String(parts[1]) : "/"
    }
}
