import AVFoundation
import Foundation

/// **The microphone, on a wire to ElevenLabs Scribe v2 Realtime, and only while
/// the subtitles are on** (2026-09-19).
///
/// This is the one thing in this app that sends the room's voices off this Mac,
/// and everything about its shape follows from that. The continuous 💬
/// transcription is **not** this: it stays on `mlx-whisper`, local, on AC, two
/// channels, exactly as it was — Victor, asked directly: *"Transcrierea continua
/// de pe ac a mea+sala trebuie sa ramana pe mlx, locala. Doar cand activez
/// subtitrarile … doar atunci pleaca vocile streaming la eleven labs."*
///
/// So: no auto-start, no power rule, no heartbeat that brings it back. It opens
/// when the menu row is clicked and it closes when the row is clicked again, the
/// socket dies, or the app quits. Off is the resting state.
///
/// ## Why a socket and not the file upload
///
/// The batch endpoint is what Walkie Talkie uses and it is both cheaper ($0.22/h
/// against $0.39/h) and *better* — measured on one clip, batch `scribe_v2` heard
/// `label of the tooltip` where realtime committed `label on the tooltip`, which
/// is a smaller model. None of that helps here: a subtitle that arrives after
/// the sentence is over is not a subtitle. The realtime socket answers with
/// `partial_transcript` while he is still talking, which is the entire product.
///
/// **Measured end to end on 2026-09-19**, feeding a 20 s clip at real time:
/// words appear **0.8–1.3 s** after they were spoken, not the 150 ms on the
/// pricing page — that number is the model's, and the rest is the network, their
/// VAD and the chunk size below. It is also why the band (`LiveCaptionBand`) draws the
/// partial dimmer than the committed text: the partials **rewrite themselves**
/// (`label on the tool` → `label of the tooltip` → `label on the tooltip`,
/// observed in that same run), so the tail of a live caption is a guess and must
/// not look like a fact.
final class LiveCaptionsStream: NSObject {

    /// `scribe_v2_realtime`, the only model on this endpoint today.
    private static let model = "scribe_v2_realtime"

    /// **~$0.69 an hour since the Walkie Talkie port** (2026-10-14; $0.39
    /// before). The realtime socket is $0.39/h, +20 % for the `keyterms`
    /// ($0.47), and every second of audio is uploaded once more to the batch
    /// model for the correction behind the live words (`scribe_v2`, $0.22/h).
    /// It is here because the menu row spends it back at Victor while the
    /// feature is on — a cost you cannot see is a cost you forget to stop
    /// paying, which is the same rule the 🔴 raw capture keeps its hours under.
    /// If the row and the invoice disagree, the invoice is right.
    static let dollarsPerHour = 0.39 * 1.2 + 0.22

    /// **Walkie Talkie's live-caption settings, ported 2026-10-14** (its
    /// `ElevenLabsLive`, where each was probed on a corpus WAV before it was
    /// written):
    ///
    /// - **`vad_silence_threshold_secs` 1.5** — committed text is frozen, the
    ///   model only revises the open segment, so a longer pause before the
    ///   freeze is more context per revision.
    /// - **Pinned to two languages** — a caption came back Turkish once
    ///   unpinned. `language_code` is the first, the rest go as
    ///   `secondary_languages`. **English first here** (Walkie: Romanian
    ///   first), because a workshop room is English more often than a
    ///   dictation is; `LIVE_CAPTIONS_LANGS=ro,en` in
    ///   `~/.training-assistants-secrets.env` flips it for a Romanian course.
    /// - **Up to 50 `keyterms`**, the first column of
    ///   `~/.walkie-talkie/vocab.txt` — the English technical words that
    ///   actually occur in his speech, ranked by Walkie's corpus. Re-read at
    ///   every start, so the file is live.
    static let vadSilence = 1.5

