#if canImport(Darwin)
  import XCTest

  @testable import NodeKit

  /// The tier is derived, never configured, so the derivation is the contract.
  /// These run on macOS where `current()` is unconditionally permanent, so the
  /// iOS-side rules are asserted through the same decision table the device
  /// evaluates — the parameters, not the platform.
  final class NodeTierTests: XCTestCase {
    func testMacIsAlwaysPermanent() {
      // On the macOS test host every combination lands permanent.
      XCTAssertEqual(NodeTier.current(), .permanent)
      XCTAssertEqual(NodeTier.current(onMains: false, screenHeldAwake: false), .permanent)
    }

    #if !os(macOS)
      func testHeldScreenIsNonNegotiable() {
        // Silicon does not exempt suspension: a pad that can lock is burst.
        XCTAssertEqual(NodeTier.current(onMains: true, screenHeldAwake: false, padClass: true), .burst)
      }

      func testPadClassHoldsPermanentOnBattery() {
        // Owner-directed 2026-08-26: an M4 iPad with the screen pinned awake
        // serves alongside the Macs even unplugged; a phone does not.
        XCTAssertEqual(NodeTier.current(onMains: false, screenHeldAwake: true, padClass: true), .permanent)
        XCTAssertEqual(NodeTier.current(onMains: false, screenHeldAwake: true, padClass: false), .burst)
      }
    #endif
  }
#endif
