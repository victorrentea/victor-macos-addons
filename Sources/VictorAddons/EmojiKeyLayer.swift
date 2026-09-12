import Foundation

/// The ⌥ / ⌥⇧ / ⌃⌥ emoji layers, owned by this app instead of by a `.keylayout`.
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
/// **⌃⌥ is a third layer, not a second shift of the first** (2026-09-10). A
/// `.keylayout` could never have carried it — macOS derives control characters
/// itself rather than asking the layout — so this board only exists because the
/// tap owns the rewrite. It has no ⇧ variant on purpose: ⌥ needed one because
/// ⌥⇧ was already a full layout's worth of characters inherited from
/// `Victor-v27`, while ⌃⌥ starts at one key, and a second empty sheet would be
/// a cheat-sheet that answers "nothing here" to every question.
///
/// The seed is the **complete** ⌥/⌥⇧ custom set of `Victor-v27` — emoji *and*
/// the Romanian diacritics `ă â î ș ț` — so the system layout can go back to
/// stock ABC and nothing is lost. Everything not in this map falls through to
/// ABC untouched, which is why the map holds only the differences: the baseline
/// is macOS's job, and copying it would mean re-implementing a layout instead
/// of layering on one.
///
/// **What it does not cover:** secure-input contexts — password fields,
/// Terminal's Secure Keyboard Entry — where event taps are disabled by design,
/// the login window, and the moments this app is restarting. In all of those ⌥
/// falls back to plain ABC.
///
/// **The control layer is deliberately NOT ported.** `Victor-v27` also carried
/// emoji on ⌃A/⌃C/⌃R and friends (verified live with `UCKeyTranslate`: ⌃C
/// really does translate to 😢). It never did any harm because terminals and
/// AppKit text views derive control characters themselves rather than asking
/// the layout, so the mapping sat inert. This tap has no such mercy — it
/// rewrites what it matches — so porting those would genuinely break ⌃C in
/// every terminal. They are dropped as the dead experiment they are.
enum EmojiKeyLayer {
    /// Which board a keystroke is on. Not `KeymapModifier`: that type also has
    /// `.commandControl`, which is a sheet of *shortcuts* and types nothing, and
    /// a layer that can be asked for an impossible case is a layer with a
    /// `fatalError` in it waiting to happen.
    enum Layer: String, CaseIterable {
        case option
        case optionShift
        case controlOption

        /// Which board a set of held modifiers types from, or nil for "none of
        /// them". ⌘ is never a typing modifier here — ⌘⌃ is the shortcut sheet
        /// and ⌘⌥ is the busiest chord on the Mac — so the caller excludes it.
        /// ⇧ splits ⌥ and is ignored on ⌃⌥, which has no shift variant.
        init?(option: Bool, shift: Bool, control: Bool) {
            guard option else { return nil }
            if control { self = .controlOption } else { self = shift ? .optionShift : .option }
        }
    }

    static let enabledKey = "EmojiKeyLayer.enabled"

