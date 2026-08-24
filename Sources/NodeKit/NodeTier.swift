#if canImport(Darwin)
  import Foundation

  /// What a node can be relied on for.
  ///
  /// Derived from measurable conditions, never configured. The first version
  /// keyed this off the platform alone, which was too blunt: an M4 iPad on a
  /// stand, plugged in, with the screen pinned awake is genuinely always
  /// available, and calling it "burst" wasted the second most capable machine
  /// in the fleet.
  ///
  /// What actually distinguishes the tiers is whether a node can keep serving
  /// unattended. macOS always can. An iOS device can while it holds power and
  /// has disabled the idle timer — both facts the device can check — and
  /// cannot once either lapses. Reading the conditions means a device promotes
  /// itself when it is docked and demotes itself when unplugged, without
  /// anyone maintaining a list.
  public enum NodeTier: String, Codable, Sendable, CaseIterable {
    /// Serves unattended. Safe to hand long or dependent work.
    case permanent
    /// Serves only while foregrounded. Available opportunistically, and may
    /// vanish mid-task without warning.
    case burst

    /// - Parameters:
    ///   - onMains: drawing external power rather than battery.
    ///   - screenHeldAwake: the app has disabled the idle timer, so the device
    ///     will not lock and suspend it.
    public static func current(onMains: Bool = false, screenHeldAwake: Bool = false)
      -> NodeTier
    {
      #if os(macOS)
        return .permanent
      #else
        // Both conditions, not either. Power without a held screen still locks
        // and suspends; a held screen on battery still dies when the battery
        // does.
        return onMains && screenHeldAwake ? .permanent : .burst
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

    /// Whether this tier was earned by conditions that can lapse.
    ///
    /// A docked iPad is permanent right now, but unplugging it changes that in
    /// a way unplugging a Mac does not. Worth surfacing so the distinction is
    /// visible rather than implied.
    public static func isConditional() -> Bool {
      #if os(macOS)
        return false
      #else
        return true
      #endif
    }
  }
#endif
