import Foundation
import WriteCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A `DeviceWriter` backed by `mlx_lm.server` over the loopback.
///
/// The point is homogeneity: the Macs run the same `mlx-community` weights the
/// phones do, through MLX on the same Metal path, so a throughput comparison
/// across the fleet measures hardware rather than two different inference
/// engines. Ollama serves GGUF through llama.cpp, which is a different runtime
/// and a different quantisation of a different model — useful capacity, but
/// not a comparable number.
///
/// This talks the OpenAI completions shape rather than Ollama's, because that
/// is what `mlx_lm.server` exposes. Everything else — limits, the enforced
/// boundary, the reported profile — is unchanged, so the mesh sees one
/// contract regardless of what is behind it.
public struct MLXServerWriter: DeviceWriter {
  public let limits: DeviceLimits
  public let model: String
  public let baseURL: URL

  public init(
    model: String,
    baseURL: URL = URL(string: "http://127.0.0.1:8081")!,
    limits: DeviceLimits = .qwen3_4B_4bit
  ) {
    self.model = model
    self.baseURL = baseURL
    self.limits = limits
  }

  /// A dedicated session, because `URLSession.shared` caps `httpMaximumConnectionsPerHost`
  /// at 6 — and that cap silently became the node's throughput ceiling. The
  /// backing `mlx_lm.server` batches concurrent decodes (one weight read feeds
  /// the whole batch), so it returns 554 tok/s at 32 concurrent requests but
  /// only ~300 when six may be in flight. The agent was throttling the very
  /// batching it exists to expose. 64 is comfortably above the server's
  /// `--decode-concurrency`, so the ceiling is the model, not the plumbing.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 64
    config.timeoutIntervalForRequest = 300
    config.timeoutIntervalForResource = 600
    return URLSession(configuration: config)
  }()

  public func generateDetailed(
    prompt: String, maxOutputTokens: Int
  ) async throws -> Generation {
    let (text, tokens) = try await complete(prompt: prompt, maxOutputTokens: maxOutputTokens)
    return Generation(text: text, tokens: tokens)
  }

  public func generate(prompt: String, maxOutputTokens: Int) async throws -> String {
    try await complete(prompt: prompt, maxOutputTokens: maxOutputTokens).text
  }

  /// The completion plus the server's own token count, which is the only
  /// honest one available — character-derived estimates read about a third high.
  private func complete(
    prompt: String, maxOutputTokens: Int
  ) async throws -> (text: String, tokens: Int?) {
    guard prompt.count <= limits.maxInputCharacters else {
      throw LANError.promptOverLimit(prompt.count)
    }
    let tokens = min(max(1, maxOutputTokens), limits.maxOutputTokens)

    var request = URLRequest(url: baseURL.appendingPathComponent("v1/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.timeoutInterval = 300
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model,
      "prompt": prompt,
      "max_tokens": tokens,
      "temperature": 0.7,
      "stream": false,
    ])

    let (data, response) = try await Self.session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw LANError.ollama(String(data: data, encoding: .utf8) ?? "no body")
    }
    guard
      let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = envelope["choices"] as? [[String: Any]],
      let text = choices.first?["text"] as? String
    else {
      throw LANError.ollama("no completion in response")
    }
    // Qwen3 emits reasoning in <think> blocks. Stripping them here keeps the
    // block out of section prose, where it would otherwise reach the verifier
    // as content and be counted toward the length budget.
    let usage = envelope["usage"] as? [String: Any]
    return (Self.stripThinking(text), usage?["completion_tokens"] as? Int)
  }

  /// Removes `<think>…</think>` spans, including an unterminated trailing one.
  static func stripThinking(_ text: String) -> String {
    var out = ""
    var rest = Substring(text)
    while let open = rest.range(of: "<think>") {
      out += rest[rest.startIndex..<open.lowerBound]
      guard let close = rest.range(of: "</think>", range: open.upperBound..<rest.endIndex)
      else {
        // Truncated mid-thought: everything after the open tag is reasoning.
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      rest = rest[close.upperBound...]
    }
    out += rest
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
