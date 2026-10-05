import AppKit
import Darwin
import Foundation

/// One `tart run` process, as read from the kernel.
struct RunningTartVM: Equatable {
    let pid: pid_t
    let name: String
    /// The `TART_HOME` the VM was started under — `tart stop` only finds the VM
    /// there. Nil = tart's default, `~/.tart`.
    let tartHome: String?
    /// The tart binary that runs it, reused for `tart stop` so the stop talks to
    /// the same tart, wherever it was installed from.
    let executable: String
    let startedAt: Date
}

/// The pure half of 🖥️: what counts as a running VM, and how it is labelled.
enum TartVMPolicy {
    /// `tart run` flags that take the next token as their value. Without this,
    /// `tart run --dir corpus:/x wt-lab` would name the VM `corpus:/x`.
    static let valueFlags: Set<String> = [
        "--dir", "--disk", "--net-bridged", "--root-disk-opts", "--serial-path",
        "--vnc-experimental-port", "--rosetta",
    ]

    /// The VM name from a full argv (`argv[0]` included), or nil when this is not
    /// `tart run` — `tart list`, `tart stop`, `tart clone` are short-lived and are
    /// not a VM eating RAM.
    static func vmName(argv: [String]) -> String? {
        guard argv.count >= 3,
              (argv[0] as NSString).lastPathComponent == "tart",
              argv[1] == "run" else { return nil }
        var i = 2
        while i < argv.count {
            let token = argv[i]
            if token == "--" { return i + 1 < argv.count ? argv[i + 1] : nil }
            if token.hasPrefix("-") {
                i += (valueFlags.contains(token) && !token.contains("=")) ? 2 : 1
                continue
            }
            return token
        }
        return nil
    }

    /// `13h 36m`, `42m`, `2d 5h` — the menu bar has room for one short number.
    static func uptime(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// The text beside 🖥️: the VM's name (or how many), so it is never just an
    /// icon you learn to stop seeing.
    static func statusTitle(_ vms: [RunningTartVM]) -> String {
        switch vms.count {
        case 0: return ""
        case 1: return "🖥️ \(vms[0].name)"
        default: return "🖥️ \(vms.count) VMs"
        }
    }
}

/// 🖥️ **A menu bar item that exists only while a tart VM is running** (2026-10-05).
///
/// The walkie lab VM (`wt-lab`, 8 GB) stayed up for 13½ hours unnoticed, on a
/// morning when Docker was also holding 12 GB, swap was full and WindowServer
/// was dropping frames. Nothing on screen said a VM was there: `tart run
/// --no-graphics` has no window and no Dock icon. So this polls the process
/// table every 5 s and shows its own status item — separate from 💬, so it
/// appears and disappears instead of hiding in a submenu — with a **Stop** row
/// per VM.
///
/// Stop runs `tart stop <name>` under the VM's own `TART_HOME` (read from the
/// process's environment; `~/tart` and the default `~/.tart` both exist on this
/// Mac and a stop under the wrong one answers "does not exist"), and falls back
/// to SIGINT on the `tart run` process, which tart handles as a clean shutdown.
final class TartVMIndicator: NSObject, NSMenuDelegate {
    static let pollInterval: TimeInterval = 5
    static let autosaveName = "tartVM"
    static let preferredPosition = 230

    private let queue = DispatchQueue(label: "ro.victorrentea.tart-vm-indicator", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var statusItem: NSStatusItem?
    private var vms: [RunningTartVM] = []   // main thread only

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: Self.pollInterval, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        let found = Self.runningVMs()
        DispatchQueue.main.async { [weak self] in self?.show(found) }
    }

    // MARK: - Status item

