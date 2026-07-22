import AppKit
import AVFoundation
import Foundation
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, URLSessionWebSocketDelegate, UNUserNotificationCenterDelegate {
    private var overlayPanel: OverlayPanel!
    private var auxOverlayPanels: [OverlayPanel] = []
    private var animator: EmojiAnimator!
    private var progressBarOverlay: ProgressBarOverlay?
    // buttonBar removed
    private var menuBarManager: MenuBarManager!
    private var whipController: WhipController?  // 🔥 Whip Claude overlay (OFF by default)
    private let breakTimer = BreakTimerController()  // ☕️ Break countdown watch overlay
    private var coffeeHoverTimer: Timer?             // polls the cursor vs floating ☕ layers
    /// Menu-triggered desktop effects run for this fixed, sound-independent
    /// duration (looping effects are stopped after it; one-shots keep their own
    /// natural length). The tablet path keeps its sound-driven durations — see
    /// `onEffect`. Arbitrary; tune freely.
    private let menuEffectDuration: TimeInterval = 5.0
    private let serverURL: String
    private var wsTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var reconnecting = false
    private var wsConnected = false
    private var pendingDisconnectError: DispatchWorkItem?
    private let disconnectErrorDelay: TimeInterval = 3.0
    private let pidFilePath: String
    private let myPID: Int32
    private var pidCheckTimer: Timer?
    private var controlsVisible = false
    private var eventTapManager: EventTapManager?
    private var keymapOverlayController: KeymapOverlayController?
    private var keymapHoldCoordinator: KeymapHoldCoordinator?
    private var keymapHoldWorkItem: DispatchWorkItem?
    private var emotionalPasteHandler: EmotionalPasteHandler?
    private var coreAudioManager: CoreAudioManager?
    private var bluetoothKeepAlive: BluetoothKeepAlive?
    private var wsServer: LocalWebSocketServer?
    private var tabletServer: TabletHttpServer?
    /// Outbound WS to the Railway bridge — the tablet's last-resort internet
    /// transport when LAN Wi-Fi and USB both fail (public-Wi-Fi client isolation).
    private var railwayBridge: RailwayBridgeClient?
    /// Last time the tablet hit /ping — feeds the tablet-sound watchdog.
    private var lastTabletPingAt: Date?
    private var tabletSoundWatchdog: Timer?
    private var pptMonitor: PowerPointMonitor?
    private var driveShareCache: GoogleDriveShareCache?
    private var ijMonitor: IntelliJMonitor?
    private var portKiller: PortKiller?
    private var whisperManager: WhisperProcessManager?
    private var transcriptionWatcher: TranscriptionWatcher?
    private var transcriptionFolder: URL = URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")
    private var joinLinkBanner: JoinLinkBanner?
    private var promptCaptureBanner: BottomLeftBanner?
    private var powerMonitor: PowerMonitor?
    /// Drives Whisper purely off the power source: on AC → transcribe, on
    /// battery → pause. No schedule, no manual start/stop.
    private var transcriptionController: TranscriptionController?
    /// Keeps the wired USB tunnel (`adb reverse`) armed so the tablet can reach
    /// the Mac at `localhost:55123` when there's no shared WiFi.
    private var usbTunnelKeeper: UsbTunnelKeeper?
    /// True while the training-assistant daemon is connected to our local WS
    /// server (≥1 client). Gates the Group Photo prompt so it only fires when
    /// there's an audience to photograph.
    private var daemonConnected = false
    private var statusBanner: StatusBanner?
    /// Auto-arranges displays for the projector workflow (mirror Retina@1080p +
    /// ASUS-primary on connect; revert to Retina-main + ASUS-right on disconnect).
    private var displayArrangementManager: DisplayArrangementManager?
    /// Victor's own displays ("mine / not presenting"): ASUS + trusted home
    /// monitors / TV. An external NOT in here = presenting (venue projector/TV).
    private let knownDisplays = KnownDisplays()
    /// Am I presenting? OR of (unknown external display) and (live meeting).
    /// Gates the aggressive silent-transcription warning.
    private var presentationDetector: PresentationDetector?
    private var silentTranscriptionWarning: SilentTranscriptionWarning?
    private var meetingDetector: MeetingDetector?
    private var breakReminderTimer: Timer?
    /// Set by auto-restart paths (heartbeat-detected crash, post-wake) so
    /// that the next `whisperManager.onStateChanged(true)` shows the
    /// "started" banner. Consumed (cleared) when the banner fires.
    private var pendingAutoRestartBanner = false

    // Session state for join link feature
    private var isSessionActive: Bool = false
    private var participantUrl: String?

    init(serverURL: String, pidFilePath: String, myPID: Int32) {
        self.serverURL = serverURL
        self.pidFilePath = pidFilePath
        self.myPID = myPID
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request permissions if not already granted
        requestMicrophonePermissions()
        requestAccessibilityPermissions(promptUser: false)
        requestScreenRecordingPermissions(promptUser: true)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, err in
            overlayInfo("Notifications: granted=\(granted) err=\(String(describing: err))")
        }

        guard !NSScreen.screens.isEmpty else { fatalError("No screens available") }
        let builtInScreen = AppDelegate.findRetinaScreen()

        overlayPanel = OverlayPanel(screen: builtInScreen)
        overlayPanel.orderFrontRegardless()
        rebuildAuxOverlayPanels()
        let keymapOverlay = KeymapOverlayController(retinaScreenProvider: { AppDelegate.findRetinaScreen() })
        keymapOverlayController = keymapOverlay
        keymapHoldCoordinator = KeymapHoldCoordinator(
            delayProvider: { KeymapHoldCoordinator.delay(monitorCount: NSScreen.screens.count) },
            schedule: { [weak self] delay, fire in
                self?.keymapHoldWorkItem?.cancel()
                let work = DispatchWorkItem(block: fire)
                self?.keymapHoldWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            },
            cancelScheduled: { [weak self] in
                self?.keymapHoldWorkItem?.cancel()
                self?.keymapHoldWorkItem = nil
            },
            show: { [weak keymapOverlay] modifier in
                keymapOverlay?.show(modifier)
            },
            hide: { [weak keymapOverlay] in
                keymapOverlay?.hide()
            }
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        guard let hostLayer = overlayPanel.contentView?.layer else {
            fatalError("Content view has no layer")
        }
        animator = EmojiAnimator(hostLayer: hostLayer)
        installCoffeeBreakHoverMonitor()
        // Render the progress bar as a CALayer on the same host layer as the emoji
        // effects (built-in Retina overlay) — a plain subview on this
        // manually-populated layer-backed view does not composite.
        progressBarOverlay = ProgressBarOverlay(hostLayer: hostLayer)
        // No completion celebration: this bar is a neutral break/warm-up
        // countdown the trainer may cancel mid-run (someone interrupts), so a
        // confetti "reward" at the end is misleading. The bar just fills, then
        // fades out (ProgressBarOverlay.fadeOut) — onComplete stays unset.

        // No outbound WebSocket: the addon only runs LocalWebSocketServer on
        // 127.0.0.1 — the daemon (training-assistant) connects to interact.victorrentea.ro
        // and pushes overlay events to us via that local socket. URLSession is still
        // initialized (delegate hooks remain wired) but we never start a wsTask.
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        // buttonBar removed — effects are now in the menu bar under Desktop Effects
        setupSignalHandler()
        transcriptionFolder = {
            if let env = ProcessInfo.processInfo.environment["TRANSCRIPTION_FOLDER"] {
                return URL(fileURLWithPath: env)
            }
            return URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")
        }()

        let wsServer = LocalWebSocketServer()
        wsServer.onEmoji = { [weak self] emoji, count, glow in
            self?.overlayPanel?.refreshScreenFrame()
            for _ in 0..<max(1, count) {
                self?.animator.spawnEmoji(emoji, glow: glow)
            }
        }
        wsServer.onClientCountChanged = { [weak self] count in
            self?.daemonConnected = (count > 0)
            self?.menuBarManager.updateWsStatus(count > 0)
            if count == 0 { self?.handleSessionEnded() }
        }
        wsServer.onSessionMessage = { [weak self] json in
            guard let type = json["type"] as? String else { return }
            if type == "session_started", let url = json["participant_url"] as? String {
                let folder = json["session_folder"] as? String
                self?.handleSessionStarted(participantUrl: url, sessionFolder: folder)
            } else if type == "session_ended" {
                self?.handleSessionEnded()
            }
        }
        wsServer.onPdfExportAlarm = { [weak self] deck, slug, failing, detail in
            self?.postPdfExportAlarm(deck: deck, slug: slug, failing: failing, detail: detail)
        }
        wsServer.start()
        self.wsServer = wsServer

        overlayInfo("Starting TabletHttpServer...")
        tabletServer = TabletHttpServer()
        tabletServer?.onAlarmStart = { [weak self] in
            self?.overlayPanel?.refreshScreenFrame()
            self?.animator.startAlarmOverlay()
        }
        tabletServer?.onAlarmStop  = { [weak self] in self?.animator.stopAlarmOverlay() }
        tabletServer?.onEffect = { [weak self] name in
            // If a tablet-routed sound was just started on THIS Mac with
            // Bluetooth compensation, delay the paired visual by the same amount
            // so it stays in sync with the silence-prepended audio. 0 for
            // stop/utility signals and on non-Bluetooth output → fires now.
            let comp = SoundManager.consumePendingVisualCompensation(for: name)
            let fire = {
            self?.overlayPanel?.refreshScreenFrame()
            switch name {
            case "earthquake":    self?.animator.showBrokenGlass(playSound: false)
            case "explosion":     self?.animator.showExplosionGif(playSound: false)
            case "game-over":     self?.animator.showGameOver(playSound: false)
            case "broken-glass":  self?.animator.showBrokenGlass(playSound: false)
            case "pulse":         self?.animator.startPulseOverlay(playSound: false)
            case "pulse/stop":    self?.animator.stopPulseOverlay()
            case "applause":      self?.animator.showApplause(playSound: false)
            case "applause/stop": self?.animator.stopApplause()
            case "heartbeat":     self?.animator.showHeartbeat()
            case "spiral-hearts": self?.animator.showSpiralHearts()
            case "spiral-hearts/stop": self?.animator.stopSpiralHearts()
            case "fireworks":     self?.animator.showFireworks(playSound: false)
            case "fear":          self?.animator.showFear(playSound: false)
            case "fail":          self?.animator.showFail(playSound: false)
            case "blood-drip":    self?.animator.showBloodDrip(playSound: false)
            case "sonar":         self?.animator.showSonar(playSound: true)
            case "sepia":         self?.animator.showSepia(playSound: false)
            case "fire-alarm":      self?.animator.showFireAlarm(playSound: false)
            case "bullet-holes":    self?.animator.showBulletHoles(playSound: false)
            case "phone-ring":      self?.animator.showPhoneRing(playSound: false)
            case "fbi-knock":       self?.animator.showFbiKnock(playSound: false)
            case "brother":         self?.animator.showBrother(playSound: false)
            case "brother/stop":    self?.animator.stopBrother()
            case "gangnam":         self?.animator.showGangnam(playSound: false)
            case "gangnam/stop":    self?.animator.stopGangnam()
            case "love-hands":      self?.animator.showLoveHands(playSound: false)
            case "love-hands/stop": self?.animator.stopLoveHands()
            case "star-wars":       self?.animator.showStarWars(playSound: false)
            case "star-wars/stop":  self?.animator.stopStarWars()
            case "gong":            self?.animator.showGong(playSound: false)
            case "rainbow":         self?.animator.showRainbow(playSound: false)
            case "rainbow/stop":    self?.animator.stopRainbow()
            case "cavalry":         self?.animator.showCavalry(playSound: false)
            case "wrong-x":         self?.animator.showWrongX(playSound: false)
            case "drum-roll":       self?.animator.showDrumRoll(playSound: false)
            case "drum-roll/stop":  self?.animator.stopDrumRoll()
            case "phoenix":         self?.animator.showPhoenix()
            case "money":           self?.animator.showMoneyRise()
            case "iris":            self?.animator.showIrisClose()
            case "minion":          self?.animator.showMinion()
            case "coffee":
                // Test hook (/test/coffee): spawn a few rising ☕ so the hold-charge
                // gesture can be exercised headlessly — hover one, hold 3s, watch it
                // freeze, grow, and explode (starts the break, or shaves 1s off it).
                for _ in 0..<3 { self?.animator.spawnEmoji("☕") }
            case "corner-confetti": self?.animator.spawnCornerConfetti()
            case "game-over/stop":  self?.animator.stopGameOver()
            case "green-flash":
                // Tablet → Mac connectivity confirmation: green screenshot-style border
                if let screen = ScreenCaptureFlash.builtInScreen {
                    ScreenCaptureFlash.flash(on: screen, duration: 4.5, color: .systemGreen)
                }
            case "click":
                // Audible tap — e.g. the tablet's ⟳ reconnect button, paired with
                // the green-flash as "the link works" feedback.
                SoundManager.shared.playOverlapping("click.wav", volume: 0.7)
            case "stop-all":
                SoundManager.shared.stopTabletSound()
                self?.animator.stopAllActiveEffects()
                self?.progressBarOverlay?.cancel()
            default:
                // Tablet timer: "progress-bar/<seconds>" grows a bar over N
                // seconds; "progress-bar/stop" clears it.
                if name.hasPrefix("progress-bar/") {
                    let arg = String(name.dropFirst("progress-bar/".count))
                    if arg == "stop" {
                        self?.progressBarOverlay?.cancel()
                    } else if let secs = Int(arg), secs > 0 {
                        self?.progressBarOverlay?.start(seconds: TimeInterval(secs))
                    }
                }
            }
            }
            if comp > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + comp, execute: fire)
            } else {
                fire()
            }
        }
        // Tablet reports EVERY sound press/stop by bare filename; the Mac owns
        // the sound→effect mapping (SoundEffectMap) and dispatches through the
        // same onEffect path so all sync/compensation logic is reused. Changing
        // a mapping needs only a Mac rebuild — no tablet redeploy.
        tabletServer?.onSoundPressed = { [weak self] file in
            guard let effect = SoundEffectMap.pressEffect(for: file) else { return }
            self?.tabletServer?.onEffect?(effect)
        }
        tabletServer?.onSoundStopped = { [weak self] file in
            guard let effect = SoundEffectMap.stopEffect(for: file) else { return }
            self?.tabletServer?.onEffect?(effect)
        }
        tabletServer?.onOpenUrl = { [weak self] url in
            self?.openUrlInChrome(url)
        }
        // Tablet video page: list downloaded videos, and play one fullscreen in
        // IINA seeking to its manifest start-second (a new play replaces the
        // previous player; VideoPlayer auto-kills it ~60s after start).
        tabletServer?.onVideos = { VideoLibrary.manifestJSON() }
        tabletServer?.onVideoPlay = { id, tOverride in
            guard let entry = VideoLibrary.entry(id: id) else { return nil }
            let start = tOverride ?? entry.startSeconds
            let ok = VideoPlayer.shared.play(fileURL: VideoLibrary.fileURL(for: entry), startSeconds: start)
            guard ok else { return nil }
            return "{\"ok\":true,\"id\":\"\(id)\",\"startSeconds\":\(start)}"
        }
        tabletServer?.onVideoStop = { VideoPlayer.shared.stop() }
        // Tablet → Mac sound routing: the tablet pings every 5s to detect the
        // Mac and compares soundsHash to detect a stale Mac bundle; when its
        // "MAC" toggle is pressed it routes soundboard playback here instead
        // of playing locally (one sound at a time, new play preempts).
        tabletServer?.onPing = { [weak self] in
            self?.lastTabletPingAt = Date()
            // Carry the Mac's wall time so the tablet can render its clock in sync
            // with the system (its own device clock/timezone is often wrong while
            // travelling). We send both the absolute epoch (corrects a wrong clock)
            // and the timezone id (corrects a wrong timezone) — the tablet formats
            // the epoch in this timezone to match exactly what the Mac shows.
            let macMs = Int64(Date().timeIntervalSince1970 * 1000)
            let macTz = TimeZone.current.identifier
            // Advertise the Mac's own LAN IPs so the tablet — which receives this
            // even over the Railway relay — can probe us DIRECTLY on the shared
            // Wi-Fi (bypassing mDNS, which hotspots filter) and prefer that
            // lower-latency local path, keeping the internet relay a last resort.
            let macLanIps = NetworkInfo.lanIPv4Addresses()
                .map { "\"\($0)\"" }.joined(separator: ",")
            return "{\"ok\":true,\"soundsHash\":\"\(SoundsManifest.combinedHash)\",\"macTimeMs\":\(macMs),\"macTz\":\"\(macTz)\",\"macLanIps\":[\(macLanIps)]}"
        }
        tabletServer?.onSoundsManifest = { SoundsManifest.manifestJSON }
        tabletServer?.onSoundPlay = { [weak self] name, volumePct in
            // The radar sound drives the full 🛰️ Sonar effect (animation + its own
            // beep-synced audio) instead of plain routed playback — the Mac owns
            // this one, so we don't ALSO play it via playTabletSound.
            if name == "23_radar.mp3" {
                self?.animator.showSonar(playSound: true)
                return "{\"ok\":true,\"durationMs\":5459}"
            }
            // Tile #53 ("53_rain.mp3") was repurposed into 💸 Money: every press
            // fires one round of dollars rising up the screen and plays the
            // checkmark "ching" (#57) instead of the original rain. Driven from
            // the routed play path (like the radar) and kept OUT of
            // SoundEffectMap so a single press = a single ching + a single round
            // (no double-trigger); repeated presses stack overlapping rounds.
            if name == "53_rain.mp3" {
                self?.animator.showMoneyRise()
                let volume = volumePct.map { Float($0) / 100 }
                // Layer the ching (overlapping pool) instead of preempting, so
                // hammering the tile STACKS overlapping chings to match the
                // stacking rounds of rising dollars — rather than each press
                // cutting the previous sound off.
                guard let duration = SoundManager.shared.playOverlappingTabletSound("57_checkmark.mp3", volume: volume) else { return nil }
                return "{\"ok\":true,\"durationMs\":\(Int(duration * 1000))}"
            }
            // Tile #31 (🕳️ iris close): formerly silent by design — now plays the
            // dramatic gong (`50_gong.mp3`, ~8.6s ≈ the iris length) so EVERY
            // tablet thumbnail is audible on the Mac. The blackout visual is still
            // driven by the press path (SoundEffectMap: 31_tarzan.mp3 → "iris").
            if name == "31_tarzan.mp3" {
                let volume = volumePct.map { Float($0) / 100 }
                guard let duration = SoundManager.shared.playTabletSound("50_gong.mp3", volume: volume) else { return nil }
                return "{\"ok\":true,\"durationMs\":\(Int(duration * 1000))}"
            }
            // Tile #34 (🔥 Phoenix): the Mac owns the phoenix cry (`phoenix.mp3`,
            // played inside showPhoenix, faded in unison with the visual). The
            // tablet's `34_phoenix.mp3` is a silent placeholder, so skip routed
            // playback here — the press path (SoundEffectMap: 34_phoenix.mp3 →
            // "phoenix") drives both the visual and the real sound.
            if name == "34_phoenix.mp3" {
                return "{\"ok\":true,\"durationMs\":1}"
            }
            // Tile #80 (🍌 badumtss → animated minion face): SILENT by design —
            // play NOTHING here. The looping minion face is driven by the press
            // path (SoundEffectMap: 80_badumtss.mp3 → "minion"). Return the minion's
            // on-screen duration so the NON-restartable tile stays "playing" for that
            // window: a re-tap within it fires /effect/stop-all (which tears the
            // tracked minion layer down) instead of restarting — that's the
            // "stop when pressed again". Unlike radar/money, this branch does NOT
            // trigger the effect (the press path already does).
            if name == "80_badumtss.mp3" {
                return "{\"ok\":true,\"durationMs\":\(Int(EmojiAnimator.minionDuration * 1000))}"
            }
            // Tile #27 (👏 Applause): play the clapping clip 30% SHORTER — the Mac
            // clips `27_clapping.mp3` to 70% of its length (fading the tail out)
            // so the audible clapping matches the trimmed GIF visual. Return the
            // clipped duration so the tablet's effect-stop chain lines up. The
            // visual is still driven by the press path (SoundEffectMap → "applause").
            if name == "27_clapping.mp3" {
                let volume = volumePct.map { Float($0) / 100 }
                guard let duration = SoundManager.shared.playTabletSoundClipped("27_clapping.mp3", fraction: 0.7, volume: volume) else { return nil }
                return "{\"ok\":true,\"durationMs\":\(Int(duration * 1000))}"
            }
            let volume = volumePct.map { Float($0) / 100 }
            guard let duration = SoundManager.shared.playTabletSound(name, volume: volume) else { return nil }
            return "{\"ok\":true,\"durationMs\":\(Int(duration * 1000))}"
        }
        tabletServer?.onSoundVolume = { pct in
            SoundManager.shared.setTabletVolume(Float(pct) / 100)
        }
        tabletServer?.onSoundStop = { SoundManager.shared.stopTabletSound() }
        // Bluetooth wake-up compensation slider (tablet header). The tablet owns
        // the persisted value and re-pushes it on every (re)connect, so the Mac
        // just applies whatever it's told; the file default seeds the tablet's
        // slider the first time via the GET below.
        tabletServer?.onBtCompensationGet = {
            let ms = Int((SoundTimingConfig.shared.effectiveBluetoothCompensationSeconds * 1000).rounded())
            let maxMs = Int((SoundTimingConfig.maxCompensationSeconds * 1000).rounded())
            return "{\"ms\":\(ms),\"maxMs\":\(maxMs)}"
        }
        tabletServer?.onBtCompensationSet = { ms in
            SoundTimingConfig.shared.setBluetoothCompensation(seconds: Double(ms) / 1000.0)
            let applied = Int((SoundTimingConfig.shared.effectiveBluetoothCompensationSeconds * 1000).rounded())
            return "{\"ok\":true,\"ms\":\(applied)}"
        }
        // Watchdog: if the tablet stops pinging (crash, network drop) while a
        // tablet-routed sound is playing, stop it — otherwise a long sound
        // would blare on with no way to stop it from the tablet.
        tabletSoundWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, SoundManager.shared.isTabletSoundPlaying,
                  let last = self.lastTabletPingAt, Date().timeIntervalSince(last) > 12 else { return }
            overlayInfo("Tablet ping lost >12s — stopping tablet-routed sound")
            SoundManager.shared.stopTabletSound()
        }
        // Warm up the sounds manifest (~15MB of SHA-256) off the main thread
        // so the first /ping doesn't pay for it.
        DispatchQueue.global(qos: .utility).async { _ = SoundsManifest.combinedHash }
        tabletServer?.onPromptCapture = { [weak self] prompt in
            guard let self else { return "{\"captured\":false,\"reason\":\"shutting-down\"}" }
            guard self.isSessionActive else {
                return "{\"captured\":false,\"reason\":\"no-session\"}"
            }
            SessionNotesAppender.offerPrompt(prompt)
            return "{\"captured\":true}"
        }
        tabletServer?.start()
        overlayInfo("TabletHttpServer.start() called")

        // Railway bridge: the tablet's last-resort internet transport. Reuses the
        // whole TabletHttpServer route table via respond(), so every LAN/USB
        // endpoint also works over the internet. Off unless a token is configured
        // (env ADDON_BRIDGE_TOKEN or the ~/.training-assistants-secrets.env key).
        if let tabletServer {
            let env = ProcessInfo.processInfo.environment
            let bridgeToken = env["ADDON_BRIDGE_TOKEN"]
                ?? SecretsLoader.load()["ADDON_BRIDGE_TOKEN"] ?? ""
            let bridgeURL = env["ADDON_BRIDGE_URL"] ?? serverURL
            if let bridge = RailwayBridgeClient(baseURL: bridgeURL, token: bridgeToken, server: tabletServer) {
                bridge.start()
                railwayBridge = bridge
                overlayInfo("RailwayBridgeClient started (\(bridgeURL))")
            }
        }

        menuBarManager = MenuBarManager()
        menuBarManager.onQuit = { [weak self] in
            self?.whisperManager?.stop()
        }
        let whisperManager = WhisperProcessManager()
        self.whisperManager = whisperManager
        let watcher = TranscriptionWatcher(transcriptionFolder: transcriptionFolder)
        watcher.onStaleChanged = { [weak self] stale in
            self?.menuBarManager.setTranscriptionStale(stale)
            self?.silentTranscriptionWarning?.setStale(stale)
        }
        self.transcriptionWatcher = watcher
        whisperManager.onStateChanged = { [weak self] running in
            self?.menuBarManager.setTranscribing(running)
            if running {
                self?.transcriptionWatcher?.startWatching()
                self?.silentTranscriptionWarning?.transcriptionStarted()
                if self?.pendingAutoRestartBanner == true {
                    self?.pendingAutoRestartBanner = false
                    self?.statusBanner?.showOnPresence(text: "started", sound: StatusBannerSound.start)
                }
            } else {
                self?.transcriptionWatcher?.stopWatching()
                self?.silentTranscriptionWarning?.transcriptionStopped()
            }
        }
        whisperManager.onDeviceChanged = { [weak self] emoji in
            self?.menuBarManager.setTranscribeSource(emoji)
        }
        whisperManager.onAvailableDevicesChanged = { [weak self] devices in
            self?.menuBarManager.setAvailableSources(devices)
        }
        let startWhisper: () -> Void = { [weak whisperManager, weak self] in
            var env: [String: String] = [:]
            if let folder = self?.transcriptionFolder {
                env["TRANSCRIPTION_FOLDER"] = folder.path
                env["WHISPER_PREFERRED_SOURCE_FILE"] = folder.appendingPathComponent(".preferred-me-source").path
            }
            DispatchQueue.global(qos: .userInitiated).async {
                whisperManager?.start(env: env)
            }
        }
        let stopWhisper: () -> Void = { [weak whisperManager] in
            whisperManager?.stop()
        }

        // Whisper runs whenever we're on AC and pauses on battery — nothing
        // else. The controller owns that decision plus a 60s heartbeat that
        // restarts Whisper if it died while still plugged in.
        let controller = TranscriptionController(isWhisperRunning: { [weak whisperManager] in
            whisperManager?.isRunning == true
        })
        controller.onStart = startWhisper
        controller.onStop = stopWhisper
        controller.onAutoRestart = { [weak self] in
            // Whisper died while on AC — the heartbeat is bringing it back.
            // Arm the "started" banner; it fires once whisper is confirmed running.
            self?.pendingAutoRestartBanner = true
        }
        controller.onPausedByBatteryChanged = { [weak self] paused in
            self?.menuBarManager.setTranscriptionPausedByBattery(paused)
        }
        self.transcriptionController = controller

        let pm = PowerMonitor()
        pm.onSwitchToBattery = { [weak self, weak controller] in
            controller?.powerDidChange()
            self?.statusBanner?.showOnPresence(text: "paused on battery", sound: StatusBannerSound.stop)
        }
        pm.onSwitchToAC = { [weak self, weak controller] in
            controller?.powerDidChange()
            self?.statusBanner?.showOnPresence(text: "resumed on AC", sound: StatusBannerSound.start)
        }
        pm.start()
        self.powerMonitor = pm

        // Auto display arrangement for the projector workflow. On projector
        // connect: mirror the Retina at 1080p + make the ASUS primary; on
        // disconnect: revert to Retina-main + ASUS-right. Fires only on changes
        // (never on launch); the 🖥️ menu item + /test/projector force it.
        // Presentation detector: OR of (unknown external display) + (live
        // meeting). Gates the aggressive silent-transcription warning.
        let presentation = PresentationDetector()
        presentation.onPresentingChanged = { [weak self] presenting in
            self?.silentTranscriptionWarning?.setPresenting(presenting)
        }
        self.presentationDetector = presentation

        let displayMgr = DisplayArrangementManager(knownDisplays: knownDisplays)
        // Show the monitor-change notification immediately (not presence-gated):
        // the user is looking at the screen the instant the layout reconfigures.
        displayMgr.onArrangementApplied = { [weak self] banner in
            self?.statusBanner?.showNow(text: banner, sound: StatusBannerSound.start, visibleDuration: 8.0)
        }
        // A venue projector / room TV (unknown external) → presenting.
        displayMgr.onUnknownExternalChanged = { [weak presentation] present in
            presentation?.setUnknownDisplayPresent(present)
        }
        displayMgr.start()
        self.displayArrangementManager = displayMgr

        // Keep the wired USB backup armed: re-run `adb reverse` on a timer so
        // plugging the tablet in mid-session restores the no-WiFi path within
        // ~20s (start.sh only arms it once, at launch).
        let usbTunnel = UsbTunnelKeeper()
        usbTunnel.start()
        self.usbTunnelKeeper = usbTunnel
        // /test/group-photo — show the overlay now, bypassing the break + daemon gates.
        tabletServer?.onTestGroupPhoto = { [weak self] in
            DispatchQueue.main.async { self?.promptGroupPhoto() }
        }

        tabletServer?.onTestWisprOutputDrift = { [weak self] in
            DispatchQueue.main.async {
                let name = self?.coreAudioManager?.currentDefaultOutputName() ?? "?"
                self?.postWisprOutputDriftNotification(output: name)
            }
        }

        tabletServer?.onTestBreakSummary = {
            // Headless trigger of the ☕️ break-summary delta — same Terminal flow
            // a real >= 5 min break fires, but bypassing the minutes + cooldown gates.
            BreakSummaryLauncher.launchNow(reason: "/test/break-summary")
        }


        tabletServer?.onTestTranscriptionStart = {
            // Headless force-(re)start of Whisper for E2E checks. The start
            // call is a no-op if it's already running.
            startWhisper()
        }
        tabletServer?.onTestWisprRecording = { [weak self] in
            guard let manager = self?.coreAudioManager else {
                return "{\"error\":\"coreAudioManager unavailable\"}"
            }
            let recording = manager.probeWisprRecording()
            return "{\"recording\":\(recording)}"
        }
        tabletServer?.onTestBreakStart = { [weak self] minutes in
            DispatchQueue.main.async { self?.breakTimer.start(minutes: minutes) }
        }
        tabletServer?.onTestBreakUntil = { [weak self] in
            // Same overlay a floating-☕ click produces: half-size "UNTIL BREAK".
            DispatchQueue.main.async { self?.breakTimer.start(minutes: 10, title: "UNTIL BREAK", sizeScale: 0.5) }
        }
        tabletServer?.onTestBreakClose = { [weak self] in
            DispatchQueue.main.async { self?.breakTimer.close() }
        }
        tabletServer?.onTestBreakPicker = { [weak self] q in
            DispatchQueue.main.async { self?.breakTimer.openCountryPicker(query: q) }
        }
        tabletServer?.onTestTile = { [weak menuBarManager] in menuBarManager?.onTileTerminals?() }
        tabletServer?.onTestWhip = { [weak menuBarManager] in menuBarManager?.onWhip?() }
        tabletServer?.onTestWhipCrack = { [weak self] in
            DispatchQueue.main.async { self?.whipController?.forceCrack() }
        }
        // /test/projector — force-apply the display arrangement now and return a
        // JSON snapshot of what was detected + applied. The HTTP route switch
        // already runs inside `DispatchQueue.main.sync`, so this callback is
        // already on the main thread — call directly (a nested main.sync would
        // deadlock), which is also where Quartz reconfiguration must happen.
        tabletServer?.onTestProjector = { [weak self] in
            self?.displayArrangementManager?.forceApplyAndSnapshot()
                ?? "{\"error\":\"display manager unavailable\"}"
        }
        // /test/presentation — JSON snapshot of the presenting state + detection.
        tabletServer?.onTestPresentation = { [weak self] in
            self?.presentationSnapshotJSON() ?? "{\"error\":\"unavailable\"}"
        }
        // /test/presentation/warn — force-show the aggressive silent warning now.
        tabletServer?.onTestPresentationWarn = { [weak self] in
            self?.silentTranscriptionWarning?.forceShow()
        }
        tabletServer?.onTestAudioPlaying = { [weak self] in
            guard let manager = self?.coreAudioManager else {
                return "{\"error\":\"coreAudioManager unavailable\"}"
            }
            let probe = manager.probeOutputLoopback()
            var payload: [String: Any] = [
                "device": probe.deviceName,
                "device_found": probe.deviceFound,
                "rms_threshold": probe.rmsThreshold,
                "peak_threshold": probe.peakThreshold,
            ]
            if let rms = probe.rms { payload["rms"] = rms }
            if let peak = probe.peak { payload["peak"] = peak }
            if let playing = probe.playing { payload["playing"] = playing }
            if !probe.deviceFound {
                payload["error"] = "device not found"
            } else if probe.rms == nil {
                payload["error"] = "tap failed"
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return "{\"error\":\"failed to encode probe\"}"
            }
            return json
        }
        tabletServer?.onTestState = { [weak self, weak whisperManager] in
            guard let self, let menuBarManager = self.menuBarManager else {
                return "{\"error\":\"app state unavailable\"}"
            }
            let ui = menuBarManager.transcriptionDebugState()
            let payload: [String: Any] = [
                "running": whisperManager?.isRunning == true,
                "on_ac": PowerMonitor.isOnAC(),
                "paused_battery": ui.isPausedByBattery,
                "ui_transcribing": ui.isTranscribing,
                "ui_stale": ui.isStale,
                "menu_title": ui.menuTitle,
                "icon_mode": ui.iconMode,
                "source": ui.source,
                "event_tap_active": self.eventTapManager?.isActive == true,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return "{\"error\":\"failed to encode state\"}"
            }
            return json
        }
        menuBarManager.onDesktopEffect = { [weak self] name in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // When the Mac's own output is Bluetooth, warm the A2DP link and
                // shift the WHOLE effect later by the compensation, so the
                // leading edge isn't clipped. Zero on non-Bluetooth output →
                // fires immediately, exactly as before.
                let comp = SoundTimingConfig.shared.currentBluetoothCompensation
                if comp > 0 { BluetoothOutput.playWakeTone(seconds: comp) }
                let fire = {
                self.overlayPanel?.refreshScreenFrame()
                // Menu-triggered effects are SILENT (`playSound: false`) and run
                // for a fixed, sound-independent duration: looping effects are
                // stopped after `menuEffectDuration`; one-shots keep their own
                // natural length. (The tablet path — onEffect — still derives
                // duration from the routed sound.)
                let stopAfter: (@escaping () -> Void) -> Void = { stop in
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.menuEffectDuration, execute: stop)
                }
                switch name {
                case "heart":        self.animator.spawnEmoji("❤️")
                case "confetti":     self.animator.spawnConfetti()
                case "zorro":        self.animator.showZorro()
                case "fear":         self.animator.showFear(playSound: false)
                case "fail":         self.animator.showFail(playSound: false)
                case "sepia":        self.animator.showSepia(playSound: false)
                case "fireworks":    self.animator.showFireworks(playSound: false)
                case "applause":     self.animator.showApplause(playSound: false); stopAfter { self.animator.stopApplause() }
                case "heartbeat":    self.animator.showHeartbeat()
                case "spiral-hearts": self.animator.showSpiralHearts(); stopAfter { self.animator.stopSpiralHearts() }
                case "explosion":    self.animator.showExplosionGif(playSound: false)
                case "broken-glass": self.animator.showBrokenGlass(playSound: false)
                case "game-over":    self.animator.showGameOver(playSound: false); stopAfter { self.animator.stopGameOver() }
                case "pulse":        self.animator.startPulseOverlay(playSound: false); stopAfter { self.animator.stopPulseOverlay() }
                case "fire-alarm":       self.animator.showFireAlarm(playSound: false)
                case "bullet-holes":    self.animator.showBulletHoles(playSound: false)
                case "phone-ring":      self.animator.showPhoneRing(playSound: false)
                case "fbi-knock":       self.animator.showFbiKnock(playSound: false)
                case "brother":         self.animator.showBrother(playSound: false); stopAfter { self.animator.stopBrother() }
                case "gangnam":         self.animator.showGangnam(playSound: false); stopAfter { self.animator.stopGangnam() }
                case "love-hands":      self.animator.showLoveHands(playSound: false); stopAfter { self.animator.stopLoveHands() }
                case "star-wars":       self.animator.showStarWars(playSound: false); stopAfter { self.animator.stopStarWars() }
                case "gong":            self.animator.showGong(playSound: false)
                case "rainbow":         self.animator.showRainbow(playSound: false); stopAfter { self.animator.stopRainbow() }
                case "cavalry":         self.animator.showCavalry(playSound: false)
                case "wrong-x":         self.animator.showWrongX(playSound: false)
                case "drum-roll":       self.animator.showDrumRoll(playSound: false); stopAfter { self.animator.stopDrumRoll() }
                case "phoenix":         self.animator.showPhoenix()
                case "money":           self.animator.showMoneyRise()
                case "iris":            self.animator.showIrisClose()
                case "laugh":           self.animator.showLaugh()
                case "corner-confetti": self.animator.spawnCornerConfetti()
                case "green-flash":
                    if let screen = ScreenCaptureFlash.builtInScreen {
                        ScreenCaptureFlash.flash(on: screen, duration: 4.5, color: .systemGreen)
                    }
                default: break
                }
                }
                if comp > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + comp, execute: fire)
                } else {
                    fire()
                }
            }
        }
        menuBarManager.onCopyGit = { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let url = GitCopier.copyIntelliJGit() else { return }
                DispatchQueue.main.async { self?.showBanner(forGitUrl: url) }
            }
        }
        menuBarManager.onOpenCalendar = { [weak self] in
            DispatchQueue.main.async { self?.openUrlInChrome("https://calendar.google.com/") }
        }
        menuBarManager.onOpenCatalog = {
            DispatchQueue.global(qos: .userInitiated).async {
                let path = NSHomeDirectory() + "/My Drive/Clients/Catalog.docx"
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Microsoft Word.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
        }
        menuBarManager.onToggleDarkMode = {
            DispatchQueue.global(qos: .userInteractive).async { DarkModeToggle.toggle() }
        }
        menuBarManager.onTileTerminals = {
            DispatchQueue.global(qos: .userInitiated).async { TerminalTiler.tile() }
        }
        menuBarManager.onFixDisplayLayout = { [weak self] in
            self?.displayArrangementManager?.applyNow()
        }
        menuBarManager.onMonitor = { [weak self] in
            self?.openTranscriptionMonitor()
        }
        menuBarManager.onTailPreview = { [weak self] in
            self?.transcriptionTailPreview()
        }
        menuBarManager.onPickSource = { [weak self] pattern in
            self?.writePreferredSource(pattern)
        }
        menuBarManager.onMenuOpened = { [weak self] in
            // Opening the app menu is a clear "I'm done with the link" signal —
            // hide the banner + QR immediately so it never lingers on the screen.
            if self?.joinLinkBanner?.bannerIsVisible == true {
                self?.joinLinkBanner?.hide()
            }
        }
        menuBarManager.onTakeScreenshot = { toClipboard in
            DispatchQueue.global(qos: .userInitiated).async { ScreenshotManager.takeScreenshot(toClipboard: toClipboard) }
        }

        // Initialize join link banner
        joinLinkBanner = JoinLinkBanner(screen: builtInScreen)
        statusBanner = StatusBanner(screensProvider: { NSScreen.screens })
        silentTranscriptionWarning = SilentTranscriptionWarning(screensProvider: { NSScreen.screens })
        promptCaptureBanner = BottomLeftBanner(screensProvider: { NSScreen.screens }, hoverable: true)
        SessionNotesAppender.promptBanner = promptCaptureBanner
        menuBarManager.onDisplayJoinLink = { [weak self] in
            self?.toggleJoinLinkBanner()
        }
        menuBarManager.onDisplayClipboardLink = { [weak self] in
            self?.displayClipboardLinkBanner()
        }
        menuBarManager.onAppendClipboardToNotes = {
            DispatchQueue.global(qos: .userInitiated).async { SessionNotesAppender.appendClipboard() }
        }
        menuBarManager.onEmojiOverlayEnabledChanged = { [weak self] enabled in
            if !enabled {
                self?.keymapHoldCoordinator?.reset()
            }
        }

        let portKiller = PortKiller()
        self.portKiller = portKiller
        menuBarManager.onKillPort = { port in
            DispatchQueue.global(qos: .userInitiated).async { portKiller.kill(port: port) }
        }
        menuBarManager.onKillPortPrompt = { portKiller.showPortPrompt() }

        // 🔥 Whip Claude — toggle the playful "interrupt Claude" overlay. ⌃W shows
        // it; a second ⌃W (or Esc) dismisses it.
        menuBarManager.onWhip = { [weak self] in
            DispatchQueue.main.async {
                self?.toggleWhip()
            }
        }

        // ☕️ Break — start/reset the countdown watch overlay for the chosen duration.
        // (The break no longer auto-launches the training-summary delta; that run is
        // now only triggered manually via the /test/break-summary hook.)
        menuBarManager.onBreak = { [weak self] minutes in
            DispatchQueue.main.async {
                guard let self else { return }
                self.breakTimer.start(minutes: minutes)
                // A group photo makes sense during a longer break: the 1h lunch
                // (any time) or an afternoon (≥13:00) break of ≥10 min — and only
                // when there's an audience connected to gather for the shot.
                if self.daemonConnected,
                   GroupPhotoBreakPolicy.shouldPrompt(breakMinutes: minutes, at: Date()) {
                    self.promptGroupPhoto()
                }
            }
        }
        // Resume an in-progress break after a redeploy/restart.
        DispatchQueue.main.async { [weak self] in self?.breakTimer.resumeIfNeeded() }

        menuBarManager.setup()
        // Start from a not-running UI; the controller flips it on once Whisper
        // is actually up (or shows the battery-paused state).
        menuBarManager.setTranscribing(false)

        let detector = MeetingDetector()
        // A live Zoom/Teams/Webex/Meet call (an app driving the 🎙️TO Zoom
        // virtual device) → presenting.
        detector.onMeetingChanged = { [weak self] active in
            self?.presentationDetector?.setMeetingActive(active)
        }
        meetingDetector = detector
        detector.checkInitialState()

        // The "Resumed Xm ago" menu clock now tracks OUR break timer — the ✕ button
        // or the countdown expiring — not the external Timer RH app. breakEndedAt is
        // persisted (UserDefaults), so it survives an app restart.
        breakTimer.onEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBarManager.breakEndedAt = Date()
                self?.scheduleBreakReminder()
            }
        }
        ScreenshotManager.onScreenshotTaken = { [weak menuBarManager] in
            DispatchQueue.main.async {
                menuBarManager?.flashScreenshotIcon()
            }
        }
        // Apply the current power state (start Whisper if on AC) and arm the
        // crash-recovery heartbeat. Single launch entry point.
        controller.start()

        let secrets = SecretsLoader.load()
        let apiKey = secrets["WISPR_CLEANUP_ANTHROPIC_API_KEY"] ?? ""
        let pasteHandler = EmotionalPasteHandler(apiKey: apiKey)
        self.emotionalPasteHandler = pasteHandler

        let audioManager = CoreAudioManager()
        self.coreAudioManager = audioManager
        audioManager.onWisprOutputDrift = { [weak self] outputName in
            DispatchQueue.main.async { self?.postWisprOutputDriftNotification(output: outputName) }
        }
        audioManager.start()

        let btKeepAlive = BluetoothKeepAlive()
        self.bluetoothKeepAlive = btKeepAlive
        btKeepAlive.start()

        let eventTap = EventTapManager()
        eventTap.onCaptureClipboard = { [weak pasteHandler] text in
            pasteHandler?.captureText(text)
        }
        eventTap.onEmotionalPaste = { [weak pasteHandler] in pasteHandler?.handleCleanHotkey() }
        eventTap.onScreenshot = { toClipboard in DispatchQueue.global(qos: .userInitiated).async { ScreenshotManager.takeScreenshot(toClipboard: toClipboard) } }
        eventTap.onToggleDarkMode = {
            DispatchQueue.global(qos: .userInteractive).async { DarkModeToggle.toggle() }
        }
        eventTap.onOpenCatalog = { [weak menuBarManager] in menuBarManager?.onOpenCatalog?() }
        eventTap.onTileTerminals = { [weak menuBarManager] in menuBarManager?.onTileTerminals?() }
        eventTap.onWhip = { [weak menuBarManager] in menuBarManager?.onWhip?() }
        eventTap.onWhipCrack = { [weak self] in self?.whipController?.forceCrack() }
        eventTap.onRepaste = {
            DispatchQueue.global().async { KeySimulator.simulateCtrlOptSpace() }
        }
        eventTap.onClaudeWorkspaceHotkey = { [weak menuBarManager] in
            DispatchQueue.main.async { menuBarManager?.openDreamPlainWorkspace() }
        }
        eventTap.onMouseButton5Pressed = { [weak audioManager] in
            audioManager?.notifyMouseButton5Pressed()
        }
        eventTap.onAppendClipboardToNotes = {
            DispatchQueue.global(qos: .userInitiated).async { SessionNotesAppender.appendClipboard() }
        }
        eventTap.onCopySelectionToNotes = {
            DispatchQueue.global(qos: .userInitiated).async { SessionNotesAppender.copySelectionAndAppend() }
        }
        eventTap.onOpenCalendar = { [weak menuBarManager] in
            menuBarManager?.onOpenCalendar?()
        }
        eventTap.onModifierFlagsChanged = { [weak self] option, shift in
            guard KeymapOverlaySettings.isEnabled else {
                self?.keymapHoldCoordinator?.reset()
                return
            }
            self?.keymapHoldCoordinator?.modifierFlagsChanged(option: option, shift: shift)
        }
        eventTap.onKeyDownWhileOptionHeld = { [weak self] in
            self?.keymapHoldCoordinator?.keyDownWhileOptionHeld()
        }
        eventTap.onCtrlVPaste = { ClipboardStackManager.shared.onCtrlVPaste() }
        eventTap.start()
        self.eventTapManager = eventTap

        // Clipboard image stack: ⌃P screenshots accumulate; ⌃V pastes then pops
        // to the next-older image (Claude Code / Copilot CLI image workflow).
        ClipboardStackManager.shared.start()

        self.driveShareCache = GoogleDriveShareCache()

        let pptMonitor = PowerPointMonitor()
        pptMonitor.onSlideChange = { [weak self] event in
            self?.wsServer?.pushSlide(event)
            self?.checkSlideSharedState(event: event)
        }
        pptMonitor.onSlidesViewed = { [weak self] slides in
            self?.wsServer?.pushSlidesViewed(slides)
        }
        pptMonitor.start()
        self.pptMonitor = pptMonitor

        // IntelliJ open-file reporting is now driven by the live-coding IntelliJ plugin, which
        // POSTs accurate data to /intellij/file-opened (wired below). The AppleScript window-title
        // scraper is kept for reference but no longer started — the plugin is the single source.
        let ijMonitor = IntelliJMonitor(outputDir: transcriptionFolder)
        ijMonitor.onGitFileOpened = { [weak self] url, branch, file, fileURL in
            self?.wsServer?.pushGitFileOpened(url: url, branch: branch, file: file, fileURL: fileURL)
        }
        // ijMonitor.start()  // disabled: superseded by the IntelliJ plugin push
        self.ijMonitor = ijMonitor

        // IntelliJ plugin → POST /intellij/file-opened → forward to the daemon via the WS bridge.
        tabletServer?.onIntellijFileOpened = { [weak self] body in
            guard let data = body.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rawUrl = json["url"] as? String, !rawUrl.isEmpty,
                  let file = json["file"] as? String, !file.isEmpty else {
                return "{\"ok\":false,\"reason\":\"bad-request\"}"
            }
            let url = IntelliJMonitor.httpsRemote(rawUrl)
            let branch = (json["branch"] as? String) ?? ""
            // Daemon ignores branch/fileURL and builds the default-branch blob URL itself.
            self?.wsServer?.pushGitFileOpened(url: url, branch: branch, file: file, fileURL: nil)
            // Bottom-left flash only while a session is live — outside a session a file
            // opening in IntelliJ is just noise (the daemon discards the push too).
            if self?.isSessionActive == true {
                self?.statusBanner?.showOnPresence(text: "📄 " + (file as NSString).lastPathComponent,
                                                   sound: nil, visibleDuration: 3.0)
            }
            return "{\"ok\":true}"
        }

        // Check every 2s if another instance took over the PID file
        pidCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPIDFile()
        }

        registerSleepWakeObservers()
    }

    // MARK: - Sleep/wake handling
    //
    // libportaudio's Pa_Terminate double-frees an internal buffer when CoreAudio
    // republishes devices on wake, crashing the whisper subprocess with SIGABRT
    // ~9s after wake. Stop whisper before sleep (SIGKILL, skipping the broken
    // teardown path) and restart it after wake once CoreAudio has settled.
    private var wasTranscribingBeforeSleep = false

    /// Open the URL as a new tab in the user's frontmost Chrome window so it
    /// inherits that window's profile — YouTube Premium / signed-in / no ads.
    /// `make new window` and `--user-data-dir=…` were tried first but both
    /// fell back to Chrome's empty "Default" profile.
    private func openUrlInChrome(_ url: String) {
        overlayInfo("Opening Chrome (front-window profile): \(url)")
        let openTask = Process()
        openTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openTask.arguments = ["-a", "Google Chrome", url]
        do {
            try openTask.run()
        } catch {
            overlayError("Failed to open URL in Chrome: \(error)")
            return
        }
        // Give Chrome a moment to surface the new tab in its front window,
        // then yank that window onto the built-in Retina display so the
        // video lands on the main monitor regardless of where Chrome was.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.moveFrontChromeWindowToRetina()
        }
    }

    private func moveFrontChromeWindowToRetina() {
        let screen = AppDelegate.findRetinaScreen()
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen).frame.height
        let f = screen.visibleFrame
        // AppleScript window bounds use a top-left origin where Y grows down,
        // measured from the top of the primary (menu-bar) display.
        let x1 = Int(f.minX)
        let y1 = Int(primaryHeight - f.maxY)
        let x2 = Int(f.maxX)
        let y2 = Int(primaryHeight - f.minY)
        let script = """
        tell application "Google Chrome"
            if (count of windows) > 0 then
                set bounds of front window to {\(x1), \(y1), \(x2), \(y2)}
            end if
        end tell
        """
        DispatchQueue.global().async {
            _ = AppleScriptRunner.run(script)
        }
    }

    private func registerSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(handleWillSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleDidWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func handleWillSleep() {
        let running = whisperManager?.isRunning == true
        wasTranscribingBeforeSleep = running
        if running {
            overlayInfo("System sleeping — SIGKILL whisper to avoid PortAudio wake crash")
            whisperManager?.killImmediate()
        }
    }

    @objc private func handleDidWake() {
        guard wasTranscribingBeforeSleep else { return }
        wasTranscribingBeforeSleep = false
        guard PowerMonitor.isOnAC() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard PowerMonitor.isOnAC(), self.whisperManager?.isRunning != true else { return }
            overlayInfo("System woke — restarting whisper")
            let env: [String: String] = [
                "TRANSCRIPTION_FOLDER": self.transcriptionFolder.path,
                "WHISPER_PREFERRED_SOURCE_FILE": self.transcriptionFolder.appendingPathComponent(".preferred-me-source").path,
            ]
            self.pendingAutoRestartBanner = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.whisperManager?.start(env: env)
            }
        }
    }

    // MARK: - Coffee-hover → "until break" timer

    /// Resting the cursor on a floating ☕ (that participants fire) FREEZES it and
    /// starts a hold-charge: it stops rising and grows for 3s, then explodes. We POLL
    /// the mouse-vs-coffee overlap (0.1s) rather than watch `.mouseMoved`, so a
    /// deliberate hold registers even with a perfectly still cursor. The 3-second
    /// hold — not a mere graze — is what triggers the payoff, so it can now run even
    /// while a break is up without accidental firing:
    ///   • no break showing → the explosion STARTS the 10-min "UNTIL BREAK" timer;
    ///   • break already running → the explosion SHAVES 1s off the remaining time
    ///     (repeat the gesture on more coffees to keep shortening the wait).
    private func installCoffeeBreakHoverMonitor() {
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.animator?.tickCoffeeCharge(cursorGlobalPoint: NSEvent.mouseLocation) == true else { return }
            if self.breakTimer.isShowing {
                overlayInfo("☕ held 3s → −1s off the break")
                self.breakTimer.addSeconds(-1)
            } else {
                overlayInfo("☕ held 3s → starting 10-min UNTIL BREAK timer")
                self.breakTimer.start(minutes: 10, title: "UNTIL BREAK", sizeScale: 0.5)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        coffeeHoverTimer = t
    }

    // MARK: - Break reminder

    /// Subtle bottom-left nudge 1h 15m after the most recent resume, prompting
    /// the trainer to ask if anyone wants a break. Latest-wins: a fresh resume
    /// cancels the previous pending reminder.
    private func scheduleBreakReminder() {
        breakReminderTimer?.invalidate()
        breakReminderTimer = Timer.scheduledTimer(withTimeInterval: 75 * 60, repeats: false) { [weak self] _ in
            self?.statusBanner?.showOnPresence(
                text: "Hit ☕ to request a break",
                sound: nil,
                visibleDuration: 7.0
            )
        }
    }

    // MARK: - Signal-based toggle (SIGUSR1 from wispr-flow menu)

    private func setupSignalHandler() {
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            self?.toggleControls()
        }
        source.resume()
        signal(SIGUSR1, SIG_IGN) // let GCD handle it
    }

    private func toggleControls() {
        // buttonBar removed — no-op
    }

    private func checkPIDFile() {
        guard let content = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let filePID = Int32(content) else {
            return
        }
        if filePID != myPID {
            overlayInfo("Replaced by newer instance — exiting")
            pidCheckTimer?.invalidate()
            tearDownForReplacement()
            NSApplication.shared.terminate(nil)
        }
    }

    /// Fast, synchronous teardown for "we're being replaced" / SIGTERM /
    /// parent-died paths. Kills any subprocesses we own so the new instance
    /// does not have to fight orphans. Safe to call multiple times.
    func tearDownForReplacement() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        whisperManager?.killImmediate()
    }

    /// Persist the user's preferred ME-source pattern to disk so whisper
    /// picks it up via its file watcher and switches without a restart.
    private func writePreferredSource(_ pattern: String) {
        let file = transcriptionFolder.appendingPathComponent(".preferred-me-source")
        do {
            try FileManager.default.createDirectory(at: transcriptionFolder, withIntermediateDirectories: true)
            try pattern.write(to: file, atomically: true, encoding: .utf8)
            overlayInfo("Preferred source: \(pattern)")
        } catch {
            overlayError("Failed to write preferred source: \(error)")
        }
    }

    /// Returns a short suffix to append to the Tail menu item, like
    /// "(5s ago): word1 word2 word3", or nil if no transcription is found.
    private func transcriptionTailPreview() -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: transcriptionFolder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return nil }

        let candidates = files
            .filter { $0.lastPathComponent.hasSuffix("transcription.txt") }
            .filter { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let latest = candidates.first else { return nil }

        guard let data = try? Data(contentsOf: latest), !data.isEmpty else { return nil }
        // Read last ~4KB to grab the final line without loading the whole file.
        let tailBytes = data.suffix(4096)
        guard let tailText = String(data: tailBytes, encoding: .utf8) else { return nil }
        let lastLine = tailText
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last
            .map(String.init) ?? ""
        // Strip leading "[HH:MM] Speaker:" prefix if present.
        let bodyStart = lastLine.range(of: "]")
            .map { lastLine.index(after: $0.upperBound) } ?? lastLine.startIndex
        let afterTimestamp = String(lastLine[bodyStart...])
        let body: String
        if let colon = afterTimestamp.range(of: ":") {
            body = String(afterTimestamp[colon.upperBound...])
        } else {
            body = afterTimestamp
        }
        let words = body
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return nil }
        let lastThree = words.suffix(3).joined(separator: " ")

        let mtime = (try? latest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let secsAgo = max(0, Int(Date().timeIntervalSince(mtime)))
        return "(\(formatAgo(secsAgo))): \(lastThree)"
    }

    private func formatAgo(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private func openTranscriptionMonitor() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let filename = "\(formatter.string(from: Date())) transcription.txt"
        let todayFile = transcriptionFolder.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: transcriptionFolder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: todayFile.path) {
                FileManager.default.createFile(atPath: todayFile.path, contents: nil)
            }

            // If today's file is empty, find the most recent non-empty transcription file
            let tailFile: URL
            let attrs = try? FileManager.default.attributesOfItem(atPath: todayFile.path)
            if (attrs?[.size] as? Int ?? 0) == 0,
               let files = try? FileManager.default.contentsOfDirectory(at: transcriptionFolder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]),
               let recent = files
                   .filter({ $0.lastPathComponent.hasSuffix("transcription.txt") })
                   .filter({ (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 })
                   .sorted(by: { ($0.lastPathComponent) > ($1.lastPathComponent) })
                   .first {
                tailFile = recent
            } else {
                tailFile = todayFile
            }

            let escapedPath = tailFile.path.replacingOccurrences(of: "'", with: "'\\''")
            let cmd = "tail -n 20 -F '\(escapedPath)'"
            let script = """
            tell application "Terminal"
                do script "\(cmd)"
                activate
            end tell
            """

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try p.run()
            overlayInfo("Monitoring transcription: \(tailFile.lastPathComponent)")
        } catch {
            overlayError("Failed to open monitor: \(error)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - WebSocket

    private func connectWebSocket() {
        reconnecting = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        let wsURL = serverURL.replacingOccurrences(of: "http://", with: "ws://")
                             .replacingOccurrences(of: "https://", with: "wss://")
        guard let url = URL(string: "\(wsURL)/ws/__overlay__") else {
            overlayError("Invalid server URL: \(serverURL)")
            return
        }
        overlayInfo("Connecting to \(url.absoluteString)...")
        wsTask = session.webSocketTask(with: url)
        wsTask?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        wsConnected = true
        cancelPendingDisconnectError()
        overlayInfo("WebSocket connected to daemon")
        let msg = "{\"type\":\"set_name\",\"name\":\"Overlay\"}"
        wsTask?.send(.string(msg)) { error in
            if let error = error {
                overlayError("Handshake failed: \(error.localizedDescription)")
            } else {
                overlayInfo("Handshake sent (set_name: Overlay)")
            }
        }
        receiveMessage()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        wsConnected = false
        scheduleDisconnectError()
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            wsConnected = false
            overlayError("WebSocket connection failed: \(error.localizedDescription)")
            scheduleDisconnectError()
            scheduleReconnect()
        }
    }

    private func receiveMessage() {
        wsTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self?.handleMessage(text)
                default:
                    break
                }
                self?.receiveMessage()
            case .failure:
                self?.wsConnected = false
                self?.scheduleDisconnectError()
                self?.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        if type == "emoji_reaction", let emoji = json["emoji"] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.overlayPanel?.refreshScreenFrame()
                self?.animator.spawnEmoji(emoji)
            }
        } else if type == "confetti" {
            DispatchQueue.main.async { [weak self] in
                self?.overlayPanel?.refreshScreenFrame()
                self?.animator.spawnConfetti()
            }
        } else if type == "session_started" {
            // WebSocket message format: {"type": "session_started", "participant_url": "...", "session_folder": "..."}
            if let url = json["participant_url"] as? String {
                let folder = json["session_folder"] as? String
                DispatchQueue.main.async { [weak self] in
                    self?.handleSessionStarted(participantUrl: url, sessionFolder: folder)
                }
            }
        } else if type == "session_ended" {
            // WebSocket message format: {"type": "session_ended"}
            DispatchQueue.main.async { [weak self] in
                self?.handleSessionEnded()
            }
        }
    }

    private func handleSessionStarted(participantUrl: String, sessionFolder: String?) {
        isSessionActive = true
        self.participantUrl = stripProtocolPrefix(from: participantUrl)
        if let folder = sessionFolder, !folder.isEmpty {
            ScreenshotManager.sessionFolder = URL(fileURLWithPath: folder)
        } else {
            ScreenshotManager.sessionFolder = nil
        }
        menuBarManager.setJoinLinkEnabled(true)
    }

    private func handleSessionEnded() {
        isSessionActive = false
        participantUrl = nil
        ScreenshotManager.sessionFolder = nil
        menuBarManager.setJoinLinkEnabled(false)
        // Auto-hide banner if currently visible
        if joinLinkBanner?.bannerIsVisible == true {
            joinLinkBanner?.hide()
        }
    }

    private func stripProtocolPrefix(from url: String) -> String {
        if url.hasPrefix("https://") {
            return String(url.dropFirst(8))
        } else if url.hasPrefix("http://") {
            return String(url.dropFirst(7))
        }
        return url
    }

    // MARK: - Multi-screen status overlays
    //
    // Status banners (9 a.m. "started", 6 p.m. countdown, battery
    // pause/resume, final "stopped") render on **every** connected screen
    // so a glance at any display surfaces them. Emoji animations stay on
    // the built-in panel only.

    /// All panels eligible to host status banners — built-in + every
    /// connected external display.
    fileprivate func allStatusOverlayPanels() -> [OverlayPanel] {
        var result: [OverlayPanel] = []
        if let main = overlayPanel { result.append(main) }
        result.append(contentsOf: auxOverlayPanels)
        return result
    }

    /// Recreate one transparent overlay panel per non-built-in screen.
    /// Safe to call repeatedly — also tears down stale panels.
    private func rebuildAuxOverlayPanels() {
        for p in auxOverlayPanels {
            p.orderOut(nil)
        }
        auxOverlayPanels.removeAll()

        let builtIn = AppDelegate.findRetinaScreen()
        let builtInID = builtIn.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        for screen in NSScreen.screens {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            if id == builtInID { continue }
            let panel = OverlayPanel(screen: screen)
            panel.orderFrontRegardless()
            auxOverlayPanels.append(panel)
        }
        overlayInfo("Aux overlay panels rebuilt: \(auxOverlayPanels.count) external screen(s)")
    }

    @objc private func handleScreensChanged() {
        rebuildAuxOverlayPanels()
    }

    /// Toggle the 🔥 Whip Claude overlay on the screen under the cursor. ⌃W is a
    /// toggle: a first press shows it, a second press dismisses it via the exact
    /// same path as Esc — handy when you can't reach Esc mid-whip. The show edge
    /// never types; the whip's Ctrl+C + scold macro only fires on a mouse click
    /// while the overlay is up (WhipController.handleClick), and it lands in
    /// whatever app currently has keyboard focus (keep Claude focused). So
    /// dismissing never types — only the show→click flow does.
    private func toggleWhip() {
        if let controller = whipController, controller.isShowing {
            controller.hide()   // same dismiss path as Esc — no typing on this edge
            return
        }
        let controller = whipController ?? WhipController()
        whipController = controller
        controller.onEscape = { [weak self] in
            self?.whipController?.hide()
        }
        // Tell the event tap when the overlay is up so Enter / the extra mouse
        // button can crack it (see EventTapManager.whipOverlayShowing).
        controller.onVisibilityChanged = { [weak self] showing in
            self?.eventTapManager?.whipOverlayShowing = showing
        }
        controller.show()
    }

    /// Always resolve the laptop's retina display when (re-)showing the banner,
    /// in case external monitors were connected/disconnected after launch.
    static func findRetinaScreen() -> NSScreen {
        let screens = NSScreen.screens
        if let s = screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }) { return s }
        if let s = screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("built-in") }) { return s }
        if let s = screens.first(where: { $0.backingScaleFactor >= 2 }) { return s }
        return NSScreen.main ?? screens[0]
    }

    private func toggleJoinLinkBanner() {
        guard let banner = joinLinkBanner else { return }

        // Every press also copies the join URL to the clipboard so it can be
        // pasted straight into chat. `participantUrl` is stored without a scheme
        // (see handleSessionStarted); re-add https:// so the pasted link is
        // clickable.
        if let url = participantUrl {
            let clickable = url.contains("://") ? url : "https://" + url
            PasteboardGate.sync { pb in
                pb.clearContents()
                pb.setString(clickable, forType: .string)
            }
        }

        // If banner is visible, hide it
        if banner.bannerIsVisible {
            banner.hide()
        } else {
            guard isSessionActive, let url = participantUrl else { return }
            banner.setTargetScreen(AppDelegate.findRetinaScreen())
            banner.show(url: url)
        }
    }

    private func showBanner(forGitUrl url: String) {
        guard let banner = joinLinkBanner else { return }
        if banner.bannerIsVisible { banner.hide() }
        banner.setTargetScreen(AppDelegate.findRetinaScreen())
        banner.show(url: stripProtocolPrefix(from: url))
    }

    private func displayClipboardLinkBanner() {
        guard let banner = joinLinkBanner else { return }
        if banner.bannerIsVisible {
            banner.hide()
            return
        }
        guard let raw = PasteboardGate.sync({ $0.string(forType: .string) }) else {
            postInvalidURLNotification("(empty)")
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            postInvalidURLNotification("(empty)")
            return
        }
        guard let url = URL(string: trimmed),
              url.scheme == "https" || url.scheme == "http" else {
            // Invalid URL - show notification with first 10 chars
            let preview = String(trimmed.prefix(10))
            postInvalidURLNotification(preview)
            return
        }
        // Display raw trimmed text so spaces aren't percent-encoded as %20
        let cleaned = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        banner.setTargetScreen(AppDelegate.findRetinaScreen())
        banner.show(url: stripProtocolPrefix(from: cleaned))
    }

    private func checkSlideSharedState(event: [String: Any]) {
        guard wsConnected else { return }
        guard let path = event["path"] as? String, !path.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let cache = self.driveShareCache else { return }
            let shared = cache.isShared(path: path)
            if !shared {
                DispatchQueue.main.async {
                    guard self.wsConnected else { return }
                    self.postSlidesNotSharedNotification(path: path)
                }
            }
        }
    }

    private func postSlidesNotSharedNotification(path: String) {
        let content = UNMutableNotificationContent()
        content.title = "Slides not shared"
        content.body = "Click to locate."
        content.userInfo = ["purpose": "slides-not-shared", "slidesPath": path]
        let identifier = "slides-not-shared:\(path)"
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { overlayInfo("Slides not-shared notification error: \(err)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    /// Persistent "Google can no longer export this deck to PDF" alarm, driven by
    /// the daemon's `pdf_export_alarm` message. Unlike the transient notifications
    /// above, this one is NOT auto-removed: it stays in Notification Center until
    /// the daemon reports recovery (failing=false), which clears it. A stable
    /// per-slug identifier means a re-fire replaces rather than stacks.
    /// Note: while PowerPoint is presenting fullscreen macOS suppresses the banner
    /// into Notification Center (same caveat as the other notifications here).
    private func postPdfExportAlarm(deck: String, slug: String, failing: Bool, detail: String) {
        let identifier = "pdf-export-alarm:\(slug)"
        let center = UNUserNotificationCenter.current()
        guard failing else {
            // Recovered — clear the persistent alarm.
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            overlayInfo("✅ PDF export recovered: \(deck)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "GDrive PDF Export failed for:"
        content.body = deck
        content.sound = .default
        content.userInfo = ["purpose": "pdf-export-alarm", "slug": slug]
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(req) { err in
            if let err { overlayInfo("PDF export alarm notification error: \(err)") }
        }
        overlayInfo("🚨 PDF export alarm raised: \(deck)")
    }

    /// "Wispr started but the system output isn't 🔊OS Output" warning, fired from
    /// `CoreAudioManager` on a Wispr-start drift. Transient: auto-removed after 6s
    /// (like the other non-persistent notifications). A stable identifier means a
    /// re-fire replaces rather than stacks.
    func postWisprOutputDriftNotification(output: String) {
        let content = UNMutableNotificationContent()
        content.title = "🔇 Mute inactiv la dictare"
        content.body = "Output = «\(output)», nu 🔊OS Output — muzica nu se va reduce. Schimbă ieșirea pe 🔊OS Output."
        content.sound = .default
        let identifier = "wispr-output-drift"
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { overlayInfo("Wispr output-drift notification error: \(err)") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    /// Prompt Victor to take a group photo using the app's standard bottom-left
    /// status banner — the same overlay as "started" / "paused on battery" / etc.
    /// Presence-gated, so if he stepped away it fades in the moment he's back at
    /// the Mac. Being the app's own always-on-top panel, it shows even while
    /// PowerPoint is presenting fullscreen (unlike a macOS notification, which
    /// gets suppressed into Notification Center). Called from break starts (gated)
    /// and `/test/group-photo`.
    private func promptGroupPhoto() {
        statusBanner?.showOnPresence(
            text: "📸 Group Photo",
            sound: StatusBannerSound.start,
            visibleDuration: 12.0
        )
        overlayInfo("📸 Group Photo prompt shown")
    }

    /// JSON snapshot of the presenting state + how each connected external is
    /// classified. Backs `GET /test/presentation`.
    private func presentationSnapshotJSON() -> String {
        let p = presentationDetector
        var externals: [String] = []
        for id in KnownDisplays.onlineDisplayIDs() where CGDisplayIsBuiltin(id) == 0 {
            let name = KnownDisplays.name(for: id) ?? "display \(id)"
            let known = knownDisplays.isKnown(id)
            externals.append("{\"name\":\"\(name)\",\"known\":\(known)}")
        }
        let trusted = knownDisplays.trustedNames.map { "\"\($0)\"" }.joined(separator: ",")
        return "{"
            + "\"presenting\":\(p?.isPresenting ?? false),"
            + "\"meetingActive\":\(p?.meetingActive ?? false),"
            + "\"unknownDisplayPresent\":\(p?.unknownDisplayPresent ?? false),"
            + "\"externals\":[\(externals.joined(separator: ","))],"
            + "\"trustedNames\":[\(trusted)]"
            + "}"
    }

    private func postInvalidURLNotification(_ clipboardPreview: String) {
        let content = UNMutableNotificationContent()
        content.title = "Invalid URL"
        content.body = clipboardPreview
        content.sound = .default
        let identifier = "invalid-url-\(UUID().uuidString)"
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { overlayInfo("Invalid URL notification error: \(err)") }
        }
        // Auto-dismiss after 5 seconds (transient)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    private func scheduleReconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.connectWebSocket()
        }
    }

    private func scheduleDisconnectError() {
        guard pendingDisconnectError == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingDisconnectError = nil
            overlayError("WebSocket not connected")
        }
        pendingDisconnectError = work
        DispatchQueue.main.asyncAfter(deadline: .now() + disconnectErrorDelay, execute: work)
    }

    private func cancelPendingDisconnectError() {
        pendingDisconnectError?.cancel()
        pendingDisconnectError = nil
    }

    // MARK: - Permissions

    private func requestMicrophonePermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .denied, .restricted:
            overlayInfo("⚠️ Microphone access denied — enable in System Settings → Privacy → Microphone")
        @unknown default:
            break
        }
    }

    private func requestAccessibilityPermissions(promptUser: Bool) {
        let accessEnabled: Bool
        if promptUser {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            accessEnabled = AXIsProcessTrustedWithOptions(options)
        } else {
            accessEnabled = AXIsProcessTrusted()
        }

        if accessEnabled {
            overlayInfo("✓ Accessibility permissions granted")
        } else {
            overlayInfo("⚠️ Accessibility permission not granted (System Settings → Privacy & Security → Accessibility)")
            if promptUser {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }
    }

    private func requestScreenRecordingPermissions(promptUser: Bool) {
        // CGPreflightScreenCaptureAccess correctly returns false when permission is not granted.
        // (CGDisplayCreateImage always succeeds but only captures desktop wallpaper when denied.)
        if CGPreflightScreenCaptureAccess() {
            return
        }
        overlayInfo("⚠️ Screen Recording permission not granted (System Settings → Privacy & Security → Screen Recording)")
        guard promptUser else { return }

        // Trigger the system permission dialog
        CGRequestScreenCaptureAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !CGPreflightScreenCaptureAccess() {
                overlayInfo("⚠️ Please grant Screen Recording permissions for screenshots")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let purpose = userInfo["purpose"] as? String,
           purpose == "slides-not-shared",
           let path = userInfo["slidesPath"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }
}
