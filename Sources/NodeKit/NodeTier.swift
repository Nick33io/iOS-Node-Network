#if canImport(Darwin)
  import Foundation

  /// What a node can be relied on for.
  ///
  /// Derived from the platform, never configured. Whether a node can serve
  /// while nobody is looking at it is a fact about the operating system, not a
  /// preference: macOS keeps a process running indefinitely, iOS suspends a
  /// backgrounded app within seconds and the listener dies with it. Letting an
  /// owner declare an iPhone "permanent" would only move the disappointment
  /// into the scheduler.
  public enum NodeTier: String, Codable, Sendable, CaseIterable {
    /// Serves unattended. Safe to hand long or dependent work.
    case permanent
    /// Serves only while foregrounded. Available opportunistically, and may
    /// vanish mid-task without warning.
    case burst

    public static var current: NodeTier {
      #if os(macOS)
        return .permanent
      #else
        return .burst
      #endif
    }

    public var label: String {
      switch self {
      case .permanent: return "permanent"
      case .burst: return "burst"
      }
    }

    /// Whether work with dependents should be placed here.
    ///
    /// A burst node losing a leaf section costs one retry; losing an assemble
    /// step that everything else waits on costs the whole task.
    public var takesDependedUponWork: Bool { self == .permanent }

    /// Ticks a lease should run before it is presumed dead.
    ///
    /// Burst nodes get short leases so a suspended phone is reclaimed quickly.
    /// Permanent nodes get long ones because a slow answer there is far more
    /// likely to be real work than a disappearance.
    public var leaseTicks: Int {
      switch self {
      case .permanent: return 24
      case .burst: return 6
      }
    }
  }
#endif
