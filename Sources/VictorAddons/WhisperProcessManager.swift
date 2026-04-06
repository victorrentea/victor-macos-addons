import Foundation

class WhisperProcessManager {
    private var process: Process?
    private(set) var isRunning: Bool = false

    // Called when transcribing state changes (for menu title update)
    var onStateChanged: ((Bool) -> Void)?

    func start(env: [String: String]) {
        guard !isRunning else { return }

        // Find python3 in PATH
        let python3 = findPython3()

        let whisperScript = findWhisperScript()
        guard !whisperScript.isEmpty else {
            overlayInfo("Whisper runner not found")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python3)
        p.arguments = ["-u", whisperScript]  // -u = unbuffered

        // Pass current env + custom vars
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env { environment[key] = value }
        p.environment = environment

        // Pipe stdout/stderr to our log
        let outputPipe = Pipe()
        p.standardOutput = outputPipe
        p.standardError = outputPipe  // merge stderr into stdout

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                overlayInfo("Whisper: \(line)")
            }
        }

        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.process = nil
                self?.onStateChanged?(false)
                overlayInfo("Whisper process ended")
            }
        }

        do {
            try p.run()
            process = p
            isRunning = true
            overlayInfo("Whisper transcription started (pid \(p.processIdentifier))")
            DispatchQueue.main.async { self.onStateChanged?(true) }
        } catch {
            overlayInfo("Failed to start whisper: \(error)")
        }
    }

    func stop() {
        isRunning = false
        guard let p = process, p.isRunning else { return }
        p.terminate()
        process = nil
        overlayInfo("Whisper transcription stopped")
        DispatchQueue.main.async { self.onStateChanged?(false) }
    }

    private func findPython3() -> String {
        // Prefer interpreters that actually have Whisper runtime deps installed.
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            if hasWhisperDependencies(python: candidate) {
                return candidate
            }
        }

        // Fallback to first available interpreter (startup may still fail with missing deps).
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    private func hasWhisperDependencies(python: String) -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: python)
        probe.arguments = [
            "-c",
            "import importlib.util as u;mods=['numpy','sounddevice','mlx_whisper'];raise SystemExit(0 if all(u.find_spec(m) for m in mods) else 1)",
        ]
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()

        do {
            try probe.run()
            probe.waitUntilExit()
            return probe.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func findWhisperScript() -> String {
        // The script is relative to the app bundle or the source tree
        // Try: next to the binary, then relative paths
        let binaryDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
        let candidates = [
            "\(binaryDir)/../../../whisper-transcribe/whisper_runner.py",
            "\(binaryDir)/whisper_runner.py",
        ]
        for candidate in candidates {
            let resolved = URL(fileURLWithPath: candidate).standardized.path
            if FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }
        // Try finding relative to CWD
        let cwd = FileManager.default.currentDirectoryPath
        let cwdScript = "\(cwd)/whisper-transcribe/whisper_runner.py"
        if FileManager.default.fileExists(atPath: cwdScript) {
            return cwdScript
        }
        return ""
    }
}
