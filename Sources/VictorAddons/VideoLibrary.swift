import AVFoundation
import AppKit
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
        /// Optional base64 JPEG tile thumbnail. Present for local (non-YouTube)
        /// videos that have no `img.youtube.com/vi/<id>` image; the tablet decodes
        /// it directly instead of fetching by id.
        let thumb: String?
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

    /// Tile-thumbnail width served to the tablet — matches the base64 JPEGs the
    /// local clips already carry by hand (480 px), which is all a tile five-to-a-row
    /// needs.
    private static let thumbWidth: CGFloat = 480

    /// The base64 JPEG the tablet paints on a tile. A manifest entry may carry its
    /// own (`thumb`, written by hand for local clips); everything else gets a frame
    /// pulled out of the already-downloaded mp4 and cached beside it as
    /// `videos/<id>.jpg`.
    ///
    /// Exists so the tablet never reaches out to `img.youtube.com`. That fetch is
    /// what leaves page 2 sitting on ▶ placeholders at a venue: the tablet tries
    /// `maxresdefault` then `mqdefault` with a 3 s connect + 5 s read timeout **per
    /// URL, per video**, and a filtered hotspot burns every one of them. Serving the
    /// image inside the same response as the list also makes the two impossible to
    /// drift apart — there is one source of truth, not two.
    ///
    /// The cache file doubles as the override: drop your own `videos/<id>.jpg` in and
    /// it is served verbatim, no manifest edit needed.
    static func thumb(for entry: Entry) -> String? {
        if let own = entry.thumb, !own.isEmpty { return own }
        let cachePath = thumbCachePath(for: entry)
        if let cached = FileManager.default.contents(atPath: cachePath) {
            return cached.base64EncodedString()
        }
        guard let data = extractFrame(from: fileURL(for: entry), atSecond: entry.startSeconds) else { return nil }
        try? data.write(to: URL(fileURLWithPath: cachePath))
        return data.base64EncodedString()
    }

    static func thumbCachePath(for entry: Entry) -> String { "\(videosDir())/\(entry.id).jpg" }

    /// Render every missing thumbnail now, off the main thread. Called at startup so
    /// the tablet's first `GET /videos` is answered from cache: an exact seek into a
    /// 90 MB mp4 costs the best part of a second, and doing thirteen of them *inside*
    /// the request would simply time the tablet out.
    static func warmThumbnails() {
        DispatchQueue.global(qos: .utility).async {
            for entry in entries() { _ = thumb(for: entry) }
        }
    }

    /// One frame as JPEG data, scaled to `thumbWidth`.
    ///
    /// Seeks to the snippet's own start second, so the tile shows what the room will
    /// actually see rather than a lead-in frame — but never to 0, because a clip that
    /// fades in from black would otherwise cache a black tile. Tolerances are `.zero`
    /// on purpose: a tolerant seek is cheaper but snaps to the nearest keyframe, which
    /// on these clips can be a different scene entirely.
    private static func extractFrame(from url: URL, atSecond second: Int) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbWidth, height: 0)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let wanted = CMTime(seconds: Double(max(second, 1)), preferredTimescale: 600)
        // A start second past the end (or an mp4 that refuses an exact seek) must not
        // cost the tile its image — fall back to a tolerant grab at the very start.
        let image = (try? generator.copyCGImage(at: wanted, actualTime: nil)) ?? {
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            return try? generator.copyCGImage(at: .zero, actualTime: nil)
        }()
        guard let cgImage = image else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// JSON served to the tablet at `GET /videos` — only what a tile needs
    /// (id → thumbnail + play call, title → label, startSeconds is informational).
    /// Every entry carries its `thumb` inline, so the tablet paints page 2 with no
    /// network of its own beyond this one call.
    static func manifestJSON() -> String {
        struct TileEntry: Codable { let id: String; let title: String; let startSeconds: Int; let thumb: String? }
        struct Out: Codable { let videos: [TileEntry] }
        let tiles = entries().map { TileEntry(id: $0.id, title: $0.title, startSeconds: $0.startSeconds, thumb: thumb(for: $0)) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(Out(videos: tiles)), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"videos\":[]}"
    }
}
