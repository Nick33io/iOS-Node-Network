import Foundation
import UIKit

/// What this device can contribute to the mesh.
///
/// The coordinator schedules against these values rather than against a device
/// name: a thermally throttled phone and a plugged-in iPad differ in ways that
/// matter to lease length and item routing, and the model identifier alone
/// does not say which state a device is in right now.
struct DeviceProfile: Sendable, Equatable {
  let identifier: String
  let memoryGB: Double
  let thermalState: ProcessInfo.ThermalState
  let lowPowerMode: Bool
  let batteryState: UIDevice.BatteryState
  let batteryLevel: Float

  static func current() -> DeviceProfile {
    UIDevice.current.isBatteryMonitoringEnabled = true
    let info = ProcessInfo.processInfo
    return DeviceProfile(
      identifier: hardwareIdentifier(),
      memoryGB: Double(info.physicalMemory) / 1_073_741_824,
      thermalState: info.thermalState,
      lowPowerMode: info.isLowPowerModeEnabled,
      batteryState: UIDevice.current.batteryState,
      batteryLevel: UIDevice.current.batteryLevel
    )
  }

  /// `iPhone17,2` style identifier. `UIDevice.model` only says "iPhone", which
  /// cannot distinguish an 8 GB device from a 12 GB one.
  private static func hardwareIdentifier() -> String {
    // The simulator reports the host's hardware, so prefer the env var it sets.
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulated
    }
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafePointer(to: &systemInfo.machine) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }
    return machine
  }

  /// Whether this device should take long-running work.
  ///
  /// Thermal pressure and Low Power Mode both cut sustained decode throughput,
  /// and a device on battery can be backgrounded by the user at any moment.
  var suitedToLongWork: Bool {
    guard !lowPowerMode else { return false }
    guard thermalState == .nominal || thermalState == .fair else { return false }
    return batteryState == .charging || batteryState == .full
  }

  var thermalLabel: String {
    switch thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  var powerLabel: String {
    switch batteryState {
    case .charging: return "charging"
    case .full: return "full"
    case .unplugged: return "battery \(Int(batteryLevel * 100))%"
    case .unknown: return "unknown"
    @unknown default: return "unknown"
    }
  }
}
