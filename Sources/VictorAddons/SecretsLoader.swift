import Foundation

enum SecretsLoader {
    static func load() -> [String: String] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".training-assistants-secrets.env").path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in content.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard !stripped.hasPrefix("#"), stripped.contains("=") else { continue }
            let parts = stripped.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}
