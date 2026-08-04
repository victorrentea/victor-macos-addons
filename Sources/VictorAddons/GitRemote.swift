import Foundation

/// Normalizes git remote URLs to their canonical https form.
/// Extracted from the deleted IntelliJMonitor, which the plugin superseded —
/// the plugin-POST handler still needs it.
enum GitRemote {
    /// e.g. `git@github.com:owner/repo.git` → `https://github.com/owner/repo`
    static func https(_ remoteURL: String) -> String {
        var url = remoteURL
        if url.hasPrefix("git@") {
            url = url.replacingOccurrences(of: ":", with: "/")
                .replacingOccurrences(of: "git@", with: "https://")
        }
        return url.replacingOccurrences(of: "\\.git$", with: "", options: .regularExpression)
    }
}
