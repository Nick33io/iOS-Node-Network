#if canImport(Darwin)
  import Foundation
  import WriteCore

  /// Minimal HTTP request parser. Returns nil until the full request has arrived.
  struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    init?(_ data: Data) {
      let separator = Data("\r\n\r\n".utf8)
      guard let headerEnd = data.range(of: separator) else { return nil }
      guard
        let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8)
      else { return nil }

      let lines = headerText.components(separatedBy: "\r\n")
      let requestLine = lines.first?.split(separator: " ") ?? []
      guard requestLine.count >= 2 else { return nil }

      let declared =
        lines
        .first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

      let bodyStart = headerEnd.upperBound
      let available = data.count - bodyStart
      // Wait for the rest rather than answering a truncated prompt.
      guard available >= declared else { return nil }

      self.method = String(requestLine[0])
      self.path = String(requestLine[1])
      self.body = data[bodyStart..<(bodyStart + declared)]
    }
  }

  /// A `/generate` body checked against this node's limits before any writer
  /// exists.
  ///
  /// `DeviceLimits` is policy, and every writer already enforces it internally.
  /// Applying it one step earlier is what makes the fleet one contract rather
  /// than several. A phone would otherwise pay a model load — a gigabyte of
  /// weights — only to reject a prompt it was never going to accept. A node
  /// backed by Ollama pays nothing for that load, so without a check here it
  /// would quietly serve prompts a phone refuses, and the coordinator would be
  /// scheduling against a boundary that only some nodes honour.
  struct GenerateRequest: Equatable {
    let prompt: String
    /// Already clamped to the device cap, so the writer is never asked for more
    /// than the boundary allows.
    let maxOutputTokens: Int

    init(body: Data, limits: DeviceLimits) throws {
      guard
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
        let prompt = json["prompt"] as? String
      else { throw NodeRequestError.malformedBody }

      guard prompt.count <= limits.maxInputCharacters else {
        throw NodeRequestError.promptOverLimit(
          characters: prompt.count, limit: limits.maxInputCharacters
        )
      }

      let requested = json["maxOutputTokens"] as? Int ?? limits.maxOutputTokens
      self.prompt = prompt
      self.maxOutputTokens = min(max(1, requested), limits.maxOutputTokens)
    }
  }

  enum NodeRequestError: Error, CustomStringConvertible {
    case malformedBody
    case promptOverLimit(characters: Int, limit: Int)

    var status: String {
      switch self {
      case .malformedBody: return "400 Bad Request"
      // The prompt is well-formed and simply too big for this node — which is a
      // property of the body, not of the syntax.
      case .promptOverLimit: return "413 Content Too Large"
      }
    }

    var description: String {
      switch self {
      case .malformedBody:
        return "expected {prompt, maxOutputTokens?}"
      case .promptOverLimit(let characters, let limit):
        return "Prompt of \(characters) characters exceeds the device limit of \(limit)."
      }
    }
  }
#endif
