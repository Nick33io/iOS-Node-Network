/// Decides whether a node that just started serving should measure itself.
///
/// Every probed neighbour's meter fills from its probe, but the self node
/// answers locally and never asks itself — so a fresh install reads
/// "unmeasured" until someone dispatches work here. Measuring once at
/// connect closes that gap. The guards keep the measurement honest:
/// anything real outranks it (a served rate, an earlier benchmark, a live
/// run), it never interrupts work in progress, it requires the weights to
/// already be local — joining the fleet must not become a silent
/// multi-gigabyte download — and it fires at most once per launch, so a
/// node that stops and resumes serving does not re-measure.
public enum AutoBenchmark {
  public static func shouldRun(
    hasBenchmark: Bool,
    servedRate: Double,
    liveRate: Double,
    running: Bool,
    weightsReady: Bool,
    alreadyAttempted: Bool
  ) -> Bool {
    !hasBenchmark && servedRate <= 0 && liveRate <= 0 && !running
      && weightsReady && !alreadyAttempted
  }
}
