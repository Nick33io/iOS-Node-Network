import Foundation
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
  static let allowedModel = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
  /// Pinned to an immutable commit. The app does not follow `main`; moving to a
  /// new revision is a reviewed code change, never an automatic "latest".
  static let allowedModelRevision = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"

  /// MLX allocator controls. These bound MLX's own arenas; they are not a
  /// claim that total process memory can never exceed them. Jetsam remains the
  /// real ceiling, and the increased-memory-limit entitlement raises it.
  static let memoryLimitBytes = 8_053_063_680  // 7.5 GB
  static let cacheLimitBytes = 67_108_864  // 64 MiB

  static let limits = DeviceLimits.qwen3_4B_4bit

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
