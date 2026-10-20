import AppKit
import Darwin
import Foundation

/// 📈 Traffic — what this Mac is moving right now: bytes in and out per second,
/// the round-trip time of its live connections, and the three apps doing most
/// of it (2026-10-20, Victor: *"throughput out, throughput in, latency, and top
/// three applications … only when I start hovering the menu item"*).
///
/// **Nothing runs until the submenu opens.** Hovering the row opens it (AppKit's
/// own submenu delay); `menuWillOpen` starts the sampling, `menuDidClose` stops
/// it — the `nettop` child is terminated and the counter timer invalidated, so a
/// closed menu costs nothing.
///
/// Three sources, all readable without root:
/// - **In/out** — the kernel's per-interface byte counters (`getifaddrs`, the
///   same numbers `netstat -ib` prints), summed over the `en*` interfaces and
///   diffed once a second. `utun*` is left out: a VPN's bytes also cross `en0`,
///   and counting both would double them.
/// - **Top apps** — `nettop -d` (delta mode), one block per second, per process;
///   helpers are folded into the `.app` they ship in, so Chrome is one line.
/// - **Latency** — the kernel's smoothed TCP RTT (`rtt_avg`) of each open
///   connection to a public address, from the same `nettop` stream: passive, the
///   real latency of real connections, no probe sent. The median, so one stale
///   idle socket (seen at 16 s) does not move it.
enum TrafficPolicy {

    struct Row: Equatable {
        /// `Google Chrome H.45972` for a process; nil for a connection.
        let process: String?
        let pid: pid_t?
        /// Remote address of a connection (`17.57.146.24`), nil for a process.
        let remote: String?
        let isTCP: Bool
        let bytesIn: Int
        let bytesOut: Int
        let rttMs: Double?
    }

    /// One line of `nettop -x -n -J bytes_in,bytes_out,rtt_avg`, or nil for the
    /// header / anything unexpected. Connection lines carry `<->`; nettop
    /// truncates the RTT column to its width (`1247.78 m`, `16787.62`), so only
    /// the leading number is read and the unit is always milliseconds.
    static func parse(line: String) -> Row? {
        // The name may itself contain commas only in theory; the three numeric
        // columns are always the last three (plus nettop's trailing comma).
        var cols = line.components(separatedBy: ",")
        if cols.last == "" { cols.removeLast() }
        guard cols.count >= 4, !cols[0].isEmpty else { return nil }
        let rttText = cols[cols.count - 1]
        guard let bytesOut = Int(cols[cols.count - 2]), let bytesIn = Int(cols[cols.count - 3]) else { return nil }
        let name = cols[0..<(cols.count - 3)].joined(separator: ",")
        let rtt = Double(rttText.prefix { $0.isNumber || $0 == "." })

        if let arrow = name.range(of: "<->") {
            let remoteEndpoint = String(name[arrow.upperBound...])
            return Row(process: nil, pid: nil, remote: host(of: remoteEndpoint),
                       isTCP: name.hasPrefix("tcp"), bytesIn: bytesIn, bytesOut: bytesOut,
                       rttMs: (rtt ?? 0) > 0 ? rtt : nil)
        }
        let dot = name.lastIndex(of: ".")
        let pid = dot.flatMap { pid_t(name[name.index(after: $0)...]) }
        return Row(process: pid == nil ? name : String(name[..<dot!]), pid: pid, remote: nil,
                   isTCP: false, bytesIn: bytesIn, bytesOut: bytesOut, rttMs: nil)
    }

    /// `17.57.146.24:5223` → `17.57.146.24`; IPv6 puts the port after a dot
    /// (`2a00:1450::1.443`).
    static func host(of endpoint: String) -> String {
        let separator: Character = endpoint.contains(".") && endpoint.filter({ $0 == ":" }).count > 1 ? "." : ":"
        guard let i = endpoint.lastIndex(of: separator) else { return endpoint }
        return String(endpoint[..<i])
    }

    /// LAN, loopback and link-local peers say nothing about the internet's
    /// latency — the tablet on 10.x answers in 0 ms, an AirPlay socket in 2.7 s.
    static func isPublic(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "*" || h.isEmpty { return false }
        if h.contains(":") {
            return !(h == "::1" || h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd"))
        }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false   // CGNAT / Tailscale
        default: return true
        }
    }

