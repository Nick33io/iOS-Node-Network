import Foundation
import WriteCore
import WriteLAN

/// Which writer this build can actually use.
///
/// MLX needs a Metal GPU, so the simulator cannot run the on-device model at
/// all. Rather than pretend otherwise, the app names the backend it is using
/// on screen — a run that silently fell back to the LAN would misrepresent
/// exactly the property this project exists to demonstrate.
enum WriterBackend: String, CaseIterable, Identifiable {
  case onDevice
  case lan

  var id: String { rawValue }

  var label: String {
    switch self {
    case .onDevice: return "on-device MLX"
    case .lan: return "LAN"
    }
  }

  /// Whether this build can run the on-device model.
  static var supportsOnDevice: Bool {
    #if canImport(MLX) && !targetEnvironment(simulator)
      return true
    #else
      return false
    #endif
  }

  static var `default`: WriterBackend {
    supportsOnDevice ? .onDevice : .lan
  }

  static var unavailableReason: String {
    #if targetEnvironment(simulator)
      return "the simulator has no Metal GPU for MLX"
    #else
      return "MLX is not available in this build"
    #endif
  }
}