    /// Default ON: with the map now the only source of these characters,
    /// starting disabled would mean an app restart silently costs Victor his
    /// diacritics.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var mapURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".victor-emoji-layer.json")
    }

    // MARK: - Lookup

    /// The string this layer's `keyCode` should type, or nil to leave the event
    /// alone.
    ///
    /// Called on the event-tap thread for every ⌥ keystroke, so it must stay
    /// cheap: the file is stat-ed at most once a second and only re-parsed when
    /// the mtime actually moved.
    static func output(keyCode: Int, layer: Layer) -> String? {
        guard isEnabled else { return nil }
        refreshIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return maps[layer]?[keyCode]
    }

    /// The whole layer, for its cheat-sheet to draw.
    ///
    /// `generation` bumps on every successful reload, so the overlay can tell
    /// whether its cached keyboard images are stale without re-reading the file
    /// or diffing dictionaries. Without it, editing the map would change what
    /// the keys *type* while the sheet kept advertising the old bindings — a
    /// cheat-sheet that lies is worse than none.
    static func snapshot(_ layer: Layer) -> (bindings: [Int: String], generation: Int) {
        refreshIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return (maps[layer] ?? [:], generation)
    }

    // MARK: - File backing

    private static let lock = NSLock()
    private static var generation = 0
    private static var maps: [Layer: [Int: String]] = seeds
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
            // A section the file simply predates falls back to the seed, and the
            // file is topped up on disk so the new board is there to be edited.
            // An *empty* section is left alone: that is someone who deleted every
            // binding on purpose, and handing the seed back would undo it.
            var loaded: [Layer: [Int: String]] = [:]
            var missing: [Layer] = []
            for layer in Layer.allCases {
                if let section = raw[layer.rawValue] {
                    loaded[layer] = numericKeys(section)
                } else {
                    loaded[layer] = seeds[layer] ?? [:]
                    missing.append(layer)
                }
            }
            lock.lock()
            maps = loaded
            loadedModified = modified
            lastLoadError = nil
            seeded = true
            generation += 1
            lock.unlock()
            if !missing.isEmpty { backfill(missing, into: raw, at: url) }
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
        var payload: [String: [String: String]] = [:]
        for (layer, map) in seeds { payload[layer.rawValue] = stringKeys(map) }
        guard write(payload, to: url) else { return }
        lock.lock()
        seeded = true
        lock.unlock()
    }

    /// Add the sections a map file written before those layers existed has never
    /// heard of, keeping every section it does have byte-for-byte.
    ///
    /// Rewriting the whole file from the seeds instead would be a silent revert
    /// of every emoji Victor has changed since — the seed is a starting point,
    /// not the truth. The write moves the mtime, so the next stat re-reads and
    /// finds the section present; that pass is a no-op and the loop ends there.
    private static func backfill(_ layers: [Layer], into raw: [String: [String: String]], at url: URL) {
        var payload = raw
        for layer in layers { payload[layer.rawValue] = stringKeys(seeds[layer] ?? [:]) }
        _ = write(payload, to: url)
    }

    @discardableResult
    private static func write(_ payload: [String: [String: String]], to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return false }
        return (try? data.write(to: url)) != nil
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
    private static var lastSeen: (keyCode: Int, layer: Layer, matched: Bool, at: Date)?
    private static var lastRewrite: (keyCode: Int, text: String, at: Date)?
    private static var rewrites = 0

    /// The last *rewritten* key is tracked separately from the last one merely
    /// seen: ⌥ chords fly past constantly (⌥⇧← to select a word, and so on), so
    /// "last seen" is almost always some unrelated navigation key by the time
    /// the status is read, and it cannot answer "did MY probe land?".
    static func noteObserved(keyCode: Int, layer: Layer, matched: Bool, text: String?) {
        lock.lock()
        lastSeen = (keyCode, layer, matched, Date())
        if let text {
            lastRewrite = (keyCode, text, Date())
            rewrites += 1
        }
        lock.unlock()
    }

    static func statusJSON() -> String {
        refreshIfNeeded()
        lock.lock()
        let counts = maps
        let modified = loadedModified
        let error = lastLoadError
        let seen = lastSeen
        let rewritten = lastRewrite
        let rewriteCount = rewrites
        lock.unlock()
        var fields: [String] = [
            "\"enabled\":\(isEnabled)",
            "\"path\":\"\(mapURL.path)\"",
            "\"option_bindings\":\(counts[.option]?.count ?? 0)",
            "\"option_shift_bindings\":\(counts[.optionShift]?.count ?? 0)",
            "\"control_option_bindings\":\(counts[.controlOption]?.count ?? 0)",
            "\"file_loaded\":\(modified != nil)",
            "\"rewrites\":\(rewriteCount)",
        ]
        if let seen {
            fields.append("\"last_opt_keydown\":{\"key_code\":\(seen.keyCode),\"layer\":\"\(seen.layer.rawValue)\",\"matched\":\(seen.matched),\"seconds_ago\":\(Int(Date().timeIntervalSince(seen.at)))}")
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

    static let seeds: [Layer: [Int: String]] = [
        .option: optionSeed,
        .optionShift: optionShiftSeed,
        .controlOption: controlOptionSeed,
    ]

    /// The ⌃⌥ board, opened on 2026-09-10 with one key.
    ///
    /// G for goose — and deliberately not ⌥8's 🪿, which stays where it is: the
    /// point of the new board is that a letter can mean the thing it starts,
    /// where the ⌥ layer ran out of letters years ago and has been handing out
    /// digits ever since.
    ///
    /// B for bug and P for parachute (2026-09-10) follow that rule, and 🪂
    /// **moved** here off ⌥⇧8 rather than being duplicated: the goose stayed on
    /// its digit because ⌥8 is muscle memory years old, while ⌥⇧8 was a digit
    /// nobody had learned — there was nothing to keep working. A letter that
    /// means the word beats a digit you have to look up, and two keys for one
    /// emoji is one of them typed by accident.
    ///
    /// C for crying laughter (2026-09-12). The letter was free because ⌃⌥C had
    /// just been vacated — the selection-or-clipboard note grab moved to ⌘⌃S to
    /// be discoverable on the shortcut sheet — so the board could take it
    /// without shadowing anything.
    static let controlOptionSeed: [Int: String] = [
          5: "🪿",   // G — goose
          8: "😂",   // C — crying laughter
         11: "🐛",   // B — bug
         35: "🪂",   // P — parachute, off ⌥⇧8
    ]

    static let optionSeed: [Int: String] = [
          0: "😡",
          1: "⭐",
          2: "☠️",
          3: "😱",
          4: "👱🏻‍♂️",
          5: "🤢",
          7: "❌",
          8: "💥",
          9: "✅",
         10: "≈",
         11: "🧠",
         12: "🎅",
         13: "⚠️",
         14: "😈",
         15: "🤖",
         16: "🫵",
         17: "🤔",
         20: "🥷",
         21: "💰",
         22: "🤯",
         23: "😵‍💫",
         25: "🙁",
         26: "🎲",
         28: "🪿",
         29: "😊",
         30: "î",
         31: "👴🏻",
         32: "🦄",
         33: "ă",
         34: "🤷‍♂️",
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
          6: "🙈",
          8: "😢",
          9: "🐄",
         11: "💣",
         12: "⚙️",
         13: "🚽",
         14: "🤤",
         15: "☢️",
         16: "✏️",
         17: "⏱️",
         20: "🧑‍💼",
         21: "🤑",
         22: "😵",
         23: "🥴",
         24: "≈",
         25: "🔽",
         26: "🗑️",
         27: "⊖",
         29: "🔼",
         30: "Î",
         31: "👀",
         32: "↗",
         33: "Ă",
         34: "♾️",
         35: "🧑‍💻",
         37: "🤞",
         39: "Ț",
         40: "👑",
         41: "Ș",
         42: "Â",
         43: "∈",
         45: "🥷",
         46: "💸",
         47: "⇒",
    ]
}
