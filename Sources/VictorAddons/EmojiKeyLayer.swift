import Foundation

/// The ⌥ / ⌥⇧ emoji layer, owned by this app instead of by a `.keylayout`.
///
/// **Why this exists.** macOS caches keyboard layouts by *identity* — the
/// numeric layout ID plus the name — not by file content, so editing a
/// `.keylayout` in place changes nothing until you log out. The documented
/// escape is to publish the edit as a *different* layout, which is why the
/// Keyboard Layouts folder holds `Victor Emoji` → `Victor Emoji2` →
/// `Victor Emoji3` → `Victor-v27`: each new emoji cost a rename and a restart.
///
/// This layer sidesteps the layout system entirely. The app already owns a
/// `.cgSessionEventTap` (`EventTapManager`), so a ⌥ chord can be rewritten on
/// its way past: the incoming key event is **mutated in place** — the ⌥/⇧ flags
/// stripped and the payload replaced via `keyboardSetUnicodeString` — and
/// forwarded. Nothing synthetic is posted, so there is no event to loop back
/// into our own tap and no modifier state to un-latch afterwards (the trap
/// documented on `KeySimulator.chord`).
///
/// The map lives in `~/.victor-emoji-layer.json`, re-read whenever its mtime
/// moves. Editing that file is live on the **next keystroke** — no rebuild, no
/// re-login, no new layout name.
///
/// **What it does not cover** (the `.keylayout` still does, and still should
/// stay installed): secure-input contexts — password fields, Terminal's Secure
/// Keyboard Entry — where event taps are disabled by design, and the login
/// window, where this app isn't running yet.
enum EmojiKeyLayer {
    static let enabledKey = "EmojiKeyLayer.enabled"

