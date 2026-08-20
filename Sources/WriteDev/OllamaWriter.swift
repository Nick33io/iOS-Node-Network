import Foundation
import WriteCore

/// Development stand-in for the on-device writer.
///
/// Talks to a local Ollama daemon but holds itself to the same contract the
/// MLX writer will have: identical limits, prompt-length rejection at the
/// boundary, capped output tokens, and no conversation state between calls
/// (each request is a fresh, stateless generate — the moral equivalent of the
/// cleared KV cache).
struct OllamaWriter: DeviceWriter {
  let limits = DeviceLimits.qwen3_4B_4bit
  let model: String
  let baseURL = URL(string: "http://127.0.0.1:11434")!

  func generate(prompt: String, maxOutputTokens: Int) async throws -> String {
    guard prompt.count <= limits.maxInputCharacters else {
      throw DevWriterError.promptOverLimit(prompt.count)
    }
    let tokens = min(max(1, maxOutputTokens), limits.maxOutputTokens)

    var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.timeoutInterval = 300
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model,
      "prompt": prompt,
      "stream": false,
      "options": [
        "num_predict": tokens,
        "num_ctx": limits.maxContextTokens,
        "temperature": 0.7,
      ],
    ] as [String: Any])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw DevWriterError.ollama(String(data: data, encoding: .utf8) ?? "no body")
    }
    let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let text = envelope?["response"] as? String else {
      throw DevWriterError.ollama("no response field")
    }
    return text
  }
}

enum DevWriterError: Error, CustomStringConvertible {
  case promptOverLimit(Int)
  case ollama(String)

  var description: String {
    switch self {
    case .promptOverLimit(let count):
      return "Prompt of \(count) characters exceeds the device limit."
    case .ollama(let detail):
      return "Ollama failure: \(detail)"
    }
  }
}
