import AppKit
import Foundation

// --- PID lock file: ensure only one instance runs at a time ---
let pidFilePath = "/tmp/VictorAddons.pid"
let myPid = getpid()

// Kill any previous instance before we start
if let oldPidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
   let oldPid = Int32(oldPidStr),
   oldPid != myPid {
    overlayInfo("Stopping previous instance...")
    kill(oldPid, SIGTERM)
    // Give it a moment, then force-kill if still alive
    usleep(200_000) // 200ms
    if kill(oldPid, 0) == 0 {
        overlayInfo("Previous instance stuck — force killing")
        kill(oldPid, SIGKILL)
    }
}

// Write our PID (supersedes any previous instance)
try? "\(myPid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)

// Clean up lock file on exit (only if we still own it)
func cleanupLockFile() {
    if let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       let pid = Int32(pidStr),
       pid == myPid {
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }
}
atexit { cleanupLockFile() }

// Handle SIGTERM gracefully so kill() from a new instance works
signal(SIGTERM) { _ in
    cleanupLockFile()
    exit(0)
}

// --- Normal startup ---
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no dock icon

// Remember our parent PID (start.sh) — if it dies, we should too
let originalParentPID = getppid()

// Server URL from command line or default
let serverURL: String
if CommandLine.arguments.count > 1 {
    serverURL = CommandLine.arguments[1]
} else {
    serverURL = "ws://localhost:8000"
}
overlayInfo("Starting VictorAddons, connecting to \(serverURL) (parent pid: \(originalParentPID))")

let delegate = AppDelegate(serverURL: serverURL, pidFilePath: pidFilePath, myPID: myPid)
app.delegate = delegate

// Periodic self-check: exit if another instance took over OR parent process died
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    // Check 1: PID file replaced by newer instance
    if let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
       let filePid = Int32(pidStr),
       filePid != myPid {
        overlayInfo("Replaced by newer instance — exiting")
        cleanupLockFile()
        exit(0)
    }

    // Check 2: Parent process (start.sh) died — ppid changes to 1 (launchd)
    let currentParent = getppid()
    if currentParent != originalParentPID {
        overlayInfo("Parent process died (\(originalParentPID) → \(currentParent)) — exiting")
        cleanupLockFile()
        exit(0)
    }
}

app.run()
