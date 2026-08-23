import Foundation
import Observation
import UIKit

/// Live instrument readings for this node.
///
/// Sampled on a timer rather than computed per view update: a SwiftUI body can
/// run many times a second, and `task_info` is a kernel call. Once a second is
/// plenty for something a human is reading.
@MainActor
@Observable
final class NodeTelemetry {
  /// Resident footprint in bytes. This is the number jetsam actually watches —
  /// not `physicalMemory`, and not what Activity Monitor calls "memory used".
  private(set) var footprintBytes: UInt64 = 0
  private(set) var memoryLimitBytes: UInt64 = 0
  /// Installed RAM. Shown as the denominator because that is the number people
  /// know their device by — "16 GB" — even though the jetsam ceiling the bar
  /// fills against is roughly half of it.
  private(set) var installedBytes: UInt64 = 0
  private(set) var thermal: ProcessInfo.ThermalState = .nominal
  private(set) var batteryLevel: Float = -1
  private(set) var batteryState: UIDevice.BatteryState = .unknown
  private(set) var lowPowerMode = false

  /// Bytes served in the last sampling window, converted to a rate.
  private(set) var bytesPerSecond: Double = 0
  /// Most recent generation's throughput, held so the meter does not blank
  /// between tasks.
  var lastTokensPerSecond: Double = 0
  var tokensThisTask = 0
  var tokensAllTime = 0

  private var timer: Timer?
  private var lastServedBytes: UInt64 = 0
  private var lastSample = Date()

  init() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    installedBytes = ProcessInfo.processInfo.physicalMemory
    memoryLimitBytes = Self.jetsamEstimate()
    sample(servedBytes: 0)
  }

  func start(servedBytes: @escaping @MainActor () -> UInt64) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.sample(servedBytes: servedBytes()) }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func sample(servedBytes: UInt64) {
    footprintBytes = Self.footprint()
    let info = ProcessInfo.processInfo
    thermal = info.thermalState
    lowPowerMode = info.isLowPowerModeEnabled
    batteryLevel = UIDevice.current.batteryLevel
    batteryState = UIDevice.current.batteryState

    let now = Date()
    let elapsed = now.timeIntervalSince(lastSample)
    if elapsed > 0, servedBytes >= lastServedBytes {
      bytesPerSecond = Double(servedBytes - lastServedBytes) / elapsed
    }
    lastServedBytes = servedBytes
    lastSample = now
  }

  // MARK: Readings

  /// 0...1 against the estimated jetsam ceiling.
  var memoryFraction: Double {
    guard memoryLimitBytes > 0 else { return 0 }
    return min(1, Double(footprintBytes) / Double(memoryLimitBytes))
  }

  var thermalFraction: Double {
    switch thermal {
    case .nominal: return 0.25
    case .fair: return 0.5
    case .serious: return 0.75
    case .critical: return 1.0
    @unknown default: return 0
    }
  }

  var thermalLabel: String {
    switch thermal {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  var powerFraction: Double {
    batteryLevel < 0 ? 1 : Double(batteryLevel)
  }

  var powerLabel: String {
    switch batteryState {
    case .charging: return "charging \(Int(max(0, batteryLevel) * 100))%"
    case .full: return "full"
    case .unplugged: return "\(Int(max(0, batteryLevel) * 100))%\(lowPowerMode ? " · low power" : "")"
    case .unknown: return "mains"
    @unknown default: return "unknown"
    }
  }

  var bandwidthLabel: String {
    bytesPerSecond < 1024
      ? String(format: "%.0f B/s", bytesPerSecond)
      : String(format: "%.1f KB/s", bytesPerSecond / 1024)
  }

  /// Scaled against 64 KB/s: the glyph stream is the heaviest thing this node
  /// normally serves, and it sits well under that.
  var bandwidthFraction: Double { min(1, bytesPerSecond / 65_536) }

  /// `0.03/16 GB` — used against installed.
  ///
  /// The bar still fills against the jetsam ceiling, not this total: a device
  /// is killed at roughly half its installed RAM, so a bar drawn against 16 GB
  /// would sit at a third when the process is actually about to die.
  var footprintLabel: String {
    let usedGB = Double(footprintBytes) / 1_073_741_824
    let totalGB = Double(installedBytes) / 1_073_741_824
    return String(format: "%.2f/%.0f GB", usedGB, totalGB.rounded())
  }

  // MARK: Platform

  /// Resident footprint via `task_vm_info`.
  ///
  /// `phys_footprint` is the figure jetsam compares against its limit, so it is
  /// the only one worth showing on a device that gets killed for exceeding it.
  private static func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
  }

  /// Estimated jetsam ceiling.
  ///
  /// iOS exposes no API for the real limit. With the increased-memory-limit
  /// entitlement a device gives roughly 55% of installed RAM; without it,
  /// closer to 40%. Erring low means the meter warns early, which is the safe
  /// direction when the penalty is the process being killed outright.
  private static func jetsamEstimate() -> UInt64 {
    UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.5)
  }
}
