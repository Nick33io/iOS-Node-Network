import SwiftUI
import WidgetKit

/// Fleet state on a schedule WidgetKit will actually honour.
///
/// A widget cannot show live throughput and should not pretend to. The system
/// budgets refreshes — a few dozen a day — so this asks for five minutes and
/// takes what it is given. The reading is stamped with its own age in the
/// larger families rather than presented as current.
struct FleetProvider: TimelineProvider {
  func placeholder(in context: Context) -> FleetEntry {
    FleetEntry(date: .now, snapshot: FleetSnapshot(throughput: 743, inFlight: 24, reachable: 3, total: 3))
  }

  func getSnapshot(in context: Context, completion: @escaping (FleetEntry) -> Void) {
    // The gallery preview gets plausible numbers rather than an empty frame,
    // which is what a live probe would render while the picker is open.
    if context.isPreview {
      completion(placeholder(in: context))
      return
    }
    let box = Handoff(send: completion)
    Task { box.send(FleetEntry(date: .now, snapshot: await FleetProbe.snapshot())) }
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<FleetEntry>) -> Void) {
    let box = Handoff(send: completion)
    Task {
      let snapshot = await FleetProbe.snapshot()
      // Sooner while the fleet is working, because that is when the number
      // changes; a quiet fleet does not need the budget spent on it.
      let next = Date.now.addingTimeInterval(snapshot.working ? 300 : 900)
      box.send(Timeline(entries: [FleetEntry(date: .now, snapshot: snapshot)], policy: .after(next)))
    }
  }
}

/// Carries WidgetKit's completion handler across a task boundary.
///
/// `@unchecked` because the closure comes from the framework and cannot be
/// made Sendable. Safe to move: it is called exactly once, from one task.
private struct Handoff<Value>: @unchecked Sendable {
  let send: (Value) -> Void
}

struct FleetEntry: TimelineEntry {
  let date: Date
  let snapshot: FleetSnapshot
}

struct FleetWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "io.thirtythree.nod3.fleet", provider: FleetProvider()) { entry in
      FleetWidgetView(snapshot: entry.snapshot)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("NOD3 Fleet")
    .description("Throughput across your Macs.")
    .supportedFamilies(Self.families)
  }

  /// Every family the platform offers. macOS has no Lock Screen accessories
  /// and no extra-large on iPhone, so the list is built rather than fixed.
  static var families: [WidgetFamily] {
    #if os(macOS)
      [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    #else
      var all: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
      if UIDevice.current.userInterfaceIdiom == .pad { all.append(.systemExtraLarge) }
      all.append(contentsOf: [.accessoryRectangular, .accessoryInline])
      return all
    #endif
  }
}

#if os(iOS)
  import UIKit
#endif
