import Foundation
import NodeKit
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
    case loading
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
  /// Host running the planner. Tailscale gives every device a stable address
  /// that survives moving between networks, which a LAN IP does not — the
  /// mesh keeps working off the home Wi-Fi.
  var host: String = "100.73.112.15"
  var plannerModel: String = "33qwen:latest"
  var writerModel: String = "33qwen-local:latest"

  var backend: WriterBackend = .default
  /// Weight-download progress on first launch, 0...1. The pinned model is
  /// ~2.3 GB; a silent first run looks like a hang.
  var loadProgress: Double = 0

  /// Tokens produced in the current run, accumulated as sections land so the
  /// meter moves during a task rather than only at the end.
  var tokensThisRun = 0
  var tokensPerSecondLive: Double = 0

  /// Link measurement to `host`, distinct from generation throughput.
  var link: LinkResult?
  var linkError: String?
  var isTestingLink = false

  /// Measured speed of this device, once benchmarked.
  var benchmark: BenchmarkResult?
  var benchmarkError: String?

  private(set) var facts: FactMap?
  #if canImport(MLX) && !targetEnvironment(simulator)
    private let deviceWriter = MLXWriter()
  #endif

  var isRunning: Bool {
    phase == .loading || phase == .planning || phase == .writing
  }

  /// Writer for serving remote requests. Same instance the UI uses, so a
  /// dispatched task and a local run cannot end up on different models.
  func writerForServing() async throws -> any DeviceWriter {
    guard let base = URL(string: "http://\(host):11434") else {
      throw MLXWriterError.unavailable("invalid host")
    }
    return try await makeWriter(base: base)
  }

  /// Downloads the weights this node selected, for `POST /fetch`.
  ///
  /// The caller does not name a model. Which model a device should hold is
  /// decided by `MLXPolicy` from that device's own headroom — a 16 GB iPad and
  /// an 8 GB phone do not belong on the same weights — so the fleet asks a node
  /// to fetch whatever it chose rather than telling it what to run.
  func prefetchSelected() async throws {
    #if canImport(MLX) && !targetEnvironment(simulator)
      guard backend == .onDevice else {
        throw MLXWriterError.unavailable("backend is \(backend.label), not on-device")
      }
      guard !MLXWriter.isDownloaded(MLXPolicy.model) else { return }
      try await deviceWriter.prefetch(MLXPolicy.model) { fraction in
        Task { @MainActor [weak self] in self?.loadProgress = fraction }
      }
    #endif
  }

  /// The writer for this run, honouring the selected backend.
  private func makeWriter(base: URL) async throws -> any DeviceWriter {
    switch backend {
    case .lan:
      return LANWriter(model: writerModel, baseURL: base)
    case .onDevice:
      #if canImport(MLX) && !targetEnvironment(simulator)
        // A model already resident always serves. The guard below exists to
        // stop a request becoming a silent multi-gigabyte download — it must
        // never veto weights that are literally in memory.
        if await deviceWriter.loadedModel != nil {
          return deviceWriter
        }
        // Refuse before loading, not inside it. An earlier fix guarded
        // generation, but the download happens here — so a request still hung
        // for however long 4.6 GB takes, with the caller unable to see why. A
        // node that lacks its weights must say so in milliseconds.
        guard MLXWriter.isDownloaded(MLXPolicy.model) else {
          throw MLXWriterError.notDownloaded(MLXPolicy.allowedModel)
        }
        phase = .loading
        try await deviceWriter.load { fraction in
          Task { @MainActor [weak self] in self?.loadProgress = fraction }
        }
        return deviceWriter
      #else
        return MLXWriterUnavailable(reason: WriterBackend.unavailableReason)
      #endif
    }
  }

  /// Measures this device alone. Separate from `run` because a document run
  /// mixes planner latency, network, and retries into the number — useless for
  /// comparing hardware.
  func runBenchmark() async {
    guard !isRunning else { return }
    benchmarkError = nil
    benchmark = nil
    guard let base = URL(string: "http://\(host):11434") else { return }
    do {
      let writer = try await makeWriter(base: base)
      phase = .writing
      benchmark = try await Benchmark.run(
        writer: writer,
        device: DeviceProfile.current().identifier,
        model: backend == .onDevice ? MLXPolicy.allowedModel : writerModel,
        backend: backend.label
      )
      phase = .idle
    } catch {
      benchmarkError = String(describing: error)
      phase = .idle
    }
  }

  /// Measures the network link to the configured host.
  func runLinkTest() async {
    guard !isTestingLink else { return }
    isTestingLink = true
    linkError = nil
    defer { isTestingLink = false }
    do {
      link = try await LinkTest.run(host: host)
    } catch {
      link = nil
      linkError = (error as NSError).localizedDescription
    }
  }

  func run() async {
    guard !isRunning else { return }
    sections = []
    title = ""
    tokensThisRun = 0
    tokensPerSecondLive = 0
    phase = .planning

    guard let base = URL(string: "http://\(host):11434") else {
      phase = .failed("Invalid host")
      return
    }

    do {
      let facts = try Demo.facts()
      self.facts = facts
      let writer = try await makeWriter(base: base)
      phase = .planning
      let pipeline = WritePipeline(
        planner: LANPlanner(model: plannerModel, baseURL: base),
        writer: writer,
        facts: facts,
        maxAttempts: 2
      )

      let started = Date()
      let sectionStarted = Date()
      let document = try await pipeline.run(brief: Demo.brief, targetWords: 500) { section in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.phase = .writing
          self.sections.append(section)
          // Character-derived: the tokenizer is not exposed through
          // DeviceWriter, and ~4 chars per token is close enough for a meter.
          let tokens = max(1, section.text.count / 4)
          self.tokensThisRun += tokens
          let elapsed = -sectionStarted.timeIntervalSinceNow
          if elapsed > 0 { self.tokensPerSecondLive = Double(self.tokensThisRun) / elapsed }
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
