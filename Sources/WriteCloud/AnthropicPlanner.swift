import Foundation
#if canImport(FoundationNetworking)
  // On Linux, URLSession lives in FoundationNetworking, not Foundation.
  import FoundationNetworking
#endif
import WriteCore

/// Cloud planner over the Anthropic Messages API.
///
/// There is no official Anthropic SDK for Swift, so this speaks raw HTTP.
///
/// This is the only component in the project that opens a socket, and it
/// receives its input already sealed by `Abstractor`. It must never be handed
/// a `FactMap`, and it deliberately has no way to reach one.
///
/// - Important: `apiKey` must not be compiled into a shipped app — anything in
///   the bundle is extractable. Point `baseURL` at a broker you control that
///   holds the key server-side and mints short-lived per-device tokens. The
///   direct-key path exists for development.
public struct AnthropicPlanner: CloudPlanner {
  public let apiKey: String
  public let baseURL: URL
  public let model: String
  public let session: URLSession

  public init(
    apiKey: String,
    baseURL: URL = URL(string: "https://api.anthropic.com")!,
    model: String = "claude-opus-5",
    session: URLSession = .shared
  ) {
    self.apiKey = apiKey
    self.baseURL = baseURL
    self.model = model
    self.session = session
  }

  public func plan(_ request: PlanRequest) async throws -> Plan {
    var http = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
    http.httpMethod = "POST"
    http.setValue("application/json", forHTTPHeaderField: "content-type")
    http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    http.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

    let body: [String: Any] = [
      "model": model,
      "max_tokens": 16000,
      // Planning is the reasoning half of the split; this is where the effort
      // belongs, because the device half cannot reason at all.
      "thinking": ["type": "adaptive"],
      "output_config": [
        "effort": "high",
        "format": ["type": "json_schema", "schema": Self.planSchema],
      ],
      // On a policy decline the API re-runs the request on a fallback model
      // inside the same call rather than returning nothing.
      "fallbacks": "default",
      "system": Self.systemPrompt,
      "messages": [["role": "user", "content": Self.userPrompt(request)]],
    ]
    http.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await session.data(for: http)
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
      throw PlannerError.transport("no HTTP response")
    }
    guard (200..<300).contains(status) else {
      throw PlannerError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
    }

    let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

    // A refusal arrives as a 200. Reading `content` without checking first
    // yields an empty plan and a confusing downstream failure.
    if envelope["stop_reason"] as? String == "refusal" {
      let details = envelope["stop_details"] as? [String: Any]
      throw PlannerError.refused(category: details?["category"] as? String)
    }

    guard let text = Self.firstText(in: envelope) else {
      throw PlannerError.malformedResponse("no text block in response")
    }
    guard let planData = text.data(using: .utf8) else {
      throw PlannerError.malformedResponse("plan text is not valid UTF-8")
    }
    do {
      return try JSONDecoder().decode(Plan.self, from: planData)
    } catch {
      throw PlannerError.malformedResponse("plan JSON did not decode: \(error)")
    }
  }

  // MARK: Prompt

  public static let systemPrompt = """
    You plan documents that another, much smaller model will write on a phone.

    You never see real names, figures, dates, or organisations. They are \
    replaced by placeholders of the form [[KIND_N]], and you are given a \
    catalogue describing what each one stands for. Use the placeholders \
    verbatim wherever the value belongs. Never invent a placeholder that is \
    not in the catalogue, and never guess at what a value might be.

    The writer is a 4B model with no memory between sections. It cannot plan, \
    infer, or decide what matters — it can only expand what you give it. So \
    each section must be self-contained and concrete: say what the section \
    argues, in what order, and which placeholders must appear in it. Vague \
    intent produces vague prose.

    Every section must be writable in a single short pass. Respect the word \
    budget you are given; split a long topic into several sections instead of \
    exceeding it.
    """

  public static func userPrompt(_ request: PlanRequest) -> String {
    let catalog = request.catalog
      .map { "  \($0.id) (\($0.kind.rawValue)) — \($0.label)" }
      .joined(separator: "\n")

    var prompt = """
      BRIEF:
      \(request.brief)

      PLACEHOLDER CATALOGUE:
      \(catalog.isEmpty ? "  (none)" : catalog)

      CONSTRAINTS:
      - No section may exceed \(request.wordBudgetPerSection) words.
      - mustInclude entries are bare ids from the catalogue (NAME_1), never \
      the bracketed placeholder form.
      """
    if let total = request.targetWords {
      prompt += "\n- The finished document should total roughly \(total) words."
    }
    return prompt
  }

  public static var planSchema: [String: Any] {[
    "type": "object",
    "properties": [
      "title": ["type": "string"],
      "audience": ["type": "string"],
      "tone": ["type": "string"],
      "sections": [
        "type": "array",
        "minItems": 1,
        "items": [
          "type": "object",
          "properties": [
            "id": ["type": "string"],
            "heading": ["type": "string"],
            "intent": ["type": "string"],
            "points": ["type": "array", "items": ["type": "string"]],
            "mustInclude": ["type": "array", "items": ["type": "string"]],
            "targetWords": ["type": "integer"],
          ],
          "required": ["id", "heading", "intent", "points", "mustInclude", "targetWords"],
          "additionalProperties": false,
        ],
      ],
    ],
    "required": ["title", "audience", "tone", "sections"],
    "additionalProperties": false,
  ]}

  static func firstText(in envelope: [String: Any]) -> String? {
    guard let content = envelope["content"] as? [[String: Any]] else { return nil }
    for block in content where block["type"] as? String == "text" {
      if let text = block["text"] as? String { return text }
    }
    return nil
  }
}

public enum PlannerError: Error, CustomStringConvertible {
  case transport(String)
  case http(status: Int, body: String)
  case refused(category: String?)
  case malformedResponse(String)

  public var description: String {
    switch self {
    case .transport(let detail):
      return "Planner transport failure: \(detail)"
    case .http(let status, let body):
      return "Planner returned HTTP \(status): \(body)"
    case .refused(let category):
      return "Planner declined the request\(category.map { " (\($0))" } ?? "")."
    case .malformedResponse(let detail):
      return "Planner response was unusable: \(detail)"
    }
  }
}
