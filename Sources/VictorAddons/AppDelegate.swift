import AppKit
import AVFoundation
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate, URLSessionWebSocketDelegate {
    private var overlayPanel: OverlayPanel!
    private var animator: EmojiAnimator!
    private var buttonBar: ButtonBar!
    private var menuBarManager: MenuBarManager!
    private let serverURL: String
    private var wsTask: URLSessionWebSocketTask?
    private var session: URLSession!
    private var reconnecting = false
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
    private var ijMonitor: IntelliJMonitor?
    private var rhTimerMonitor: RHTimerMonitor?
    private var portKiller: PortKiller?
    private var whisperManager: WhisperProcessManager?
    private var transcriptionWatcher: TranscriptionWatcher?
    private var transcriptionFolder: URL = URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")
    private var joinLinkBanner: JoinLinkBanner?

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
        requestScreenRecordingPermissions(promptUser: false)

        guard !NSScreen.screens.isEmpty else { fatalError("No screens available") }
        let builtInScreen = NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.screens[0]

        overlayPanel = OverlayPanel(screen: builtInScreen)
        overlayPanel.orderFrontRegardless()

        guard let hostLayer = overlayPanel.contentView?.layer else {
            fatalError("Content view has no layer")
        }
        animator = EmojiAnimator(hostLayer: hostLayer)

        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        connectWebSocket()
        setupButtonBar(screen: builtInScreen)
        setupSignalHandler()
        transcriptionFolder = {
            if let env = ProcessInfo.processInfo.environment["TRANSCRIPTION_FOLDER"] {
                return URL(fileURLWithPath: env)
            }
            return URL(fileURLWithPath: "/Users/victorrentea/workspace/victor-macos-addons/addons-output")
        }()

        let wsServer = LocalWebSocketServer()
        wsServer.onEmoji = { [weak self] emoji, count in
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
                self?.handleSessionStarted(participantUrl: url)
            } else if type == "session_ended" {
                self?.handleSessionEnded()
            }
        }
        wsServer.start()
        self.wsServer = wsServer

        overlayInfo("Starting TabletHttpServer...")
        tabletServer = TabletHttpServer()
        tabletServer?.onAlarmStart = { [weak self] in self?.animator.startAlarmOverlay() }
        tabletServer?.onAlarmStop  = { [weak self] in self?.animator.stopAlarmOverlay() }
        tabletServer?.onEffect = { [weak self] name in
            switch name {
            case "earthquake":    self?.animator.showBrokenGlass()
            case "explosion":     self?.animator.showExplosionGif()
            case "game-over":     self?.animator.showGameOver()
            case "broken-glass":  self?.animator.showBrokenGlass()
            case "pulse":         self?.animator.startPulseOverlay()
            case "pulse/stop":    self?.animator.stopPulseOverlay()
            case "applause":      self?.animator.showApplause()
            case "applause/stop": self?.animator.stopApplause()
            case "fireworks":     self?.animator.showFireworks()
            case "fear":          self?.animator.showFear()
            case "fail":          self?.animator.showFail()
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
        }
        self.transcriptionWatcher = watcher
        whisperManager.onStateChanged = { [weak self] running in
            self?.menuBarManager.setTranscribing(running)
            if running { self?.transcriptionWatcher?.startWatching() }
            else { self?.transcriptionWatcher?.stopWatching() }
        }
        whisperManager.onDeviceChanged = { [weak self] emoji in
            self?.menuBarManager.setTranscribeSource(emoji)
        }
        let startTranscription: () -> Void = { [weak whisperManager, weak self] in
            var env: [String: String] = [:]
            if let folder = self?.transcriptionFolder {
                env["TRANSCRIPTION_FOLDER"] = folder.path
            }
            DispatchQueue.global(qos: .userInitiated).async {
                whisperManager?.start(env: env)
            }
        }
        let stopTranscription: () -> Void = { [weak whisperManager] in
            whisperManager?.stop()
        }
        let toggleTranscription: () -> Void = { [weak whisperManager] in
            if whisperManager?.isRunning == true {
                UserDefaults.standard.set(false, forKey: "transcribingEnabled")
                stopTranscription()
            } else {
                UserDefaults.standard.set(true, forKey: "transcribingEnabled")
                startTranscription()
            }
        }
        menuBarManager.onToggleTranscribe = {
            toggleTranscription()
        }
        tabletServer?.onTestTranscriptionStart = {
            UserDefaults.standard.set(true, forKey: "transcribingEnabled")
            startTranscription()
        }
        tabletServer?.onTestTranscriptionStop = {
            UserDefaults.standard.set(false, forKey: "transcribingEnabled")
            stopTranscription()
        }
        tabletServer?.onTestTranscriptionToggle = {
            toggleTranscription()
        }
        tabletServer?.onTestState = { [weak self, weak whisperManager] in
            guard let self, let menuBarManager = self.menuBarManager else {
                return "{\"error\":\"app state unavailable\"}"
            }
            let ui = menuBarManager.transcriptionDebugState()
            let payload: [String: Any] = [
                "running": whisperManager?.isRunning == true,
                "enabled_preference": UserDefaults.standard.object(forKey: "transcribingEnabled") as? Bool ?? true,
                "ui_transcribing": ui.isTranscribing,
                "ui_stale": ui.isStale,
                "menu_title": ui.menuTitle,
                "icon_mode": ui.iconMode,
                "source": ui.source,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else {
                return "{\"error\":\"failed to encode state\"}"
            }
            return json
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
        menuBarManager.onCopyGit = { DispatchQueue.global(qos: .userInitiated).async { GitCopier.copyIntelliJGit() } }
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
        menuBarManager.onMonitor = { [weak self] in
            self?.openTranscriptionMonitor()
        }
        menuBarManager.onTakeScreenshot = {
            DispatchQueue.global(qos: .userInitiated).async { ScreenshotManager.takeScreenshot() }
        }

        // Initialize join link banner
        joinLinkBanner = JoinLinkBanner(screen: builtInScreen)
        menuBarManager.onDisplayJoinLink = { [weak self] in
            self?.toggleJoinLinkBanner()
        }
        menuBarManager.onDisplayClipboardLink = { [weak self] in
            self?.displayClipboardLinkBanner()
        }

        let portKiller = PortKiller()
        self.portKiller = portKiller
        menuBarManager.onKillPort = { port in
            DispatchQueue.global(qos: .userInitiated).async { portKiller.kill(port: port) }
        }
        menuBarManager.onKillPortPrompt = { portKiller.showPortPrompt() }
        portKiller.onKillComplete = { [weak menuBarManager] port in menuBarManager?.addToPortHistory(port) }

        menuBarManager.setup()
        // Reflect real process state on startup to avoid stale "Stop Transcribing" UI.
        menuBarManager.setTranscribing(false)

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
        let wasTranscribing = UserDefaults.standard.object(forKey: "transcribingEnabled") as? Bool ?? true
        if wasTranscribing { startTranscription() }

        let secrets = SecretsLoader.load()
        let apiKey = secrets["WISPR_CLEANUP_ANTHROPIC_API_KEY"] ?? ""
        let pasteHandler = EmotionalPasteHandler(apiKey: apiKey)
        self.emotionalPasteHandler = pasteHandler

        let audioManager = CoreAudioManager()
        self.coreAudioManager = audioManager

        let eventTap = EventTapManager()
        eventTap.onCaptureClipboard = { [weak pasteHandler] text in
            pasteHandler?.captureText(text)
        }
        eventTap.onEmotionalPaste = { [weak pasteHandler] in pasteHandler?.handleCleanHotkey() }
        eventTap.onScreenshot = { DispatchQueue.global(qos: .userInitiated).async { ScreenshotManager.takeScreenshot() } }
        eventTap.onToggleDarkMode = {
            DispatchQueue.global(qos: .userInteractive).async { DarkModeToggle.toggle() }
        }
        eventTap.onOpenCatalog = { [weak menuBarManager] in menuBarManager?.onOpenCatalog?() }
        eventTap.onDictationMute = { [weak audioManager] in
            DispatchQueue.global(qos: .userInteractive).async {
                audioManager?.toggleDictationMute()
            }
        }
        eventTap.onWheelLongPress = {
            AppleScriptRunner.run("""
                tell application "Terminal"
                    do script "cd ~/workspace && claude"
                    activate
                end tell
            """)
        }
        eventTap.onRepaste = {
            let src = CGEventSource(stateID: .hidSystemState)
            let flags: CGEventFlags = [.maskControl, .maskAlternate]
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: false)
            down?.flags = flags
            up?.flags   = flags
            down?.post(tap: .cgSessionEventTap)
            up?.post(tap: .cgSessionEventTap)
        }
        eventTap.start()
        self.eventTapManager = eventTap

        let pptMonitor = PowerPointMonitor()
        pptMonitor.onSlideChange = { [weak self] event in
            self?.wsServer?.pushSlide(event)
        }
        pptMonitor.onSlidesViewed = { [weak self] slides in
            self?.wsServer?.pushSlidesViewed(slides)
        }
        pptMonitor.start()
        self.pptMonitor = pptMonitor

        let ijMonitor = IntelliJMonitor(outputDir: transcriptionFolder)
        ijMonitor.onGitFileOpened = { [weak self] url, branch, file in
            self?.wsServer?.pushGitFileOpened(url: url, branch: branch, file: file)
        }
        ijMonitor.start()
        self.ijMonitor = ijMonitor

        // Check every 2s if another instance took over the PID file
        pidCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPIDFile()
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
        controlsVisible = !controlsVisible
        if controlsVisible {
            buttonBar.slideInAndStay()
        } else {
            buttonBar.hideAndUnpin()
        }
    }

    // MARK: - Button bar

    private func setupButtonBar(screen: NSScreen) {
        let buttons: [ButtonBar.ButtonDef] = [
            .init(label: "❤️", tooltip: "Floating Heart") { [weak self] in
                self?.animator.spawnEmoji("❤️")
            },
            .init(label: "🎊", tooltip: "Confetti") { [weak self] in
                self?.animator.spawnConfetti()
            },
            // tablet-triggered: // .init(label: "🚨", tooltip: "Danger") { [weak self] in self?.animator.showDanger() },
            // tablet-triggered — kept for reference:
            // .init(label: "💥", tooltip: "Screen crash") { [weak self] in self?.animator.showBrokenGlass() },
            // .init(label: "🎆", imageName: "fireworks-button.png", tooltip: "Fireworks") { [weak self] in self?.animator.showFireworks() },
            // .init(label: "😱", tooltip: "Fear") { [weak self] in self?.animator.showFear() },
            // .init(label: "👏", tooltip: "Applause (toggle)") { [weak self] in self?.animator.showApplause() },
            // .init(label: "", imageName: "ecg_icon.png", tooltip: "Pulse") { [weak self] in self?.animator.showPulse() },
            .init(label: "", imageName: "zorro_icon.png", tooltip: "Zorro") { [weak self] in
                self?.animator.showZorro()
            },
            .init(label: "📽️", tooltip: "Sepia") { [weak self] in
                self?.animator.showSepia()
            },
        ]

        buttonBar = ButtonBar(buttons: buttons, screen: screen)
        buttonBar.orderFrontRegardless()
    }

    private func checkPIDFile() {
        guard let content = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let filePID = Int32(content) else {
            return
        }
        if filePID != myPID {
            overlayInfo("Replaced by newer instance — exiting")
            pidCheckTimer?.invalidate()
            wsTask?.cancel(with: .goingAway, reason: nil)
            NSApplication.shared.terminate(nil)
        }
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

            let escapedPath = todayFile.path.replacingOccurrences(of: "'", with: "'\\''")
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
            overlayInfo("Monitoring transcription: \(filename)")
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
        scheduleDisconnectError()
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
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
                self?.animator.spawnEmoji(emoji)
            }
        } else if type == "confetti" {
            DispatchQueue.main.async { [weak self] in
                self?.animator.spawnConfetti()
            }
        } else if type == "session_started" {
            // WebSocket message format: {"type": "session_started", "participant_url": "https://interact.victorrentea.ro/abc123"}
            if let url = json["participant_url"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.handleSessionStarted(participantUrl: url)
                }
            }
        } else if type == "session_ended" {
            // WebSocket message format: {"type": "session_ended"}
            DispatchQueue.main.async { [weak self] in
                self?.handleSessionEnded()
            }
        }
    }

    private func handleSessionStarted(participantUrl: String) {
        isSessionActive = true
        self.participantUrl = stripProtocolPrefix(from: participantUrl)
        menuBarManager.setJoinLinkEnabled(true)
    }

    private func handleSessionEnded() {
        isSessionActive = false
        participantUrl = nil
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

    private func toggleJoinLinkBanner() {
        guard let banner = joinLinkBanner else { return }

        // If banner is visible, hide it
        if banner.bannerIsVisible {
            banner.hide()
        } else {
            guard isSessionActive, let url = participantUrl else { return }
            banner.show(url: url)
        }
    }

    private func displayClipboardLinkBanner() {
        guard let banner = joinLinkBanner else { return }
        if banner.bannerIsVisible {
            banner.hide()
            return
        }
        guard let raw = NSPasteboard.general.string(forType: .string),
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http" else {
            overlayError("No URL in clipboard")
            return
        }
        banner.show(url: stripProtocolPrefix(from: url.absoluteString))
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
}
