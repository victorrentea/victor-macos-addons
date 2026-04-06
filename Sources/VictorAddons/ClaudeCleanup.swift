import Foundation

private let CLEANUP_MODEL = "claude-haiku-4-5-20251001"
private let CLEANUP_MAX_TOKENS = 4096
private let CLEANUP_TIMEOUT_BASE: Double = 2.0
private let CLEANUP_TIMEOUT_PER_1K_CHARS: Double = 1.5
private let CLEANUP_TIMEOUT_MAX: Double = 15.0
private let CLEANUP_MAX_INPUT_CHARS = 5000

private let CLEANUP_PROMPT = """
Fix grammar, punctuation, and spelling errors.
Remove filler words and false starts from speech-to-text output.
Synthesize verbose text into concise form while preserving all meaning.
Add at least 1 emoji to the output, placed where it naturally fits.
Use at most 1 emoji per 2 sentences.
Detect the input language and respond in the same language.
Return ONLY the cleaned text, nothing else.
"""

class ClaudeCleanup {
    private let apiKey: String

    init?(apiKey: String) {
        guard !apiKey.isEmpty else { return nil }
        self.apiKey = apiKey
    }

    // Returns (cleanedText, costUSD) or throws
    func clean(_ text: String) async throws -> (String, Double) {
        let timeout = min(
            CLEANUP_TIMEOUT_BASE + Double(text.count) / 1000.0 * CLEANUP_TIMEOUT_PER_1K_CHARS,
            CLEANUP_TIMEOUT_MAX
        )

        let body: [String: Any] = [
            "model": CLEANUP_MODEL,
            "max_tokens": CLEANUP_MAX_TOKENS,
            "system": CLEANUP_PROMPT,
            "messages": [
                ["role": "user", "content": text]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/v1/messages")!,
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw NSError(domain: "ClaudeCleanup", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(body)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ClaudeCleanup", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid JSON response"])
        }

        guard let content = json["content"] as? [[String: Any]],
              let first = content.first,
              first["type"] as? String == "text",
              let cleanedText = first["text"] as? String else {
            throw NSError(domain: "ClaudeCleanup", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response structure"])
        }

        var inputTokens = 0
        var outputTokens = 0
        if let usage = json["usage"] as? [String: Any] {
            inputTokens = usage["input_tokens"] as? Int ?? 0
            outputTokens = usage["output_tokens"] as? Int ?? 0
        }

        let cost = Double(inputTokens) * 0.80 / 1_000_000.0
                 + Double(outputTokens) * 4.00 / 1_000_000.0

        return (cleanedText, cost)
    }
}
