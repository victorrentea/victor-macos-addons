import Foundation
import Network

/// Minimal HTTP server on port 55123 for tablet → Mac triggers.
class TabletHttpServer {
    static let port: UInt16 = 55123

    enum Route: Equatable {
        case alarmStart
        case alarmStop
        case effect(String)
        case testTranscriptionStart
        case testTranscriptionStop
        case testTranscriptionToggle
        case testState
        case unknown
    }

    var onAlarmStart: (() -> Void)?
    var onAlarmStop: (() -> Void)?
    /// Generic effect handler: receives the effect name (e.g. "fireworks", "applause", "applause/stop")
    var onEffect: ((String) -> Void)?
    var onTestTranscriptionStart: (() -> Void)?
    var onTestTranscriptionStop: (() -> Void)?
    var onTestTranscriptionToggle: (() -> Void)?
    var onTestState: (() -> String)?

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
            let route = Self.route(forPath: path)

            var statusCode = 200
            var body = "ok"
            var contentType = "text/plain; charset=utf-8"

            DispatchQueue.main.sync {
                switch route {
                case .alarmStart:
                    self?.onAlarmStart?()
                case .alarmStop:
                    self?.onAlarmStop?()
                case .effect(let name):
                    self?.onEffect?(name)
                case .testTranscriptionStart:
                    self?.onTestTranscriptionStart?()
                case .testTranscriptionStop:
                    self?.onTestTranscriptionStop?()
                case .testTranscriptionToggle:
                    self?.onTestTranscriptionToggle?()
                case .testState:
                    contentType = "application/json"
                    body = self?.onTestState?() ?? "{\"error\":\"state unavailable\"}"
                    if self?.onTestState == nil {
                        statusCode = 503
                    }
                case .unknown:
                    statusCode = 404
                    body = "not found"
                }
            }

            let response = Self.httpResponse(statusCode: statusCode, contentType: contentType, body: body)
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    static func parsePath(_ request: String) -> String {
        let parts = request.split(separator: " ", maxSplits: 2)
        return parts.count > 1 ? String(parts[1]) : "/"
    }

    static func route(forPath path: String) -> Route {
        switch path {
        case "/alarm/start":
            return .alarmStart
        case "/alarm/stop":
            return .alarmStop
        case "/test/transcription/start":
            return .testTranscriptionStart
        case "/test/transcription/stop":
            return .testTranscriptionStop
        case "/test/transcription/toggle":
            return .testTranscriptionToggle
        case "/test/state":
            return .testState
        default:
            if path.hasPrefix("/effect/") {
                return .effect(String(path.dropFirst("/effect/".count)))
            }
            return .unknown
        }
    }

    private static func httpResponse(statusCode: Int, contentType: String, body: String) -> String {
        let reason: String
        switch statusCode {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let bytes = body.utf8.count
        return "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bytes)\r\n\r\n\(body)"
    }
}
