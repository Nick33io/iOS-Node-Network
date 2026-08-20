import Foundation
import WriteCore

#if canImport(MLX) && !targetEnvironment(simulator)
  import MLX
  import MLXLLM
  import MLXLMCommon

  /// `DeviceWriter` backed by MLX Swift LM running the pinned Qwen3-4B.
  ///
  /// Load and unload are isolated to `@MainActor` so the weights are only ever
  /// swapped from one place. That is not a performance concern: generation is
  /// one long `await` on the GPU, so the actor is idle for the duration rather
  /// than blocking the UI.
  ///
  /// Only available on physical devices. MLX needs a Metal GPU that the iOS
  /// simulator does not provide, which is why the simulator path uses the LAN
  /// writer instead — see `MLXWriterUnavailable` below.
  @MainActor
  final class MLXWriter: DeviceWriter {
    nonisolated var limits: DeviceLimits { MLXPolicy.limits }

    private var container: ModelContainer?

    /// Held outside the actor's isolation: `ChatSession` is not `Sendable` and
    /// its `clear`/`respond` are `nonisolated async`, so reaching for it from
    /// isolated storage would send a non-Sendable value across domains on every
    /// call. Generation is instead done entirely off the actor, one call at a
    /// time — which is the same single-threaded contract the KV-cache clearing
    /// in `respond` already depends on.
    private nonisolated(unsafe) var session: ChatSession?

    init() {
      MLX.GPU.set(memoryLimit: MLXPolicy.memoryLimitBytes)
      MLX.GPU.set(cacheLimit: MLXPolicy.cacheLimitBytes)
    }

    /// Loads the pinned model, downloading it on first run if it is not cached.
    ///
    /// Separate from `generate` so the caller can show progress: the weights
    /// are ~2.3 GB, and a first launch that silently blocks for minutes is
    /// indistinguishable from a hang.
    func load(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
      guard container == nil else { return }

      let configuration = ModelConfiguration(
        id: MLXPolicy.allowedModel,
        revision: MLXPolicy.allowedModelRevision
      )
      // MLX Swift LM is provider-agnostic: it supplies no downloader and no
      // tokenizer, so both sides of the supply chain are ours to name.
      let loaded = try await loadModelContainer(
        from: PinnedModelDownloader(),
        using: PinnedTokenizerLoader(),
        configuration: configuration,
        useLatest: false
      ) { progressReport in
        progress(progressReport.fractionCompleted)
      }

      container = loaded
      session = ChatSession(
        loaded,
        instructions: MLXPolicy.systemInstructions,
        generateParameters: Self.parameters(maxOutputTokens: MLXPolicy.limits.maxOutputTokens)
      )
    }

    var isLoaded: Bool { container != nil }

    nonisolated func generate(prompt: String, maxOutputTokens: Int) async throws -> String {
      try await MainActor.run { try self.validate(prompt: prompt) }
      return try await respond(prompt: prompt, maxOutputTokens: maxOutputTokens)
    }

    private func validate(prompt: String) throws {
      guard prompt.count <= MLXPolicy.limits.maxInputCharacters else {
        throw MLXWriterError.promptOverLimit(
          characters: prompt.count,
          limit: MLXPolicy.limits.maxInputCharacters
        )
      }
    }

    private nonisolated func respond(prompt: String, maxOutputTokens: Int) async throws -> String {
      guard let session else { throw MLXWriterError.notLoaded }
      let tokens = min(max(1, maxOutputTokens), MLXPolicy.limits.maxOutputTokens)

      // Clear history and the KV cache before every generation, preserving the
      // fixed instructions. Sections are independent by design — this is what
      // stops drift accumulating across a document, and it is why continuity
      // has to be passed explicitly in the prompt.
      await session.clear()
      session.instructions = MLXPolicy.systemInstructions
      session.generateParameters = Self.parameters(maxOutputTokens: tokens)

      return try await session.respond(to: prompt)
    }

    /// Releases the weights. Worth calling when the app backgrounds: holding
    /// ~2.3 GB resident is the fastest way to get jetsammed on an 8 GB device.
    func unload() {
      session = nil
      container = nil
      MLX.GPU.clearCache()
    }

    private nonisolated static func parameters(maxOutputTokens: Int) -> GenerateParameters {
      GenerateParameters(
        maxTokens: maxOutputTokens,
        maxKVSize: MLXPolicy.limits.maxContextTokens,
        temperature: 0.2,
        topP: 0.9,
        topK: 40,
        prefillStepSize: 512
      )
    }
  }
#endif

/// Stand-in used where MLX cannot run, so the app still builds and the failure
/// is a clear message rather than a missing symbol.
struct MLXWriterUnavailable: DeviceWriter {
  let limits = MLXPolicy.limits
  let reason: String

  func generate(prompt: String, maxOutputTokens: Int) async throws -> String {
    throw MLXWriterError.unavailable(reason)
  }
}

enum MLXWriterError: Error, CustomStringConvertible {
  case notLoaded
  case promptOverLimit(characters: Int, limit: Int)
  case unavailable(String)

  var description: String {
    switch self {
    case .notLoaded:
      return "The on-device model is not loaded."
    case .promptOverLimit(let characters, let limit):
      return "Prompt of \(characters) characters exceeds the device limit of \(limit)."
    case .unavailable(let reason):
      return "On-device generation is unavailable: \(reason)"
    }
  }
}
