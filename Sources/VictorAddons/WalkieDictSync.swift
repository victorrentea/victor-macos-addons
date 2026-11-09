import Foundation

/// 📖 Keeps Walkie Talkie's `vocabulary.txt` and Wispr Flow's Dictionary in sync (2026-11-09).
///
/// Victor: *"sau mai bine, îl poți programa ca timer în victor macos addons"* — instead of a
/// LaunchAgent of its own. Every 10 min (and 30 s after launch) it runs
/// `../walkie-talkie/helpers/walkie-dict sync`: a three-way merge that carries a word added or
/// deleted on either side to the other (the script's docstring has the rules). A run takes
/// milliseconds and writes only on a difference.
///
/// **The dependency points this way only**: Walkie Talkie must stay usable without this app
/// (it is public, this one private), so the sync lives here as a caller of Walkie's script, and
/// `walkie-dict add` — what an agent runs on a misheard word — still syncs on its own.
/// No checkout beside this one → every tick is a no-op.
final class WalkieDictSync {
    static let interval: TimeInterval = 600
    static let firstRun: TimeInterval = 30
    static var script: String {
        NSHomeDirectory() + "/workspace/walkie-talkie/helpers/walkie-dict"
    }

    private let queue = DispatchQueue(label: "ro.victorrentea.walkie-dict-sync", qos: .utility)
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.firstRun, repeating: Self.interval, leeway: .seconds(30))
        t.setEventHandler { Self.tick() }
        t.resume()
        timer = t
    }

    private static func tick() {
        guard FileManager.default.isExecutableFile(atPath: script) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script, "sync"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            overlayInfo("📖 walkie-dict sync could not start: \(error.localizedDescription)")
            return
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // "in sync" is the common answer and says nothing; a change or a failure is logged.
        if p.terminationStatus != 0 || text != "in sync" {
            overlayInfo("📖 walkie-dict sync (exit \(p.terminationStatus)): " + text.replacingOccurrences(of: "\n", with: " · "))
        }
    }
}