    static var languages: [String] {
        let raw = ProcessInfo.processInfo.environment["LIVE_CAPTIONS_LANGS"]
            ?? SecretsLoader.load()["LIVE_CAPTIONS_LANGS"] ?? "en,ro"
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func keyterms() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".walkie-talkie/vocab.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { String($0.split(separator: ":", maxSplits: 1)[0]).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(50).map { $0 }
    }

    /// **The batch model corrects the live words behind him** — Walkie's
    /// technique (2026-09-26 there). At every segment the server commits, the
    /// audio since the previous cut is uploaded to the batch endpoint and its
    /// text replaces the live segments of that span; the band shows the swap
    /// softly (`gentle`). A failure leaves the cut where it was, and the next
    /// commit after a 5 s hold covers the longer span.
    static let minSpan: TimeInterval = 1.0
    /// **Captions run for hours here, a dictation for seconds in Walkie** — so
    /// the uncorrected audio is capped: past this much (a batch endpoint that
    /// keeps failing) the span is given up on and the live words stand.
    static let maxSpan: TimeInterval = 60
    /// And the text the band is handed is capped too: the band aligns the
    /// whole text at every update, and two lines of it are ~30 words. Old
    /// segments, long rolled out, are dropped from the head past this.
    static let keepWords = 150

    /// Walkie's batch model, from its own config — the two apps bill the same
    /// key, so they should agree on the model too.
    static var batchModel: String {
        ProcessInfo.processInfo.environment["WT_ELEVEN_MODEL"]
            ?? walkieConfig()["WT_ELEVEN_MODEL"] ?? "scribe_v2"
    }

    /// **250 ms.** Small enough that the first words of a sentence are on the
    /// wire while he is still saying it, large enough that a workshop's Wi-Fi is
    /// not being asked for four round trips a second. It is also a floor under
    /// the latency measured above — a chunk cannot arrive before it is full.
    private static let chunkSeconds = 0.25

