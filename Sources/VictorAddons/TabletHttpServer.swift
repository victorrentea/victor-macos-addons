import Foundation
import Network

/// Minimal HTTP server on port 55123 for tablet → Mac triggers.
class TabletHttpServer {
    static let port: UInt16 = 55123

    /// One JSON string literal, quotes and escaping included — the routes here
    /// hand-assemble their JSON, and a session name like `AI@"MM"` must not be
    /// able to break the body it is pasted into.
    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    enum Route: Equatable {
        /// Only the three effect names addons still owns: `training-end`,
        /// `stop-all` and `focus-playlist`. Everything else under `/effect/`
        /// is `.proxied` to Victor Effects.
        case effect(String)
        /// Forwarded verbatim (path AND query) to the effects app on 55124 —
        /// see `EffectsProxy` and the prefix table in `isProxied`.
        case proxied(String)
        /// The effects app calling back: `GET /effects/event?type=…`. Today the
        /// only type is `coffee-popped` (B.4 of the split plan), which carries
        /// `x`/`y` in global screen coordinates.
        case effectsEvent(type: String, params: [String: String])
        case openUrl(String)
    /// Test hook for the ⌘⌃ openers: same route a shortcut takes (official
    /// Chrome, window on the screen under the mouse) without a keypress.
    case testOpenOnMouseScreen(String)
    /// Read-only: which Chrome this app considers Victor's, and where its
    /// windows are.
    case testChromeWindows
    /// Tell the Chrome extension to reload itself, so an edit under
    /// `chrome-extension/` takes effect without anyone opening
    /// `chrome://extensions` — a page no extension, and no agent, can click.
    case chromeExtensionReload
        case testTranscriptionStart
        case testState
case testTerminalFont
        case testAudioPlaying
        case testLidAwakeState
        case testLidAwakeFlatline
        case testClaudeActivity
        case testWisprRecording
        /// Start/reset the Break countdown overlay for N minutes (test hook).
        case testBreakStart(Int)
        case testBreakUntil        // the ☕-click variant: half-size "UNTIL BREAK"
        /// Close the Break countdown overlay (test hook).
        case testBreakClose
        /// Toggle ⏸ on the Break overlay and return the resulting on-screen state (test hook).
        case testBreakPause
        /// Read-only snapshot of what the Break overlay is displaying (test hook).
        case testBreakState
        /// Open the country picker on the Break overlay, optionally pre-filtered (test hook).
        case testBreakPicker(String?)
        /// Tile Terminal windows — same action as ⌘⌃A (test hook).
        case testTile
        /// 🎙️ Open the transcript picker — same action as ⌘⌃V (test hook). Not
        /// read-only and not instant: it waits ~10 s for whisper, then really
        /// runs the local cleanup and puts a modal up on the cursor's screen.
        /// `?at=HH:MM` rewinds to that minute of today's transcript and skips
        /// the wait — the only way to exercise this outside a live session.
        case testTranscriptPicker(String?)
        /// ✂️ Interactive crop — puts macOS's crosshair up, so this one WAITS for a
        /// human to drag (or Esc). Not read-only: it really writes a file and
        /// really replaces the clipboard.
        case testScreenshotCrop
        /// 🟡 Play the capture's cursor mark at the mouse, without taking a shot —
        /// the one part of ⌃P that cannot be checked from a saved file.
        case testScreenshotMark(String?)
        /// Post the 13:00 "Group Photo" notification now, bypassing the time +
        /// connection gates (test hook).
        case testGroupPhoto
        /// Run the *end-of-break* Group Photo prompt now, as if a qualifying
        /// break had just finished — the half that otherwise costs an hour of
        /// lunch to see (test hook).
        case testGroupPhotoBreakEnd
        /// Post the "Wispr started but output ≠ 🔊OS Output" notification now,
        /// using the real current default-output name (test hook).
    /// Force the dictation window open/closed, to exercise the Chrome
    /// pause/resume bridge without actually dictating (`?active=0|1`).
    case testDictation(Bool)
        /// Force-apply the projector/standard display arrangement now and return
        /// a JSON snapshot of the detected displays + applied scene (test hook).
        case testProjector
        /// JSON snapshot of the presenting state (meeting / unknown display).
        case testPresentation
        /// JSON snapshot of Zoom's share picker + a forced re-prepare of it.
        case testZoomShare
        /// JSON snapshot of the ⌥ emoji layer (`EmojiKeyLayer`): whether it is
        /// on, the map file it is serving and how many bindings it holds.
        case testEmojiLayer
        /// Turn the ⌥ emoji layer on/off at runtime and return the same
        /// snapshot — the kill switch if a synthetic character misbehaves in
        /// some app mid-workshop.
        case testEmojiLayerEnable(Bool)
        /// Force-show the aggressive silent-transcription warning now.
        case testPresentationWarn
        /// Fire the ☕️ break-summary delta run now, bypassing the >= 5 min +
        /// cooldown gates — same Terminal flow a real break triggers (test hook).
        case testBreakSummary
        /// Fire the 🔬 Research Proof run now (test hook) — the same Terminal
        /// flow the menu item fires, so a fact-check can be exercised without
        /// clicking during a session.
        case testResearchProof
        /// Show the "Start summarization?" wrap-up offer now, bypassing the
        /// 16:45 / 17:15 schedule (test hook). Hovering it still launches the
        /// interactive claude for real.
        case testSummaryReminder
        /// Show a 🔔 bell card now with an optional "?name=" caller (defaulting to
        /// a sample name), bypassing the daemon-connected gate (test hook).
        case testBell(String?)
        /// Show a bottom-left banner and dismiss it with the rising fade after a
        /// short beat — the "accepted / committed" exit — so the animation can be
        /// screen-recorded without a live session (test hook).
        case testBannerRise(String)
        /// Force one Flux-inbox poll now, bypassing the battery gate, and return
        /// a JSON snapshot of the poller's state (test hook).
        case testEmailPoll
        /// ⌘⌃P without the keyboard — mail the current clipboard to Victor.
        case testReminderMail
        /// Force a tablet app (re)deploy now, bypassing the source-stamp check
        /// and the failure cooldown; returns a JSON snapshot (test hook).
        case testAndroidDeploy
        /// Open the RFCOMM channel to the phone now — the signal that asks it for
        /// its hotspot — whatever the Mac's connectivity, the geofence or the
        /// cooldown; returns a JSON snapshot (test hook).
        case testHotspot
        /// JSON snapshot of the 📱 phone low-battery mirror (read-only): whether
        /// the tablet is being told to blink, at what charge, and how fresh the
        /// underlying Soduto notification is (test hook).
        case testPhoneBattery
        /// Pretend the phone is at N% for a couple of minutes, so the tablet's
        /// blink can be previewed without waiting for a genuinely flat phone.
        case testPhoneBatterySimulate(Int)
        /// JSON snapshot of the 🔒 screen-lock mirror the tablet uses to go into
        /// standby: whether the Mac reports itself locked right now (test hook).
        case testScreenLock
        /// Pretend the Mac's screen is locked (1) / unlocked (0) for a few
        /// minutes, so the tablet's standby can be watched without locking the
        /// very screen you'd be watching it from.
        case testScreenLockSimulate(Bool)
        case promptCapture
        case intellijFileOpened
        /// Video page (tablet): list downloaded videos.
        case videos
        /// Play a downloaded video by id, with an optional "?t=" start-second override.
        case videoPlay(String, Int?)
        /// Stop / close the video player.
        case videoStop
        /// 🎵 Play a video snippet's SOUND ONLY (no window, nothing on screen),
        /// with an optional "?t=" start-second override. The ♪ button on the
        /// tablet's video tiles.
        case videoSoundPlay(String, Int?)
        /// 🎵 Silence the soundtrack-only playback (the ♪ pressed a second time).
        case videoSoundStop
        /// 🎵 Read-only snapshot of the soundtrack-only player (test hook).
        case videoSoundState
        /// 📱 Is anything from the video page playing right now — clip or
        /// soundtrack — and how long is left of it. Polled by the tablet once a
        /// second while its video page is pinned to a playing tile.
        case videoState
        /// ✋ An agent is about to drive the mouse and keyboard: raise the
        /// hands-off frame. Carries who is driving, what it is doing, and how
        /// long to believe it before releasing on its own.
        case handsOffStart(agent: String?, what: String?, ttl: TimeInterval?)
        /// ✋ The agent is done — release the machine.
        case handsOffEnd
        /// Read-only snapshot of the hands-off state (test hook).
        case handsOffState
        /// Name of the training session that is live right now — the session
        /// folder with its date prefix stripped ("2026-09-03 AI@MM" → "AI@MM").
        /// The feedback-form robot uses it to name the survey it clones.
        case sessionName
        /// Put a link in front of the room in one call: copy it to the
        /// clipboard, raise the 🔳 clipboard-link banner (URL + QR on the
        /// projected screen) and append it to the session notes — the same
        /// three things a hand does with ⌘⌃S plus the menu item.
        case linkPublish(String)
        /// Take the banner back down (the robot's counterpart to pressing the
        /// menu item a second time).
        case linkHide
        /// 📝 Ask the Chrome extension to publish this session's feedback form.
        case feedbackForm(String?)
        /// Show the "Feedback form?" offer now, bypassing the 16:30 / 17:00
        /// schedule and the live-session gate (test hook).
        case testFeedbackReminder
        /// The extension has published a survey: `?url=` (and the `?title=` it
        /// was given). Everything `/link/publish` does, plus the participants'
        /// left-hand menu in Interact.
        case feedbackPublished(url: String, title: String?)
        case unknown
    }