    private func show(_ found: [RunningTartVM]) {
        let appeared = vms.isEmpty && !found.isEmpty
        vms = found
        guard !found.isEmpty else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            // A new status item lands **left** of every existing one, and on this
            // Mac's crowded bar that is under the notch — measured 2026-10-05, the
            // first build's item was simply not on screen. So the first appearance
            // is pinned near the clock (points from the right edge; Battery sits at
            // 157); a ⌘-drag afterwards overwrites the key and sticks.
            let positionKey = "NSStatusItem Preferred Position \(Self.autosaveName)"
            if UserDefaults.standard.object(forKey: positionKey) == nil {
                UserDefaults.standard.set(Self.preferredPosition, forKey: positionKey)
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = Self.autosaveName
            item.isVisible = true
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        statusItem?.button?.title = TartVMPolicy.statusTitle(found)
        statusItem?.button?.toolTip = found.map { "\($0.name) running for \(TartVMPolicy.uptime(-$0.startedAt.timeIntervalSinceNow))" }
            .joined(separator: "\n")
        if appeared { overlayInfo("🖥️ tart VM running: \(found.map(\.name).joined(separator: ", "))") }
    }

    /// Built on open, so the uptime in the rows is the uptime now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for vm in vms {
            let home = vm.tartHome.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/.tart"
            let info = NSMenuItem(title: "\(vm.name) — up \(TartVMPolicy.uptime(-vm.startedAt.timeIntervalSinceNow)) · \(home)",
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            let stop = NSMenuItem(title: "⏹ Stop \(vm.name)", action: #selector(stopClicked(_:)), keyEquivalent: "")
            stop.target = self
            stop.representedObject = vm.pid
            menu.addItem(stop)
            menu.addItem(.separator())
        }
        if vms.count > 1 {
            let all = NSMenuItem(title: "⏹ Stop all \(vms.count) VMs", action: #selector(stopAllClicked), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    @objc private func stopClicked(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t,
              let vm = vms.first(where: { $0.pid == pid }) else { return }
        stop([vm])
    }

    @objc private func stopAllClicked() { stop(vms) }

    private func stop(_ targets: [RunningTartVM]) {
        statusItem?.button?.title = "🖥️ stopping…"
        queue.async { [weak self] in
            for vm in targets { Self.stop(vm) }
            self?.poll()
        }
    }

    // MARK: - Process table

    static func stop(_ vm: RunningTartVM) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: vm.executable)
        process.arguments = ["stop", vm.name]
        var env = ProcessInfo.processInfo.environment
        env["TART_HOME"] = vm.tartHome
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                overlayInfo("🖥️ tart VM \(vm.name) stopped")
                return
            }
        } catch {}
        // `tart stop` could not find it (unknown TART_HOME, moved binary):
        // SIGINT is what Ctrl-C on `tart run` sends, and tart shuts the guest down on it.
        let sent = kill(vm.pid, SIGINT) == 0
        overlayInfo(sent ? "🖥️ tart VM \(vm.name): tart stop failed, sent SIGINT to \(vm.pid)"
                         : "🖥️ tart VM \(vm.name): could not stop pid \(vm.pid)")
    }

    static func runningVMs() -> [RunningTartVM] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var name = [CChar](repeating: 0, count: 256)
        var found: [RunningTartVM] = []
        for pid in pids.prefix(max(0, n)) where pid > 0 {
            // The cheap filter first: the short process name, before any argv read.
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "tart",
                  let args = procArgs(pid),
                  let vmName = TartVMPolicy.vmName(argv: args.argv) else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let started = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
                ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)) : Date()
            found.append(RunningTartVM(pid: pid, name: vmName, tartHome: args.env["TART_HOME"],
                                       executable: args.executable, startedAt: started))
        }
        return found.sorted { $0.startedAt < $1.startedAt }
    }

    /// `KERN_PROCARGS2`: argc, the executable path, argv, then the environment —
    /// readable for any process of the same user, no entitlement.
    static func procArgs(_ pid: pid_t) -> (executable: String, argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs2(Array(buffer.prefix(size)))
    }

    static func parseProcArgs2(_ bytes: [UInt8]) -> (executable: String, argv: [String], env: [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        func nextString() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            i += 1
            return s
        }
        guard let executable = nextString() else { return nil }
        while i < bytes.count, bytes[i] == 0 { i += 1 }   // padding after the executable path
        var argv: [String] = []
        for _ in 0..<argc { guard let a = nextString() else { break }; argv.append(a) }
        var env: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            if let eq = entry.firstIndex(of: "=") { env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...]) }
        }
        return (executable, argv, env)
    }
}
