import Foundation

enum AppleScriptRunner {
    struct ScriptResult {
        let output: String?
        let error: String?
        let exitCode: Int32

        var succeeded: Bool { exitCode == 0 }
    }

    /// Run an AppleScript inline string. Returns stdout or nil on error.
    static func run(_ script: String, timeout: TimeInterval = 5.0) -> String? {
        let result = runDetailed(script, timeout: timeout)
        guard result.succeeded else {
            if let error = result.error, !error.isEmpty {
                overlayError("AppleScript failed: \(error)")
            } else {
                overlayError("AppleScript failed with exit code \(result.exitCode)")
            }
            return nil
        }
        return result.output
    }

    static func runDetailed(_ script: String, timeout: TimeInterval = 5.0) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return ScriptResult(output: nil, error: error.localizedDescription, exitCode: -1)
        }
        // Wait with timeout
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return ScriptResult(output: nil, error: "Timed out after \(timeout)s", exitCode: -1)
        }
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScriptResult(output: output, error: error, exitCode: process.terminationStatus)
    }
}
