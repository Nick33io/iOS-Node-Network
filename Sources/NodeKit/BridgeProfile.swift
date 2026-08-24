#if canImport(Darwin)
  import Foundation
  import WriteCore

  /// This node described in 33 Shell's `33-shell-bridge-fleet/v1` vocabulary.
  ///
  /// The Shell already models a fleet of Tailscale-reachable nodes, so NOD3 emits
  /// that shape directly rather than something the controller would have to
  /// translate. Matching an existing contract is what keeps the two applications
  /// from drifting into two half-compatible fleet models.
  ///
  /// One field cannot be satisfied honestly: `BridgeProfile.port` is typed as the
  /// literal `22` because every existing transport is SSH. iOS cannot run sshd at
  /// all — that constraint is the entire reason this listener exists — so this
  /// reports its real port and a `tailscale-http` transport. Consuming it needs
  /// the Shell to widen `port` and add the transport case. Reporting 22 to fit
  /// the type would be a lie the controller would act on.
  ///
  /// A Mac could run sshd and be modelled as an SSH bridge, but then it would be
  /// a different kind of fleet member from every phone. It emits this same shape
  /// so the controller has one node model, not two.
  /// A node's current activity, as opposed to its capacity.
  ///
  /// Every other field in the profile describes what a node *could* do. These
  /// say what it *is* doing, which is the reading a scheduler needs to avoid
  /// piling work onto a node that is already busy.
  public struct NodeLoad: Sendable {
    public let inFlight: Int
    public let completed: Int
    public let failed: Int
    public let uptimeSeconds: Int

    public init(inFlight: Int, completed: Int, failed: Int, uptimeSeconds: Int) {
      self.inFlight = inFlight
      self.completed = completed
      self.failed = failed
      self.uptimeSeconds = uptimeSeconds
    }

    public static let idle = NodeLoad(inFlight: 0, completed: 0, failed: 0, uptimeSeconds: 0)
  }

  public enum BridgeProfileEmitter {
    public static let schema = "33-shell-bridge-fleet/v1"
    public static let transport = "tailscale-http"

    /// Stable per-install identity.
    ///
    /// SSH profiles use a host key fingerprint to notice when a host has been
    /// replaced. There is no equivalent for an app, so this is a random value
    /// minted once and kept — if it changes, the controller is talking to a
    /// reinstalled app and any cached assumptions about it are void.
    public static var fingerprint: String {
      let key = "node.fingerprint"
      if let existing = UserDefaults.standard.string(forKey: key) { return existing }
      let minted = UUID().uuidString.lowercased()
      UserDefaults.standard.set(minted, forKey: key)
      return minted
    }

    public static var pairedAt: String {
      let key = "node.pairedAt"
      if let existing = UserDefaults.standard.string(forKey: key) { return existing }
      let now = ISO8601DateFormatter().string(from: Date())
      UserDefaults.standard.set(now, forKey: key)
      return now
    }

    /// This node's identity on the mesh. Stable across launches so a
    /// reconnecting node is recognised as the same one it was before, and shared
    /// between the peer transport and the fleet profile so a controller and a
    /// peer are naming the same node.
    public static var nodeIdentity: String {
      let key = "node.identity"
      if let existing = UserDefaults.standard.string(forKey: key) { return existing }
      let generated = "node-" + UUID().uuidString.prefix(8).lowercased()
      UserDefaults.standard.set(generated, forKey: key)
      return generated
    }

    /// - Parameters:
    ///   - node: this device's mesh identity.
    ///   - backend: which writer is actually serving.
    ///   - model: the model that writer runs.
    public static func payload(
      node: String,
      label: String,
      backend: String,
      model: String,
      limits: DeviceLimits,
      /// Whether the caller has pinned the screen awake. Only the app knows
      /// this, and it is half of what makes an iOS node permanent.
      screenHeldAwake: Bool = false,
      load: NodeLoad = .idle
    ) -> [String: Any] {
      let profile = DeviceProfile.current()
      let tier = NodeTier.current(
        onMains: profile.power.isExternal,
        screenHeldAwake: screenHeldAwake
      )
      return [
        "schema": schema,
        "profile": [
          "id": node,
          "label": label,
          // The controller knows the address it dialled; the device does not
          // reliably know its own tailnet address, and guessing would be worse
          // than leaving the controller to fill in what it already has.
          "host": NSNull(),
          "port": NodeServer.port,
          "user": "",
          "fingerprint": fingerprint,
          "transport": transport,
          "credentialMode": "device-key",
          "memoryGiB": profile.memoryGB,
          "pairedAt": pairedAt,
          "lastSeenAt": ISO8601DateFormatter().string(from: Date()),
        ],
        // Beyond the SSH profile: an HTTP probe can report live state that an
        // SSH reachability check cannot cheaply get, and scheduling wants it.
        "capabilities": [
          "backend": backend,
          "model": model,
          "maxOutputTokens": limits.maxOutputTokens,
          "maxInputCharacters": limits.maxInputCharacters,
          "maxContextTokens": limits.maxContextTokens,
          "wordBudgetPerSection": limits.wordBudgetPerSection,
          "thermal": profile.thermalLabel,
          "power": profile.powerLabel,
          "suitedToLongWork": profile.suitedToLongWork,
          "hardware": profile.identifier,
        // Derived from the platform, so a fleet cannot be told a phone is
        // permanent. See NodeTier.
        "tier": tier.rawValue,
        "leaseTicks": tier.leaseTicks,
        "takesDependedUponWork": tier.takesDependedUponWork,
        // True where the tier rests on conditions that can lapse — a docked
        // iPad is permanent until it is unplugged, a Mac simply is.
        "tierIsConditional": NodeTier.isConditional(),
        // Reported so a manager can show used-against-installed rather than
        // installed alone, which says nothing about current pressure.
        "footprintGiB": Double(DeviceProfile.residentFootprintBytes()) / 1_073_741_824,
        // Headroom before jetsam, asked of the OS. Installed RAM says what the
        // hardware has; this says what this process is actually allowed.
        "availableGiB": Double(DeviceProfile.availableMemoryBytes()) / 1_073_741_824,
          // Which WorkKinds this node will accept, matching MeshMessage.join.
          "kinds": ["section"],
        // Live use, not capacity. Everything else here says what a node could
        // do; these say what it is doing.
        "inFlight": load.inFlight,
        "completed": load.completed,
        "failed": load.failed,
        "uptimeSeconds": load.uptimeSeconds,
        ],
      ]
    }
  }
#endif
