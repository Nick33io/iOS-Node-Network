import Foundation

#if canImport(MLX) && !targetEnvironment(simulator)
  import MLXLMCommon
  import Tokenizers

  /// Loads the tokenizer out of the verified directory, and only from there.
  ///
  /// MLX Swift LM is provider-agnostic and ships no concrete tokenizer, so the
  /// conformance has to come from here. `AutoTokenizer.from(modelFolder:)` is
  /// the purely local entry point: it reads `tokenizer.json`,
  /// `tokenizer_config.json` and `chat_template.jinja` off disk and never
  /// resolves anything over the network. All three are in the manifest the
  /// downloader has already verified, so the tokenizer is covered by the same
  /// digests as the weights.
  struct PinnedTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
      let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
      return BridgedTokenizer(underlying: tokenizer)
    }
  }

  /// Adapts swift-transformers' `Tokenizer` to the one MLXLMCommon declares.
  ///
  /// The two protocols describe the same object but share no declaration —
  /// MLXLMCommon defines its own so it stays independent of any tokenizer
  /// library — so each requirement is forwarded by hand. Only argument labels
  /// differ; nothing here reinterprets what the tokenizer does, which matters
  /// because the tokenizer decides what the verified weights actually see.
  private struct BridgedTokenizer: MLXLMCommon.Tokenizer {
    let underlying: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
      underlying.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
      underlying.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
      underlying.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
      underlying.convertIdToToken(id)
    }

    var bosToken: String? { underlying.bosToken }
    var eosToken: String? { underlying.eosToken }
    var unknownToken: String? { underlying.unknownToken }

    func applyChatTemplate(
      messages: [[String: any Sendable]],
      tools: [[String: any Sendable]]?,
      additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
      try underlying.applyChatTemplate(
        messages: messages, tools: tools, additionalContext: additionalContext)
    }
  }
#endif
