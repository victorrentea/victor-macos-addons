import Foundation

/// Minimal client for **mpv's JSON IPC** — the control channel IINA exposes when
/// launched with `--mpv-input-ipc-server=<path>`. It is how `VideoPlayer` can
/// still talk to the player after handing it off: ask whether playback hit the
/// end, rewind it, pause it.
///
/// One connection per command (connect → write one line → read one line → close)
/// rather than a long-lived session: the commands are a handful per second at
/// most, and a socket that has to survive the player quitting, restarting and
/// being killed is far more state than this is worth.
///
/// Every failure — no socket yet (the player takes ~a second to create it), the
/// player gone, a timeout — comes back as `nil`. Callers treat that as "nothing
/// to do", never as an error worth surfacing.
enum MpvIPC {
    /// Send one command and return its decoded reply, or nil.
    @discardableResult
    static func send(socketPath: String, command: [Any], timeout: TimeInterval = 0.4) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        guard let payload = try? JSONSerialization.data(withJSONObject: ["command": command]) else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxPath else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxPath) { dst in
                _ = strncpy(dst, socketPath, maxPath - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, size)
            }
        }
        guard connected == 0 else { return nil }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var line = payload
        line.append(0x0A)  // mpv reads one JSON command per line
        let written = line.withUnsafeBytes { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
        guard written == line.count else { return nil }

        // Read until the first newline: that's this command's reply. mpv can also
        // emit unsolicited event lines, so keep reading past any line that isn't
        // an answer (it has no "error" key) until the deadline.
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   obj["error"] != nil {
                    return obj
                }
            }
        }
        return nil
    }

    /// Read a property, or nil when the player isn't answering / doesn't have it.
    static func property(socketPath: String, _ name: String) -> Any? {
        guard let reply = send(socketPath: socketPath, command: ["get_property", name]),
              (reply["error"] as? String) == "success" else { return nil }
        return reply["data"]
    }

    static func boolProperty(socketPath: String, _ name: String) -> Bool? {
        property(socketPath: socketPath, name) as? Bool
    }
}