    /// 16 kHz mono int16: what Scribe wants, and half the bytes of anything
    /// else that would also work.
    private static let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                  sampleRate: 16000, channels: 1,
                                                  interleaved: true)!

    // MARK: - What the caller hears back

    /// What was heard so far, on main: the committed segments (corrected by
    /// the batch model where it has caught up), the one still being spoken,
    /// whether this update is a batch correction (`gentle`), and the indices
    /// of the committed words where a new voice begins — the band's own
    /// `setText` signature, which is the point.
    var onText: ((_ committed: String, _ partial: String, _ gentle: Bool, _ speakers: [Int]) -> Void)?
    /// **The socket is gone and the captions are over.** Always followed by the
    /// controller taking the overlay down: a caption frozen mid-sentence in
    /// front of a room is worse than no caption, because it looks like it is
    /// still working.
    var onClosed: ((String?) -> Void)?

    // MARK: - The key

    /// **This app's secrets first, Walkie Talkie's file second.**
    ///
    /// The second one is not a hack, it is the fact: the key is already on this
    /// Mac at `~/.walkie-talkie/elevenlabs.env`, put there for the relay's own
    /// Scribe calls, and asking Victor to paste the same string into a second
    /// file is how two copies of one secret come to disagree. `ELEVENLABS_API_KEY`
    /// in `~/.training-assistants-secrets.env` overrides it when he wants the
    /// two apps billed to different keys.
    static func apiKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !key.isEmpty {
            return key
        }
        if let key = SecretsLoader.load()["ELEVENLABS_API_KEY"], !key.isEmpty { return key }
        return walkieConfig()["ELEVENLABS_API_KEY"]
    }

    /// `~/.walkie-talkie/elevenlabs.env` as `KEY=value` rows.
    static func walkieConfig() -> [String: String] {
        let relay = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".walkie-talkie/elevenlabs.env")
        guard let text = try? String(contentsOf: relay, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let row = line.trimmingCharacters(in: .whitespaces)
            guard !row.hasPrefix("#"), let eq = row.firstIndex(of: "=") else { continue }
            var value = String(row[row.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { out[String(row[..<eq])] = value }
        }
        return out
    }

    // MARK: - State

    private var socket: URLSessionWebSocketTask?

    /// **Held, and that is not a formality.** `URLSession` owns its tasks, not
    /// the other way round: created as a local in `start()`, the session was
    /// released the moment that function returned and took the WebSocket down
    /// with it before the handshake completed — no error, no connection, and a
    /// band that sat on `…` for ever while the row happily said it was on.
    /// Found 2026-09-19 by looking for the socket in `lsof` and not finding it.
    private var session: URLSession?
    /// **A fresh engine per session, never a reused one.** An `AVAudioEngine`
    /// that has had its tap removed and reinstalled across several start/stop
    /// cycles is the other half of the hang above: building a new one costs
    /// nothing at the rate this is switched on, and it starts from a state
    /// nobody has to reason about.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    /// Samples converted but not yet a full chunk. Audio thread only.
    private var pending = Data()
    private let lock = NSLock()
    private var running = false
    /// Said once. A socket that fails keeps failing, and a banner per failure is
    /// a banner nobody reads.
    private var closeReported = false

    /// **The last thing the socket said**, kept for `GET
    /// /test/live-captions/state`. `overlayInfo` goes to an in-app window no
    /// script can read, and "is the socket actually up" is the first question
    /// anybody debugging this asks.
    private(set) var lastMessage: String?
    /// How many transcripts of each kind have arrived — the cheapest proof that
    /// audio is not only leaving but being heard.
    private(set) var partials = 0
    private(set) var commits = 0

    /// Which microphone the room is hearing itself through — the **system
    /// default input**, named so the row can say it.
    ///
    /// Deliberately not the 💬 transcription's own priority ladder (Wireless Mic
    /// → Room Speakerphone → XLR → Bose → MacBook, as it stood then):
    /// that lives inside
    /// `whisper_runner.py`, and reaching into another process's choice to guess
    /// at a device is how the two come to disagree silently. The default input
    /// is a thing Victor can see and change in one place, and the row names it
    /// so a caption coming out of the wrong microphone is visible rather than
    /// mysterious.
    private(set) var deviceName: String = "default input"

    // MARK: - The text and the correction (on `textQueue`)

    private let textQueue = DispatchQueue(label: "ro.victorrentea.addons.live-captions.text")
    /// Segments the server committed, in order; a correction collapses the
    /// span it covered into one. `trimmed` counts segments dropped off the
    /// head, so a correction in flight can find its span again.
    private var segments: [String] = []
    /// Per segment, the indices of its words where a new voice begins — only
    /// a corrected segment has any (the live socket does not diarize).
    private var voices: [[Int]] = []
    private var trimmed = 0
    private var partial = ""
    private var correctedSegments = 0
    /// Audio from the last cut on (the head before it is dropped): 16 kHz mono
    /// int16, 32 000 bytes a second.
    private var pcm = Data()
    private var correcting = false
    private var correctionHoldUntil = Date.distantPast
    private var key = ""
    private(set) var corrections = 0
    private(set) var correctionFailures = 0
    /// New voices the diarization found inside corrected spans.
    private(set) var speakerChanges = 0
    private(set) var keytermCount = 0

    // MARK: - Start / stop

    /// Opens the socket and the microphone, in that order — a chunk produced
    /// before there is anywhere to send it is a chunk dropped, and the first
    /// words of the first sentence are the ones somebody is watching for.
    ///
    /// - Returns: why it could not start, or nil.
    func start(_ done: @escaping (String?) -> Void) {
        guard !running else { return done(nil) }
        guard let key = Self.apiKey() else {
            return done("no ElevenLabs API key — ELEVENLABS_API_KEY in ~/.training-assistants-secrets.env")
        }
        // **Pinned to two languages since 2026-10-14** (it was not pinned at
        // all before): Walkie Talkie found that the unpinned socket sometimes
        // answers in the wrong language entirely — see `languages`.
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var query = [URLQueryItem(name: "model_id", value: Self.model),
                     URLQueryItem(name: "audio_format", value: "pcm_16000"),
                     URLQueryItem(name: "commit_strategy", value: "vad"),
                     URLQueryItem(name: "vad_silence_threshold_secs", value: String(Self.vadSilence))]
        let terms = Self.keyterms()
        for term in terms { query.append(URLQueryItem(name: "keyterms", value: term)) }
        let langs = Self.languages
        if let first = langs.first {
            query.append(URLQueryItem(name: "language_code", value: first))
            for extra in langs.dropFirst() { query.append(URLQueryItem(name: "secondary_languages", value: extra)) }
        }
        components.queryItems = query
        textQueue.sync {
            self.key = key
            self.keytermCount = terms.count
            self.segments = []; self.voices = []; self.trimmed = 0; self.partial = ""
            self.correctedSegments = 0; self.pcm = Data(); self.correcting = false
            self.correctionHoldUntil = .distantPast
        }
        overlayInfo("LiveCaptions: languages \(langs.joined(separator: "+")), \(terms.count) keyterms, commit after \(Self.vadSilence) s, corrected by \(Self.batchModel)")
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        socket = task
        closeReported = false
        task.resume()
        receive()

        // **The microphone on the main thread, and nowhere else** (2026-09-19,
        // read off a `sample` of the hung app).
        //
        // The obvious reflex — CoreAudio can block, so push it to a background
        // queue — is wrong here and was tried: `AVAudioEngine.inputNode` does a
        // **`dispatch_sync` of its own** inside `UpdateInputNode`, and asked for
        // it from anywhere but main it simply never returns. The symptom is the
        // worst kind: the switch reports success, the socket is up, the row says
        // it is on, and not one byte of audio ever leaves — `chunksSent` stays
        // at 0 for ever.
        //
        // What actually has to be true is weaker than "off the main thread", and
        // it is what the rest of this file now does: a **fresh engine per
        // session** rather than one reused across start/stop cycles, and a
        // `shutdown` that does not ask a dying process to close an audio device
        // politely.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return done("gone") }
            if let why = self.startMicrophone() {
                self.stop()
                done(why)
                return
            }
            self.running = true
            overlayInfo("LiveCaptions: streaming \(self.deviceName) to \(Self.model)")
            done(nil)
        }
    }

    /// Safe from any thread and safe to call twice. The socket goes down
    /// **immediately** — it is the half that bills and the half that is sending
    /// his voice somewhere — and the audio teardown is queued onto main behind
    /// it.
    func stop() {
        // **A close we asked for is not a failure.** Cancelling the task makes
        // `receive` fail with *Socket is not connected*, which would otherwise
        // travel up as `onClosed` and put a Basso and a red band on screen for
        // the ordinary act of turning the feature off.
        closeReported = true
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        // Invalidated rather than merely dropped: a session left to be collected
        // takes its task down before the handshake, which is the bug that made
        // this connect to nothing at all for three builds.
        session?.invalidateAndCancel()
        session = nil
        textQueue.async { self.pcm = Data() }
        let teardown = { [weak self] in
            guard let self = self else { return }
            self.engine?.inputNode.removeTap(onBus: 0)
            self.engine?.stop()
            self.engine = nil
            self.converter = nil
            self.lock.lock(); self.pending = Data(); self.lock.unlock()
        }
        Thread.isMainThread ? teardown() : DispatchQueue.main.async(execute: teardown)
    }

    /// **The app is quitting: drop the wire and leave the hardware alone.**
    ///
    /// `applicationWillTerminate` runs on main with the run loop already on its
    /// way out, and asking CoreAudio to close a device there is how a `pkill`
    /// turns into a process that will not die — observed 2026-09-19, and the
    /// only way back was `kill -9`. The socket is the half that matters (it
    /// bills, and it is his voice on a wire); the microphone is released by the
    /// process ending, which is a thing the kernel does and cannot block on.
    func abandon() {
        closeReported = true
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    var isRunning: Bool { running }

    // MARK: - The microphone

    /// - Precondition: on the main thread. → `start(_:)`
    private func startMicrophone() -> String? {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // **Never the WH-1000XM3** (2026-09-23, Victor: *"niciodata nu voi folosi
        // mic de pe WH casti bt"*). This stream follows the system default,
        // and macOS hands the default to the headphones the moment they
        // connect — so when it is a `MicRoster.neverRecord` device, the input
        // unit is pointed at the best ladder mic instead, before the format is
        // read. With no other microphone at all, the captions do not start.
        var steered: String?
        if let name = Self.defaultInputName(), MicRoster.isNeverRecord(name) {
            guard let target = Self.bestLadderInput() else {
                return "the only microphone is \(name), which is never recorded through"
            }
            var id = target.id
            guard let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                return "cannot move off \(name) to \(target.name)"
            }
            steered = target.name
            overlayInfo("LiveCaptions: default input is \(name) — recording through \(target.name) instead")
        }
        // **`inputFormat`, never `outputFormat`** — the lesson Walkie Talkie
        // paid for on this same Mac: `outputFormat(forBus:)` is the node's
        // cached idea and does not refresh when the device under it changes,
        // and handing `installTap` a format the hardware disagrees with throws
        // an **NSException**, which Swift cannot catch. The app does not fail to
        // record; it aborts.
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0 else {
            return "no input device"
        }
        deviceName = steered ?? Self.defaultInputName() ?? "default input"
        guard let conv = AVAudioConverter(from: inFormat, to: Self.wireFormat) else {
            return "cannot convert \(Int(inFormat.sampleRate))Hz to 16kHz mono"
        }
        converter = conv

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return "microphone unavailable: \(error.localizedDescription)"
        }
        return nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let conv = converter else { return }
        let ratio = Self.wireFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.wireFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            // One buffer per call — handing the same one back twice loops the
            // last 100 ms of audio onto the wire forever.
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0,
              let channel = out.int16ChannelData else { return }

        let bytes = Int(out.frameLength) * MemoryLayout<Int16>.size
        let chunk = channel[0].withMemoryRebound(to: UInt8.self, capacity: bytes) {
            Data(bytes: $0, count: bytes)
        }
        let full = Int(Self.chunkSeconds * Self.wireFormat.sampleRate) * MemoryLayout<Int16>.size

        lock.lock()
        pending.append(chunk)
        var ready: [Data] = []
        while pending.count >= full {
            ready.append(pending.prefix(full))
            pending.removeFirst(full)
        }
        lock.unlock()
        for data in ready { send(data) }
        textQueue.async { self.pcm.append(chunk) }
    }

    // MARK: - The wire

    /// How many chunks have gone up the wire. If this is 0 the microphone is
    /// not producing, which is a different fault from the socket being down.
    private(set) var chunksSent = 0

    private func send(_ pcm: Data) {
        guard let socket = socket else { return }
        chunksSent += 1
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "sample_rate": Int(Self.wireFormat.sampleRate),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            if let error = error { self?.closed("send failed: \(error.localizedDescription)") }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.closed(error.localizedDescription)
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                if case .data(let data) = message,
                   let text = String(data: data, encoding: .utf8) { self.handle(text) }
                // Re-arm: `receive` delivers exactly one message.
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let kind = json["message_type"] as? String else {
            lastMessage = "unparsed: " + text.prefix(120)
            return
        }
        lastMessage = kind
        let body = (json["text"] as? String) ?? ""
        switch kind {
        case "partial_transcript":
            partials += 1
            textQueue.async {
                self.partial = body
                self.publish()
            }
        case "committed_transcript":
            commits += 1
            // **Only the plain one.** `committed_transcript_with_timestamps`
            // carries the same words again with a `words[]` beside them, and
            // acting on both would draw every settled sentence twice. Timings
            // are what Walkie Talkie's markers need; a subtitle needs none.
            let segment = body.trimmingCharacters(in: .whitespaces)
            textQueue.async {
                if !segment.isEmpty { self.segments.append(segment); self.voices.append([]) }
                self.partial = ""
                self.trim()
                self.publish()
                self.correctIfDue()
            }
        case "session_started":
            overlayInfo("LiveCaptions: session \(json["session_id"] as? String ?? "?")")
        default:
            // Every error type they define ends in `_error`, and all of them
            // mean the same thing here: the captions are over and Victor has to
            // be told why rather than watching the screen stop moving.
            if kind.hasSuffix("error") {
                self.closed((json["error"] as? String) ?? kind)
            }
        }
    }

    // MARK: - Text and correction (on `textQueue`)

    private func publish(gentle: Bool = false) {
        guard running || socket != nil else { return }
        let committed = segments.joined(separator: " ")
        let partial = self.partial.trimmingCharacters(in: .whitespaces)
        var speakers: [Int] = [], offset = 0
        for (segment, starts) in zip(segments, voices) {
            speakers += starts.map { $0 + offset }
            offset += segment.split(whereSeparator: { $0.isWhitespace }).count
        }
        DispatchQueue.main.async { [weak self] in self?.onText?(committed, partial, gentle, speakers) }
    }

    /// Drops whole segments off the head while the rest still holds
    /// `keepWords` — corrected ones first; an uncorrected one only once the
    /// text is twice the cap (a correction that keeps failing).
    private func trim() {
        func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }
        var total = segments.reduce(0) { $0 + words($1) }
        while segments.count > 1, total - words(segments[0]) >= Self.keepWords,
              correctedSegments > 0 || total >= 2 * Self.keepWords {
            total -= words(segments.removeFirst())
            voices.removeFirst()
            trimmed += 1
            correctedSegments = max(0, correctedSegments - 1)
        }
    }

    /// Live segments not yet corrected and at least `minSpan` of audio since
    /// the cut → upload the span. Called at every commit.
    private func correctIfDue() {
        guard running, !correcting, segments.count > correctedSegments,
              Date() >= correctionHoldUntil,
              pcm.count > Int(Self.minSpan * 32_000) else { return }
        if pcm.count > Int(Self.maxSpan * 32_000) {
            // Given up on: the live words stand for this span.
            pcm = Data()
            correctedSegments = segments.count
            return
        }
        let span = pcm, to = pcm.count
        let from = correctedSegments + trimmed, upTo = segments.count + trimmed
        correcting = true
        Self.transcribeBatch(pcm: span, key: key) { [weak self] result in
            guard let self else { return }
            self.textQueue.async {
                self.correcting = false
                guard self.running else { return }
                switch result {
                case .failure(let why):
                    self.correctionFailures += 1
                    self.correctionHoldUntil = Date().addingTimeInterval(5)
                    overlayError("LiveCaptions correction failed — \(why); the next commit after 5 s covers the span again")
                case .success(let (text, starts)):
                    let lo = from - self.trimmed, hi = upTo - self.trimmed
                    self.pcm.removeFirst(min(to, self.pcm.count))
                    // The span rolled off the head meanwhile: nothing to swap.
                    guard !text.isEmpty, lo >= 0, lo == self.correctedSegments, hi <= self.segments.count, lo < hi else {
                        self.correctedSegments = max(self.correctedSegments, min(hi, self.segments.count))
                        return
                    }
                    self.segments.replaceSubrange(lo..<hi, with: [text])
                    self.voices.replaceSubrange(lo..<hi, with: [starts])
                    if !starts.isEmpty { self.speakerChanges += starts.count }
                    self.correctedSegments = lo + 1
                    self.corrections += 1
                    self.publish(gentle: true)
                }
            }
        }
    }

    /// One upload of `pcm` to the batch endpoint — Walkie's
    /// `ElevenLabsSource.transcribe`, minus the retry: the next commit is the
    /// retry. Language auto-detected, as Walkie's batch is.
    ///
    /// **Diarized since 2026-10-14**, so the band can start a new line where a
    /// new voice does (`speakerStarts`). The realtime socket has no such
    /// switch — its words carry a `speaker_id` only "if available", and it
    /// never is — so the line break arrives with the correction, a few seconds
    /// behind the words. Each upload is diarized on its own, so `speaker_0` in
    /// one span is not `speaker_0` in the next: what it can say is *the voice
    /// changed here*, never *who*, and never across two spans. A change across
    /// a VAD commit (1.5 s of silence) mostly coincides with a sentence end,
    /// which starts a line already. Measured on two `say` voices answering
    /// each other 0.3 s apart: every word on the right side, both changes
    /// found. No surcharge for `diarize` on the price list.
    static func transcribeBatch(pcm: Data, key: String, _ done: @escaping (Result<(String, [Int]), BatchError>) -> Void) {
        let boundary = "addons-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model_id", batchModel)
        field("diarize", "true")
        field("timestamps_granularity", "word")
        field("tag_audio_events", "false")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"span.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav(pcm: pcm))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error { return done(.failure(BatchError(error.localizedDescription))) }
            guard code == 200, let data else {
                let detail = data.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? ""
                return done(.failure(BatchError("HTTP \(code) \(detail)")))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = speakerStarts(json) else {
                return done(.failure(BatchError("unreadable reply")))
            }
            done(.success(reply))
        }.resume()
    }

    /// The batch reply as the band reads it: the text, and the indices of its
    /// whitespace-separated words where `speaker_id` changes. The text is the
    /// `words[]` laid end to end (spacing included), so the indices count the
    /// same words the band will split; no `words[]` → `text`, no voices.
    static func speakerStarts(_ json: [String: Any]) -> (String, [Int])? {
        func count(_ s: Substring) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }
        guard let list = json["words"] as? [[String: Any]], !list.isEmpty else {
            return (json["text"] as? String).map { ($0.trimmingCharacters(in: .whitespacesAndNewlines), []) }
        }
        var text = "", starts: [Int] = [], last: String?
        for item in list {
            let piece = item["text"] as? String ?? ""
            if item["type"] as? String == "word", let who = item["speaker_id"] as? String {
                // A word glued to the one before (no spacing between) is not a
                // place to break a line.
                if let last, who != last, !text.isEmpty, text.last?.isWhitespace == true {
                    starts.append(count(text[...]))
                }
                last = who
            }
            text += piece
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), starts.filter { $0 > 0 })
    }

    struct BatchError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// A 16 kHz mono 16-bit RIFF/WAVE around raw PCM.
    static func wav(pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    private func closed(_ why: String?) {
        lastMessage = "closed: " + (why ?? "?")
        guard !closeReported else { return }
        closeReported = true
        DispatchQueue.main.async { self.onClosed?(why) }
    }
}

