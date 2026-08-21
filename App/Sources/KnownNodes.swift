import Foundation

/// The tailnet, as a catalogue.
///
/// Typing a 100.x address on a tablet is the kind of chore that stops a fleet
/// being used. These are the devices that actually exist on this tailnet, so
/// adding one is a tap on a name rather than an address recalled from memory.
///
/// Addresses are stable — Tailscale keeps them across networks and reboots —
/// but they are not immutable: a device removed and re-added to the tailnet
/// gets a new one. This is a convenience list, not a source of truth, which is
/// why free-text entry stays available beside it.
enum KnownNodes {
  struct Entry: Identifiable, Sendable {
    let label: String
    let host: String
    let platform: String
    var id: String { host }
  }

  static let all: [Entry] = [
    .init(label: "M5 Max", host: "100.73.112.15", platform: "macOS"),
    .init(label: "Mini M4 Pro", host: "100.101.220.18", platform: "macOS"),
    .init(label: "iPad Pro 13", host: "100.80.12.78", platform: "iOS"),
    .init(label: "iPhone 15 Pro Max", host: "100.126.56.73", platform: "iOS"),
    .init(label: "iPhone 17 Pro Max", host: "100.65.9.108", platform: "iOS"),
    .init(label: "iPhone Air", host: "100.86.4.127", platform: "iOS"),
    .init(label: "Fold 8 Ultra", host: "100.103.128.56", platform: "Android"),
    .init(label: "Z Flip", host: "100.93.35.81", platform: "Android"),
    .init(label: "33io backend 1", host: "100.67.145.126", platform: "macOS"),
    .init(label: "33io backend", host: "100.114.110.90", platform: "macOS"),
  ]

  /// Resolves free text to a host.
  ///
  /// Accepts an address outright, otherwise matches a catalogue label loosely —
  /// "fold", "17 pro", and "mini" should all land somewhere sensible, because
  /// nobody types a device's full name correctly on a touch keyboard.
  static func resolve(_ input: String) -> Entry? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    if looksLikeAddress(trimmed) {
      return all.first { $0.host == trimmed }
        ?? Entry(label: trimmed, host: trimmed, platform: "unknown")
    }
    let needle = trimmed.lowercased()
    return all.first { $0.label.lowercased() == needle }
      ?? all.first { $0.label.lowercased().contains(needle) }
  }

  static func looksLikeAddress(_ text: String) -> Bool {
    let parts = text.split(separator: ".")
    guard parts.count == 4 else { return text.contains(":") }
    return parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
  }
}
