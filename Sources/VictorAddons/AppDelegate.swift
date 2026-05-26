import AppKit
import AVFoundation
import Foundation
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, URLSessionWebSocketDelegate, UNUserNotificationCenterDelegate {
    private var overlayPanel: OverlayPanel!
    private var auxOverlayPanels: [OverlayPanel] = []
    private var animator: EmojiAnimator!
    // buttonBar removed
    private var menuBarManager: MenuBarManager!
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
    private var emotionalPasteHandler: EmotionalPasteHandler?
    private var coreAudioManager: CoreAudioManager?
    private var wsServer: LocalWebSocketServer?
    private var tabletServer: TabletHttpServer?
    private var pptMonitor: PowerPointMonitor?
    private var driveShareCache: GoogleDriveShareCache?
    private var ijMonitor: IntelliJMonitor?
    private var rhTimerMonitor: RHTimerMonitor?
    private var portKiller: PortKiller?
    private var whisperManager: WhisperProcessManager?
    private var transcriptionWatcher: TranscriptionWatcher?
    private var transcriptionFolder: URL = URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")
    private var joinLinkBanner: JoinLinkBanner?
    private var powerMonitor: PowerMonitor?
    private var transcriptionStateMachine: TranscriptionStateMachine?
    private var transcriptionScheduler: TranscriptionScheduler?
    private var transcriptionCountdownOverlay: TranscriptionCountdownOverlay?
    private var statusBanner: StatusBanner?
    private var silentTranscriptionWarning: SilentTranscriptionWarning?
    private var meetingDetector: MeetingDetector?
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
        wsServer.onEmoji = { [weak self] emoji, count in
            self?.overlayPanel?.refreshScreenFrame()
            for _ in 0..<max(1, count) {
                self?.animator.spawnEmoji(emoji)
            }
        }
        wsServer.onClientCountChanged = { [weak self] count in
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
            self?.overlayPanel?.refreshScreenFrame()
            switch name {
            case "earthquake":    self?.animator.showBrokenGlass(playSound: false)
            case "explosion":     self?.animator.showExplosionGif(playSound: false)
            case "game-over":     self?.animator.showGameOver(playSound: false)
            case "broken-glass":  self?.animator.showBrokenGlass(playSound: false)
            case "pulse":         self?.animator.startPulseOverlay(playSound: false)
            case "pulse/stop":    self?.animator.stopPulseOverlay()
            case "applause":
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.animator.showApplause(playSound: false)
                }
            case "applause/stop": self?.animator.stopApplause()
            case "heartbeat":     self?.animator.showHeartbeat()
            case "spiral-hearts": self?.animator.showSpiralHearts()
            case "fireworks":     self?.animator.showFireworks(playSound: false)
            case "fear":          self?.animator.showFear(playSound: false)
            case "fail":          self?.animator.showFail(playSound: false)
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
            case "drum-roll":       self?.animator.showDrumRoll(playSound: false)
            case "drum-roll/stop":  self?.animator.stopDrumRoll()
            case "game-over/stop":  self?.animator.stopGameOver()
            case "stop-all":        self?.animator.stopAllActiveEffects()
            default: break
            }
        }
        tabletServer?.start()
        overlayInfo("TabletHttpServer.start() called")

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

        // State machine owns the persisted (state, wasOn) pair and decides
        // whisper start/stop. See docs/transcription-state.puml.
        let sm = TranscriptionStateMachine(isWhisperRunning: { [weak whisperManager] in
            whisperManager?.isRunning == true
        })
        sm.onStartWhisper = startWhisper
        sm.onStopWhisper = stopWhisper
        sm.onAutoRestart = { [weak self] in
            // Whisper died inside the workday window — heartbeat is bringing
            // it back. Arm the "started" banner; it fires once whisper is
            // actually confirmed running.
            self?.pendingAutoRestartBanner = true
        }
        sm.onStateChanged = { [weak self] state, _ in
            DispatchQueue.main.async {
                self?.menuBarManager.setTranscriptionPausedByBattery(state == .battery)
            }
        }
        self.transcriptionStateMachine = sm

        menuBarManager.onToggleTranscribe = { [weak sm] in
            guard let sm else { return }
            switch sm.state {
            case .off: sm.userClickStart()
            case .on:  sm.userClickStop()
            case .onWorkday, .battery: break  // menu disabled in these states
            }
        }

        let pm = PowerMonitor()
        pm.onSwitchToBattery = { [weak self, weak sm] in
            guard let sm else { return }
            let wasRunning = sm.state == .on || sm.state == .onWorkday
            sm.switchToBattery()
            if wasRunning {
                self?.statusBanner?.showOnPresence(text: "paused on battery", sound: StatusBannerSound.stop)
            }
        }
        pm.onSwitchToAC = { [weak self, weak sm] in
            guard let sm else { return }
            let wasPaused = sm.state == .battery
            sm.switchToAC()
            if wasPaused, sm.state == .on || sm.state == .onWorkday {
                self?.statusBanner?.showOnPresence(text: "resumed on AC", sound: StatusBannerSound.start)
            }
        }
        pm.start()
        self.powerMonitor = pm

        let scheduler = TranscriptionScheduler()
        scheduler.onEnterWindow = { [weak self, weak sm] in
            guard let sm else { return }
            sm.enterWorkday()
            if sm.state == .onWorkday {
                self?.statusBanner?.showOnPresence(text: "started", sound: StatusBannerSound.start)
            }
        }
        let exitWindowAction: () -> Void = { [weak self, weak sm] in
            guard let self = self, let sm = sm else { return }

            if self.transcriptionCountdownOverlay == nil {
                self.transcriptionCountdownOverlay = TranscriptionCountdownOverlay(panelsProvider: { [weak self] in
                    self?.allStatusOverlayPanels() ?? []
                })
            }

            self.transcriptionCountdownOverlay?.startCountdown(
                onContinue: {
                    overlayInfo("Transcription continues beyond 6pm (user hovered)")
                },
                onStop: {
                    sm.exitWorkday()
                    overlayInfo("Transcription stopped at 6pm (countdown finished)")
                }
            )
        }
        scheduler.onExitWindow = exitWindowAction
        scheduler.onHeartbeat = { [weak sm] in sm?.heartbeat() }
        scheduler.start()
        self.transcriptionScheduler = scheduler

        tabletServer?.onTestTranscriptionStart = { [weak sm] in
            sm?.userClickStart()
        }
        tabletServer?.onTestTranscriptionStop = { [weak sm] in
            if TranscriptionScheduler.isLockedOn() {
                overlayInfo("🔒 /test/transcription/stop ignored — locked until 18:00")
                return
            }
            sm?.userClickStop()
        }
        tabletServer?.onTestTranscriptionToggle = { [weak sm] in
            guard let sm else { return }
            switch sm.state {
            case .off: sm.userClickStart()
            case .on:  sm.userClickStop()
            case .onWorkday, .battery: break
            }
        }
        tabletServer?.onTestExitWindow = exitWindowAction
        tabletServer?.onTestWisprRecording = { [weak self] in
            guard let manager = self?.coreAudioManager else {
                return "{\"error\":\"coreAudioManager unavailable\"}"
            }
            let recording = manager.probeWisprRecording()
            return "{\"recording\":\(recording)}"
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
                "state": self.transcriptionStateMachine?.state.rawValue ?? "unknown",
                "wasOn": self.transcriptionStateMachine?.wasOn ?? false,
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
                self?.overlayPanel?.refreshScreenFrame()
                switch name {
                case "heart":        self?.animator.spawnEmoji("❤️")
                case "confetti":     self?.animator.spawnConfetti()
                case "zorro":        self?.animator.showZorro()
                case "fear":         self?.animator.showFear()
                case "fail":         self?.animator.showFail()
                case "sepia":        self?.animator.showSepia()
                case "fireworks":    self?.animator.showFireworks()
                case "applause":     self?.animator.showApplause()
                case "heartbeat":    self?.animator.showHeartbeat()
                case "spiral-hearts": self?.animator.showSpiralHearts()
                case "explosion":    self?.animator.showExplosionGif()
                case "broken-glass": self?.animator.showBrokenGlass()
                case "game-over":    self?.animator.showGameOver()
                case "pulse":        self?.animator.startPulseOverlay()
                case "fire-alarm":       self?.animator.showFireAlarm()
                case "bullet-holes":    self?.animator.showBulletHoles()
                case "phone-ring":      self?.animator.showPhoneRing()
                case "fbi-knock":       self?.animator.showFbiKnock()
                case "brother":         self?.animator.showBrother()
                case "gangnam":         self?.animator.showGangnam()
                case "love-hands":      self?.animator.showLoveHands()
                case "star-wars":       self?.animator.showStarWars()
                case "gong":            self?.animator.showGong()
                case "drum-roll":       self?.animator.showDrumRoll()
                case "laugh":           self?.animator.showLaugh()
                default: break
                }
            }
        }
        menuBarManager.onConnectTablet = {
            DispatchQueue.global(qos: .userInitiated).async {
                let adb = "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: adb)
                p.arguments = ["reverse", "tcp:55123", "tcp:55123"]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
                let msg = p.terminationStatus == 0 ? "Tablet connected via USB-C ✓" : "Tablet not found — plug in USB-C first"
                DispatchQueue.main.async { overlayInfo(msg) }
            }
        }
        menuBarManager.onCopyGit = { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let url = GitCopier.copyIntelliJGit() else { return }
                DispatchQueue.main.async { self?.showBanner(forGitUrl: url) }
            }
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
        statusBanner = StatusBanner(panelsProvider: { [weak self] in
            self?.allStatusOverlayPanels() ?? []
        })
        silentTranscriptionWarning = SilentTranscriptionWarning(panelsProvider: { [weak self] in
            self?.allStatusOverlayPanels() ?? []
        })
        menuBarManager.onDisplayJoinLink = { [weak self] in
            self?.toggleJoinLinkBanner()
        }
        menuBarManager.onDisplayClipboardLink = { [weak self] in
            self?.displayClipboardLinkBanner()
        }
        menuBarManager.onAppendClipboardToNotes = {
            DispatchQueue.global(qos: .userInitiated).async { SessionNotesAppender.appendClipboard() }
        }

        let portKiller = PortKiller()
        self.portKiller = portKiller
        menuBarManager.onKillPort = { port in
            DispatchQueue.global(qos: .userInitiated).async { portKiller.kill(port: port) }
        }
        menuBarManager.onKillPortPrompt = { portKiller.showPortPrompt() }

        menuBarManager.setup()
        // Reflect real process state on startup to avoid stale "Stop Transcribing" UI.
        menuBarManager.setTranscribing(false)

        let detector = MeetingDetector()
        meetingDetector = detector
        detector.checkInitialState()

        let rhMonitor = RHTimerMonitor()
        rhMonitor.onBreakEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.menuBarManager.breakEndedAt = Date()
            }
        }
        rhMonitor.start()
        self.rhTimerMonitor = rhMonitor
        ScreenshotManager.onScreenshotTaken = { [weak menuBarManager] in
            DispatchQueue.main.async {
                menuBarManager?.flashScreenshotIcon()
            }
        }
        // Settle the persisted state against the current hour / battery.
        // This is the single launch entry point — see Restore + Settle in
        // docs/transcription-state.puml.
        sm.settle()

        let secrets = SecretsLoader.load()
        let apiKey = secrets["WISPR_CLEANUP_ANTHROPIC_API_KEY"] ?? ""
        let pasteHandler = EmotionalPasteHandler(apiKey: apiKey)
        self.emotionalPasteHandler = pasteHandler

        let audioManager = CoreAudioManager()
        self.coreAudioManager = audioManager
        audioManager.start()

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
        eventTap.onToggleTranscription = { [weak sm] in
            guard let sm else { return }
            switch sm.state {
            case .off: sm.userClickStart()
            case .on:  sm.userClickStop()
            case .onWorkday, .battery: break
            }
        }
        eventTap.onRepaste = {
            DispatchQueue.global().async { KeySimulator.simulateDoubleOptionPress() }
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
        eventTap.start()
        self.eventTapManager = eventTap

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

        let ijMonitor = IntelliJMonitor(outputDir: transcriptionFolder)
        ijMonitor.onGitFileOpened = { [weak self] url, branch, file, fileURL in
            self?.wsServer?.pushGitFileOpened(url: url, branch: branch, file: file, fileURL: fileURL)
        }
        ijMonitor.start()
        self.ijMonitor = ijMonitor

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
        let st = transcriptionStateMachine?.state
        guard st == .on || st == .onWorkday else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let s = self.transcriptionStateMachine?.state
            guard s == .on || s == .onWorkday, self.whisperManager?.isRunning != true else { return }
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
        guard let raw = NSPasteboard.general.string(forType: .string) else {
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
