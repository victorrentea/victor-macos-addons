import Foundation

/// 🎬 One JSONL line per Video Snippet the room actually saw or heard, in
/// `~/.victor-addons/video-plays.jsonl`. The training-assistant daemon reads it for a
/// time window and links each clip's YouTube upload into the end-of-day summary and the
/// wiki, at the minute it was played ("played shorts"). Best-effort: a write failure is
/// logged and never touches the play.
enum VideoPlayLog {
    static var fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".victor-addons", isDirectory: true)
        .appendingPathComponent("video-plays.jsonl")
    private static let queue = DispatchQueue(label: "video-play-log", qos: .utility)

    /// `kind` is "video" (the clip, fullscreen) or "soundtrack" (the ♪ button: sound only).
    static func line(id: String, title: String, startSeconds: Int, kind: String, at date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        let obj: [String: Any] = ["ts": f.string(from: date), "id": id, "title": title,
                                  "startSeconds": startSeconds, "kind": kind]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func append(id: String, title: String, startSeconds: Int, kind: String) {
        let text = line(id: id, title: title, startSeconds: startSeconds, kind: kind) + "\n"
        let url = fileURL
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let h = try? FileHandle(forWritingTo: url) {
                    defer { try? h.close() }
                    try h.seekToEnd()
                    try h.write(contentsOf: Data(text.utf8))
                } else {
                    try Data(text.utf8).write(to: url)
                }
            } catch {
                NSLog("VideoPlayLog: could not append to \(url.path): \(error)")
            }
        }
    }
}
