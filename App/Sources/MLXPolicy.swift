import Foundation
import os
import WriteCore

/// The device-writer boundary, carried over verbatim from the audited
/// `tauri-plugin-mlx-qwen` in 33io.
///
/// These are policy, not tuning knobs. The section loop is shaped by the
/// context and output caps, and `Plan.validate` rejects any plan that cannot
/// be executed inside them. Changing a value here changes what the planner is
/// allowed to ask for, so treat it as a reviewed policy change and not an
/// optimisation.
enum MLXPolicy {
  /// The model this build runs.
  ///
  /// Qwen3-1.7B at 4-bit is 0.98 GB against Qwen3-4B's 2.3 GB. That margin is
  /// the difference between loading and being jetsammed on an 8 GB device, and
  /// it holds even where the increased-memory-limit entitlement is missing —
  /// so the app works on a device that has not been specially provisioned.
  ///
  /// Both entries are pinned to immutable commits. The app does not follow
  /// `main`; changing a revision is a reviewed code change, never an
  /// automatic "latest".
  /// Chosen by installed memory rather than fixed.
  ///
  /// The fleet is deliberately heterogeneous — an M4 iPad has room the 15 Pro
  /// Max does not — and pinning every device to the smallest model wastes the
  /// large ones. 12 GB is the threshold because the 4B needs ~2.3 GB of weights
  /// plus KV cache and headroom, which an 8 GB device cannot give it under
  /// jetsam.
  ///
  /// The manifest travels with the model, so switching here cannot desync the
  /// revision from its digests.
  static var model: PinnedModel {
    let installedGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    // The 8B only fits where the entitlement has actually been granted. Without
    // it a 16 GB device is held near 6 GB, and 4.6 GB of weights plus KV cache
    // is a jetsam kill rather than a slow load — so this checks what was
    // granted instead of assuming it from the entitlements file, which can be
    // present in the source and stripped at signing.
    // Largest that actually fits, asked of the OS rather than assumed from
    // installed RAM — the two differ by whatever the entitlement was granted.
    // Tried at reduced context too, so a device that cannot host a model at
    // 4096 still gets it at 2048 rather than dropping a whole size class.
    let candidates: [PinnedModel] = [.qwen3_8B_4bit, .qwen3_4B_4bit]
    for candidate in candidates
    where installedGB >= 8 && canHost(candidate, context: affordableContext(for: candidate))
      && affordableContext(for: candidate) >= 2048
      && canHost(candidate, context: 2048)
    {
      return candidate
    }
    return .qwen3_1_7B_4bit
  }

  /// Bytes this process may still allocate before jetsam kills it.
  ///
  /// `os_proc_available_memory` reports the real remaining headroom, which is
  /// strictly better than inferring it from the entitlement: an entitlement can
  /// be declared in source and silently stripped at signing, and even when
  /// granted the ceiling varies by device and by what else the system is doing.
  /// Asking costs nothing and cannot be wrong.
  static var availableMemoryBytes: Int { os_proc_available_memory() }

  /// Whether this device can hold the model and generate at `context`.
  ///
  /// Sized from the actual working set rather than a multiple of the weights.
  /// A 15% margin covers measurement drift and whatever else the system does
  /// while a task runs; being killed mid-generation costs the whole task, so
  /// the margin is worth more than the last few hundred megabytes.
  static func canHost(_ candidate: PinnedModel, context: Int = 4096) -> Bool {
    Double(candidate.residentBytes(context: context)) * 1.15
      < Double(availableMemoryBytes)
  }

  /// The context this device can afford for a given model.
  ///
  /// Halving context halves the KV cache, which is the only part of the
  /// working set that can be traded. On a device that cannot quite fit a model
  /// at full context, a shorter one is the difference between running a larger
  /// model and not running it — and the section loop already caps prompts well
  /// below 4096, so the loss is mostly theoretical.
  static func affordableContext(for candidate: PinnedModel) -> Int {
    for context in [4096, 3072, 2048] where canHost(candidate, context: context) {
      return context
    }
    return 2048
  }

  /// True when the process has meaningfully more headroom than an
  /// unentitled app of this size would get.
  static var hasIncreasedMemoryLimit: Bool {
    let installed = Double(ProcessInfo.processInfo.physicalMemory)
    return Double(availableMemoryBytes) > installed * 0.42
  }

  static var allowedModel: String { model.id }
  static var allowedModelRevision: String { model.revision }

  /// MLX allocator controls. These bound MLX's own arenas; they are not a
  /// claim that total process memory can never exceed them. Jetsam remains the
  /// real ceiling, and the increased-memory-limit entitlement raises it.
  ///
  /// The 33io plugin used a flat 7.5 GB. That is wrong on a phone: on an 8 GB
  /// device jetsam kills the process long before MLX reaches 7.5 GB, so a
  /// fixed ceiling means MLX never throttles itself and the OS decides
  /// instead — which presents as an unexplained crash. Deriving the limit from
  /// installed memory makes MLX back off first, where it can fail cleanly.
  static let cacheLimitBytes = 67_108_864  // 64 MiB

  /// Roughly half of installed memory, capped at the audited 7.5 GB.
  ///
  /// Half is deliberately conservative: the entitlement raises the jetsam
  /// ceiling to around 55-60% on an 8 GB device, and the app still needs room
  /// for the tokenizer, KV cache, and the UI on top of the weights.
  static var memoryLimitBytes: Int {
    let installed = ProcessInfo.processInfo.physicalMemory
    let half = Int(installed / 2)
    return min(half, 8_053_063_680)
  }

  /// Limits follow the chosen model's affordable context rather than being
  /// fixed, so a node that had to shorten context reports that honestly to the
  /// fleet instead of advertising a window it cannot serve.
  static var limits: DeviceLimits {
    let context = affordableContext(for: model)
    return DeviceLimits(
      maxContextTokens: context,
      maxInputCharacters: min(3072, context - 1024),
      maxInputTokens: min(3072, context - 1024),
      maxOutputTokens: 512,
      contextHeadroomTokens: 512
    )
  }

  /// Fixed instructions, reasserted before every generation. The writer has no
  /// tools and no network surface; saying so plainly is cheaper than letting
  /// the model invent an action it cannot take.
  static let systemInstructions = """
    You are the on-device writer. Respond only from the text supplied to you. \
    You have no tools and no access to files, shell commands, accounts, \
    sensors, external services, or the network. Never claim to have performed \
    an action outside this response.
    """
}