    /// Median RTT of the public TCP connections, preferring those that moved
    /// bytes in this sample: an idle socket's smoothed RTT is whatever it was
    /// when it last spoke.
    static func latency(of rows: [Row]) -> (ms: Double, connections: Int)? {
        let tcp = rows.filter { $0.isTCP && $0.rttMs != nil && $0.remote.map(isPublic) == true }
        let active = tcp.filter { $0.bytesIn + $0.bytesOut > 0 }
        let pool = (active.isEmpty ? tcp : active).compactMap(\.rttMs).sorted()
        guard !pool.isEmpty else { return nil }
        let mid = pool.count / 2
        let median = pool.count % 2 == 1 ? pool[mid] : (pool[mid - 1] + pool[mid]) / 2
        return (median, pool.count)
    }

    struct App: Equatable {
        let name: String
        let bytesIn: Int
        let bytesOut: Int
    }

    /// The `count` busiest apps of one delta block, by bytes in + out. `appName`
    /// folds a pid into the app that owns it (helpers into their `.app`).
    static func topApps(of rows: [Row], count: Int = 3, appName: (Row) -> String) -> [App] {
        var totals: [String: (Int, Int)] = [:]
        for row in rows where row.process != nil && row.bytesIn + row.bytesOut > 0 {
            let name = appName(row)
            let t = totals[name] ?? (0, 0)
            totals[name] = (t.0 + row.bytesIn, t.1 + row.bytesOut)
        }
        return totals.map { App(name: $0.key, bytesIn: $0.value.0, bytesOut: $0.value.1) }
            .sorted { ($0.bytesIn + $0.bytesOut, $1.name) > ($1.bytesIn + $1.bytesOut, $0.name) }
            .prefix(count).map { $0 }
    }

    /// `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome
    /// Helper.app/Contents/MacOS/Google Chrome Helper` → `Google Chrome`: the
    /// **outermost** bundle, which is the app Victor would recognise.
    static func appName(executablePath: String) -> String? {
        guard let r = executablePath.range(of: ".app/") else { return nil }
        return executablePath[..<r.lowerBound].split(separator: "/").last.map(String.init)
    }

    /// Bytes per second, decimal units like Activity Monitor's network tab.
    static func rate(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b < 1_000 { return "\(Int(b)) B/s" }
        if b < 1_000_000 { return String(format: "%.0f KB/s", b / 1_000) }
        return String(format: "%.1f MB/s", b / 1_000_000)
    }

    /// Wrap-aware difference of two 32-bit interface counters (`if_data` is
    /// 32-bit and wraps every 4 GB — once every half hour at 2 MB/s).
    static func delta(_ now: UInt32, _ before: UInt32) -> UInt64 {
        UInt64(now &- before)
    }
}

/// The 📈 Traffic row and its submenu. Owns its own `NSMenuDelegate`, so opening
/// it does not run `MenuBarManager`'s `menuNeedsUpdate` (which rebuilds the
/// whole top level).
final class TrafficMenu: NSObject, NSMenuDelegate {

    let item: NSMenuItem
    private let submenu = NSMenu()
    private let inItem = TrafficMenu.readout("↓ In   measuring…")
    private let outItem = TrafficMenu.readout("↑ Out  measuring…")
    private let latencyItem = TrafficMenu.readout("⏱️ Latency  measuring…")
    private let appItems = (0..<3).map { _ in TrafficMenu.readout("") }

    private var nettop: Process?
    private var counterTimer: Timer?
    private var lastCounters: [String: (UInt32, UInt32)] = [:]
    private var lastCounterTime: TimeInterval = 0
    private var pendingLines: [String] = []
    private var blocksSeen = 0
    private var flushScheduled = false
    private var appNames: [pid_t: String] = [:]

    override init() {
        item = NSMenuItem(title: "📈 Traffic", action: nil, keyEquivalent: "")
        super.init()
        item.toolTip = "Hover to measure: bytes in/out per second, latency of the open connections, and the three busiest apps. Nothing runs while closed."
        submenu.autoenablesItems = false
        submenu.delegate = self
        [inItem, outItem, latencyItem].forEach(submenu.addItem)
        submenu.addItem(.separator())
        appItems.forEach(submenu.addItem)
        item.submenu = submenu
    }

    /// Enabled with no action: drawn in full colour (a disabled row is dimmed,
    /// which is wrong for a live number), and a click just closes the menu.
    private static func readout(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        return item
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        startSampling()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === submenu else { return }
        stopSampling()
    }

    // MARK: - Sampling

