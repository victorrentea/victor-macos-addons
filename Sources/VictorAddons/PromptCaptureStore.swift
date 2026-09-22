import Foundation

/// The week of intercepted prompts behind the 🤖 **Prompts…** panel.
///
/// Until now an intercepted prompt existed for exactly 9.5 seconds: the
/// bottom-left pill offered it, and if the hover didn't come — mid-sentence, in
/// front of a room, which is when prompts are typed — the text was gone. The
/// prompts worth showing the participants are usually the ones typed while
/// talking, so the pill was missing precisely the ones that mattered.
///
/// This is the second chance: every prompt the pill offers is also written
/// here, and the panel can send it to the notes minutes or days later. The
/// *offer* is unchanged — this store only remembers what it offered.
///
/// **It records only while a training session is active.** That is the filter
/// Victor asked for: outside a session a prompt is ordinary work, not material
/// for the room, and a list that also holds every evening's debugging is a list
/// nobody scrolls. `AppDelegate` applies the session check before calling
/// `record` — the same guard that already decided whether the pill appears.
///
/// Storage is a single JSON file under `~/Library/Caches` (like
/// `ClipboardHistoryStore`): seven days of short strings, and nothing here is
/// an archive — the notes file is where a prompt is *kept* once it is sent.
final class PromptCaptureStore {
    static let shared = PromptCaptureStore()

    /// Posted on the main queue whenever the list changes, so an open panel
    /// redraws instead of showing a stale week.
    static let changed = Notification.Name("PromptCaptureStoreChanged")

    private let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ro.victorrentea.macos-addons/prompt-capture", isDirectory: true)
    }()
    private var indexFile: URL { folder.appendingPathComponent("index.json") }

    private let lock = NSLock()
    private var loaded = false
    private var entries: [CapturedPrompt] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Reads

    /// Every kept prompt, oldest first, already pruned to the retention window.
    func all() -> [CapturedPrompt] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries
    }

    /// Grouped for the panel: newest day first, newest prompt first.
    func sections(now: Date = Date()) -> [PromptCapturePolicy.DaySection] {
        PromptCapturePolicy.sections(from: all(), now: now)
    }

    // MARK: Writes

    /// Remember a prompt the hook just forwarded. Returns its id so the caller
    /// can mark it sent if the offer pill is hovered a moment later — the pill
    /// and the panel write the same flag, so a prompt already on the
    /// participants' screen never shows a live Send button.
    ///
    /// Returns nil when the text is empty or machine noise (`normalize`).
    @discardableResult
    func record(_ text: String, source: PromptSource) -> UUID? {
        guard let clean = PromptCapturePolicy.normalize(text) else { return nil }
        let entry = CapturedPrompt(text: clean, source: source)
        lock.lock()
        loadIfNeeded()
        entries.append(entry)
        entries = PromptCapturePolicy.prune(entries)
        save()
        lock.unlock()
        notifyChanged()
        return entry.id
    }

    /// Flag a prompt as having reached the session notes. Idempotent, and a
    /// no-op for an id that has since aged out of the window.
    func markSent(_ id: UUID) {
        lock.lock()
        loadIfNeeded()
        guard let idx = entries.firstIndex(where: { $0.id == id }), !entries[idx].sent else {
            lock.unlock()
            return
        }
        entries[idx].sent = true
        save()
        lock.unlock()
        notifyChanged()
    }

    /// Drop every kept prompt. The panel's one destructive control; the notes
    /// already written are untouched.
    func clear() {
        lock.lock()
        loadIfNeeded()
        entries = []
        save()
        lock.unlock()
        notifyChanged()
    }

    // MARK: Disk

    /// Caller holds the lock.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: indexFile) else { return }
        guard let decoded = try? decoder.decode([CapturedPrompt].self, from: data) else {
            overlayError("Prompt history index unreadable; starting empty")
            return
        }
        entries = PromptCapturePolicy.prune(decoded)
    }

    /// Caller holds the lock. A failure here is logged and swallowed: losing
    /// the week's prompt list must never be able to break a prompt submission.
    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: indexFile, options: .atomic)
        } catch {
            overlayError("Prompt history save failed: \(error)")
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: PromptCaptureStore.changed, object: nil)
        }
    }
}
