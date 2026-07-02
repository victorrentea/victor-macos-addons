import Foundation

/// Reads the gitignored `videos/` manifest (`videos.json`) written by the
/// `add-training-video` skill, resolves ids to downloaded files, and produces
/// the small JSON the tablet's video page fetches at `GET /videos`.
///
/// The manifest is the single source of truth for a video's start second, so
/// the tablet only has to say "play id X" — the Mac knows where to seek.
enum VideoLibrary {
    struct Entry: Codable {
        let id: String
        let title: String
        let startSeconds: Int
        let file: String
        let url: String?
    }

    /// Resolve the repo's `videos/` directory using the same root strategy as
    /// `WhisperProcessManager` / `BreakSummaryLauncher` (env root, binary-relative,
    /// canonical workspace path, cwd).
    static func videosDir() -> String {
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let envRoot = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"] ?? ""
        let home = NSHomeDirectory()
        let cwd = FileManager.default.currentDirectoryPath
        var candidates = [
            "\(binaryDir)/../../../videos",
            "\(binaryDir)/videos",
        ]
        if !envRoot.isEmpty { candidates.append("\(envRoot)/videos") }
        candidates.append("\(home)/workspace/victor-macos-addons/videos")
        candidates.append("\(cwd)/videos")
        for c in candidates {
            let resolved = URL(fileURLWithPath: c).standardized.path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
                return resolved
            }
        }
        // Fall back to the canonical path even if it doesn't exist yet.
        return URL(fileURLWithPath: "\(home)/workspace/victor-macos-addons/videos").standardized.path
    }

    static func manifestPath() -> String { "\(videosDir())/videos.json" }

    private struct Manifest: Codable { let videos: [Entry] }

    static func entries() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: manifestPath()) else { return [] }
        return (try? JSONDecoder().decode(Manifest.self, from: data))?.videos ?? []
    }

    static func entry(id: String) -> Entry? {
        entries().first { $0.id == id }
    }

    static func fileURL(for entry: Entry) -> URL {
        URL(fileURLWithPath: "\(videosDir())/\(entry.file)")
    }

    /// JSON served to the tablet at `GET /videos` — only what a tile needs
    /// (id → thumbnail + play call, title → label, startSeconds is informational).
    static func manifestJSON() -> String {
        struct TileEntry: Codable { let id: String; let title: String; let startSeconds: Int }
        struct Out: Codable { let videos: [TileEntry] }
        let tiles = entries().map { TileEntry(id: $0.id, title: $0.title, startSeconds: $0.startSeconds) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(Out(videos: tiles)), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"videos\":[]}"
    }
}
