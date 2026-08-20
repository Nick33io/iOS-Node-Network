import Foundation
import XCTest
import WriteCore
@testable import WriteMesh

final class MeshProtocolTests: XCTestCase {
  private func spec() -> SectionSpec {
    SectionSpec(
      id: "s1", heading: "Status", intent: "Report.",
      points: ["Name the week."], mustInclude: ["NAME_1"], targetWords: 80
    )
  }

  /// Every message the mesh can say, one of each case.
  private func allMessages() -> [MeshMessage] {
    [
      .announce(session: "33write", items: 7),
      .join(capabilities: [.assemble, .review, .section]),
      .offer(
        item: WorkItem(id: "s1", dependencies: [], payload: .section(spec())),
        inputs: [Handoff(itemID: "s0", text: "prior text")]
      ),
      .claim(itemID: "s1"),
      .progress(itemID: "s1", fraction: 0.5),
      .result(itemID: "s1", outcome: .completed(text: "done text", issues: ["over length"])),
      .result(itemID: "s1", outcome: .failed(reason: "generation refused")),
      .release(itemID: "s1", reason: "unsupported kind"),
      .heartbeat,
    ]
  }

  func testEveryMessageRoundTripsThroughCodable() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for message in allMessages() {
      let envelope = MeshEnvelope(from: NodeID("n1"), body: message)
      let data = try encoder.encode(envelope)
      let decoded = try decoder.decode(MeshEnvelope.self, from: data)
      XCTAssertEqual(decoded, envelope)
    }
  }

  func testFutureProtocolVersionIsDetectedBeforeTheBody() throws {
    let envelope = MeshEnvelope(from: NodeID("n1"), body: .heartbeat)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let json = String(data: try encoder.encode(envelope), encoding: .utf8)!
    // A version-2 peer may also carry a body case this build cannot decode;
    // mangling only the version proves the guard fires first.
    let futureJSON = json.replacingOccurrences(
      of: "\"version\":\(MeshEnvelope.currentVersion)",
      with: "\"version\":\(MeshEnvelope.currentVersion + 1)"
    )
    XCTAssertNotEqual(futureJSON, json)

    XCTAssertThrowsError(
      try JSONDecoder().decode(MeshEnvelope.self, from: Data(futureJSON.utf8))
    ) { error in
      XCTAssertEqual(
        error as? MeshProtocolError,
        .unsupportedVersion(MeshEnvelope.currentVersion + 1)
      )
    }
  }
}
