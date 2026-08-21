#if canImport(Darwin)
  import Darwin
  import Foundation

  public struct NodeAddress: Sendable, Equatable {
    public let interface: String
    public let address: String

    public init(interface: String, address: String) {
      self.interface = interface
      self.address = address
    }
  }

  /// The addresses this node can actually be reached on.
  ///
  /// A node that is listening but unreachable looks exactly like one that is
  /// working, and the difference only shows up as a timeout on the controller.
  /// The tailnet address in particular cannot be told to the process — only
  /// asked of the interfaces — so a node prints what it found and lets the
  /// operator see immediately whether Tailscale is up.
  public enum NetworkAddresses {
    public static func current() -> [NodeAddress] {
      var head: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&head) == 0, let first = head else { return [] }
      defer { freeifaddrs(head) }

      var found: [NodeAddress] = []
      for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(pointer.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else {
          continue
        }
        guard let socketAddress = pointer.pointee.ifa_addr else { continue }
        let family = socketAddress.pointee.sa_family
        guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard
          getnameinfo(
            socketAddress, socklen_t(socketAddress.pointee.sa_len),
            &buffer, socklen_t(buffer.count),
            nil, 0, NI_NUMERICHOST
          ) == 0
        else { continue }

        let address = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        // Link-local IPv6 is per-interface and needs a scope suffix to dial, so
        // printing it invites someone to copy an address that will not connect.
        if address.hasPrefix("fe80:") { continue }
        found.append(
          NodeAddress(interface: String(cString: pointer.pointee.ifa_name), address: address)
        )
      }
      return found
    }
  }
#endif
