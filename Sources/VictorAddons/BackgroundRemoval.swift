import AppKit
import CoreImage
import Vision

/// ✂️ Cut the subject out of a picture — the ⌘⇧V bezel's `Paste w/o bg`.
///
/// **BiRefNet first, Apple Vision as the fallback** (2026-10-05, Victor). Six
/// engines were run on the same two pictures — Vision, BiRefNet general and
/// lite, ISNet, U²-Net, BRIA RMBG-2.0 — and Victor's verdict on the zoomed
/// edges was *"birefnet-general-bleed e clar superior"*. Vision was the first
/// version: 0.4 s, nothing to install, but a soft edge three times as wide as
/// BiRefNet's, and it kept a curtain as a second subject.
///
/// **"-bleed" is the half that fixed the dark rim**, and it is not the model:
/// every one of the six copies the *original* pixel into the semi-transparent
/// edge, background included. A drawing on black came out with a dark line
/// around it on any light page. `bg-remove/cutout_server.py` gives each edge
/// pixel the colour of the solid foreground next to it instead.
///
/// BiRefNet runs in the warm sidecar (`BackgroundRemovalServer`); Vision only
/// when that cannot answer — so a click always produces *something*, and says
/// which engine it was.
enum BackgroundRemoval {

    enum Engine: String { case birefnet = "BiRefNet", vision = "Vision" }

    static func cutOut(imageAt url: URL) -> (png: Data, engine: Engine)? {
        if let png = BackgroundRemovalServer.shared.cutOut(imageAt: url) { return (png, .birefnet) }
        if let png = visionCutOut(imageAt: url) { return (png, .vision) }
        return nil
    }