    /// Default ON: the seed below is transcribed from the active `Victor-v27`
    /// layout, so with the layout still installed both paths produce the same
    /// character and enabling this changes nothing visible. The one exception is
    /// the probe on key 18 — see `optionSeed`.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var mapURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".victor-emoji-layer.json")
    }

    // MARK: - Lookup

    /// The string ⌥(⇧)+`keyCode` should type, or nil to leave the event alone.
    ///
    /// Called on the event-tap thread for every ⌥ keystroke, so it must stay
    /// cheap: the file is stat-ed at most once a second and only re-parsed when
    /// the mtime actually moved.
    static func output(keyCode: Int, shift: Bool) -> String? {
        guard isEnabled else { return nil }
        refreshIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return (shift ? optionShift : option)[keyCode]
    }

    // MARK: - File backing

    private static let lock = NSLock()
    private static var option: [Int: String] = optionSeed
    private static var optionShift: [Int: String] = optionShiftSeed
    private static var loadedModified: Date?
    private static var lastStatAt: TimeInterval = 0
    private static var lastLoadError: String?
    private static var seeded = false

    private static let statInterval: TimeInterval = 1.0

    private static func refreshIfNeeded() {
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock()
        guard now - lastStatAt >= statInterval else { lock.unlock(); return }
        lastStatAt = now
        let alreadySeeded = seeded
        let known = loadedModified
        lock.unlock()

        let url = mapURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attrs?[.modificationDate] as? Date else {
            // No file yet: write the built-in seed once so there is something to
            // edit. A user who deletes it deliberately gets it back, which is the
            // right answer — the in-memory map is the same thing either way.
            if !alreadySeeded { writeSeed(to: url) }
            return
        }
        guard modified != known else { return }
        load(from: url, modified: modified)
    }

    private static func load(from url: URL, modified: Date) {
        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONDecoder().decode([String: [String: String]].self, from: data)
            let opt = numericKeys(raw["option"] ?? [:])
            let optShift = numericKeys(raw["optionShift"] ?? [:])
            lock.lock()
            option = opt
            optionShift = optShift
            loadedModified = modified
            lastLoadError = nil
            seeded = true
            lock.unlock()
        } catch {
            // Keep serving the last good map: a half-saved file mid-edit must not
            // silently turn the whole layer off.
            lock.lock()
            loadedModified = modified
            lastLoadError = "\(error)"
            lock.unlock()
        }
    }

    private static func numericKeys(_ dict: [String: String]) -> [Int: String] {
        var out: [Int: String] = [:]
        for (key, value) in dict {
            guard let code = Int(key) else { continue }
            out[code] = value
        }
        return out
    }

    private static func writeSeed(to url: URL) {
        let payload: [String: [String: String]] = [
            "option": stringKeys(optionSeed),
            "optionShift": stringKeys(optionShiftSeed),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: url)
        lock.lock()
        seeded = true
        lock.unlock()
    }

    private static func stringKeys(_ dict: [Int: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (code, value) in dict { out[String(code)] = value }
        return out
    }

    // MARK: - Diagnostics

    /// Every ⌥ keyDown the tap actually receives, matched or not.
    ///
    /// This is the whole difference between the two ways this can fail: a key
    /// that never shows up here was taken upstream of us (another app's tap,
    /// inserted ahead of ours), while one that shows up as `matched` and still
    /// types the old character means the rewrite is being ignored downstream.
    /// Guessing between those two is a waste of a restart.
    private static var lastSeen: (keyCode: Int, shift: Bool, matched: Bool, at: Date)?
    private static var lastRewrite: (keyCode: Int, text: String, at: Date)?
    private static var rewrites = 0

    /// The last *rewritten* key is tracked separately from the last one merely
    /// seen: ⌥ chords fly past constantly (⌥⇧← to select a word, and so on), so
    /// "last seen" is almost always some unrelated navigation key by the time
    /// the status is read, and it cannot answer "did MY probe land?".
    static func noteObserved(keyCode: Int, shift: Bool, matched: Bool, text: String?) {
        lock.lock()
        lastSeen = (keyCode, shift, matched, Date())
        if let text {
            lastRewrite = (keyCode, text, Date())
            rewrites += 1
        }
        lock.unlock()
    }

    static func statusJSON() -> String {
        refreshIfNeeded()
        lock.lock()
        let counts = (option.count, optionShift.count)
        let modified = loadedModified
        let error = lastLoadError
        let seen = lastSeen
        let rewritten = lastRewrite
        let rewriteCount = rewrites
        lock.unlock()
        var fields: [String] = [
            "\"enabled\":\(isEnabled)",
            "\"path\":\"\(mapURL.path)\"",
            "\"option_bindings\":\(counts.0)",
            "\"option_shift_bindings\":\(counts.1)",
            "\"file_loaded\":\(modified != nil)",
            "\"rewrites\":\(rewriteCount)",
        ]
        if let seen {
            fields.append("\"last_opt_keydown\":{\"key_code\":\(seen.keyCode),\"shift\":\(seen.shift),\"matched\":\(seen.matched),\"seconds_ago\":\(Int(Date().timeIntervalSince(seen.at)))}")
        } else {
            fields.append("\"last_opt_keydown\":null")
        }
        if let rewritten {
            fields.append("\"last_rewrite\":{\"key_code\":\(rewritten.keyCode),\"typed\":\"\(rewritten.text)\",\"seconds_ago\":\(Int(Date().timeIntervalSince(rewritten.at)))}")
        } else {
            fields.append("\"last_rewrite\":null")
        }
        if let modified {
            fields.append("\"file_modified\":\(Int(modified.timeIntervalSince1970))")
        }
        if let error {
            let escaped = error.replacingOccurrences(of: "\"", with: "'")
            fields.append("\"last_error\":\"\(escaped)\"")
        }
        return "{\(fields.joined(separator: ","))}"
    }

    // MARK: - Seed
    //
    // Transcribed from the active `Victor-v27.keylayout` (⌥ = mapIndex 3,
    // ⌥⇧ = mapIndex 4), keeping only the entries that differ from stock ABC —
    // baseline characters like ⌥+A → å are macOS's job, not ours, and copying
    // them would mean re-implementing a layout rather than layering on one.
    // Dead keys (`action=` rather than `output=`) are deliberately dropped: they
    // are all stock ABC accents, and a dead key is a state machine this layer
    // has no way to express.

    static let optionSeed: [Int: String] = [
          0: "😡",
          3: "😱",
          4: "👱🏻‍♂️",
          5: "🤢",
          6: "🫩",
          7: "❌",
          8: "💥",
          9: "✅",
         10: "≈",
         11: "🧠",
         12: "🎅",
         13: "⚠️",
         15: "🤖",
         16: "🫵",
         // Key 18 = "1". Stock ABC types ¡ here and Victor-v27 leaves it alone,
         // so this is the probe: a 🧪 on ⌥+1 can ONLY have come from this tap,
         // which is what makes the experiment falsifiable while every other
         // binding agrees with the still-installed layout.
         18: "🧪",
         20: "💰",
         // ⌥+6 → "a" is faithfully transcribed from the layout, where it looks
         // like a slip of the mouse in Ukelele rather than an intended binding.
         22: "a",
         25: "🙁",
         29: "😊",
         30: "î",
         31: "👴🏻",
         32: "🦄",
         33: "ă",
         35: "🙏",
         37: "🔒",
         38: "🤣",
         39: "ț",
         40: "👍",
         41: "ș",
         42: "â",
         45: "👉",
         46: "🤪",
    ]

    static let optionShiftSeed: [Int: String] = [
          0: "🚨",
          1: "💩",
          2: "Δ",
          3: "🔥",
          4: "❤️",
          5: "🤮",
          8: "😢",
         11: "💣",
         13: "🚽",
         14: "🤤",
         15: "☢️",
         17: "⏱️",
         20: "🤑",
         25: "🔽",
         27: "⊖",
         29: "🔼",
         30: "Î",
         31: "👀",
         33: "Ă",
         34: "♾️",
         35: "🧑‍💻",
         37: "🤞",
         39: "Ț",
         40: "👑",
         41: "Ș",
         42: "Â",
         43: "∈",
         46: "💸",
         47: "⇒",
    ]
}
