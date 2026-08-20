import Foundation
import WriteCore
import WriteCloud

/// Development planner over a strong local model, for when the Anthropic
/// account is out of credits. Reuses `AnthropicPlanner`'s prompts verbatim so
/// a later switch back changes the transport and nothing else.
///
/// The local Ollama build ignores the `format` parameter entirely (verified
/// against 0.32.14: identical prose output with a schema, `"json"`, or
/// nothing), so schema adherence is prompt-driven here and the response is
/// mined for its first balanced JSON object. `Plan.validate` remains the
/// semantic gate either way; this only has to get parseable JSON out.
struct OllamaPlanner: CloudPlanner {
  let model: String
  let baseURL = URL(string: "http://127.0.0.1:11434")!
  let attempts = 2

  func plan(_ request: PlanRequest) async throws -> Plan {
    var lastError: Error = DevWriterError.ollama("no attempts made")
    for _ in 0..<attempts {
      do {
        return try await planOnce(request)
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  private func planOnce(_ request: PlanRequest) async throws -> Plan {
    let schemaData = try JSONSerialization.data(withJSONObject: AnthropicPlanner.planSchema)
    let schema = String(data: schemaData, encoding: .utf8) ?? "{}"

    let prompt = """
      \(AnthropicPlanner.systemPrompt)

      \(AnthropicPlanner.userPrompt(request))

      Respond with a single JSON object matching this schema, and nothing else \
      — no preamble, no markdown fences:
      \(schema)
      """

    var http = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
    http.httpMethod = "POST"
    http.setValue("application/json", forHTTPHeaderField: "content-type")
    http.timeoutInterval = 600
    http.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model,
      "prompt": prompt,
      "stream": false,
      "options": ["temperature": 0.3, "num_ctx": 8192],
    ] as [String: Any])

    let (data, response) = try await URLSession.shared.data(for: http)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw DevWriterError.ollama(String(data: data, encoding: .utf8) ?? "no body")
    }
    let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let text = envelope?["response"] as? String else {
      throw DevWriterError.ollama("no response field")
    }
    guard let json = Self.firstJSONObject(in: text) else {
      throw DevWriterError.ollama("no JSON object in planner output: \(text.prefix(120))…")
    }
    return try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
  }

  /// First balanced `{…}` in the text, brace-scanned with string awareness so
  /// braces inside JSON strings do not end the object early.
  static func firstJSONObject(in text: String) -> String? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var escaped = false
    var index = start
    while index < text.endIndex {
      let character = text[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else {
        switch character {
        case "\"": inString = true
        case "{": depth += 1
        case "}":
          depth -= 1
          if depth == 0 { return String(text[start...index]) }
        default: break
        }
      }
      index = text.index(after: index)
    }
    return nil
  }
}
