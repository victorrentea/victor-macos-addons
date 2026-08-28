import Foundation

/// Compresses the last 40 seconds of transcript into **five things worth
/// pasting**.
///
/// The first version cleaned that window up *verbatim* and offered it at growing
/// lengths. That was the wrong product: tidied speech is still speech, and
/// nobody wants a paragraph of their own hesitations on the clipboard. What is
/// actually being reached for is the **idea** — a point of view, a line worth
/// quoting, the bit that landed emotionally, or an instruction ready to hand to
/// an agent. So the model compresses rather than transcribes, and the five slots
/// are five *kinds* rather than five lengths.
///
/// ## Which model, and why through the CLI
///
/// `claude -p` on Victor's **subscription**, the same auth path
/// `summarize-on-break.sh` and `flux-agent.sh` use — because the two Anthropic
/// keys in `~/.training-assistants-secrets.env` both answer *"credit balance is
/// too low"* (re-verified 2026-08-14). That dead key is also why every launcher
/// here starts with `env -u ANTHROPIC_API_KEY`: exported, it shadows the
/// subscription and fails auth. Same reason applies here.
///
/// **Sonnet, not Haiku** — measured on the same window, on this Mac:
/// sonnet **13 s**, haiku **17 s**. Sonnet being both better *and* faster is
/// counterintuitive and worth writing down: the cost here is dominated by output
/// tokens, and the weaker model spends more of them saying the same thing.
/// (`gemma3:4b` on the local Ollama does it in 8 s but drifts into third-person
/// analysis — *"The speaker's proposed solution…"* — which is exactly wrong for
/// text you are about to paste as your own.) Override with
/// `TRANSCRIPT_DISTILL_MODEL`.
enum TranscriptDistiller {

    /// The five slots, in order: the four things Victor said he actually reaches
    /// for — a point of view, a funny line, an emotional anchor, a prompt for an
    /// agent — plus the idea itself as the workhorse.
    ///
    /// Two slots from a wider draft were dropped rather than shuffled.
    /// **"Everything, dense"** stopped being a distinct answer the moment options
    /// were capped at two lines: at 180 characters it converges on "the idea,
    /// 1–2 sentences", and the dedup filter below was catching them as one row.
    /// **"Title / hook"** was never asked for — it was a guess, and a guess does
    /// not earn a permanent slot on a panel scanned under time pressure.
    ///
    /// Captions are **fixed here, never asked of the model**: the shape is the
    /// same every run, so there is one less thing that can be hallucinated and
    /// the row labels cannot drift — which is what lets the hand learn "the agent
    /// prompt is the last one" and stop reading. They are in **English while the
    /// options are not**, deliberately: an option is *content* and has to stay in
    /// the speaker's own words, a caption is chrome and matches every other label
    /// this app draws.
    static let kinds = [
        "the point — one line",
        "the idea, 1–2 sentences",
        "the funny line",
        "the emotional anchor",
        "agent-ready prompt",
    ]

    /// Budget per option, in characters. The panel is scanned, not read — rows
    /// that each need a paragraph of attention are not a menu, they are homework.
    ///
    /// **Measured, not guessed, and set deliberately under the real ceiling.**
    /// Two lines at the picker's text width (730 pt, 14 pt system font) hold
    /// ~223 characters. The budget is 180 because the model treats a stated
    /// limit as a target and lands ~15 % over it — asking for 220 produced 250,
    /// which wraps to three lines. Asking for 180 lands around 205, which fits.
    static let maxCharsPerOption = 180

    static var model: String {
        ProcessInfo.processInfo.environment["TRANSCRIPT_DISTILL_MODEL"] ?? "sonnet"
    }