    /// The three effect names addons still handles itself — `training-end`,
    /// `stop-all`, `focus-playlist`. Everything visual moved to Victor Effects.
    var onEffect: ((String) -> Void)?
    /// The effects app reporting something back (`/effects/event?type=…`).
    var onEffectsEvent: ((String, [String: String]) -> Void)?
    /// The addons half of the merged `/ping`: a JSON **fragment** that already
    /// starts with a comma (`,"macTimeMs":…,"macLanIps":[…]…`), spliced onto the
    /// effects app's own ping object by `EffectsProxy.mergedPing`. Collected
    /// inside a `main.sync` because every field it reads is main-thread state.
    var onPingExtras: (() -> String)?
    /// Open a URL in a fullscreen Chrome window on the primary display.
    var onOpenUrl: ((String) -> Void)?
    /// Open a URL the way the ⌘⌃ openers do — official Chrome, on the screen
    /// under the mouse. Test hook only.
    var onTestOpenOnMouseScreen: ((String) -> Void)?
    /// Returns false when no extension on the bridge can reload itself yet.
    var onChromeExtensionReload: (() -> Bool)?
    var onTestTranscriptionStart: (() -> Void)?
    var onTestState: (() -> String)?
    var onTestAudioPlaying: (() -> String)?
    var onTestLidAwakeState: (() -> String)?
    var onTestLidAwakeFlatline: (() -> Void)?
    var onTestWisprRecording: (() -> String)?
    var onTestBreakStart: ((Int) -> Void)?
    var onTestBreakUntil: (() -> Void)?
    var onTestBreakClose: (() -> Void)?
    var onTestBreakPicker: ((String?) -> Void)?
    var onTestBreakPause: (() -> String)?
    var onTestBreakState: (() -> String)?
    var onTestTile: (() -> Void)?
    var onTestTranscriptPicker: ((String?) -> Void)?
    var onTestScreenshotCrop: (() -> Void)?
    var onTestScreenshotMark: ((String?) -> Void)?
    var onTestGroupPhoto: (() -> Void)?
    var onTestGroupPhotoBreakEnd: (() -> Void)?
    /// Force the dictation window; returns the bridge's JSON snapshot.
    var onTestDictation: ((Bool) -> String)?
    /// Force-apply the display arrangement now; returns a JSON snapshot.
    var onTestProjector: (() -> String)?
    /// JSON snapshot of the presenting state + display classification.
    var onTestPresentation: (() -> String)?
    /// JSON snapshot of Zoom's share picker; also re-arms and re-runs the prep.
    var onTestZoomShare: (() -> String)?
    /// Force-show the aggressive silent-transcription warning.
    var onTestPresentationWarn: (() -> Void)?
    var onTestBreakSummary: (() -> Void)?
    var onTestResearchProof: (() -> Void)?
    var onTestSummaryReminder: (() -> Void)?
    /// Show a 🔔 bell card now; the argument is the optional "?name=" caller.
    var onTestBell: ((String?) -> Void)?
    var onTestBannerRise: ((String) -> Void)?
    /// Force one Flux-inbox poll now; returns the poller's JSON snapshot.
    var onTestEmailPoll: (() -> String)?
    /// Fires the ⌘⌃P reminder mail. Returns nothing: the send is asynchronous
    /// and its verdict lands in the banner and the log, exactly as it does when
    /// the key is pressed — a hook that waited for it would be testing a
    /// different code path from the one in production.
    var onTestReminderMail: (() -> Void)?
    /// Force a tablet app (re)deploy now; returns a JSON snapshot of the
    /// deployer's state (the deploy itself continues in the background).
    var onTestAndroidDeploy: (() -> String)?
    var onTestHotspot: (() -> String)?
    /// Read-only JSON snapshot of the 📱 phone low-battery mirror.
    var onTestPhoneBattery: (() -> String)?
    /// Force a synthetic phone charge for a short while; returns the snapshot.
    var onTestPhoneBatterySimulate: ((Int) -> String)?
    /// Read-only JSON snapshot of the 🔒 screen-lock mirror.
    var onTestScreenLock: (() -> String)?
    /// Force a synthetic lock state for a short while; returns the snapshot.
    var onTestScreenLockSimulate: ((Bool) -> String)?
    /// Receives the prompt body; returns JSON describing whether it was captured.
    var onPromptCapture: ((String) -> String)?
    /// Receives the IntelliJ plugin's open-file JSON body; returns JSON describing whether it was accepted.
    var onIntellijFileOpened: ((String) -> String)?
    /// Video page: manifest JSON of downloaded videos, for the tablet to build tiles.
    var onVideos: (() -> String)?
    /// Play a downloaded video by id (optional start-second override); returns
    /// JSON, or nil if the id is unknown / not downloaded (→ 404).
    var onVideoPlay: ((String, Int?) -> String?)?
    /// Stop / close the video player.
    var onVideoStop: (() -> Void)?
    /// 🎵 Play a snippet's soundtrack alone by id (optional start-second
    /// override); returns JSON carrying `durationMs` — how long the tablet
    /// should hold its video page open — or nil if the id is unknown (→ 404).
    var onVideoSoundPlay: ((String, Int?) -> String?)?
    /// 🎵 Silence the soundtrack-only playback.
    var onVideoSoundStop: (() -> Void)?
    /// 🎵 Read-only JSON snapshot of the soundtrack-only player.
    var onVideoSoundState: (() -> String)?
    /// 📱 `{playing,kind,id,remainingMs}` for whichever of the two video-page
    /// players is running (clip wins; they are mutually exclusive by design).
    var onVideoState: (() -> String)?
    /// ✋ Raise the hands-off frame (agent, what, ttl seconds); returns the state JSON.
    var onHandsOffStart: ((String?, String?, TimeInterval?) -> String)?
    /// ✋ Release it; returns the state JSON.
    var onHandsOffEnd: (() -> String)?
    /// ✋ Read-only snapshot.
    var onHandsOffState: (() -> String)?
    /// Returns JSON naming the live session, e.g. `{"ok":true,"name":"AI@MM"}`.
    var onSessionName: (() -> String)?
    /// Copies the URL, raises the clipboard-link banner and files it in the
    /// session notes; returns JSON describing what happened.
    var onLinkPublish: ((String) -> String)?
    /// Hides the clipboard-link banner; returns JSON.
    var onLinkHide: (() -> String)?
    /// Asks Chrome to publish the feedback form; returns JSON.
    var onFeedbackForm: ((String?) -> String)?
    var onTestFeedbackReminder: (() -> Void)?
    /// Handles a freshly published survey; returns JSON.
    var onFeedbackPublished: ((String, String?) -> String)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "tablet-http", qos: .utility)

    func start() {
        let tcpParams = NWParameters.tcp
        tcpParams.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: tcpParams, on: NWEndpoint.Port(rawValue: Self.port)!) else {
            overlayError("TabletHttpServer: failed to bind port \(Self.port)")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:   overlayInfo("Tablet HTTP server on :\(Self.port)")
            case .failed(let err): overlayError("TabletHttpServer failed: \(err)")
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = Self.parsePath(raw)
            let result = self.respond(path: path, requestBody: Self.extractBody(raw))
            let response = Self.httpResponse(statusCode: result.status,
                                             contentType: result.contentType, body: result.body)
            conn.send(content: response.data(using: .utf8),
                      completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// Pure request handler shared by the TCP listener (LAN/USB) and the Railway
    /// bridge (internet fallback). Maps `path` to a route, runs its handler on
    /// the main thread, and returns the HTTP-style result. `requestBody` is the
    /// decoded request body, consulted only by the POST-like routes.
    ///
    /// Must NOT be called on the main thread (it does `DispatchQueue.main.sync`);
    /// both callers invoke it from a background queue.
    func respond(path: String, requestBody: String) -> (status: Int, contentType: String, body: String) {
        let route = Self.route(forPath: path)

        // Proxied routes never touch the main thread: the effects app may be
        // stopped, slow to start or mid-rebuild, and a `main.sync` behind a
        // 3 s socket timeout would freeze the menu bar for every one of them.
        // This runs on the server queue, which also keeps the tablet's
        // stop-all -> play -> pressed chain in order (one connection at a time).
        if case .proxied(let forwarded) = route {
            return EffectsProxy.forward(forwarded, body: requestBody, pingExtras: onPingExtras)
        }

        var statusCode = 200
        var body = "ok"
        var contentType = "text/plain; charset=utf-8"

        DispatchQueue.main.sync {
            switch route {
            case .proxied:
                break   // handled above, before the main-thread hop
            case .effectsEvent(let type, let params):
                self.onEffectsEvent?(type, params)
            case .effect(let name):
                self.onEffect?(name)
            case .openUrl(let url):
                self.onOpenUrl?(url)
            case .testOpenOnMouseScreen(let url):
                self.onTestOpenOnMouseScreen?(url)
            case .testChromeWindows:
                contentType = "application/json"
                body = OfficialChrome.debugJSON()
            case .chromeExtensionReload:
                contentType = "application/json"
                let asked = self.onChromeExtensionReload?() ?? false
                body = "{\"asked\":\(asked)}"
                if !asked { statusCode = 503 }
            case .testTranscriptionStart:
                self.onTestTranscriptionStart?()
            case .testTerminalFont:
                contentType = "application/json"
                body = TerminalFontSizeProbe.json()
            case .testState:
                contentType = "application/json"
                body = self.onTestState?() ?? "{\"error\":\"state unavailable\"}"
                if self.onTestState == nil {
                    statusCode = 503
                }
            case .testAudioPlaying:
                contentType = "application/json"
                body = self.onTestAudioPlaying?() ?? "{\"error\":\"audio probe unavailable\"}"
                if self.onTestAudioPlaying == nil {
                    statusCode = 503
                }
            case .testLidAwakeState:
                contentType = "application/json"
                body = self.onTestLidAwakeState?() ?? "{\"error\":\"lid awake unavailable\"}"
            case .testLidAwakeFlatline:
                self.onTestLidAwakeFlatline?()
            case .testClaudeActivity:
                contentType = "application/json"
                let working = ClaudeActivity.workingSessions()
                let helpers = ClaudeActivity.processTable()
                    .filter { $0.name == "caffeinate" }
                    .map(\.ppid)
                    .compactMap { pid -> String? in
                        guard let kind = ClaudeActivity.helperKind(of: pid) else { return nil }
                        return "\(pid):\(kind)"
                    }
                body = "{\"working\":[\(working.map(String.init).joined(separator: ","))],"
                    + "\"skipped_helpers\":[\(helpers.map { "\"\($0)\"" }.joined(separator: ","))]}"
            case .testWisprRecording:
                contentType = "application/json"
                body = self.onTestWisprRecording?() ?? "{\"error\":\"wispr probe unavailable\"}"
                if self.onTestWisprRecording == nil {
                    statusCode = 503
                }
            case .testBreakStart(let minutes):
                self.onTestBreakStart?(minutes)
            case .testBreakUntil:
                self.onTestBreakUntil?()
            case .testBreakClose:
                self.onTestBreakClose?()
            case .testBreakPause:
                contentType = "application/json"
                body = self.onTestBreakPause?() ?? "{\"error\":\"break timer unavailable\"}"
            case .testBreakState:
                contentType = "application/json"
                body = self.onTestBreakState?() ?? "{\"error\":\"break timer unavailable\"}"
            case .testBreakPicker(let q):
                self.onTestBreakPicker?(q)
            case .testTile:
                self.onTestTile?()
            case .testTranscriptPicker(let at):
                self.onTestTranscriptPicker?(at)
            case .testScreenshotCrop:
                self.onTestScreenshotCrop?()
            case .testScreenshotMark(let at):
                self.onTestScreenshotMark?(at)
            case .testGroupPhoto:
                self.onTestGroupPhoto?()
            case .testGroupPhotoBreakEnd:
                self.onTestGroupPhotoBreakEnd?()
            case .testProjector:
                contentType = "application/json"
                body = self.onTestProjector?() ?? "{\"error\":\"display manager unavailable\"}"
                if self.onTestProjector == nil {
                    statusCode = 503
                }
            case .testPresentation:
                contentType = "application/json"
                body = self.onTestPresentation?() ?? "{\"error\":\"unavailable\"}"
                if self.onTestPresentation == nil { statusCode = 503 }
            case .testZoomShare:
                contentType = "application/json"
                body = self.onTestZoomShare?() ?? "{\"error\":\"unavailable\"}"
                if self.onTestZoomShare == nil { statusCode = 503 }
            case .testEmojiLayer:
                contentType = "application/json"
                body = EmojiKeyLayer.statusJSON()
            case .testEmojiLayerEnable(let on):
                EmojiKeyLayer.isEnabled = on
                contentType = "application/json"
                body = EmojiKeyLayer.statusJSON()
            case .testPresentationWarn:
                self.onTestPresentationWarn?()
            case .testBreakSummary:
                self.onTestBreakSummary?()
            case .testResearchProof:
                self.onTestResearchProof?()
            case .testSummaryReminder:
                self.onTestSummaryReminder?()
            case .testBell(let name):
                self.onTestBell?(name)
            case .testBannerRise(let mode):
                self.onTestBannerRise?(mode)
            case .testEmailPoll:
                contentType = "application/json"
                body = self.onTestEmailPoll?() ?? "{\"error\":\"flux poller unavailable\"}"
                if self.onTestEmailPoll == nil { statusCode = 503 }
            case .testReminderMail:
                self.onTestReminderMail?()
            case .testAndroidDeploy:
                contentType = "application/json"
                body = self.onTestAndroidDeploy?() ?? "{\"error\":\"android deployer unavailable\"}"
                if self.onTestAndroidDeploy == nil { statusCode = 503 }
            case .testDictation(let active):
                contentType = "application/json"
                body = self.onTestDictation?(active) ?? "{\"error\":\"dictation bridge unavailable\"}"
            case .testHotspot:
                contentType = "application/json"
                body = self.onTestHotspot?() ?? "{\"error\":\"hotspot fallback unavailable\"}"
                if self.onTestHotspot == nil { statusCode = 503 }
            case .testPhoneBattery:
                contentType = "application/json"
                body = self.onTestPhoneBattery?() ?? "{\"error\":\"phone battery monitor unavailable\"}"
                if self.onTestPhoneBattery == nil { statusCode = 503 }
            case .testPhoneBatterySimulate(let pct):
                contentType = "application/json"
                body = self.onTestPhoneBatterySimulate?(pct) ?? "{\"error\":\"phone battery monitor unavailable\"}"
                if self.onTestPhoneBatterySimulate == nil { statusCode = 503 }
            case .testScreenLock:
                contentType = "application/json"
                body = self.onTestScreenLock?() ?? "{\"error\":\"screen lock monitor unavailable\"}"
                if self.onTestScreenLock == nil { statusCode = 503 }
            case .testScreenLockSimulate(let locked):
                contentType = "application/json"
                body = self.onTestScreenLockSimulate?(locked) ?? "{\"error\":\"screen lock monitor unavailable\"}"
                if self.onTestScreenLockSimulate == nil { statusCode = 503 }
            case .promptCapture:
                contentType = "application/json"
                body = self.onPromptCapture?(requestBody) ?? "{\"captured\":false,\"reason\":\"handler-missing\"}"
            case .intellijFileOpened:
                contentType = "application/json"
                body = self.onIntellijFileOpened?(requestBody) ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"
            case .videos:
                contentType = "application/json"
                body = self.onVideos?() ?? "{\"videos\":[]}"
            case .videoPlay(let id, let t):
                contentType = "application/json"
                if let json = self.onVideoPlay?(id, t) {
                    body = json
                } else {
                    statusCode = 404
                    body = "{\"ok\":false,\"reason\":\"unknown-video\"}"
                }
            case .videoStop:
                self.onVideoStop?()
            case .videoSoundPlay(let id, let t):
                contentType = "application/json"
                if let json = self.onVideoSoundPlay?(id, t) {
                    body = json
                } else {
                    statusCode = 404
                    body = "{\"ok\":false,\"reason\":\"unknown-video\"}"
                }
            case .videoSoundStop:
                self.onVideoSoundStop?()
            case .videoSoundState:
                contentType = "application/json"
                body = self.onVideoSoundState?() ?? "{\"playing\":false}"
            case .videoState:
                contentType = "application/json"
                body = self.onVideoState?() ?? "{\"playing\":false,\"kind\":\"none\"}"
            case .handsOffStart(let agent, let what, let ttl):
                contentType = "application/json"
                body = self.onHandsOffStart?(agent, what, ttl) ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"
            case .handsOffEnd:
                contentType = "application/json"
                body = self.onHandsOffEnd?() ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"
            case .handsOffState:
                contentType = "application/json"
                body = self.onHandsOffState?() ?? "{\"active\":false}"
            case .sessionName:
                contentType = "application/json"
                body = self.onSessionName?() ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"
            case .linkPublish(let url):
                contentType = "application/json"
                body = self.onLinkPublish?(url) ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"
            case .linkHide:
                contentType = "application/json"
                body = self.onLinkHide?() ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"
            case .feedbackForm(let session):
                contentType = "application/json"
                body = self.onFeedbackForm?(session) ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"
            case .testFeedbackReminder:
                self.onTestFeedbackReminder?()
            case .feedbackPublished(let url, let title):
                contentType = "application/json"
                body = self.onFeedbackPublished?(url, title) ?? "{\"ok\":false,\"reason\":\"handler-missing\"}"

            case .unknown:
                statusCode = 404
                body = "not found"
            }
        }

        // `/effect/stop-all` is the one route that is BOTH local and forwarded:
        // the 🎵 soundtrack and the 🏁 arming live here, the animator and the
        // soundboard live there. Forwarded synchronously, on this queue, AFTER
        // the local half — the tablet fires stop-all → play → pressed as three
        // requests in a row, and the effects app must see them in that order or
        // a stop-all arriving late silences the sound it was meant to precede.
        if case .effect("stop-all") = route {
            _ = EffectsProxy.forward("/effect/stop-all")
        }

        return (statusCode, contentType, body)
    }

    /// Extract the body from a raw HTTP request — everything after the blank
    /// line that terminates the headers. Returns "" if no body present.
    static func extractBody(_ raw: String) -> String {
        if let range = raw.range(of: "\r\n\r\n") {
            return String(raw[range.upperBound...])
        }
        if let range = raw.range(of: "\n\n") {
            return String(raw[range.upperBound...])
        }
        return ""
    }

    static func parsePath(_ request: String) -> String {
        let parts = request.split(separator: " ", maxSplits: 2)
        return parts.count > 1 ? String(parts[1]) : "/"
    }

    /// The three effect names that did NOT move to Victor Effects, because
    /// what they drive lives here: the 🏁 end-of-training sequence (it needs
    /// the whisper `VICTOR_VOICE` pulse), `stop-all` (it must also silence the
    /// 🎵 video soundtrack and disarm 🏁 before forwarding) and the 🎧 focus
    /// playlist (a Chrome tab, not a pixel).
    static let localEffectNames: Set<String> = ["training-end", "stop-all", "focus-playlist"]

    /// Path prefixes forwarded verbatim to the effects app on 55124. `/ping` is
    /// merged rather than passed through (see `EffectsProxy.mergedPing`);
    /// everything else is a straight hop.
    ///
    /// Note what is NOT here: `/video/*` and `/videos` (IINA and the training
    /// clips stay in addons), `/test/state`, `/hands-off/*`, `/session/*`,
    /// `/link/*`. `/sound/` does not catch `/video/sound/...` because the
    /// match is on a leading prefix, not a substring.
    static let proxiedPrefixes = ["/ping", "/sounds/", "/sound/", "/effect/",
                                  "/alarm/", "/bt-compensation", "/tiles", "/state",
                                  // The tile press counts behind the tablet's
                                  // green dots now live in the effects app, with
                                  // the panel presses they were always missing.
                                  "/usage"]

    /// The historic `/test/<effect>` aliases. They keep answering on 55123 —
    /// every script, doc and muscle memory points at them — and are simply
    /// forwarded under the same spelling, which the effects app also serves.
    /// `/test/focus-playlist` is deliberately absent: it is local.
    static let proxiedTestAliases: Set<String> = [
        "/test/sonar", "/test/beethoven", "/test/phoenix", "/test/money",
        "/test/coffee", "/test/coffee/pop", "/test/iris",
        "/test/snow", "/test/snow/stop",
        "/test/elephant", "/test/elephant/stop",
        "/test/claude-peek", "/test/claude-peek/stop",
        "/test/minion", "/test/counter-strike",
        "/test/chainsaw", "/test/chainsaw/stop",
        "/test/fire", "/test/fire/stop", "/test/microwave",
        "/test/whip", "/test/whip/crack",
    ]

    /// Does this path belong to the effects app? Call only AFTER the local
    /// `/effect/<name>` exceptions have been taken out — `/effect/` is in the
    /// prefix table and would otherwise swallow them.
    static func isProxied(_ pathOnly: String) -> Bool {
        if proxiedTestAliases.contains(pathOnly) { return true }
        return proxiedPrefixes.contains { pathOnly.hasPrefix($0) }
    }

    static func route(forPath path: String) -> Route {
        let (pathOnly, queryItems) = parsePathAndQuery(path)

        // Local effects first: they share the `/effect/` prefix with everything
        // that gets forwarded, so the exception has to be checked before the
        // prefix table below. `/test/focus-playlist` is the one alias among them.
        if pathOnly.hasPrefix("/effect/") {
            let name = String(pathOnly.dropFirst("/effect/".count))
            if localEffectNames.contains(name) { return .effect(name) }
        }
        if pathOnly == "/test/focus-playlist" { return .effect("focus-playlist") }

        // The effects app calling back — today only the ☕ payoff (B.4).
        if pathOnly == "/effects/event" {
            guard let type = queryItems.first(where: { $0.name == "type" })?.value, !type.isEmpty else {
                return .unknown
            }
            var params: [String: String] = [:]
            for item in queryItems where item.name != "type" {
                params[item.name] = item.value ?? ""
            }
            return .effectsEvent(type: type, params: params)
        }

        // Everything the effects app owns, forwarded with its query intact.
        if isProxied(pathOnly) { return .proxied(path) }

        switch pathOnly {
        case "/videos":
            return .videos
        case "/video/stop":
            return .videoStop
        case "/test/video/stop":
            return .videoStop
        case "/video/sound/stop":
            return .videoSoundStop
        case "/test/video/sound/stop":
            return .videoSoundStop
        case "/test/video/sound":
            return .videoSoundState
        case "/video/state":
            return .videoState
        case "/test/video/state":
            return .videoState
        case "/test/transcription/start":
            return .testTranscriptionStart
        case "/test/terminal-font":
            return .testTerminalFont
        case "/test/state":
            return .testState
        case "/test/audio/playing":
            return .testAudioPlaying
        case "/test/lid-awake/state":
            return .testLidAwakeState
        case "/test/lid-awake/flatline":
            return .testLidAwakeFlatline
        case "/test/claude-activity":
            return .testClaudeActivity
        case "/test/wispr/recording":
            return .testWisprRecording
        case "/test/break/close":
            return .testBreakClose
        case "/test/break/pause":
            return .testBreakPause
        case "/test/break/state":
            return .testBreakState
        case "/test/break/picker":
            return .testBreakPicker(queryItems.first(where: { $0.name == "q" })?.value)
        case "/test/tile":
            return .testTile
        case "/test/transcript-picker":
            return .testTranscriptPicker(queryItems.first(where: { $0.name == "at" })?.value)
        case "/test/screenshot/crop":
            return .testScreenshotCrop
        case "/test/screenshot/mark":
            return .testScreenshotMark(queryItems.first(where: { $0.name == "at" })?.value)
        case "/test/group-photo":
            return .testGroupPhoto
        case "/test/group-photo/break-end":
            return .testGroupPhotoBreakEnd
        case "/test/dictation":
            let raw = queryItems.first(where: { $0.name == "active" })?.value ?? "1"
            return .testDictation(raw != "0" && raw.lowercased() != "false")
        case "/test/projector":
            return .testProjector
        case "/test/presentation":
            return .testPresentation
        case "/test/zoom-share":
            return .testZoomShare
        case "/test/emoji-layer":
            return .testEmojiLayer
        case "/test/emoji-layer/on":
            return .testEmojiLayerEnable(true)
        case "/test/emoji-layer/off":
            return .testEmojiLayerEnable(false)
        case "/test/presentation/warn":
            return .testPresentationWarn
        case "/test/break-summary":
            return .testBreakSummary
        case "/test/research-proof":
            return .testResearchProof
        case "/test/feedback-reminder":
            return .testFeedbackReminder
        case "/feedback-form/published":
            if let url = queryItems.first(where: { $0.name == "url" })?.value, !url.isEmpty {
                return .feedbackPublished(url: url,
                                          title: queryItems.first(where: { $0.name == "title" })?.value)
            }
            return .unknown
        case "/test/summary-reminder":
            return .testSummaryReminder
        case "/test/bell":
            return .testBell(queryItems.first(where: { $0.name == "name" })?.value)
        case "/test/banner/rise":
            return .testBannerRise(queryItems.first(where: { $0.name == "hover" })?.value ?? "")
        case "/test/email":
            return .testEmailPoll
        case "/test/reminder":
            return .testReminderMail
        case "/test/android-deploy":
            return .testAndroidDeploy
        case "/test/hotspot":
            return .testHotspot
        case "/test/phone-battery":
            return .testPhoneBattery
        case "/test/screen-lock":
            return .testScreenLock
        case "/training/prompt-capture":
            return .promptCapture
        case "/intellij/file-opened":
            return .intellijFileOpened
        case "/hands-off/start":
            return .handsOffStart(
                agent: queryItems.first(where: { $0.name == "agent" })?.value,
                what: queryItems.first(where: { $0.name == "what" })?.value,
                ttl: queryItems.first(where: { $0.name == "ttl" })?.value.flatMap(Double.init)
            )
        case "/hands-off/end":
            return .handsOffEnd
        case "/hands-off/state":
            return .handsOffState
        case "/session/name":
            return .sessionName
        case "/link/publish":
            if let url = queryItems.first(where: { $0.name == "url" })?.value, !url.isEmpty {
                return .linkPublish(url)
            }
            return .unknown
        case "/link/hide":
            return .linkHide
        case "/feedback-form/publish":
            // "?session=" is a test hook: it names the form without a live
            // session, which is the only way to exercise the whole chain
            // outside a workshop. The menu item has no such door — it stays
            // hidden until a session is really running.
            return .feedbackForm(queryItems.first(where: { $0.name == "session" })?.value)
        case "/open":
            if let url = queryItems.first(where: { $0.name == "url" })?.value, !url.isEmpty {
                return .openUrl(url)
            }
            return .unknown
        case "/test/chrome/windows":
            return .testChromeWindows
        case "/chrome/extension/reload":
            return .chromeExtensionReload
        case "/test/open-mouse":
            if let url = queryItems.first(where: { $0.name == "url" })?.value, !url.isEmpty {
                return .testOpenOnMouseScreen(url)
            }
            return .unknown
        default:
            if pathOnly.hasPrefix("/video/play/") {
                let id = String(pathOnly.dropFirst("/video/play/".count))
                let t = queryItems.first(where: { $0.name == "t" })?.value.flatMap(Int.init)
                if !id.isEmpty { return .videoPlay(id, t) }
            }
            if pathOnly.hasPrefix("/video/sound/") {
                let id = String(pathOnly.dropFirst("/video/sound/".count))
                let t = queryItems.first(where: { $0.name == "t" })?.value.flatMap(Int.init)
                if !id.isEmpty { return .videoSoundPlay(id, t) }
            }
            // Checked BEFORE the plain /test/video/ hook below, which would
            // otherwise swallow this as a video id of "sound/<id>".
            if pathOnly.hasPrefix("/test/video/sound/") {
                let id = String(pathOnly.dropFirst("/test/video/sound/".count))
                if !id.isEmpty { return .videoSoundPlay(id, nil) }
            }
            // Headless test hook: /test/video/<id> plays it (start second from the
            // manifest). /test/video/stop is handled by the exact-match case above.
            if pathOnly.hasPrefix("/test/video/") {
                let id = String(pathOnly.dropFirst("/test/video/".count))
                if !id.isEmpty { return .videoPlay(id, nil) }
            }
            if pathOnly.hasPrefix("/test/phone-battery/simulate/") {
                let suffix = String(pathOnly.dropFirst("/test/phone-battery/simulate/".count))
                if let pct = Int(suffix), (0...100).contains(pct) {
                    return .testPhoneBatterySimulate(pct)
                }
            }
            if pathOnly.hasPrefix("/test/screen-lock/simulate/") {
                let suffix = String(pathOnly.dropFirst("/test/screen-lock/simulate/".count))
                if suffix == "1" { return .testScreenLockSimulate(true) }
                if suffix == "0" { return .testScreenLockSimulate(false) }
            }
            if pathOnly.hasPrefix("/test/break/") {
                let suffix = String(pathOnly.dropFirst("/test/break/".count))
                if suffix == "until" { return .testBreakUntil }
                if let minutes = Int(suffix) {
                    return .testBreakStart(minutes)
                }
            }
            return .unknown
        }
    }

    private static func parsePathAndQuery(_ raw: String) -> (String, [URLQueryItem]) {
        guard let comps = URLComponents(string: "http://x" + raw) else { return (raw, []) }
        return (comps.path, comps.queryItems ?? [])
    }

    private static func httpResponse(statusCode: Int, contentType: String, body: String) -> String {
        let reason: String
        switch statusCode {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let bytes = body.utf8.count
        return "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bytes)\r\n\r\n\(body)"
    }
}
