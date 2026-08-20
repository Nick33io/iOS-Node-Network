import Foundation
import Observation
import WriteCore
import WriteLAN

/// Drives one document run and exposes it to the UI as it happens.
///
/// Sections are published the moment each one lands rather than at the end:
/// a device writes at roughly 20-30 tokens/second, so a multi-section document
/// takes minutes, and a silent screen for that long is indistinguishable from
/// a hang.
@MainActor
@Observable
final class RunModel {
  enum Phase: Equatable {
    case idle
    case planning
    case writing
    case finished(seconds: Int)
    case failed(String)
  }

  var phase: Phase = .idle
  var sections: [WrittenSection] = []
  var title: String = ""
  /// Host running the model server. The simulator cannot run MLX, so during
  /// development both roles are served over the LAN from the Mac.
  var host: String = "127.0.0.1"
  var plannerModel: String = "33qwen:latest"
  var writerModel: String = "33qwen-local:latest"

  private(set) var facts: FactMap?

  var isRunning: Bool {
    phase == .planning || phase == .writing
  }

  func run() async {
    guard !isRunning else { return }
    sections = []
    title = ""
    phase = .planning

    guard let base = URL(string: "http://\(host):11434") else {
      phase = .failed("Invalid host")
      return
    }

    do {
      let facts = try Demo.facts()
      self.facts = facts
      let pipeline = WritePipeline(
        planner: LANPlanner(model: plannerModel, baseURL: base),
        writer: LANWriter(model: writerModel, baseURL: base),
        facts: facts,
        maxAttempts: 2
      )

      let started = Date()
      let document = try await pipeline.run(brief: Demo.brief, targetWords: 500) { section in
        Task { @MainActor [weak self] in
          self?.phase = .writing
          self?.sections.append(section)
        }
      }
      title = document.title
      phase = .finished(seconds: Int(-started.timeIntervalSinceNow))
    } catch {
      phase = .failed(String(describing: error))
    }
  }
}

/// A brief carrying exactly the material that must not reach the planner.
enum Demo {
  static func facts() throws -> FactMap {
    try FactMap([
      Fact(id: "ORG_1", kind: .org, value: "Ironline Pictures", label: "the production company"),
      Fact(id: "NAME_1", kind: .name, value: "Marisol Vane", label: "the line producer"),
      Fact(id: "NAME_2", kind: .name, value: "Teddy Okafor", label: "the transportation captain"),
      Fact(id: "MONEY_1", kind: .money, value: "$48,500", label: "the transport overage to date"),
      Fact(id: "MONEY_2", kind: .money, value: "$1,900,000", label: "the remaining contingency"),
      Fact(id: "NUMBER_1", kind: .number, value: "11", label: "shooting days remaining"),
      Fact(id: "LOCATION_1", kind: .location, value: "Fairhope, Alabama", label: "the current location"),
    ])
  }

  static let brief = """
    Write an internal memo from Marisol Vane to the studio about the transport \
    overage on the Fairhope, Alabama shoot. Ironline Pictures is 11 shooting \
    days from wrap. Transport is $48,500 over, driven by picture-car towing and \
    a second fuel truck Teddy Okafor added during the storm week. Remaining \
    contingency is $1,900,000. Explain the drivers, state why no further \
    overage is expected, and recommend absorbing it from contingency.
    """
}