// MARK: - Which microphone

extension LiveCaptionsStream {
    /// The first `MicRoster` rung present among the inputs, skipping
    /// `neverRecord` devices; else any input that is not one. For steering off
    /// the WH-1000XM3 when it is the system default (2026-09-23).
    static func bestLadderInput() -> (id: AudioDeviceID, name: String)? {
        let inputs = inputDevices().filter { !MicRoster.isNeverRecord($0.name) }
        for mic in MicRoster.all {
            if let hit = inputs.first(where: { $0.name.range(of: mic.pattern, options: .caseInsensitive) != nil }) {
                return hit
            }
        }
        return inputs.first
    }

    /// Every device with at least one input channel, with its name.
    static func inputDevices() -> [(id: AudioDeviceID, name: String)] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var cfg = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &cfg, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfg, 0, nil, &bytes, raw) == noErr else { return nil }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            guard list.contains(where: { $0.mNumberChannels > 0 }) else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var value: CFString?
            let st = withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, $0)
            }
            guard st == noErr, let name = value as String? else { return nil }
            return (id, name)
        }
    }

    /// The system default input's name, for the menu row. Nil rather than a
    /// guess: a row that names the wrong device is worse than one that admits
    /// it does not know.
    static func defaultInputName() -> String? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr, id != 0 else {
            return nil
        }
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr else {
            return nil
        }
        return name as String
    }
}
