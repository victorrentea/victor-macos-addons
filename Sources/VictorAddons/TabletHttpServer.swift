import Foundation
import Network

/// Minimal HTTP server on port 55123 for tablet → Mac triggers.
class TabletHttpServer {
    static let port: UInt16 = 55123

    enum Route: Equatable {
        case alarmStart
        case alarmStop
        case effect(String)
        case openUrl(String)
        case testTranscriptionStart
        case testTranscriptionStop
        case testTranscriptionToggle
        case testExitWindow
        case testState
        case testAudioPlaying
        case testWisprRecording
        case promptCapture
        case unknown
    }

    var onAlarmStart: (() -> Void)?
    var onAlarmStop: (() -> Void)?
    /// Generic effect handler: receives the effect name (e.g. "fireworks", "applause", "applause/stop")
    var onEffect: ((String) -> Void)?
    /// Open a URL in a fullscreen Chrome window on the primary display.
    var onOpenUrl: ((String) -> Void)?
    var onTestTranscriptionStart: (() -> Void)?
    var onTestTranscriptionStop: (() -> Void)?
    var onTestTranscriptionToggle: (() -> Void)?
    var onTestExitWindow: (() -> Void)?
    var onTestState: (() -> String)?
    var onTestAudioPlaying: (() -> String)?
    var onTestWisprRecording: (() -> String)?
    /// Receives the prompt body; returns JSON describing whether it was captured.
    var onPromptCapture: ((String) -> String)?

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
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = Self.parsePath(raw)
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
                case .openUrl(let url):
                    self?.onOpenUrl?(url)
                case .testTranscriptionStart:
                    self?.onTestTranscriptionStart?()
                case .testTranscriptionStop:
                    self?.onTestTranscriptionStop?()
                case .testTranscriptionToggle:
                    self?.onTestTranscriptionToggle?()
                case .testExitWindow:
                    self?.onTestExitWindow?()
                case .testState:
                    contentType = "application/json"
                    body = self?.onTestState?() ?? "{\"error\":\"state unavailable\"}"
                    if self?.onTestState == nil {
                        statusCode = 503
                    }
                case .testAudioPlaying:
                    contentType = "application/json"
                    body = self?.onTestAudioPlaying?() ?? "{\"error\":\"audio probe unavailable\"}"
                    if self?.onTestAudioPlaying == nil {
                        statusCode = 503
                    }
                case .testWisprRecording:
                    contentType = "application/json"
                    body = self?.onTestWisprRecording?() ?? "{\"error\":\"wispr probe unavailable\"}"
                    if self?.onTestWisprRecording == nil {
                        statusCode = 503
                    }
                case .promptCapture:
                    contentType = "application/json"
                    let promptBody = Self.extractBody(raw)
                    body = self?.onPromptCapture?(promptBody) ?? "{\"captured\":false,\"reason\":\"handler-missing\"}"
                case .unknown:
                    statusCode = 404
                    body = "not found"
                }
            }

            let response = Self.httpResponse(statusCode: statusCode, contentType: contentType, body: body)
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// Extract the body from a raw HTTP request — everything after the blank
    /// line that terminates the headers. Returns "" if no body present.
    static func extractBody(_ raw: String) -> String {
        if let range = raw.range(of: "\r\n\r\n") {
            return String(raw[range.upperBound...])
        }
        if let range = raw.range(of: "\n\n") {
            return String(raw[range.upperBound...])
        }
        return ""
    }

    static func parsePath(_ request: String) -> String {
        let parts = request.split(separator: " ", maxSplits: 2)
        return parts.count > 1 ? String(parts[1]) : "/"
    }

    static func route(forPath path: String) -> Route {
        let (pathOnly, queryItems) = parsePathAndQuery(path)
        switch pathOnly {
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
        case "/test/transcription/exit-window":
            return .testExitWindow
        case "/test/state":
            return .testState
        case "/test/audio/playing":
            return .testAudioPlaying
        case "/test/wispr/recording":
            return .testWisprRecording
        case "/training/prompt-capture":
            return .promptCapture
        case "/open":
            if let url = queryItems.first(where: { $0.name == "url" })?.value, !url.isEmpty {
                return .openUrl(url)
            }
            return .unknown
        default:
            if pathOnly.hasPrefix("/effect/") {
                return .effect(String(pathOnly.dropFirst("/effect/".count)))
            }
            return .unknown
        }
    }

    private static func parsePathAndQuery(_ raw: String) -> (String, [URLQueryItem]) {
        guard let comps = URLComponents(string: "http://x" + raw) else { return (raw, []) }
        return (comps.path, comps.queryItems ?? [])
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
