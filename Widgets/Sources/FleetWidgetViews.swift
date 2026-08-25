import SwiftUI
import WidgetKit

/// One layout per family, sharing a palette and a scale.
///
/// The families are not the same widget at different sizes — a small widget
/// answers "is it working", a large one answers "what is each machine doing".
/// Rendering the same content scaled would waste the space the larger families
/// exist to provide.
struct FleetWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let snapshot: FleetSnapshot

  private var live: Color { Color(red: 0.42, green: 0.95, blue: 0.62) }
  private var quiet: Color { .primary.opacity(0.55) }
  private var accent: Color { snapshot.working ? live : quiet }

  var body: some View {
    switch family {
    case .systemSmall: small
    case .systemLarge: large
    #if os(iOS)
      case .accessoryRectangular: accessoryRect
      case .accessoryInline:
        Text(snapshot.working ? "NOD3 \(Int(snapshot.throughput)) tok/s" : "NOD3 idle")
    #endif
    default: medium
    }
  }

  // MARK: Families

  /// Is it working, and how fast.
  private var small: some View {
    VStack(alignment: .leading, spacing: 2) {
      label
      Spacer(minLength: 0)
      Text(snapshot.working ? "\(Int(snapshot.throughput))" : "—")
        .font(.system(size: 40, weight: .medium, design: .monospaced))
        .foregroundStyle(accent)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
      Text("tokens/sec")
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Adds what the fleet is doing to how fast it is going.
  private var medium: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        label
        Spacer(minLength: 0)
        Text(snapshot.working ? "\(Int(snapshot.throughput))" : "—")
          .font(.system(size: 44, weight: .medium, design: .monospaced))
          .foregroundStyle(accent)
          .minimumScaleFactor(0.6)
          .lineLimit(1)
        Text("tokens/sec")
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: 10) {
        stat("\(snapshot.inFlight)", "in flight")
        stat("\(snapshot.reachable)/\(snapshot.total)", "nodes up")
      }
    }
  }

  /// The whole picture, including the nodes themselves.
  private var large: some View {
    VStack(alignment: .leading, spacing: 12) {
      label
      Text(snapshot.working ? "\(Int(snapshot.throughput))" : "—")
        .font(.system(size: 58, weight: .medium, design: .monospaced))
        .foregroundStyle(accent)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
      Text(snapshot.working ? "tokens/sec · \(snapshot.inFlight) in flight" : "tokens/sec · idle")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
      Divider().opacity(0.25)
      VStack(spacing: 7) {
        ForEach(Array(FleetProbe.macs.enumerated()), id: \.offset) { index, _ in
          HStack(spacing: 8) {
            Circle()
              .fill(index < snapshot.reachable ? accent : .secondary.opacity(0.3))
              .frame(width: 5, height: 5)
            Text(Self.macNames[index])
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.primary.opacity(0.75))
            Spacer()
            Text(index < snapshot.reachable ? "up" : "—")
              .font(.system(size: 10, design: .monospaced))
              .foregroundStyle(.secondary)
          }
        }
      }
      Spacer(minLength: 0)
    }
  }

  #if os(iOS)
    private var accessoryRect: some View {
      VStack(alignment: .leading, spacing: 1) {
        Text("NOD3")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
        Text(snapshot.working ? "\(Int(snapshot.throughput)) tok/s" : "idle")
          .font(.system(size: 15, weight: .medium, design: .monospaced))
        Text("\(snapshot.reachable)/\(snapshot.total) nodes")
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
  #endif

  // MARK: Parts

  private static let macNames = ["M5 Max", "Mac mini", "MacBook Air"]

  private var label: some View {
    HStack(spacing: 5) {
      Circle().fill(accent).frame(width: 5, height: 5)
      Text("NOD3")
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(1.6)
        .foregroundStyle(.secondary)
    }
  }

  private func stat(_ value: String, _ caption: String) -> some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(value)
        .font(.system(size: 19, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.85))
      Text(caption)
        .font(.system(size: 8.5, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }
}