    /// Where `GET /test/menu/open?traffic=1` leaves the rows it saw.
    static let testOutput = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".victor-addons/traffic-test.txt")

    func startSampling() {
        stopSampling()
        inItem.title = "↓ In   measuring…"
        outItem.title = "↑ Out  measuring…"
        latencyItem.title = "⏱️ Latency  measuring…"
        appItems.forEach { $0.title = "…"; $0.isHidden = false }
        appItems.dropFirst().forEach { $0.isHidden = true }

        lastCounters = Self.readCounters()
        lastCounterTime = ProcessInfo.processInfo.systemUptime
        // `.common`: while the menu tracks, the run loop is in event-tracking
        // mode and a default-mode timer would never fire.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sampleCounters() }
        RunLoop.main.add(timer, forMode: .common)
        counterTimer = timer

        startNettop()
    }

    func stopSampling(writingTestOutput: Bool = false) {
        if writingTestOutput {
            let rows = ([inItem, outItem, latencyItem] + appItems.filter { !$0.isHidden }).map(\.title)
            try? (rows.joined(separator: "\n") + "\n").write(to: Self.testOutput, atomically: true, encoding: .utf8)
        }
        counterTimer?.invalidate()
        counterTimer = nil
        if let p = nettop {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        nettop = nil
        pendingLines = []
        blocksSeen = 0
    }

    private func sampleCounters() {
        let now = ProcessInfo.processInfo.systemUptime
        let counters = Self.readCounters()
        let seconds = max(0.001, now - lastCounterTime)
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        for (name, c) in counters {
            guard let before = lastCounters[name] else { continue }
            bytesIn += TrafficPolicy.delta(c.0, before.0)
            bytesOut += TrafficPolicy.delta(c.1, before.1)
        }
        lastCounters = counters
        lastCounterTime = now
        inItem.title = "↓ In   " + TrafficPolicy.rate(Double(bytesIn) / seconds)
        outItem.title = "↑ Out  " + TrafficPolicy.rate(Double(bytesOut) / seconds)
    }

    /// Byte counters of the `en*` interfaces that are up (Wi-Fi, Ethernet
    /// dongles, the iPhone/Android USB tether).
    private static func readCounters() -> [String: (UInt32, UInt32)] {
        var result: [String: (UInt32, UInt32)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return result }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self).pointee else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            result[name] = (data.ifi_ibytes, data.ifi_obytes)
        }
        return result
    }

    private func startNettop() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-d", "-s", "1", "-L", "0", "-x", "-n", "-t", "external",
                       "-J", "bytes_in,bytes_out,rtt_avg"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var partial = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            partial += chunk
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            // Hop onto the main run loop in *common* modes: the main queue is
            // not drained while the menu tracks, so `DispatchQueue.main` would
            // deliver every sample only after the menu closed.
            RunLoop.main.perform(inModes: [.common]) { self?.receive(lines) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        do {
            try p.run()
            nettop = p
        } catch {
            latencyItem.title = "⏱️ Latency  nettop failed"
        }
    }

    /// nettop prints one header line (`,bytes_in,…`) per sample, then the rows,
    /// all in one burst. A block is taken as complete 0.2 s after its last line
    /// arrived, rather than at the next header a second later.
    private func receive(_ lines: [String]) {
        for line in lines {
            if line.hasPrefix(",") {
                flush()
                blocksSeen += 1
            } else if !line.isEmpty {
                pendingLines.append(line)
            }
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.flushScheduled = false
            self?.flush()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func flush() {
        let lines = pendingLines
        pendingLines = []
        // The first block of delta mode is the totals since each socket opened,
        // not one second's worth.
        guard blocksSeen >= 2, !lines.isEmpty, nettop != nil else { return }
        let rows = lines.compactMap(TrafficPolicy.parse(line:))

        if let l = TrafficPolicy.latency(of: rows) {
            latencyItem.title = String(format: "⏱️ Latency  %.0f ms", l.ms) + "  (\(l.connections) conn.)"
        } else {
            latencyItem.title = "⏱️ Latency  no open connection"
        }

        let top = TrafficPolicy.topApps(of: rows) { [unowned self] in self.appName(for: $0) }
        for (i, row) in appItems.enumerated() {
            if i < top.count {
                let app = top[i]
                row.title = "\(i + 1). \(app.name)   ↓ \(TrafficPolicy.rate(Double(app.bytesIn)))  ↑ \(TrafficPolicy.rate(Double(app.bytesOut)))"
                row.isHidden = false
            } else {
                row.title = i == 0 ? "No app is moving data" : ""
                row.isHidden = i > 0
            }
        }
    }

    private func appName(for row: TrafficPolicy.Row) -> String {
        let fallback = row.process ?? "?"
        guard let pid = row.pid else { return fallback }
        if let cached = appNames[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let name: String
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            name = TrafficPolicy.appName(executablePath: String(cString: buffer)) ?? fallback
        } else {
            name = fallback
        }
        appNames[pid] = name
        return name
    }
}
