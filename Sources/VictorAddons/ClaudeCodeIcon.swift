import AppKit

/// **Claude Code's own mark — Clawd, not the Claude app's asterisk**
/// (2026-09-23, Victor: *"iconița de claude code, nu claude"*). Read at runtime
/// from the newest `anthropic.claude-code-*` VS Code extension on this Mac, so
/// nothing brand-owned is bundled and an extension update brings the current
/// drawing. Nil when the extension is not installed; callers fall back.
enum ClaudeCodeIcon {
    private static let source: NSImage? = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vscode/extensions")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let newest = names.filter({ $0.hasPrefix("anthropic.claude-code-") })
                  .sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }).last
        else { return nil }
        return NSImage(contentsOf: dir.appendingPathComponent(newest)
            .appendingPathComponent("resources/clawd.svg"))
    }()

    /// A copy `height` points tall, aspect kept (Clawd is wider than tall).
    static func image(height: CGFloat) -> NSImage? {
        guard let source, source.size.height > 0,
              let copy = source.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: (source.size.width / source.size.height * height).rounded(), height: height)
        return copy
    }
}
