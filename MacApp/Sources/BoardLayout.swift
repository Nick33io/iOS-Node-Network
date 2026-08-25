import Observation
import SwiftUI

/// Where a module sits, in grid cells rather than points.
///
/// Cells, not points, because the window resizes and a saved pixel position
/// means nothing at a different size. A module dropped beside another stays
/// beside it.
struct ModuleFrame: Codable, Equatable, Sendable {
  var col: Int
  var row: Int
  var cols: Int
  var rows: Int
}

/// The arrangement of the board, and the only thing that persists about it.
///
/// Layout is a preference, so it outlives the window. Nodes come and go — a
/// phone that leaves the fleet should not take its position with it, and one
/// that returns should come back where it was — so frames are keyed by host
/// and kept even when the node is absent.
@Observable
final class BoardLayout {
  /// One grid cell. Small enough that a module can be sized close to what its
  /// content wants, large enough that dragging feels like placing rather than
  /// nudging.
  static let cell = CGSize(width: 46, height: 26)
  static let gap: CGFloat = 8

  static let collapsed = (cols: 6, rows: 3)
  static let expanded = (cols: 6, rows: 15)

  private(set) var frames: [String: ModuleFrame] = [:]
  var expandedIDs: Set<String> = []

  private static let key = "nod3.monitor.board"

  init() {
    if let data = UserDefaults.standard.data(forKey: Self.key),
      let saved = try? JSONDecoder().decode([String: ModuleFrame].self, from: data) {
      frames = saved
    }
  }

  func frame(for id: String, index: Int) -> ModuleFrame {
    if let existing = frames[id] { return existing }
    // First sight of a node: lay it out reading order, four across.
    let placed = ModuleFrame(
      col: (index % 4) * (Self.collapsed.cols + 1),
      row: (index / 4) * (Self.collapsed.rows + 1),
      cols: Self.collapsed.cols, rows: Self.collapsed.rows
    )
    frames[id] = placed
    return placed
  }

  func move(_ id: String, toCol col: Int, row: Int) {
    guard var frame = frames[id] else { return }
    frame.col = max(0, col)
    frame.row = max(0, row)
    frames[id] = frame
    save()
  }

  func resize(_ id: String, cols: Int, rows: Int) {
    guard var frame = frames[id] else { return }
    // A floor, because a module smaller than its own header is a module you
    // can no longer read or grab.
    frame.cols = max(4, cols)
    frame.rows = max(2, rows)
    frames[id] = frame
    save()
  }

  func toggle(_ id: String) {
    guard var frame = frames[id] else { return }
    if expandedIDs.contains(id) {
      expandedIDs.remove(id)
      frame.rows = Self.collapsed.rows
    } else {
      expandedIDs.insert(id)
      // Only grow if the module is still at its collapsed height — someone who
      // has sized it themselves has said what they want.
      if frame.rows <= Self.collapsed.rows { frame.rows = Self.expanded.rows }
      if frame.cols < Self.expanded.cols { frame.cols = Self.expanded.cols }
    }
    frames[id] = frame
    save()
  }

  func isExpanded(_ id: String) -> Bool { expandedIDs.contains(id) }

  /// Puts every module back on the default reading-order grid.
  func reset() {
    frames.removeAll()
    expandedIDs.removeAll()
    save()
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(frames) else { return }
    UserDefaults.standard.set(data, forKey: Self.key)
  }

  // MARK: Geometry

  static func point(_ frame: ModuleFrame) -> CGPoint {
    CGPoint(
      x: CGFloat(frame.col) * (cell.width + gap),
      y: CGFloat(frame.row) * (cell.height + gap)
    )
  }

  static func size(_ frame: ModuleFrame) -> CGSize {
    CGSize(
      width: CGFloat(frame.cols) * cell.width + CGFloat(frame.cols - 1) * gap,
      height: CGFloat(frame.rows) * cell.height + CGFloat(frame.rows - 1) * gap
    )
  }

  /// Nearest cell to a point, which is what makes a drop snap.
  static func cellIndex(x: CGFloat, y: CGFloat) -> (col: Int, row: Int) {
    (
      Int((x / (cell.width + gap)).rounded()),
      Int((y / (cell.height + gap)).rounded())
    )
  }
}
