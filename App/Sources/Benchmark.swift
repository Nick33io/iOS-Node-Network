import Foundation
import WriteCore

/// One device's measured generation speed.
///
/// Reported per device because the fleet is deliberately heterogeneous: the
/// coordinator's scheduling is only as good as its knowledge of who is fast,
/// and "fast" is a property of this chip running this model right now — not
/// something inferable from a model identifier.
struct BenchmarkResult: Sendable, Equatable {
  let device: String
  let model: String
  let backend: String
  /// Wall time from first call to last token.
  let seconds: Double
  let outputCharacters: Int
  /// Rough token count. Character-based because the tokenizer is not exposed
  /// through `DeviceWriter`, and ~4 characters per token is close enough for
  /// comparing devices against each other.
  var approximateTokens: Int { max(1, outputCharacters / 4) }
  var tokensPerSecond: Double { seconds > 0 ? Double(approximateTokens) / seconds : 0 }

  var line: String {
    String(
      format: "%@  %.1f tok/s  %.1fs  %d chars",
      device, tokensPerSecond, seconds, outputCharacters
    )
  }
}

enum Benchmark {
  /// A prompt sized to the device boundary: long enough to exercise prefill,
  /// short enough to leave the full output budget available.
  static let prompt = """
    Write one paragraph explaining why a production schedule slips when a \
    location changes late. Be concrete and specific. Do not use headings or \
    bullet points.
    """

  /// Times a single generation at the device's own output cap.
  static func run(
    writer: any DeviceWriter,
    device: String,
    model: String,
    backend: String
  ) async throws -> BenchmarkResult {
    let started = Date()
    let text = try await writer.generate(
      prompt: prompt,
      maxOutputTokens: writer.limits.maxOutputTokens
    )
    return BenchmarkResult(
      device: device,
      model: model,
      backend: backend,
      seconds: -started.timeIntervalSinceNow,
      outputCharacters: text.trimmed.count
    )
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
