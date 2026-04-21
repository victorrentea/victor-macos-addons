import Foundation
import CoreGraphics

/// Snaps each Terminal window to the nearest free quadrant of its current monitor.
/// Minimizes total movement (brute-force permutations — fine for ≤4 windows per monitor).
/// Windows stay on whichever display they currently occupy.
enum TerminalTiler {

    private static let MARGIN = 2

    private struct Rect {
        let x: Int, y: Int, w: Int, h: Int
        var x2: Int { x + w }
        var y2: Int { y + h }
        var center: (Double, Double) { (Double(x) + Double(w) / 2, Double(y) + Double(h) / 2) }
    }

    static func tile() {
        let displays = getDisplays()
        let wins = getTerminalWindows()
        guard !displays.isEmpty, !wins.isEmpty else { return }

        var groups: [Int: [(idx: Int, rect: Rect)]] = [:]
        for w in wins {
            let (cx, cy) = w.rect.center
            let di = displayFor(cx: cx, cy: cy, displays: displays)
            groups[di, default: []].append(w)
        }

        var commands: [String] = []
        for (di, var ws) in groups {
            let quads = quadrants(of: displays[di])
            ws = Array(ws.prefix(quads.count))
            let assignment = assignOptimally(windows: ws, quads: quads)
            for (i, w) in ws.enumerated() {
                let q = quads[assignment[i]]
                commands.append("tell window \(w.idx) to set position to {\(q.x), \(q.y)}")
                commands.append("tell window \(w.idx) to set size to {\(q.w), \(q.h)}")
            }
        }

        guard !commands.isEmpty else { return }
        let apple = """
        tell application "System Events"
            tell process "Terminal"
        \(commands.joined(separator: "\n"))
            end tell
        end tell
        """
        _ = AppleScriptRunner.run(apple)
    }

    // MARK: - Displays

    private static func getDisplays() -> [Rect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map {
            let b = CGDisplayBounds($0)
            return Rect(x: Int(b.origin.x), y: Int(b.origin.y),
                        w: Int(b.size.width), h: Int(b.size.height))
        }
    }

    private static func displayFor(cx: Double, cy: Double, displays: [Rect]) -> Int {
        for (i, d) in displays.enumerated() {
            if Double(d.x) <= cx, cx < Double(d.x2),
               Double(d.y) <= cy, cy < Double(d.y2) { return i }
        }
        return 0
    }

    // MARK: - Terminal windows

    private static func getTerminalWindows() -> [(idx: Int, rect: Rect)] {
        // System Events is the only reliable way to read/write Terminal window geometry
        // (Terminal's own AppleScript bounds setter silently refuses some moves).
        let script = """
        tell application "System Events"
            tell process "Terminal"
                set out to ""
                set i to 0
                repeat with w in windows
                    set i to i + 1
                    set p to position of w
                    set s to size of w
                    set out to out & i & "," & (item 1 of p) & "," & (item 2 of p) & "," & (item 1 of s) & "," & (item 2 of s) & linefeed
                end repeat
                return out
            end tell
        end tell
        """
        guard let output = AppleScriptRunner.run(script) else { return [] }
        return output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: ",").compactMap { Int($0) }
                guard parts.count == 5 else { return nil }
                return (idx: parts[0],
                        rect: Rect(x: parts[1], y: parts[2], w: parts[3], h: parts[4]))
            }
    }

    // MARK: - Quadrants & assignment

    private static func quadrants(of d: Rect) -> [Rect] {
        let hw = d.w / 2, hh = d.h / 2
        return [
            Rect(x: d.x + MARGIN,  y: d.y + MARGIN, w: hw - MARGIN, h: hh - MARGIN),
            Rect(x: d.x + hw,      y: d.y + MARGIN, w: hw - MARGIN, h: hh - MARGIN),
            Rect(x: d.x + MARGIN,  y: d.y + hh,     w: hw - MARGIN, h: hh - MARGIN),
            Rect(x: d.x + hw,      y: d.y + hh,     w: hw - MARGIN, h: hh - MARGIN),
        ]
    }

    private static func dist2(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = a.0 - b.0, dy = a.1 - b.1
        return dx*dx + dy*dy
    }

    private static func permutations(of n: Int, choose k: Int) -> [[Int]] {
        if k == 0 { return [[]] }
        var result: [[Int]] = []
        for i in 0..<n {
            for rest in permutations(of: n, choose: k - 1) where !rest.contains(i) {
                result.append([i] + rest)
            }
        }
        return result
    }

    private static func assignOptimally(windows: [(idx: Int, rect: Rect)], quads: [Rect]) -> [Int] {
        var bestPerm: [Int] = []
        var bestCost = Double.infinity
        for perm in permutations(of: quads.count, choose: windows.count) {
            let cost = (0..<windows.count).reduce(0.0) { acc, i in
                acc + dist2(windows[i].rect.center, quads[perm[i]].center)
            }
            if cost < bestCost { bestCost = cost; bestPerm = perm }
        }
        return bestPerm
    }
}
