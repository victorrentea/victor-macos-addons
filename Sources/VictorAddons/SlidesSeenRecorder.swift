import CryptoKit
import Foundation

/// One probe of PowerPoint, as `PowerPointMonitor` saw it.
struct PowerPointSample: Equatable {
    let at: Date
    let deck: String
    let path: String?
    let slide: Int
    /// PowerPoint's `slide ID` — the `<p:sldId id>` of the .pptx. Unlike `slide`
    /// (the position) it survives inserting, deleting and reordering slides.
    let slideID: Int?
    let presenting: Bool
    let frontmost: Bool
    let saved: Bool

    static func gone(at: Date) -> PowerPointSample {
        PowerPointSample(at: at, deck: "", path: nil, slide: 0, slideID: nil,
                         presenting: false, frontmost: false, saved: true)
    }
}

/// A slide that held the screen without interruption.
struct SlideSpan: Equatable {
    let deck: String
    let path: String?
    let slide: Int
    let slideID: Int
    let presenting: Bool
    let start: Date
    var end: Date
}

/// 📑 Decides what counts as a slide "shown": the same slide, PowerPoint in front,
/// for at least `minSeconds` in a row. Pure, so the thresholds are unit-tested.
struct SlidesSeenPolicy {
    enum Action: Equatable {
        /// Crossed the threshold: now is the moment to save the deck and copy it.
        case qualified(SlideSpan)
        /// The slide left the screen; only qualified spans are reported.
        case closed(SlideSpan)
    }

    var minSeconds: TimeInterval = 7
    private(set) var current: SlideSpan?
    private(set) var qualified = false

    mutating func consume(_ s: PowerPointSample) -> [Action] {
        var out: [Action] = []
        let sameSlide = current.map { s.frontmost && s.path == $0.path && s.slideID == $0.slideID } ?? false
        if sameSlide {
            current!.end = s.at
        } else {
            if let c = current, qualified { out.append(.closed(c)) }
            current = nil
            qualified = false
            if s.frontmost, let id = s.slideID, !s.deck.isEmpty {
                current = SlideSpan(deck: s.deck, path: s.path, slide: s.slide, slideID: id,
                                    presenting: s.presenting, start: s.at, end: s.at)
            }
        }
        if let c = current, !qualified, c.end.timeIntervalSince(c.start) >= minSeconds {
            qualified = true
            out.append(.qualified(c))
        }
        return out
    }
}

/// 📑 Slides seen: every slide shown ≥ 7 s goes into a day log, with a copy of the
/// deck as it was on disk when shown, so a summary can later export exactly that
/// slide (by `slide ID`, not position) as a PDF page with its links.
///
/// Everything lives in PowerPoint's own sandbox container: PowerPoint opens and
/// writes files there without its "Grant File Access" dialog, which it raises for
/// any other path it is asked to open or write by script (measured 2026-10-29).
final class SlidesSeenRecorder {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.microsoft.Powerpoint/Data/Documents/slides-seen")
    static let retentionDays = 30

    private var policy = SlidesSeenPolicy()
    private let queue = DispatchQueue(label: "ro.victorrentea.slides-seen", qos: .utility)
    /// path → (size, mtime, snapshot file name): skip re-hashing an unchanged deck.
    private var lastSnapshot: [String: (Int, Date, String)] = [:]
    /// The snapshot taken when the current span qualified, written with it on close.
    private var pendingSnapshot: String?

    init() {
        queue.async { Self.prune() }
    }

    func consume(_ sample: PowerPointSample) {
        queue.async { [self] in
            for action in policy.consume(sample) {
                switch action {
                case .qualified(let span):
                    pendingSnapshot = nil
                    if let path = span.path {
                        if !sample.saved { save(path) }
                        pendingSnapshot = snapshot(path)
                    }
                case .closed(let span):
                    append(span, snapshot: pendingSnapshot)
                    pendingSnapshot = nil
                }
            }
        }
    }

    /// Unsaved edits are not on disk, and the copy is taken from disk: save first.
    /// Victor asked for it (2026-10-29), knowing Google Drive sometimes refuses a save.
    private func save(_ path: String) {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Microsoft PowerPoint"
            repeat with k from 1 to (count of presentations)
                if (full name of presentation k) is "\(escaped)" then
                    save presentation k
                    return "saved"
                end if
            end repeat
        end tell
        return "not open"
        """
        let r = AppleScriptRunner.runDetailed(script, timeout: 30)
        overlayInfo("SlidesSeen: save \(URL(fileURLWithPath: path).lastPathComponent) → \(r.output ?? r.error ?? "?")")
    }

    /// Content-addressed copy: one file per distinct version of a deck.
    private func snapshot(_ path: String) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if let last = lastSnapshot[path], last.0 == size, last.1 == mtime { return last.2 }
        guard let sha = Self.sha256(path) else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.isEmpty ? "pptx" : URL(fileURLWithPath: path).pathExtension
        let name = "\(sha.prefix(16)).\(ext)"
        let decks = Self.root.appendingPathComponent("decks")
        let dest = decks.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: decks, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(atPath: path, toPath: dest.path) }
        } catch {
            overlayError("SlidesSeen: snapshot of \(path) failed: \(error.localizedDescription)")
            return nil
        }
        lastSnapshot[path] = (size, mtime, name)
        return name
    }

    private func append(_ span: SlideSpan, snapshot: String?) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        var entry: [String: Any] = [
            "start": iso.string(from: span.start), "end": iso.string(from: span.end),
            "seconds": Int(span.end.timeIntervalSince(span.start).rounded()),
            "deck": span.deck, "slide": span.slide, "slide_id": span.slideID,
            "presenting": span.presenting,
        ]
        if let p = span.path { entry["path"] = p }
        if let s = snapshot { entry["snapshot"] = s }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let logDir = Self.root.appendingPathComponent("log")
        let file = logDir.appendingPathComponent("\(day.string(from: span.start)).jsonl")
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: file)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data + Data("\n".utf8))
        } catch {
            overlayError("SlidesSeen: log write failed: \(error.localizedDescription)")
        }
    }

    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Logs and deck copies older than the retention window go; a training lasts days, not months.
    private static func prune() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        for sub in ["log", "decks", "work"] {
            let dir = root.appendingPathComponent(sub)
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let m, m < cutoff { try? fm.removeItem(at: f) }
            }
        }
    }
}
