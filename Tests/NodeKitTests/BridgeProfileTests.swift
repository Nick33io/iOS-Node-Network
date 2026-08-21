#if canImport(Darwin)
  import Foundation
  import WriteCore
  import XCTest

  @testable import NodeKit

  /// The profile is a contract with 33 Shell, not an internal struct. A field
  /// that quietly changes name or type breaks a controller this repo cannot see,
  /// so the shape is asserted rather than assumed.
  final class BridgeProfileTests: XCTestCase {
    private let limits = DeviceLimits.qwen3_4B_4bit

    private func payload() -> [String: Any] {
      BridgeProfileEmitter.payload(
        node: "node-abc123",
        label: "Test Node",
        backend: "LAN",
        model: "llama-33fast:latest",
        limits: limits
      )
    }

    func testCarriesTheFleetSchema() {
      XCTAssertEqual(payload()["schema"] as? String, "33-shell-bridge-fleet/v1")
    }

    func testProfileNamesTheHTTPTransportAndTheRealPort() throws {
      let profile = try XCTUnwrap(payload()["profile"] as? [String: Any])
      XCTAssertEqual(profile["id"] as? String, "node-abc123")
      XCTAssertEqual(profile["label"] as? String, "Test Node")
      XCTAssertEqual(profile["transport"] as? String, "tailscale-http")
      // Not 22. Reporting the SSH port to satisfy the Shell's type would be a
      // lie the controller would dial.
      XCTAssertEqual(profile["port"] as? UInt16, NodeServer.port)
      XCTAssertEqual(profile["credentialMode"] as? String, "device-key")
      // The device does not reliably know its own tailnet address; the
      // controller fills in the one it dialled.
      XCTAssertTrue(profile["host"] is NSNull)
      XCTAssertFalse(try XCTUnwrap(profile["fingerprint"] as? String).isEmpty)
    }

    func testMemoryIsRealAndNotAPlaceholder() throws {
      let profile = try XCTUnwrap(payload()["profile"] as? [String: Any])
      let memory = try XCTUnwrap(profile["memoryGiB"] as? Double)
      XCTAssertEqual(
        memory, Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824, accuracy: 0.001
      )
    }

    func testCapabilitiesPublishTheEnforcedLimits() throws {
      let capabilities = try XCTUnwrap(payload()["capabilities"] as? [String: Any])
      XCTAssertEqual(capabilities["backend"] as? String, "LAN")
      XCTAssertEqual(capabilities["model"] as? String, "llama-33fast:latest")
      XCTAssertEqual(capabilities["maxOutputTokens"] as? Int, limits.maxOutputTokens)
      XCTAssertEqual(capabilities["maxInputCharacters"] as? Int, limits.maxInputCharacters)
      XCTAssertEqual(capabilities["maxContextTokens"] as? Int, limits.maxContextTokens)
      XCTAssertEqual(capabilities["wordBudgetPerSection"] as? Int, limits.wordBudgetPerSection)
      XCTAssertEqual(capabilities["kinds"] as? [String], ["section"])
      XCTAssertNotNil(capabilities["thermal"] as? String)
      XCTAssertNotNil(capabilities["power"] as? String)
      XCTAssertNotNil(capabilities["suitedToLongWork"] as? Bool)
    }

    /// The whole payload crosses the wire as JSON. A value JSONSerialization
    /// cannot encode would turn `/health` into an empty object at runtime.
    func testPayloadIsSerialisable() throws {
      XCTAssertTrue(JSONSerialization.isValidJSONObject(payload()))
      let data = try JSONSerialization.data(withJSONObject: payload(), options: [.sortedKeys])
      let round = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(round["schema"] as? String, BridgeProfileEmitter.schema)
    }

    func testIdentityIsStableAcrossCalls() {
      XCTAssertEqual(BridgeProfileEmitter.nodeIdentity, BridgeProfileEmitter.nodeIdentity)
      XCTAssertTrue(BridgeProfileEmitter.nodeIdentity.hasPrefix("node-"))
    }
  }

  final class DeviceProfileTests: XCTestCase {
    /// A Mac is scheduled as mains-powered, so only thermal pressure or Low
    /// Power Mode should hold it back from long work.
    func testMacIsEligibleForLongWorkWhenCool() {
      let profile = DeviceProfile(
        identifier: "Mac16,10", memoryGB: 64, thermalState: .nominal,
        lowPowerMode: false, power: .mains
      )
      XCTAssertTrue(profile.suitedToLongWork)
      XCTAssertEqual(profile.powerLabel, "mains")
    }

    func testThermalPressureStillDisqualifiesAMac() {
      let profile = DeviceProfile(
        identifier: "Mac16,10", memoryGB: 64, thermalState: .serious,
        lowPowerMode: false, power: .mains
      )
      XCTAssertFalse(profile.suitedToLongWork)
      XCTAssertEqual(profile.thermalLabel, "serious")
    }

    /// Unchanged from the iOS-only version: a device on battery can be
    /// backgrounded at any moment, so it takes short leases.
    func testUnpluggedDeviceIsNotSuitedToLongWork() {
      let profile = DeviceProfile(
        identifier: "iPhone17,2", memoryGB: 8, thermalState: .nominal,
        lowPowerMode: false, power: .battery(percent: 82)
      )
      XCTAssertFalse(profile.suitedToLongWork)
      XCTAssertEqual(profile.powerLabel, "battery 82%")
    }

    func testChargingDeviceIsSuitedToLongWork() {
      let profile = DeviceProfile(
        identifier: "iPhone17,2", memoryGB: 8, thermalState: .fair,
        lowPowerMode: false, power: .charging
      )
      XCTAssertTrue(profile.suitedToLongWork)
    }

    func testLowPowerModeDisqualifiesRegardlessOfPower() {
      let profile = DeviceProfile(
        identifier: "Mac16,10", memoryGB: 64, thermalState: .nominal,
        lowPowerMode: true, power: .mains
      )
      XCTAssertFalse(profile.suitedToLongWork)
    }

    func testCurrentReportsRealMemoryAndAModelIdentifier() {
      let profile = DeviceProfile.current()
      XCTAssertGreaterThan(profile.memoryGB, 0)
      XCTAssertFalse(profile.identifier.isEmpty)
      // `uname` would report "arm64" here; the model identifier is the field
      // that distinguishes an Air from a Studio.
      XCTAssertNotEqual(profile.identifier, "arm64")
    }
  }
#endif
