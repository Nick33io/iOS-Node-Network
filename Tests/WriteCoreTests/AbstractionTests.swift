import XCTest
@testable import WriteCore

final class AbstractionTests: XCTestCase {
  private func map() throws -> FactMap {
    try FactMap([
      Fact(id: "ORG_1", kind: .org, value: "Acme Studios Ltd", label: "the production company"),
      Fact(id: "ORG_2", kind: .org, value: "Acme", label: "the parent group"),
      Fact(id: "NAME_1", kind: .name, value: "Dana Reyes", label: "the line producer"),
      Fact(id: "MONEY_1", kind: .money, value: "$1,250,000", label: "the department allocation"),
    ])
  }

  func testRedactsLongestValueFirst() throws {
    let a = Abstractor(facts: try map())
    // "Acme" is a prefix of "Acme Studios Ltd"; shortest-first would strand
    // " Studios Ltd" in the redacted text.
    XCTAssertEqual(a.redact("Acme Studios Ltd owns it"), "[[ORG_1]] owns it")
  }

  func testRedactionIsCaseInsensitiveAndCanonical() throws {
    let a = Abstractor(facts: try map())
    XCTAssertEqual(a.redact("dana reyes and DANA REYES"), "[[NAME_1]] and [[NAME_1]]")
  }

  func testSealedPassesWhenFullyRedacted() throws {
    let a = Abstractor(facts: try map())
    let sealed = try a.sealed("Dana Reyes at Acme Studios Ltd approved $1,250,000.")
    XCTAssertFalse(sealed.lowercased().contains("dana"))
    XCTAssertFalse(sealed.contains("1,250,000"))
  }

  func testLeakOfPlainValueIsBlocked() throws {
    let a = Abstractor(facts: try map())
    XCTAssertThrowsError(try a.assertNoLeak("Dana Reyes signed off")) { error in
      XCTAssertEqual(error as? EgressError, .valueLeaked(id: "NAME_1", kind: .name))
    }
  }

  func testReformattedNumberIsBlocked() throws {
    let a = Abstractor(facts: try map())
    // Redaction misses this because the surface form differs, so the gate is
    // the only thing standing between it and the network.
    XCTAssertThrowsError(try a.assertNoLeak("the allocation of 1250000 dollars")) { error in
      XCTAssertEqual(error as? EgressError, .valueLeaked(id: "MONEY_1", kind: .money))
    }
  }

  func testShortValueDoesNotRedactInsideALongerNumber() throws {
    let a = Abstractor(facts: try FactMap([
      Fact(id: "NUMBER_1", kind: .number, value: "12", label: "episode count")
    ]))
    // Unbounded substring matching would rewrite this as "shot in 20[[NUMBER_1]]".
    XCTAssertEqual(a.redact("shot in 2012 over 12 days"), "shot in 2012 over [[NUMBER_1]] days")
  }

  func testValueDoesNotRedactInsideALongerWord() throws {
    let a = Abstractor(facts: try map())
    XCTAssertEqual(a.redact("Acmeworks is not Acme"), "Acmeworks is not [[ORG_2]]")
  }

  func testSealedPassesOnceShortValuesAreRedacted() throws {
    let a = Abstractor(facts: try FactMap([
      Fact(id: "NUMBER_1", kind: .number, value: "12", label: "episode count")
    ]))
    XCTAssertNoThrow(try a.sealed("shot in 2012 over 12 days"))
  }

  func testRehydrateRestoresValues() throws {
    let a = Abstractor(facts: try map())
    XCTAssertEqual(a.rehydrate("[[NAME_1]] at [[ORG_1]]"), "Dana Reyes at Acme Studios Ltd")
  }

  func testScanIgnoresMalformedAndUnterminated() {
    XCTAssertEqual(Abstractor.scanPlaceholders("[[NAME_1]] [[lower_1]] [[NAME_2"), ["NAME_1"])
  }

  func testCatalogCarriesNoValues() throws {
    let catalog = try map().catalog
    let encoded = String(data: try JSONEncoder().encode(catalog), encoding: .utf8)!
    XCTAssertFalse(encoded.contains("Dana Reyes"))
    XCTAssertFalse(encoded.contains("1,250,000"))
    XCTAssertTrue(encoded.contains("the line producer"))
  }
}
