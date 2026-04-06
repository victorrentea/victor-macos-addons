import Foundation

enum AppleScriptRunner {
    /// Run an AppleScript inline string. Returns stdout or nil on error.
    static func run(_ script: String, timeout: TimeInterval = 5.0) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        // Wait with timeout
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
