#if canImport(Darwin)
  import Darwin
  import Foundation
import os

  #if canImport(UIKit)
    import UIKit
  #else
    import SystemConfiguration
  #endif

  /// Where a node's power is coming from, in the terms scheduling cares about.
  ///
  /// A phone can answer this precisely because UIKit reports the battery. A Mac
  /// cannot without IOKit power-source polling, and inventing a percentage would
  /// be worse than saying which assumption is in force — hence `mains` rather
  /// than a fabricated `battery(percent:)`.
  public enum NodePower: Sendable, Equatable {
    case charging
    case full
    case battery(percent: Int)
    case mains
    case unknown
  }

  /// What this device can contribute to the mesh.
  ///
  /// The coordinator schedules against these values rather than against a device
  /// name: a thermally throttled phone and a plugged-in iPad differ in ways that
  /// matter to lease length and item routing, and the model identifier alone
  /// does not say which state a device is in right now.
  public struct DeviceProfile: Sendable, Equatable {
    public let identifier: String
    public let memoryGB: Double
    public let thermalState: ProcessInfo.ThermalState
    public let lowPowerMode: Bool
    public let power: NodePower

    public init(
      identifier: String,
      memoryGB: Double,
      thermalState: ProcessInfo.ThermalState,
      lowPowerMode: Bool,
      power: NodePower
    ) {
      self.identifier = identifier
      self.memoryGB = memoryGB
      self.thermalState = thermalState
      self.lowPowerMode = lowPowerMode
      self.power = power
    }

    /// Resident footprint of this process.
    ///
    /// `phys_footprint` is the figure jetsam compares against its limit, so it
    /// is the only memory number worth reporting from a device that can be
    /// killed for exceeding it. Installed RAM says what the hardware has; this
    /// says how close the process is to being terminated.
    /// Bytes this process may still allocate before the system kills it.
    ///
    /// On iOS this is `os_proc_available_memory`, the real remaining headroom.
    /// macOS has no equivalent jetsam ceiling for a normal process, so it
    /// reports installed memory — the honest answer for a machine that pages
    /// instead of being terminated.
    public static func availableMemoryBytes() -> UInt64 {
      #if os(iOS)
        return UInt64(max(0, os_proc_available_memory()))
      #else
        return ProcessInfo.processInfo.physicalMemory
      #endif
    }

    public static func residentFootprintBytes() -> UInt64 {
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

    public static func current() -> DeviceProfile {
      let info = ProcessInfo.processInfo
      return DeviceProfile(
        identifier: hardwareIdentifier(),
        memoryGB: Double(info.physicalMemory) / 1_073_741_824,
        thermalState: info.thermalState,
        lowPowerMode: info.isLowPowerModeEnabled,
        power: currentPower()
      )
    }

    private static func currentPower() -> NodePower {
      #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .charging: return .charging
        case .full: return .full
        case .unplugged: return .battery(percent: Int(UIDevice.current.batteryLevel * 100))
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
      #else
        // A Mac is scheduled as mains-powered. Reading the real power source
        // needs IOKit, which no node does yet; until one does, a laptop on
        // battery is over-scheduled rather than misreported. Thermal state
        // still gates long work, and that is what actually throttles decode.
        return .mains
      #endif
    }

    /// `iPhone17,2` / `Mac16,10` style identifier. The friendly model name only
    /// says "iPhone" or "MacBook Pro", which cannot distinguish an 8 GB device
    /// from a 12 GB one.
    private static func hardwareIdentifier() -> String {
      #if canImport(UIKit)
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
      #else
        // `uname` reports the architecture on macOS — "arm64" for every Apple
        // silicon Mac from an Air to a Studio. `hw.model` is the field that
        // carries the model identifier the iOS side reports.
        return sysctlString("hw.model") ?? "Mac"
      #endif
    }

    private static func sysctlString(_ name: String) -> String? {
      var size = 0
      guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
      var value = [UInt8](repeating: 0, count: size)
      guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
      return String(decoding: value.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Whether this device should take long-running work.
    ///
    /// Thermal pressure and Low Power Mode both cut sustained decode throughput,
    /// and a device on battery can be backgrounded by the user at any moment.
    public var suitedToLongWork: Bool {
      guard !lowPowerMode else { return false }
      guard thermalState == .nominal || thermalState == .fair else { return false }
      switch power {
      case .charging, .full, .mains: return true
      case .battery, .unknown: return false
      }
    }

    public var thermalLabel: String {
      switch thermalState {
      case .nominal: return "nominal"
      case .fair: return "fair"
      case .serious: return "serious"
      case .critical: return "critical"
      @unknown default: return "unknown"
      }
    }

    public var powerLabel: String {
      switch power {
      case .charging: return "charging"
      case .full: return "full"
      case .battery(let percent): return "battery \(percent)%"
      case .mains: return "mains"
      case .unknown: return "unknown"
      }
    }

    /// What a human calls this node. Reported in the fleet profile, so it has to
    /// be the name the owner would recognise rather than the mesh identity.
    public static var localLabel: String {
      #if canImport(UIKit)
        return UIDevice.current.name
      #else
        // Read from the dynamic store rather than via `Host`/`ProcessInfo`,
        // both of which can go out to DNS or mDNS and block. This runs on the
        // main actor while answering `/health`, so a resolver stall there would
        // stop the node serving.
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? { return name }
        return sysctlString("kern.hostname") ?? "Mac"
      #endif
    }
  }
#endif
