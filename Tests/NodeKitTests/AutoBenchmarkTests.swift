import XCTest

@testable import NodeKit

final class AutoBenchmarkTests: XCTestCase {
  /// The connect-time case this exists for: nothing measured, node idle,
  /// weights local, first attempt.
  func test_fresh_idle_node_with_local_weights_measures() {
    XCTAssertTrue(
      AutoBenchmark.shouldRun(
        hasBenchmark: false, servedRate: 0, liveRate: 0,
        running: false, weightsReady: true, alreadyAttempted: false))
  }

  func test_anything_real_outranks_the_synthetic_measurement() {
    // An earlier benchmark.
    XCTAssertFalse(
      AutoBenchmark.shouldRun(
        hasBenchmark: true, servedRate: 0, liveRate: 0,
        running: false, weightsReady: true, alreadyAttempted: false))
    // A rate from actually serving someone.
    XCTAssertFalse(
      AutoBenchmark.shouldRun(
        hasBenchmark: false, servedRate: 31.5, liveRate: 0,
        running: false, weightsReady: true, alreadyAttempted: false))
    // A live local run mid-generation.
    XCTAssertFalse(
      AutoBenchmark.shouldRun(
        hasBenchmark: false, servedRate: 0, liveRate: 24.0,
        running: false, weightsReady: true, alreadyAttempted: false))
  }

  func test_never_interrupts_work_in_progress() {
    XCTAssertFalse(
      AutoBenchmark.shouldRun(
        hasBenchmark: false, servedRate: 0, liveRate: 0,
        running: true, weightsReady: true, alreadyAttempted: false))
  }

  func test_connect_must_not_become_a_download() {
    XCTAssertFalse(
      AutoBenchmark.shouldRun(
        hasBenchmark: false, servedRate: 0, liveRate: 0,
        running: false, weightsReady: false, alreadyAttempted: false))
  }

  func test_fires_at_most_once_per_launch() {
    XCTAssertFalse(
      AutoBenchmark.shouldRun(
        hasBenchmark: false, servedRate: 0, liveRate: 0,
        running: false, weightsReady: true, alreadyAttempted: true))
  }
}