    /// Hardcoded rather than resolved with `command -v`: a GUI app launched by
    /// LaunchServices inherits almost no PATH, so the lookup the shell scripts
    /// can afford would fail here.
    private static var claudeBinary: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
    }

    private static let timeout: TimeInterval = 60

    private static let instructions = """
    You receive the last ~40 seconds of a live speech-to-text transcript — raw \
    Whisper output: filler words, false starts, missing punctuation, duplicated \
    fragments where audio chunks overlapped, and no speaker labels (the \
    microphones pick up the whole room, so do not invent attributions).

    DISTILL it. Do NOT return it verbatim and do NOT merely clean it up: compress \
    it to its idea. The reader is the speaker himself, about to paste one of these \
    somewhere — into a message, a slide, a post, or as a prompt to a coding agent.

    Return exactly 5 options, in this exact order:
    1. THE POINT OF VIEW — one line. The claim, the stance, the thing he is \
    actually arguing.
    2. THE IDEA — the same thing in one or two sentences, with just enough of the \
    reasoning to stand on its own.
    3. THE FUNNY LINE — the wittiest or most surprising thing said, kept close to \
    how he said it. If nothing is genuinely funny, give the sharpest or most \
    unexpected phrasing instead — never invent a joke that was not there.
    4. THE EMOTIONAL ANCHOR — the moment that actually landed: the frustration, \
    the stake, the human bit. What someone would still remember tomorrow.
    5. THE AGENT PROMPT — the actionable intent rewritten as a direct, imperative \
    instruction you could hand to a coding agent. If there is no actionable \
    intent, write the instruction the idea implies.

    The five must be five genuinely different answers. If two of them would come \
    out saying the same thing, push each further into its own job — sharper for \
    1, more concrete for 2, closer to his exact words for 3, more human for 4, \
    more directly actionable for 5.

    HARD LIMIT: every option must be at most \(maxCharsPerOption) characters. \
    Count the characters before you answer, and if one is over, cut content until \
    it fits; never cut a sentence in half and never let it run on. Options 1, 3 \
    and 4 should be far shorter than the limit.

    Write every option in the SAME LANGUAGE AS THE TRANSCRIPT — if the transcript \
    is in English, answer in English; if it is in Romanian, answer in Romanian. \
    Keep his voice and register; this is compression, not a corporate rewrite. \
    Write in first person, the way he speaks — never "the speaker says that…". \
    No preamble, no labels, no surrounding quotes, no emoji.

    If the window is very short or barely says anything, STILL return 5 options — \
    work with what little is there. Never answer with an explanation, an apology, \
    or a note that the input is insufficient: the reply is parsed by a program, \
    and prose reaches the user as an error.

    Return ONLY a JSON object: {"options": ["...", …5 strings in total…]}
    """

    /// Below this many words the window is not worth a model call.
    ///
    /// Found the hard way: pressed after a lull, the window came down to the
    /// single word "Da!", and sonnet answered — quite reasonably — with a
    /// sentence explaining there was nothing to distill, which the parser could
    /// only report as a failure. Twelve seconds and a Basso to be told what the
    /// word count already knew.
    static let minWordsWorthDistilling = 10

    enum DistillError: LocalizedError {
        case launchFailed(String)
        case timedOut
        case failed(Int32, String)
        case badReply(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let why): return "could not start claude: \(why)"
            case .timedOut: return "claude took longer than \(Int(timeout))s"
            case .failed(let code, let err): return "claude exited \(code): \(err.prefix(200))"
            case .badReply(let what): return "unexpected reply: \(what)"
            }
        }
    }

    /// Words of actual speech in a rendered window, ignoring the `[HH:MM]`
    /// stamps — which would otherwise count as one word per line and make a
    /// window of eight grunts look substantial.
    ///
    /// The speaker glyph gets the same treatment for the same reason. Since
    /// 2026-08-28 a labelled line reads `[HH:MM] 🎙️ text`, and counting the
    /// glyph would quietly re-introduce exactly the inflation the stamp
    /// stripping exists to prevent.
    static func speechWordCount(in transcript: String) -> Int {
        transcript.split(separator: "\n").reduce(0) { total, line in
            var text = line
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                text = line[line.index(after: close)...]
            }
            let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .filter { $0 != "🎙️" && $0 != "👥" }
            return total + words.count
        }
    }

    static func distill(_ transcript: String) async throws -> [String] {
        let prompt = instructions + "\n\nTRANSCRIPT:\n" + transcript
        let reply = try await runClaude(prompt: prompt)
        return try parseOptions(reply)
    }

    // MARK: - Subprocess

    private static func runClaude(prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudeBinary)
            process.arguments = [
                "-p", prompt,
                "--model", model,
                // Nothing here needs a connector, and loading them is pure
                // startup cost on a path a hand is waiting on.
                "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            ]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            process.environment = env

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            // Without this the CLI spends 3 s waiting to see whether something
            // is being piped in, on every single run.
            process.standardInput = FileHandle.nullDevice

            // `readDataToEndOfFile` after `waitUntilExit` deadlocks once the
            // output outgrows the pipe buffer, so drain while it runs.
            var stdoutData = Data(), stderrData = Data()
            let lock = NSLock()
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock(); stdoutData.append(chunk); lock.unlock()
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock(); stderrData.append(chunk); lock.unlock()
            }

            let resumed = ManagedAtomicFlag()
            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                guard resumed.claim() else { return }
                lock.lock()
                let stdout = String(decoding: stdoutData, as: UTF8.self)
                let stderr = String(decoding: stderrData, as: UTF8.self)
                lock.unlock()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: DistillError.failed(proc.terminationStatus, stderr))
                }
            }

            do {
                try process.run()
            } catch {
                guard resumed.claim() else { return }
                continuation.resume(throwing: DistillError.launchFailed(error.localizedDescription))
                return
            }

            // A wedged CLI must not leave the spinner on screen forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                guard resumed.claim() else { return }
                continuation.resume(throwing: DistillError.timedOut)
            }
        }
    }

    /// A `CheckedContinuation` must be resumed exactly once, and there are three
    /// racing paths here (exit, launch failure, timeout).
    private final class ManagedAtomicFlag {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    // MARK: - Parsing

    /// Pull the option list out of the reply.
    ///
    /// "Return ONLY JSON" gets JSON most of the time and a ```json fence the
    /// rest of it. Slicing from the first `{` to the last `}` covers both and
    /// costs nothing when the reply was already clean.
    static func parseOptions(_ reply: String) throws -> [String] {
        // The reply itself rides in the error. When the model answers with prose
        // instead of JSON it is *saying why* — "there is nothing here to
        // distill" — and a bare "no `options` array" throws that away and turns
        // a legible refusal into a mystery.
        let quoted = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)

        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw DistillError.badReply("no JSON, model said: \(quoted)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(String(reply[start...end]).utf8))
                as? [String: Any],
              let raw = obj["options"] as? [Any] else {
            throw DistillError.badReply("no `options` array, model said: \(quoted)")
        }
        let options = raw.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !options.isEmpty else { throw DistillError.badReply("`options` was empty") }
        // Two slots that compress to the same words are a choice with no
        // difference — and they push a genuinely different one off the panel.
        var seen = Set<String>()
        return options.filter { seen.insert($0).inserted }
    }

    /// The caption drawn under option `index`, or nil past the known slots.
    static func kind(at index: Int) -> String? {
        kinds.indices.contains(index) ? kinds[index] : nil
    }
}
