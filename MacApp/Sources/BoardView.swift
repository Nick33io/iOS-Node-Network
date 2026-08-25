import SwiftUI

/// The arrangeable surface.
///
/// Free positions rather than a flow layout, because the arrangement carries
/// meaning a flow cannot: the machine you are watching goes where you look
/// first, and the ones you are not watching go where you do not. Positions
/// snap to a grid so an arrangement stays legible without anyone lining
/// anything up by hand.
/// Everything the board can hold.
///
/// The console panels are modules like any other — placeable, sizable, and
/// removable from view by dragging them aside — rather than chrome the
/// arrangement has to work around.
enum BoardItem: Identifiable {
  case summary
  case throughput
  case node(FleetNode)

  var id: String {
    switch self {
    case .summary: return "module.summary"
    case .throughput: return "module.throughput"
    case .node(let node): return node.host
    }
  }
}

struct BoardView: View {
  @Bindable var layout: BoardLayout
  let items: [BoardItem]
  let fleet: FleetManager
  let selfLabel: String
  let refresh: (FleetNode) -> Void
  let measure: (FleetNode) -> Void
  let testLink: (FleetNode) -> Void
  let remove: (FleetNode) -> Void

  /// Live drag state, kept out of the layout so a cancelled drag leaves no
  /// trace and nothing is persisted until the module is dropped.
  @State private var dragging: String?
  @State private var dragBy: CGSize = .zero
  @State private var resizing: String?
  @State private var resizeBy: CGSize = .zero

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      ZStack(alignment: .topLeading) {
        grid
        ForEach(items) { item in
          module(item)
        }
      }
      .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
      .padding(20)
    }
    .scrollIndicators(.never)
  }

  // MARK: Modules

  @ViewBuilder
  private func module(_ item: BoardItem) -> some View {
    let frame = layout.frame(for: item.id, default: Self.fallback(item, items: items))
    let origin = BoardLayout.point(frame)
    let size = BoardLayout.size(frame)
    let isDragging = dragging == item.id
    let isResizing = resizing == item.id

    content(item)
      .frame(
        width: max(120, size.width + (isResizing ? resizeBy.width : 0)),
        height: max(60, size.height + (isResizing ? resizeBy.height : 0))
      )
      .overlay(alignment: .bottomTrailing) { handle(item.id) }
      .offset(
        x: origin.x + (isDragging ? dragBy.width : 0),
        y: origin.y + (isDragging ? dragBy.height : 0)
      )
      .shadow(color: .black.opacity(isDragging ? 0.55 : 0), radius: isDragging ? 18 : 0, y: 6)
      .zIndex(isDragging || isResizing ? 10 : 0)
      .animation(.smooth(duration: 0.22), value: frame)
      .gesture(dragGesture(item.id, frame: frame))
  }

  @ViewBuilder
  private func content(_ item: BoardItem) -> some View {
    switch item {
    case .summary:
      SummaryModule(
        permanentUp: fleet.permanentUp,
        permanentTotal: fleet.nodes(in: .permanent).count,
        burstUp: fleet.burstUp,
        burstTotal: fleet.nodes(in: .burst).count,
        throughput: liveThroughput,
        lastSweep: fleet.lastSweep,
        autoRefresh: fleet.autoRefresh,
        interval: fleet.refreshInterval,
        refreshing: fleet.isRefreshing
      )
    case .throughput:
      ThroughputPanel(
        nodes: fleet.nodes, selfLabel: selfLabel, selfRate: 0, isRunning: fleet.isRefreshing
      )
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .glassEffect(.regular, in: .rect(cornerRadius: 12))
    case .node(let node):
      DeviceModule(
        node: node,
        expanded: layout.isExpanded(node.host),
        toggle: { withAnimation(.smooth(duration: 0.28)) { layout.toggle(node.host) } },
        refresh: { refresh(node) },
        measure: { measure(node) },
        testLink: { testLink(node) },
        remove: { remove(node) }
      )
    }
  }

  /// Rolling throughput across reachable nodes — the honest figure, not the
  /// per-request rate the older aggregate uses.
  private var liveThroughput: Double {
    fleet.nodes.filter { $0.aliasOf == nil }.compactMap(\.throughput).reduce(0, +)
  }

  /// Where a module goes the first time it is seen. Nodes are grouped by tier
  /// so a fresh board reads the way the iPad console does: permanent first,
  /// then burst.
  private static func fallback(_ item: BoardItem, items: [BoardItem]) -> ModuleFrame {
    switch item {
    case .summary: return BoardLayout.summaryFrame
    case .throughput: return BoardLayout.throughputFrame
    case .node(let node):
      let nodes = items.compactMap { item -> FleetNode? in
        if case .node(let value) = item { return value }
        return nil
      }
      let permanent = nodes.filter { $0.tier == .permanent }
      let burst = nodes.filter { $0.tier != .permanent }
      if let index = permanent.firstIndex(where: { $0.host == node.host }) {
        return BoardLayout.nodeFrame(indexInTier: index, tierBand: 0)
      }
      let index = burst.firstIndex { $0.host == node.host } ?? 0
      // Burst begins below however many rows permanent needed, plus a gap.
      let permanentRows = ((permanent.count + 3) / 4) * (BoardLayout.collapsed.rows + 1)
      return BoardLayout.nodeFrame(indexInTier: index, tierBand: permanentRows + 2)
    }
  }

  /// Moves a module. The drop, not the drag, is what snaps — following the
  /// cursor exactly and settling on release reads as placing something down.
  private func dragGesture(_ id: String, frame: ModuleFrame) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        dragging = id
        dragBy = value.translation
      }
      .onEnded { value in
        let origin = BoardLayout.point(frame)
        let target = BoardLayout.cellIndex(
          x: origin.x + value.translation.width,
          y: origin.y + value.translation.height
        )
        withAnimation(.smooth(duration: 0.24)) {
          layout.move(id, toCol: target.col, row: target.row)
        }
        dragging = nil
        dragBy = .zero
      }
  }

  /// The resize corner. Deliberately small and unlabelled — it is a thing you
  /// find when you want it, not a control competing with the readings.
  private func handle(_ id: String) -> some View {
    Path { path in
      path.move(to: CGPoint(x: 11, y: 1))
      path.addLine(to: CGPoint(x: 1, y: 11))
      path.move(to: CGPoint(x: 11, y: 6))
      path.addLine(to: CGPoint(x: 6, y: 11))
    }
    .stroke(Palette.faint, lineWidth: 1)
    .frame(width: 12, height: 12)
    .padding(6)
    .contentShape(.rect)
    .gesture(
      DragGesture(minimumDistance: 2)
        .onChanged { value in
          resizing = id
          resizeBy = value.translation
        }
        .onEnded { value in
          guard let frame = layout.frames[id] else { return }
          let size = BoardLayout.size(frame)
          let cells = BoardLayout.cellIndex(
            x: size.width + value.translation.width,
            y: size.height + value.translation.height
          )
          withAnimation(.smooth(duration: 0.24)) {
            layout.resize(id, cols: cells.col + 1, rows: cells.row + 1)
          }
          resizing = nil
          resizeBy = .zero
        }
    )
  }

  // MARK: Grid

  /// The grid, visible only faintly. It exists so a drag has somewhere to
  /// land; making it prominent would turn the background into the subject.
  private var grid: some View {
    Canvas { context, size in
      let stepX = BoardLayout.cell.width + BoardLayout.gap
      let stepY = BoardLayout.cell.height + BoardLayout.gap
      var path = Path()
      for x in stride(from: 0.0, through: size.width, by: stepX) {
        for y in stride(from: 0.0, through: size.height, by: stepY) {
          path.addRect(CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
      context.fill(path, with: .color(.white.opacity(dragging != nil || resizing != nil ? 0.13 : 0.04)))
    }
    .frame(width: canvas.width, height: canvas.height)
    .animation(.easeInOut(duration: 0.2), value: dragging)
    .allowsHitTesting(false)
  }

  /// Room for what is placed, plus a screen's worth to drag into.
  private var canvas: CGSize {
    let far = layout.frames.values.reduce(CGSize(width: 900, height: 560)) { size, frame in
      let corner = CGPoint(
        x: BoardLayout.point(frame).x + BoardLayout.size(frame).width,
        y: BoardLayout.point(frame).y + BoardLayout.size(frame).height
      )
      return CGSize(width: max(size.width, corner.x), height: max(size.height, corner.y))
    }
    return CGSize(width: far.width + 320, height: far.height + 240)
  }
}
