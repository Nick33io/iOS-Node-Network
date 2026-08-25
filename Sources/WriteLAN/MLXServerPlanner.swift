import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import WriteCore
import WriteCloud

/// Planner over `mlx_lm.server`, so the executive tier is the same runtime the
/// writers use rather than a second inference engine.
///
/// This exists because the fleet moved off Ollama: the planner was the last
/// thing still calling `:11434`, which meant the one node deciding the shape of
/// a document was running a different engine, a different quantisation, and a
/// different model from every node that wrote it.
///
/// Prompts, schema and JSON mining are `LANPlanner`'s verbatim — only the
/// transport differs (OpenAI completions rather than Ollama's `/api/generate`),
/// so a planner comparison measures the model and not the scaffolding.
///
/// Point this at a capability-tier model. Measured on an M5 Max, `Qwen3-30B-A3B`
/// returns 373.9 tok/s at concurrency 16 against dense 8B's 317 — faster *and*
/// a far larger model — which is what makes it the right executive. It loses to
/// dense 4B at every concurrency; that is the price of the parameters, and
/// planning is the one job worth paying it for.
public struct MLXServerPlanner: CloudPlanner {
  public let model: String
  public let baseURL: URL
  public let attempts: Int

  public init(
    model: String,
    baseURL: URL = URL(string: "http://127.0.0.1:8082")!,
    attempts: Int = 2
  ) {
    self.model = model
    self.baseURL = baseURL
    self.attempts = attempts
  }

  public func plan(_ request: PlanRequest) async throws -> Plan {
    var lastError: Error = LANError.ollama("no attempts made")
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
      — no preamble, no reasoning, no markdown fences. Your reply must begin \
      with { and end with }:
      \(schema)
      """

    var http = URLRequest(url: baseURL.appendingPathComponent("v1/completions"))
    http.httpMethod = "POST"
    http.setValue("application/json", forHTTPHeaderField: "content-type")
    http.timeoutInterval = 600
    http.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model,
      "prompt": prompt,
      // A plan is a schema to fill, not prose to invent. Low temperature here
      // is the difference between a retry and a parse.
      "temperature": 0.3,
      // Qwen3 reasons before it answers, and a plan that runs out of budget
      // mid-thought yields prose with no JSON in it at all — which fails as a
      // parse error rather than a short plan. Budget for the thinking as well
      // as the object.
      "max_tokens": 3200,
      "stream": false,
    ] as [String: Any])

    let (data, response) = try await Self.session.data(for: http)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw LANError.ollama(String(data: data, encoding: .utf8) ?? "no body")
    }
    guard
      let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = envelope["choices"] as? [[String: Any]],
      let text = choices.first?["text"] as? String
    else {
      throw LANError.ollama("no completion in planner response")
    }
    // Take the first object that *decodes*, not the first that parses. The
    // prompt carries the schema, and a model that echoes it back emits a
    // perfectly well-formed JSON object that is not a plan — which failed as a
    // missing-key error rather than as a bad response.
    var rest = Substring(text)
    var lastError: Error = LANError.ollama(
      "no plan-shaped JSON in planner output: \(text.prefix(120))…")
    while let json = LANPlanner.firstJSONObject(in: String(rest)) {
      do {
        return try JSONDecoder().decode(Plan.self, from: Data(json.utf8))
      } catch {
        lastError = error
      }
      guard let start = rest.range(of: json)?.upperBound else { break }
      rest = rest[start...]
    }
    throw lastError
  }

  private static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 8
    config.timeoutIntervalForRequest = 600
    return URLSession(configuration: config)
  }()
}
