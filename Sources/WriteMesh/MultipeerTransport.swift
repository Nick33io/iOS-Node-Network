#if canImport(MultipeerConnectivity)
  import Foundation
  import MultipeerConnectivity

  /// `MeshTransport` over MultipeerConnectivity, for when there is no network
  /// to join.
  ///
  /// MPC links devices directly over peer-to-peer Wi-Fi and Bluetooth, so it
  /// needs no router, no DHCP, and no addresses typed in. That is the whole
  /// reason it exists here: on location with no usable Wi-Fi, this is the only
  /// transport that still forms a mesh.
  ///
  /// It is Apple-only and cannot carry Android peers, so a mesh that must
  /// include the Fold needs the LAN transport instead. That is why the choice
  /// is a runtime toggle rather than a compile-time one.
  ///
  /// Implemented as a lock-guarded class rather than an actor because every
  /// `MCPeerID` is non-`Sendable`: handing one to an actor is a data race under
  /// Swift 6. Keeping all peer identity inside this object means it never
  /// crosses an isolation boundary at all. Delegate callbacks arrive on MPC's
  /// own queue and touch shared state only under `lock`.
  ///
  /// Guarded by `canImport` so the portable core still builds on Linux, where
  /// this file compiles to nothing.
  public final class MultipeerTransport: NSObject, MeshTransport, @unchecked Sendable {
    /// Bonjour service type. Must be 1-15 characters of lowercase letters,
    /// digits, and hyphens, and must also appear in the app's
    /// `NSBonjourServices` or iOS silently refuses to advertise or browse.
    public static let serviceType = "node33-mesh"

    private let session: MCSession
    private let peerID: MCPeerID
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser

    private let lock = NSLock()
    private var handler: (@Sendable (MeshEnvelope) async -> Void)?
    /// Fired whenever the peer set changes. Without this a caller has no way to
    /// learn that a peer arrived: MPC reports membership through delegate
    /// callbacks, and polling would either lag or burn cycles.
    private var onPeersChanged: (@Sendable ([NodeID]) -> Void)?
    /// MPC identifies peers by `MCPeerID`; the mesh identifies them by
    /// `NodeID`. This is the only place the two meet.
    private var peers: [NodeID: MCPeerID] = [:]

    public init(localNode: NodeID) {
      // The display name is the node id, so a peer learns who it just met from
      // discovery alone with no extra handshake. MPC caps it at 63 bytes.
      let peerID = MCPeerID(displayName: String(localNode.raw.prefix(63)))
      self.peerID = peerID
      self.session = MCSession(
        peer: peerID, securityIdentity: nil, encryptionPreference: .required
      )
      self.advertiser = MCNearbyServiceAdvertiser(
        peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType
      )
      self.browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
      super.init()
      session.delegate = self
      advertiser.delegate = self
      browser.delegate = self
    }

    deinit {
      advertiser.stopAdvertisingPeer()
      browser.stopBrowsingForPeers()
      session.disconnect()
    }

    // MARK: MeshTransport

    public func attach(
      _ node: NodeID,
      handler: @escaping @Sendable (MeshEnvelope) async -> Void
    ) {
      lock.withLock { self.handler = handler }
    }

    /// Observe membership changes. Called on MPC's queue, so the observer must
    /// hop to whatever isolation it needs.
    public func observePeers(_ observer: @escaping @Sendable ([NodeID]) -> Void) {
      lock.withLock { self.onPeersChanged = observer }
      observer(connectedNodes)
    }

    private func notifyPeersChanged() {
      let observer = lock.withLock { self.onPeersChanged }
      observer?(connectedNodes)
    }

    /// Fire-and-forget, per the transport contract. An unreachable peer is
    /// silence, not an error: recovery belongs to lease expiry in the
    /// coordinator. Reporting failures here would duplicate it badly, since a
    /// peer that vanishes mid-send is indistinguishable from one that received
    /// the message and then died.
    public func send(_ envelope: MeshEnvelope, to node: NodeID) {
      guard let data = try? JSONEncoder().encode(envelope) else { return }
      let peer = lock.withLock { peers[node] }
      guard let peer, session.connectedPeers.contains(peer) else { return }
      try? session.send(data, toPeers: [peer], with: .reliable)
    }

    // MARK: Lifecycle

    public func start() {
      advertiser.startAdvertisingPeer()
      browser.startBrowsingForPeers()
    }

    public func stop() {
      advertiser.stopAdvertisingPeer()
      browser.stopBrowsingForPeers()
      session.disconnect()
      lock.withLock { peers.removeAll() }
    }

    /// Nodes currently reachable. Drives the connection indicator in the UI.
    public var connectedNodes: [NodeID] {
      let connected = Set(session.connectedPeers)
      return lock.withLock { peers.filter { connected.contains($0.value) }.keys.sorted() }
    }
  }

  // MARK: - MPC delegates

  extension MultipeerTransport: MCSessionDelegate {
    public func session(
      _ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState
    ) {
      switch state {
      case .connected:
        lock.withLock { peers[NodeID(peerID.displayName)] = peerID }
        notifyPeersChanged()
      case .notConnected:
        lock.withLock { peers = peers.filter { $0.value != peerID } }
        notifyPeersChanged()
      case .connecting:
        break
      @unknown default:
        break
      }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
      // A peer on a newer protocol version fails to decode cleanly and is
      // dropped, rather than half-parsed into a message we misunderstand.
      guard let envelope = try? JSONDecoder().decode(MeshEnvelope.self, from: data) else { return }
      let handler = lock.withLock { self.handler }
      guard let handler else { return }
      Task { await handler(envelope) }
    }

    // Unused stream and resource paths. The mesh sends only small encoded
    // envelopes; anything arriving here is not ours.
    public func session(
      _ session: MCSession, didReceive stream: InputStream, withName streamName: String,
      fromPeer peerID: MCPeerID
    ) {}
    public func session(
      _ session: MCSession, didStartReceivingResourceWithName resourceName: String,
      fromPeer peerID: MCPeerID, with progress: Progress
    ) {}
    public func session(
      _ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
      fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?
    ) {}
  }

  extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    public func browser(
      _ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
      withDiscoveryInfo info: [String: String]?
    ) {
      // Invite deterministically. Without a rule both sides invite each other
      // and MPC tears one session down mid-handshake; the lower id invites.
      guard peerID.displayName > self.peerID.displayName else { return }
      browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
      lock.withLock { peers = peers.filter { $0.value != peerID } }
      notifyPeersChanged()
    }
  }

  extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(
      _ advertiser: MCNearbyServiceAdvertiser,
      didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
      invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
      invitationHandler(true, session)
    }
  }
#endif
