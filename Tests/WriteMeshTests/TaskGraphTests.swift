import XCTest
import WriteCore
@testable import WriteMesh

final class TaskGraphTests: XCTestCase {
  private func item(_ id: String, deps: [String] = []) -> WorkItem {
    WorkItem(id: id, dependencies: deps, payload: .assemble)
  }

  func testEmptyGraphIsRejected() {
    XCTAssertThrowsError(try TaskGraph(items: []).validate()) { error in
      XCTAssertEqual(error as? TaskGraphError, .noItems)
    }
  }

  func testDuplicateItemIDIsRejected() {
    let graph = TaskGraph(items: [item("a"), item("a")])
    XCTAssertThrowsError(try graph.validate()) { error in
      XCTAssertEqual(error as? TaskGraphError, .duplicateItemID("a"))
    }
  }

  func testUnknownDependencyIsRejected() {
    let graph = TaskGraph(items: [item("a", deps: ["ghost"])])
    XCTAssertThrowsError(try graph.validate()) { error in
      XCTAssertEqual(error as? TaskGraphError, .unknownDependency(item: "a", dependency: "ghost"))
    }
  }

  func testCycleIsRejectedAndNamed() {
    let graph = TaskGraph(items: [
      item("a", deps: ["c"]),
      item("b", deps: ["a"]),
      item("c", deps: ["b"]),
      item("free"),
    ])
    XCTAssertThrowsError(try graph.validate()) { error in
      XCTAssertEqual(error as? TaskGraphError, .cycle(involving: ["a", "b", "c"]))
    }
  }

  func testSelfDependencyIsRejectedAsACycle() {
    let graph = TaskGraph(items: [item("a", deps: ["a"])])
    XCTAssertThrowsError(try graph.validate()) { error in
      XCTAssertEqual(error as? TaskGraphError, .cycle(involving: ["a"]))
    }
  }

  func testValidGraphPasses() throws {
    let graph = TaskGraph(items: [
      item("a"),
      item("b"),
      item("join", deps: ["a", "b"]),
    ])
    XCTAssertNoThrow(try graph.validate())
  }

  func testPlanConversionYieldsSectionsThenAssemble() throws {
    let plan = Plan(
      title: "T", audience: "a", tone: "plain",
      sections: (1...3).map { index in
        SectionSpec(
          id: "s\(index)", heading: "H\(index)", intent: "i",
          points: [], mustInclude: [], targetWords: 80
        )
      }
    )
    let graph = try TaskGraph.from(plan)

    XCTAssertEqual(graph.items.count, 4)
    for (item, spec) in zip(graph.items, plan.sections) {
      XCTAssertEqual(item.id, spec.id)
      XCTAssertEqual(item.dependencies, [])
      XCTAssertEqual(item.payload, .section(spec))
    }
    let assemble = try XCTUnwrap(graph.items.last)
    XCTAssertEqual(assemble.id, TaskGraph.assembleItemID)
    XCTAssertEqual(assemble.kind, .assemble)
    XCTAssertEqual(assemble.dependencies, ["s1", "s2", "s3"])
  }

  func testPlanConversionRejectsASectionNamedAssemble() {
    let plan = Plan(
      title: "T", audience: "a", tone: "plain",
      sections: [
        SectionSpec(
          id: TaskGraph.assembleItemID, heading: "H", intent: "i",
          points: [], mustInclude: [], targetWords: 80
        )
      ]
    )
    XCTAssertThrowsError(try TaskGraph.from(plan)) { error in
      XCTAssertEqual(error as? TaskGraphError, .duplicateItemID(TaskGraph.assembleItemID))
    }
  }

  func testKindIsDerivedFromPayload() {
    let spec = SectionSpec(
      id: "s1", heading: "H", intent: "i", points: [], mustInclude: [], targetWords: 80
    )
    XCTAssertEqual(WorkItem(id: "a", dependencies: [], payload: .section(spec)).kind, .section)
    XCTAssertEqual(WorkItem(id: "b", dependencies: [], payload: .review(targetItemID: "a")).kind, .review)
    XCTAssertEqual(WorkItem(id: "c", dependencies: [], payload: .assemble).kind, .assemble)
  }
}