    /// PNG with alpha, or nil when Vision saw no subject at all (a screenshot
    /// of a text editor, a flat diagram). Every instance it finds is kept, on
    /// the original canvas size. No edge bleed: this is the fallback.
    static func visionCutOut(imageAt url: URL) -> Data? {
        // The package still targets an older macOS; this Mac is on 15.
        guard #available(macOS 14, *) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first,
                  !observation.allInstances.isEmpty else { return nil }
            let masked = try observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                             from: handler,
                                                             croppedToInstancesExtent: false)
            return CIContext().pngRepresentation(of: CIImage(cvPixelBuffer: masked),
                                                 format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        } catch {
            overlayError("✂️ Vision failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// The BiRefNet sidecar: `uv run` of `bg-remove/cutout_server.py`, one JSON
/// line in, one out, the model kept on the GPU between clicks.
///
/// **Warm, because cold is unusable**: ~5 s to load and a ~4 s first
/// inference (MPS compiling its kernels), then ~1 s per picture, bleed and PNG
/// included. So it is started when the bezel shows an image (`prewarm`) —
/// the walk to the right clip pays for the load — and stopped after
/// `idleTimeout` without a request, because a few GB of torch and weights
/// have no business sitting in memory all day for a button.
///
/// Everything runs on one serial queue, so a click that lands while the
/// model is still loading simply waits for it.
final class BackgroundRemovalServer {
    static let shared = BackgroundRemovalServer()

    static let idleTimeout: TimeInterval = 30 * 60
    /// A first-ever start also builds the venv (torch is ~1 GB of wheels).
    private static let startTimeout: TimeInterval = 300
    private static let requestTimeout: TimeInterval = 60
    private static let uv = "/opt/homebrew/bin/uv"
    private static let log = URL(fileURLWithPath: "/tmp/victor-bg-remove.log")

    private let queue = DispatchQueue(label: "ro.victorrentea.macos-addons.bg-remove", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var ready = false
    private var idleStop: DispatchWorkItem?

    private let linesLock = NSLock()
    private var lines: [String] = []
    private var pending = Data()
    private let lineArrived = DispatchSemaphore(value: 0)

    func prewarm() {
        queue.async { [self] in
            guard !ready else { return }
            _ = ensureRunning()
            scheduleIdleStop()
        }
    }

    /// Blocking — call it off the main thread. Nil when the sidecar cannot be
    /// started or does not answer; the caller falls back to Vision.
    func cutOut(imageAt url: URL) -> Data? {
        queue.sync { [self] in
            defer { scheduleIdleStop() }
            if !ready { overlayInfo("✂️ loading BiRefNet…") }
            guard ensureRunning(), let input else { return nil }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("cutout-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: out) }
            let request = ["in": url.path, "out": out.path]
            guard let json = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            do {
                try input.write(contentsOf: json + Data("\n".utf8))
            } catch {
                stop()
                return nil
            }
            guard let reply = nextMessage(timeout: Self.requestTimeout) else {
                overlayError("✂️ BiRefNet did not answer in \(Int(Self.requestTimeout)) s — restarting it next time")
                stop()
                return nil
            }
            guard reply["ok"] as? Bool == true else {
                overlayError("✂️ BiRefNet: \(reply["error"] as? String ?? "failed")")
                return nil
            }
            return try? Data(contentsOf: out)
        }
    }

    // MARK: - queue-only

    private func ensureRunning() -> Bool {
        if ready, process?.isRunning == true { return true }
        stop()
        guard let script = Self.serverDirectory() else {
            overlayError("✂️ bg-remove/cutout_server.py not found")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.uv)
        p.arguments = ["run", "-q", "--project", script.path, "python", "-u",
                       script.appendingPathComponent("cutout_server.py").path]
        var env = ProcessInfo.processInfo.environment
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        // Warnings and tracebacks go to a file, not the void: a sidecar that
        // dies without saying why is the bug this app has paid for before.
        FileManager.default.createFile(atPath: Self.log.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: Self.log)) ?? FileHandle.nullDevice
        linesLock.lock(); lines.removeAll(); pending.removeAll(); linesLock.unlock()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        do {
            try p.run()
        } catch {
            overlayError("✂️ could not start BiRefNet: \(error.localizedDescription)")
            return false
        }
        process = p
        input = stdin.fileHandleForWriting
        guard let hello = nextMessage(timeout: Self.startTimeout), hello["ready"] as? Bool == true else {
            overlayError("✂️ BiRefNet failed to start — see \(Self.log.path)")
            stop()
            return false
        }
        overlayInfo("✂️ BiRefNet ready on \(hello["device"] as? String ?? "?") in \((hello["load_ms"] as? Int ?? 0) / 1000) s")
        ready = true
        return true
    }

    private func stop() {
        ready = false
        idleStop?.cancel()
        idleStop = nil
        try? input?.close()   // EOF ends the server's read loop
        input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.process != nil else { return }
            self.stop()
            overlayInfo("✂️ BiRefNet stopped after \(Int(Self.idleTimeout / 60)) min idle")
        }
        idleStop = work
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    /// The next stdout line that parses as a JSON object. Anything else a
    /// library prints to stdout is skipped rather than taken for an answer.
    private func nextMessage(timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            linesLock.lock()
            let line = lines.isEmpty ? nil : lines.removeFirst()
            linesLock.unlock()
            if let line {
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    return object
                }
                continue
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 || process?.isRunning != true && lines.isEmpty { return nil }
            _ = lineArrived.wait(timeout: .now() + min(left, 1))
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        linesLock.lock()
        pending.append(data)
        var count = 0
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            lines.append(line)
            count += 1
        }
        linesLock.unlock()
        for _ in 0..<count { lineArrived.signal() }
    }

    /// The source tree, like the whisper sidecar: the app is only ever built
    /// on this Mac, next to its checkout.
    private static func serverDirectory() -> URL? {
        var candidates: [String] = []
        if let root = ProcessInfo.processInfo.environment["VICTOR_ADDONS_ROOT"] { candidates.append("\(root)/bg-remove") }
        candidates.append("\(NSHomeDirectory())/workspace/victor-macos-addons/bg-remove")
        return candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("cutout_server.py").path) }
    }
}
