import CoreGraphics
import Foundation

/// The door to **Victor Mirror** (`victor-mirror`, 🪞), the menu-bar app that owns
/// the 🪞 Virtual Desktop and 🔊 Auto Share Faceover since 2026-10-26. They left
/// so that redeploying this app no longer kills the invisible screen — and with
/// it the Teams/Zoom share running on it.
///
/// Only the two historic test hooks are forwarded (`/test/virtual-desktop`,
/// `/test/zoom-share`), so the curl lines in old notes still work on 55123. Like
/// `EffectsProxy`, it runs on the server queue, never the main thread.
enum MirrorProxy {
    static let baseURL = "http://127.0.0.1:55127"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    static func forward(_ pathAndQuery: String) -> (status: Int, contentType: String, body: Data) {
        guard let url = URL(string: baseURL + pathAndQuery) else {
            return (400, "application/json", Data("{\"ok\":false}".utf8))
        }
        var answer: (Int, Data)?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, _ in
            if let http = response as? HTTPURLResponse { answer = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        guard let answer else {
            return (503, "application/json", Data("{\"ok\":false,\"reason\":\"mirror-down\"}".utf8))
        }
        return (answer.0, "application/json", answer.1)
    }

    /// The silhouette's window ids, asked once at launch: Victor Mirror pushes
    /// every later change itself (`/mirror/exclusions`), but not one it made
    /// while this app was down.
    static func fetchExclusions(_ done: @escaping ([CGWindowID]) -> Void) {
        guard let url = URL(string: baseURL + "/test/exclusions") else { return }
        session.dataTask(with: url) { data, _, _ in
            guard let data,
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = o["ids"] as? [NSNumber] else { return }
            done(ids.map { CGWindowID($0.uint32Value) })
        }.resume()
    }
}
