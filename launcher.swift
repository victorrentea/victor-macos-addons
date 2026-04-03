import AVFoundation
import Foundation

// Read repo path from bundle Resources/repo_path
let bundle = Bundle.main
let repoPathFile = bundle.resourceURL!.appendingPathComponent("repo_path")
let repoDir = try! String(contentsOf: repoPathFile, encoding: .utf8)

func launch() {
    let startScript = "\(repoDir)/start.sh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
    process.arguments = ["-arm64", startScript]
    try? process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
}

// Check/request mic permission — this triggers the macOS consent dialog
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    launch()
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .audio) { _ in
        launch()
    }
    RunLoop.main.run()
case .denied, .restricted:
    fputs("Mic access denied — enable in System Settings → Privacy → Microphone\n", stderr)
    launch()
@unknown default:
    launch()
}
