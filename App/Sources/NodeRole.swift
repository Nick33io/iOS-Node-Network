import SwiftUI
import UIKit

/// What this device is for.
///
/// One app, two jobs. An iPad has the screen and the battery to sit and watch a
/// fleet; a phone is better spent as a worker. Splitting by idiom rather than
/// shipping two apps keeps the node contract in one place — the manager and the
/// nodes it watches are compiled from the same source of truth about what a
/// node reports.
enum NodeRole {
  case node
  case manager

  static var current: NodeRole {
    UIDevice.current.userInterfaceIdiom == .pad ? .manager : .node
  }
}
