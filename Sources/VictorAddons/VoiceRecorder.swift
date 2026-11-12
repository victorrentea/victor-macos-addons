import AppKit
import AVFoundation
import Foundation

/// ⏺️ Record voice — what the people in the room say, into an .m4a in
/// ~/Downloads (2026-11-12, Victor: *"Record audio, which has a stop icon
/// somewhere displayed so I can capture the voice of people"*).
///
/// **Which microphone**: the one transcription is hearing right now, when it is
/// one of `MicRoster`'s; otherwise the first of the roster that is plugged in
/// (`XLR ▸ DJI ▸ Stage ▸ Bose ▸ Mac`), never a `neverRecord` headset. Not the
/// macOS default input: that one is routinely the MacBook's own mic while the
/// DJI receiver sits in the USB port, and a recording of the room from the
/// laptop lid is the recording nobody wanted (measured that afternoon: default
/// input `MacBook Pro Microphone`, DJI `Wireless Mic Rx` connected).
/// A second reader of the same input is fine on macOS — whisper keeps hearing it.
///
/// **The stop button is its own status item**, a red ⏹ and the elapsed time,
/// up only while recording — the shape `TartVMIndicator` uses for a running VM.
/// One click stops, finalises the file and shows it in Finder. Not an overlay:
/// the built-in screen is the projected one.
final class VoiceRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    static let shared = VoiceRecorder()

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var stopItem: NSStatusItem?
    private var tick: Timer?
    private var startedAt: Date?
    private var deviceName = ""
    private var finished = true

    /// Asked at start: the `MicRoster` pattern of the mic transcription is on, if any.
    var currentTranscribePattern: (() -> String?)?
    /// Called whenever recording starts or stops, so the menu row can retitle.
    var onChange: (() -> Void)?

    var isRecording: Bool { output?.isRecording == true || (session != nil && !finished) }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard session == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? self.begin() : self.explainDenied() }
            }
        default:
            explainDenied()
        }
    }

    func stop() {
        guard let output, output.isRecording else { tearDown(); return }
        output.stopRecording()   // → fileOutput(_:didFinishRecordingTo:…)
    }

    /// For quit: an AAC file is only playable once its header is written, and
    /// `stopRecording` finishes asynchronously — wait for it, briefly.
    func stopAndWait(timeout: TimeInterval = 2) {
        guard isRecording else { return }
        stop()
        let deadline = Date().addingTimeInterval(timeout)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: device choice (pure, tested)

    /// Index into `names` of the device to record, or nil = the system default.
    static func pick(names: [String], preferredPattern: String?) -> Int? {
        func match(_ pattern: String) -> Int? {
            names.firstIndex { $0.range(of: pattern, options: .caseInsensitive) != nil
                && !MicRoster.isNeverRecord($0) }
        }
        if let p = preferredPattern, !p.isEmpty, let i = match(p) { return i }
        for mic in MicRoster.all { if let i = match(mic.pattern) { return i } }
        return nil
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: private

    private static func audioDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.microphone, .external]
        } else {
            types = [.builtInMicrophone, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio,
                                                position: .unspecified).devices
    }

    private func chooseDevice() -> AVCaptureDevice? {
        let devices = Self.audioDevices()
        if let i = Self.pick(names: devices.map(\.localizedName),
                             preferredPattern: currentTranscribePattern?()) {
            return devices[i]
        }
        return AVCaptureDevice.default(for: .audio)
    }

    private func begin() {
        guard session == nil else { return }
        guard let device = chooseDevice() else {
            overlayError("⏺️ Record voice: no microphone found")
            return
        }
        guard let url = DownloadsFolder.freshURL(ext: "m4a") else {
            overlayError("⏺️ Record voice: no Downloads folder")
            return
        }
        do {
            let s = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { throw NSError(domain: "VoiceRecorder", code: 1) }
            s.addInput(input)
            let out = AVCaptureAudioFileOutput()
            out.audioSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
            guard s.canAddOutput(out) else { throw NSError(domain: "VoiceRecorder", code: 2) }
            s.addOutput(out)
            s.startRunning()
            out.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
            session = s
            output = out
            finished = false
            deviceName = device.localizedName
            startedAt = Date()
            overlayInfo("⏺️ Recording \(deviceName) → \(url.path)")
            showStopItem()
            onChange?()
        } catch {
            overlayError("⏺️ Could not record from \(device.localizedName): \(error)")
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            let took = Self.clock(-(self.startedAt ?? Date()).timeIntervalSinceNow)
            if let error {
                // An unplugged mic ends the take with an error but usually a
                // usable file; say so and still show it.
                overlayError("⏺️ Recording ended with \(error.localizedDescription) after \(took)")
            } else {
                overlayInfo("⏺️ Recording stopped after \(took): \(url.path)")
            }
            self.finished = true
            self.tearDown()
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func tearDown() {
        session?.stopRunning()
        session = nil
        output = nil
        finished = true
        tick?.invalidate(); tick = nil
        if let stopItem { NSStatusBar.system.removeStatusItem(stopItem) }
        stopItem = nil
        onChange?()
    }

    private func showStopItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                .applying(.init(paletteColors: [.white, .systemRed]))
            button.image = NSImage(systemSymbolName: "stop.circle.fill",
                                   accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
            button.toolTip = "Recording \(deviceName) — click to stop and show the file"
            button.target = self
            button.action = #selector(stopClicked)
        }
        stopItem = item
        refreshClock()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshClock() }
        RunLoop.main.add(t, forMode: .common)   // keeps counting while a menu is open
        tick = t
    }

    private func refreshClock() {
        stopItem?.button?.title = " " + Self.clock(-(startedAt ?? Date()).timeIntervalSinceNow)
    }

    @objc private func stopClicked() { stop() }

    private func explainDenied() {
        overlayError("⏺️ Microphone access denied — System Settings › Privacy & Security › Microphone")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
