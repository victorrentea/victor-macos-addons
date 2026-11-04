import AppKit

/// The agent's own icon, read off the Mac at runtime — nothing brand-owned is
/// bundled. Claude Code's Clawd from its VS Code extension, Copilot's from the
/// extension VS Code ships, Cursor's from its own app. Nil when the file is
/// missing (or the source is unknown); callers fall back to `PromptSource.badge`.
///
/// Shared by the 🤖 Prompts panel's rows and the bottom-left offer pill, so the
/// prompt Victor sees fly by and the row it becomes later wear the same face.
extension PromptSource {
    func icon(height: CGFloat) -> NSImage? {
        switch self {
        case .claude:
            return ClaudeCodeIcon.image(height: height)
        case .copilot:
            guard let source = Self.copilotSource, source.size.height > 0,
                  let copy = source.copy() as? NSImage else { return nil }
            copy.size = NSSize(width: (source.size.width / source.size.height * height).rounded(),
                               height: height)
            return copy
        case .cursor:
            guard FileManager.default.fileExists(atPath: Self.cursorApp) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: Self.cursorApp)
            icon.size = NSSize(width: height, height: height)
            return icon
        case .unknown:
            return nil
        }
    }

    private static let cursorApp = "/Applications/Cursor.app"

    private static let copilotSource: NSImage? = NSImage(contentsOfFile:
        "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/copilot/assets/copilot.png")
}
