import Foundation

/// Generation limits enforced at the device boundary.
///
/// These are carried over verbatim from the audited `tauri-plugin-mlx-qwen`
/// boundary in 33io. They are not tuning knobs: the section loop is shaped by
/// them, and `Plan` validation rejects any plan that cannot be executed inside
/// them. Widening a value here silently changes what the planner is allowed to
/// ask for, so treat a change as a reviewed policy change.
public struct DeviceLimits: Sendable, Equatable {
  public let maxContextTokens: Int
  public let maxInputCharacters: Int
  public let maxInputTokens: Int
  public let maxOutputTokens: Int
  public let contextHeadroomTokens: Int

  public init(
    maxContextTokens: Int,
    maxInputCharacters: Int,
    maxInputTokens: Int,
    maxOutputTokens: Int,
    contextHeadroomTokens: Int
  ) {
    self.maxContextTokens = maxContextTokens
    self.maxInputCharacters = maxInputCharacters
    self.maxInputTokens = maxInputTokens
    self.maxOutputTokens = maxOutputTokens
    self.contextHeadroomTokens = contextHeadroomTokens
  }

  /// `mlx-community/Qwen3-4B-Instruct-2507-4bit` under the 33io boundary.
  public static let qwen3_4B_4bit = DeviceLimits(
    maxContextTokens: 4096,
    maxInputCharacters: 3072,
    maxInputTokens: 3072,
    maxOutputTokens: 512,
    contextHeadroomTokens: 512
  )

  /// Words a single `generate` call can be expected to produce.
  ///
  /// English averages ~0.75 words per token; 512 tokens is therefore ~384
  /// words. We budget below that so a section that runs slightly long still
  /// terminates on `end_turn` rather than being truncated mid-sentence.
  public var wordBudgetPerSection: Int { 340 }
}
