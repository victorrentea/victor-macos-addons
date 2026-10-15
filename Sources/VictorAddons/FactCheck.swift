import AppKit
import Foundation

/// 🔬 **Fact-check** — "is what was just said true?", answered in seconds.
///
/// Takes the last ~30 s of the room's transcript and hands it to Walkie Talkie
/// as a ⚡ quick question (`POST /ask` on 127.0.0.1:8917–8919, token from
/// `~/.walkie-talkie/reply-token`), framed as a discussion that was overheard.
/// Walkie answers it exactly as it answers one Victor dictates: first words in
/// about a second, then a 🌐 searched and a 🧐 reviewed rewrite, in the pop-up
/// beside his pointer.
///
/// Until 2026-10-15 this was a 10-minute window run through an unattended
/// `claude` in a Terminal, with researcher subagents and an HTML report — minutes
/// per answer. Victor: *"this fact check I expected to return very fast answers
/// to me"*. The pipeline is gone; git has it.
///
/// **No waiting for whisper.** The file trails speech by about one whisper
/// batch (~8 s), so the window is really ~40 s ago → ~8 s ago. The distiller's
/// `TranscriptSettlePolicy` would buy that last sentence for an 8 s floor, and
/// speed is the point here.
enum FactCheck {
    /// Set by `AppDelegate`: where today's `…-transcription.txt` lives.
    static var transcriptionFolder: URL?
    static let windowSeconds: Double = 30
    static let ports = [8917, 8918, 8919]

    /// Menu click and `GET /test/research-proof`. Main thread or not: nothing
    /// here blocks the caller.
    static func launchNow(reason: String) {
        guard let folder = transcriptionFolder else {
            overlayError("🔬 fact-check: no transcription folder")
            return fail()
        }
        let parsed = TranscriptTail.parse(TranscriptTail.readTail(of: TranscriptTail.todayFile(in: folder)))
        let lines = TranscriptTail.lastSeconds(parsed, seconds: windowSeconds)
        let transcript = TranscriptTail.render(lines)
        guard !lines.isEmpty, TranscriptDistiller.speechWordCount(in: transcript) >= 5 else {
            overlayInfo("🔬 fact-check (\(reason)): nothing said in the last \(Int(windowSeconds)) s")
            return fail()
        }
        let speech = lines.map(\.text).joined(separator: " ")
        guard let token = try? String(contentsOfFile: NSHomeDirectory() + "/.walkie-talkie/reply-token", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            overlayError("🔬 fact-check: no ~/.walkie-talkie/reply-token — is Walkie Talkie running?")
            return fail()
        }
        let body: [String: Any] = ["token": token, "text": header(for: speech), "prompt": prompt(for: transcript)]
        overlayInfo("🔬 fact-check (\(reason)): \(lines.count) lines → Walkie Talkie")
        post(body, ports: ports)
    }

    /// The pop-up's header: what is being checked, so he can tell at a glance
    /// which part of the conversation the answer is about.
    static func header(for speech: String, limit: Int = 60) -> String {
        // The transcript marks each line with who spoke (🎙️ Victor, 👥 the room).
        let flat = speech.split(whereSeparator: \.isWhitespace)
            .filter { $0 != "🎙️" && $0 != "👥" }
            .joined(separator: " ")
        let cut = flat.count > limit ? "…" + String(flat.suffix(limit)).trimmingCharacters(in: .whitespaces) : flat
        return "🔬 «\(cut)»"
    }

    /// What Walkie's quick model is asked. Its system prompt says "be brief, no
    /// lists unless asked" — so this asks for the list, one line per claim,
    /// which keeps it brief per claim instead of one sentence for all of them.
    static func prompt(for transcript: String) -> String {
        """
        This discussion was just overheard in a live training room. It was \
        transcribed automatically, so some words may be misheard.

        \(transcript)

        Find the facts claimed in it, and anything left unknown or asked without \
        an answer. Check them and answer as you would answer a question: one short \
        line each — ✅ true, ❌ false or ❓ unsure — then the correct fact. Plain \
        text, in the language of the discussion.
        """
    }

    /// First port that answers 200 wins, like `walkie-reply`.
    private static func post(_ body: [String: Any], ports: [Int]) {
        guard let port = ports.first,
              let url = URL(string: "http://127.0.0.1:\(port)/ask"),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            overlayError("🔬 fact-check: Walkie Talkie did not answer on 8917–8919")
            return fail()
        }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                overlayInfo("🔬 fact-check: asked Walkie Talkie on \(port)")
            } else if code == 403 {
                overlayError("🔬 fact-check: Walkie Talkie refused the token on \(port)")
                fail()
            } else {
                post(body, ports: Array(ports.dropFirst()))
            }
        }.resume()
    }

    private static func fail() {
        DispatchQueue.main.async { NSSound(named: "Basso")?.play() }
    }
}
