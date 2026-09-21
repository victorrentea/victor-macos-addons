import AppKit
import CryptoKit
import Foundation

/// The clipboard history behind ⌘⇧V — Flycut's gesture, with images.
///
/// Flycut (which this replaces on this Mac) keeps text and silently drops
/// everything else, so a run of ⌃P screenshots — the thing most often copied
/// during a workshop — is exactly what its history cannot hold. The whole point
/// of this one is the image case, and the image case is also the only thing
/// that makes a clipboard history expensive, so the rule Victor set is the
/// rule the storage is built around:
///
/// **Pixels never live in memory.** An image that lands on the clipboard is
/// written straight to disk as two files — `<id>.png`, the bytes that get
/// pasted back, and `<id>-thumb.png`, a downscaled copy that is the only one
/// ever *displayed* — and the in-memory list keeps a `ClipboardEntry`: an id, a
/// pixel size, a byte count and a date. Decoding happens when the overlay shows
/// one clip, and the `NSImage` dies with the overlay.
///
/// **And the disk cleans itself.** The folder is under `~/Library/Caches`,
/// which is the one place emptying the Trash and every "free up space" tool
/// actually reclaim, and it is bounded from the inside by
/// `ClipboardHistoryPolicy` (40 entries / 3 days / 400 MB, newest always kept),
/// applied on every capture. Nothing here is an archive: the screenshots folder
/// (`ScreenshotManager`) is where a ⌃P is *kept*, and it has its own, longer
/// retention. This is a staging area for the last few things you copied.
///
/// The capture itself has no poller of its own: `ClipboardStackManager` already
/// polls `changeCount` every 300 ms behind the `PasteboardGate` and already
/// pays for the TIFF→PNG conversion of every copied image. It hands the result
/// here. One read of the pasteboard, two consumers.
final class ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    /// Where the pixels go. Caches, never Application Support — see the class
    /// note; this folder is meant to be reclaimable by anything, at any time,
    /// including macOS itself under disk pressure.
    let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ro.victorrentea.macos-addons/clipboard-history", isDirectory: true)
    }()
    private var indexFile: URL { folder.appendingPathComponent("index.json") }

    /// The longest side a thumbnail may have, in pixels. The overlay shows an
    /// image at a quarter of the screen's *area* — about 1700×1100 points on
    /// the retina, so ~1600 px of thumbnail is already at or past what the
    /// panel can show, and it decodes in a few milliseconds where a 6 MB
    /// screenshot does not.
    private let thumbnailMaxPixels: CGFloat = 1600

    private let lock = NSLock()
    private var entries: [ClipboardEntry] = []
    /// A `changeCount` this app produced itself — the clip the overlay just put
    /// back on the pasteboard. Without it, pasting from the history would
    /// re-capture the clip as a brand-new copy (and re-write its PNG) one tick
    /// of the poller later.
    private var ignoredChangeCount: Int = -1
    /// Bundle id of the app in front, cached from the main thread so the
    /// poller's queue can stamp a clip with it without touching AppKit
    /// off-thread — the same arrangement `EventTapManager` uses, and for the
    /// same reason. It is read up to 300 ms after the ⌘C (that is the poll
    /// interval), so a copy followed instantly by a ⌘⇥ is credited to the app
    /// switched *to*; the alternative is an event tap on ⌘C, which is a lot of
    /// machinery for a watermark.
    private var frontmostBundleID: String?

    // MARK: - Lifecycle

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setFrontmost(NSWorkspace.shared.frontmostApplication)
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                self?.setFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            self.loadIndex()
            self.pruneAndSave()
            // Whatever is on the clipboard right now is clip #1 — otherwise the
            // first ⌘⇧V after a restart opens on the *second* most recent thing
            // the Mac copied, which reads as a lost clip.
            self.captureCurrentPasteboard()
        }
    }

    /// Newest first. A snapshot: the overlay walks it while the poller keeps
    /// running behind it.
    var snapshot: [ClipboardEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    var isEmpty: Bool { snapshot.isEmpty }

    // MARK: - Capture (called from the ClipboardStackManager poller queue)

    /// True when this pasteboard change is one of ours and must not be captured.
    func shouldIgnore(changeCount: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return changeCount == ignoredChangeCount
    }

    func record(text: String) { record(text: text, source: currentFrontmost()) }

    /// `source` is spelled out rather than looked up here because the one
    /// caller that must *not* look it up is the launch capture below: the app
    /// in front when this app starts is not the app that clip came from.
    private func record(text: String, source: String?) {
        // A copy of nothing but whitespace is a slip of the hand — usually a
        // ⌘C with an empty selection — and it would push a real clip off the
        // end of the list.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = ClipboardEntry(id: UUID().uuidString,
                                   kind: .text(text),
                                   copiedAt: Date(),
                                   fingerprint: "t:" + Self.digest(Data(text.utf8)),
                                   sourceBundleID: source)
        add(entry)
    }

    private func setFrontmost(_ app: NSRunningApplication?) {
        lock.lock()
        frontmostBundleID = app?.bundleIdentifier
        lock.unlock()
    }

    private func currentFrontmost() -> String? {
        lock.lock(); defer { lock.unlock() }
        return frontmostBundleID
    }

    /// `png` comes from the poller, which has already converted the clipboard's
    /// TIFF once for the image stack — this re-uses that work rather than
    /// touching the pasteboard a second time.
    func record(png: Data) {
        let fingerprint = "i:" + Self.digest(png)
        // Same bytes as a clip we already hold: nothing to write, just move it
        // to the front with a fresh date (`insert` does both).
        if let existing = (snapshot.first { $0.fingerprint == fingerprint }) {
            var refreshed = existing
            refreshed.copiedAt = Date()
            add(refreshed)
            return
        }
        guard let rep = NSBitmapImageRep(data: png) else { return }
        let id = UUID().uuidString
        let fullURL = folder.appendingPathComponent(id + ".png")
        guard (try? png.write(to: fullURL)) != nil else { return }
        var bytes = png.count
        if let thumb = Self.thumbnail(from: rep, maxPixels: thumbnailMaxPixels),
           (try? thumb.write(to: thumbURL(for: id))) != nil {
            bytes += thumb.count
        }
        let entry = ClipboardEntry(id: id,
                                   kind: .image(pixelWidth: rep.pixelsWide,
                                                pixelHeight: rep.pixelsHigh,
                                                bytes: bytes),
                                   copiedAt: Date(),
                                   fingerprint: fingerprint)
        add(entry)
    }

    // MARK: - Files

    func fullURL(for entry: ClipboardEntry) -> URL {
        folder.appendingPathComponent(entry.id + ".png")
    }

    /// What the overlay draws. Falls back to the full image for an entry whose
    /// thumbnail failed to write — a big decode is better than a blank panel.
    func displayURL(for entry: ClipboardEntry) -> URL {
        let thumb = thumbURL(for: entry.id)
        return FileManager.default.fileExists(atPath: thumb.path) ? thumb : fullURL(for: entry)
    }

    private func thumbURL(for id: String) -> URL {
        folder.appendingPathComponent(id + "-thumb.png")
    }

    // MARK: - Paste

    /// Put a remembered clip back on the pasteboard. Returns false when an image
    /// entry's file has gone (a cache purge between the copy and the paste),
    /// which the caller reports rather than pasting the previous clipboard by
    /// accident.
    @discardableResult
    func place(_ entry: ClipboardEntry) -> Bool {
        var payload: Data?
        if entry.isImage {
            guard let data = try? Data(contentsOf: fullURL(for: entry)) else {
                remove(entry)
                return false
            }
            payload = data
        }
        PasteboardGate.sync { pb in
            pb.clearContents()
            switch entry.kind {
            case .text(let string):
                pb.setString(string, forType: .string)
            case .image:
                if let payload { pb.setData(payload, forType: .png) }
            }
            lock.lock()
            ignoredChangeCount = pb.changeCount
            lock.unlock()
        }
        // It is the current clipboard now, so it is also clip #1 — the next
        // ⌘⇧V must open on it, exactly as if it had just been copied by hand.
        var refreshed = entry
        refreshed.copiedAt = Date()
        add(refreshed)
        return true
    }

    /// Drop one clip and its files — the ⌫ key in the overlay, and the recovery
    /// path when an image's file has vanished under us.
    func remove(_ entry: ClipboardEntry) {
        lock.lock()
        entries.removeAll { $0.id == entry.id }
        lock.unlock()
        deleteFiles(of: [entry])
        saveIndex()
    }

    // MARK: - Internals

    private func add(_ entry: ClipboardEntry) {
        lock.lock()
        let result = ClipboardHistoryPolicy.insert(entry, into: entries)
        entries = result.list
        lock.unlock()
        deleteFiles(of: result.evicted)
        pruneAndSave()
    }

    private func pruneAndSave() {
        lock.lock()
        let doomed = ClipboardHistoryPolicy.expired(entries, now: Date())
        if !doomed.isEmpty {
            let ids = Set(doomed.map(\.id))
            entries.removeAll { ids.contains($0.id) }
        }
        lock.unlock()
        deleteFiles(of: doomed)
        // Files with no entry pointing at them — left behind by a crash between
        // the write and the index save. Nothing else would ever reclaim them.
        collectOrphanFiles()
        saveIndex()
    }

    private func deleteFiles(of entries: [ClipboardEntry]) {
        let fm = FileManager.default
        for entry in entries where entry.isImage {
            try? fm.removeItem(at: fullURL(for: entry))
            try? fm.removeItem(at: thumbURL(for: entry.id))
        }
    }

    private func collectOrphanFiles() {
        let known = Set(snapshot.map(\.id))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" {
            let stem = file.deletingPathExtension().lastPathComponent
            let id = stem.hasSuffix("-thumb") ? String(stem.dropLast("-thumb".count)) : stem
            if !known.contains(id) { try? fm.removeItem(at: file) }
        }
    }

    private func captureCurrentPasteboard() {
        enum Current { case none, text(String), image(Data) }
        let current: Current = PasteboardGate.sync { pb in
            if let s = pb.string(forType: .string) { return .text(s) }
            guard pb.canReadObject(forClasses: [NSImage.self], options: nil),
                  let image = NSImage(pasteboard: pb),
                  let tiff = image.tiffRepresentation else { return .none }
            return .image(tiff)
        }
        switch current {
        case .none: break
        case .text(let s): record(text: s, source: nil)
        case .image(let tiff):
            guard let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            record(png: png)
        }
    }

    // MARK: - Index

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFile),
              let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data) else { return }
        // An entry whose PNG did not survive (a cache purge, a manual clean) is
        // dropped on load rather than offered and found missing at paste time.
        let fm = FileManager.default
        let alive = decoded.filter { !$0.isImage || fm.fileExists(atPath: fullURL(for: $0).path) }
        lock.lock()
        entries = alive
        lock.unlock()
    }

    private func saveIndex() {
        let data = try? JSONEncoder().encode(snapshot)
        guard let data else { return }
        try? data.write(to: indexFile, options: .atomic)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Downscale to at most `maxPixels` on the long side, PNG out. Returns nil
    /// when the image is already small enough — the caller then has no thumbnail
    /// file and `displayURL` falls back to the original, which is the right
    /// answer for a 200×80 clip.
    private static func thumbnail(from rep: NSBitmapImageRep, maxPixels: CGFloat) -> Data? {
        let width = CGFloat(rep.pixelsWide), height = CGFloat(rep.pixelsHigh)
        let longSide = max(width, height)
        guard longSide > maxPixels, longSide > 0 else { return nil }
        let scale = maxPixels / longSide
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        scaled.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return scaled.representation(using: .png, properties: [:])
    }
}
