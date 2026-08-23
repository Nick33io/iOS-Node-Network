import Foundation

/// Measures the network link to a node.
///
/// Distinct from generation throughput, which the benchmark covers. A node can
/// be fast at producing tokens and slow to reach — over a relayed Tailscale
/// path those two numbers diverge sharply, and the scheduler cares about both:
/// throughput decides who writes, latency decides whether handing off is worth
/// the trip at all.
struct LinkResult: Sendable, Equatable {
  /// Round-trip for a near-empty request. The floor on any exchange with this
  /// node regardless of payload.
  let latencyMilliseconds: Int
  let downloadMBps: Double
  let uploadMBps: Double
  /// Bytes moved in each direction during the test.
  let payloadBytes: Int

  var summary: String {
    String(format: "%d ms · ↓%.1f ↑%.1f MB/s", latencyMilliseconds, downloadMBps, uploadMBps)
  }
}

enum LinkTest {
  /// 512 KB. Large enough that transfer dominates the measurement rather than
  /// connection setup, small enough not to punish a phone on a relayed path.
  static let payloadBytes = 512 * 1024

  static func run(host: String) async throws -> LinkResult {
    let session = URLSession(configuration: .ephemeral)

    // Latency first, on a trivial request, so setup cost is measured separately
    // from transfer rather than smeared across it.
    var probe = URLRequest(url: URL(string: "http://\(host):8833/health")!)
    probe.timeoutInterval = 15
    probe.cachePolicy = .reloadIgnoringLocalCacheData
    let latencyStart = Date()
    _ = try await session.data(for: probe)
    let latency = Int(-latencyStart.timeIntervalSinceNow * 1000)

    // Download: ask for a payload, send almost nothing.
    var down = URLRequest(url: URL(string: "http://\(host):8833/echo")!)
    down.httpMethod = "POST"
    down.setValue("application/json", forHTTPHeaderField: "content-type")
    down.timeoutInterval = 60
    down.httpBody = try JSONSerialization.data(withJSONObject: ["bytes": payloadBytes])
    let downStart = Date()
    let (downData, _) = try await session.data(for: down)
    let downSeconds = -downStart.timeIntervalSinceNow

    // Upload: send the payload, ask for nothing back.
    var up = URLRequest(url: URL(string: "http://\(host):8833/echo")!)
    up.httpMethod = "POST"
    up.setValue("application/json", forHTTPHeaderField: "content-type")
    up.timeoutInterval = 60
    up.httpBody = try JSONSerialization.data(withJSONObject: [
      "bytes": 0, "pad": String(repeating: "a", count: payloadBytes),
    ])
    let upStart = Date()
    _ = try await session.data(for: up)
    let upSeconds = -upStart.timeIntervalSinceNow

    let megabytes = Double(payloadBytes) / 1_048_576
    return LinkResult(
      latencyMilliseconds: latency,
      downloadMBps: downSeconds > 0 ? Double(downData.count) / 1_048_576 / downSeconds : 0,
      uploadMBps: upSeconds > 0 ? megabytes / upSeconds : 0,
      payloadBytes: payloadBytes
    )
  }
}
