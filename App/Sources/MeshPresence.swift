import Foundation
import NodeKit
import Observation
import WriteMesh

/// Whether this device is joined to the peer mesh, and who else is on it.
///
/// The peer-to-peer transport is a deliberate toggle rather than an automatic
/// fallback. It is the right transport when there is no network to join, and
/// the wrong one when the Fold has to participate — Multipeer is Apple-only.
/// Nothing can infer which situation the user is in, so the user decides.
@MainActor
@Observable
final class MeshPresence {
  private(set) var isJoined = false
  private(set) var peers: [NodeID] = []

  /// This device's identity on the mesh. Stable across launches so a
  /// reconnecting node is recognised as the same one it was before.
  let localNode: NodeID

  #if canImport(MultipeerConnectivity)
    private var transport: MultipeerTransport?
  #endif

  init() {
    // Minted and stored by NodeKit so the peer transport and the fleet profile
    // name this node identically. A controller that meets it over Multipeer and
    // a controller that probes it over HTTP must be talking about one node.
    localNode = NodeID(BridgeProfileEmitter.nodeIdentity)
  }

  var isAvailable: Bool {
    #if canImport(MultipeerConnectivity)
      return true
    #else
      return false
    #endif
  }

  func join() {
    #if canImport(MultipeerConnectivity)
      guard transport == nil else { return }
      let transport = MultipeerTransport(localNode: localNode)
      transport.attach(localNode) { _ in
        // Envelope handling belongs to the coordinator and worker actors; this
        // object only tracks presence for the UI.
      }
      // Membership arrives on MPC's queue; hop to the main actor so SwiftUI
      // sees the change. Polling here would either lag behind a peer arriving
      // or spin needlessly while nothing is happening.
      transport.observePeers { [weak self] nodes in
        Task { @MainActor in self?.peers = nodes }
      }
      transport.start()
      self.transport = transport
      isJoined = true
    #endif
  }

  func leave() {
    #if canImport(MultipeerConnectivity)
      transport?.stop()
      transport = nil
    #endif
    isJoined = false
    peers = []
  }

  func refresh() {
    #if canImport(MultipeerConnectivity)
      peers = transport?.connectedNodes ?? []
    #endif
  }
}
