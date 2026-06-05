import CryptoKit
import Foundation

/// SHA-256 manifest of the shared tablet sounds (Resources/sounds/*.mp3 — a
/// build-time copy of the Android app's assets folder). The tablet computes
/// the same manifest over its own assets and compares the combined hash from
/// each /ping response: a mismatch means the Mac bundle is stale (rebuild
/// with build-app.sh) and the tablet falls back to local playback for the
/// files that differ.
///
/// Canonical form (must match the Android side exactly):
///   - all *.mp3 files in the folder, sorted by filename
///   - one line per file: "<filename>:<sha256-hex-lowercase>\n"
///   - combined hash = SHA-256 hex of the concatenated lines
enum SoundsManifest {
    /// filename → SHA-256 hex, computed once on first access (~15MB, <100ms).
    static let files: [String: String] = computeFiles()

    /// The single value the tablet compares on every /ping.
    static let combinedHash: String = {
        let joined = files.keys.sorted().map { "\($0):\(files[$0]!)\n" }.joined()
        return SHA256.hash(data: Data(joined.utf8)).hexString
    }()

    /// JSON for GET /sounds/manifest — fetched by the tablet only on a
    /// combined-hash mismatch, to compute the per-file fallback set.
    static var manifestJSON: String {
        let entries = files.keys.sorted()
            .map { "\"\($0)\":\"\(files[$0]!)\"" }
            .joined(separator: ",")
        return "{\"hash\":\"\(combinedHash)\",\"files\":{\(entries)}}"
    }

    private static func computeFiles() -> [String: String] {
        // bundleURL, not resourceURL — see SoundManager.soundURL(for:).
        let dir = Bundle.module.bundleURL.appendingPathComponent("Resources/sounds")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            overlayError("SoundsManifest: Resources/sounds not found in bundle")
            return [:]
        }
        var result: [String: String] = [:]
        for url in urls where url.pathExtension.lowercased() == "mp3" {
            guard let data = try? Data(contentsOf: url) else { continue }
            result[url.lastPathComponent] = SHA256.hash(data: data).hexString
        }
        return result
    }
}

private extension SHA256Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
