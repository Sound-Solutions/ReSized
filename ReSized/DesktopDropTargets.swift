import AppKit

/// Where a desktop drop can land. The config window's SeamDestination covers
/// cells and panes; the desktop can also create a brand-new column or row at
/// the layout's outer boundaries, which the config grid has no gesture for.
enum DesktopDropDestination: Equatable {
    case seam(SeamDestination)
    case newColumn(index: Int)
    case newRow(index: Int)
}

/// A droppable boundary on a live layout, in TOP-LEFT (CG/AX) coordinates —
/// the same space as CGEvent locations, so cursor distance tests need no
/// conversion. Convert back only when drawing.
struct DesktopDropTarget {
    var destination: DesktopDropDestination
    var origin: CGPoint
    var length: CGFloat
    var isVertical: Bool

    /// Segment distance, same maths as LayoutSeam.distance — a seam far down
    /// a column must not look close just because the cursor shares its x.
    func distance(to point: CGPoint) -> CGFloat {
        if isVertical {
            let overshoot = max(origin.y - point.y, point.y - (origin.y + length), 0)
            return hypot(point.x - origin.x, overshoot)
        }
        let overshoot = max(origin.x - point.x, point.x - (origin.x + length), 0)
        return hypot(overshoot, point.y - origin.y)
    }

    /// The band to draw, still in top-left coordinates.
    var indicatorRect: CGRect {
        let half = WindowManager.seamGrabThickness / 2
        return isVertical
            ? CGRect(x: origin.x - half, y: origin.y, width: WindowManager.seamGrabThickness, height: length)
            : CGRect(x: origin.x, y: origin.y - half, width: length, height: WindowManager.seamGrabThickness)
    }
}

func nearestDropTarget(
    to point: CGPoint, in targets: [DesktopDropTarget], within radius: CGFloat
) -> DesktopDropTarget? {
    let best = targets.min { $0.distance(to: point) < $1.distance(to: point) }
    guard let best, best.distance(to: point) <= radius else { return nil }
    return best
}

/// Throttle for the drag diagnostics below — dropTargets runs per drag event.
private var lastDropDiagnosticsLog = Date.distantPast

extension WindowManager {
    /// One snapshot a second of what the drop-target builder believes the grid
    /// is, against what the model holds — a cell with no recorded frame
    /// silently vanishes from the seams, which reads as bands for a grid that
    /// matches nothing on screen.
    private func logDropDiagnostics(for layout: MonitorLayout, tiles: [TileFrame], columnsMode: Bool) {
        guard Date().timeIntervalSince(lastDropDiagnosticsLog) > 1 else { return }
        lastDropDiagnosticsLog = Date()

        func desc(_ r: CGRect) -> String {
            "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
        }

        AccessibilityHelper.logDebug(
            "drag-diag: mode=\(layout.layoutMode.rawValue) expectedFrames=\(layout.expectedFrames.count) tiles=\(tiles.count)"
        )
        if columnsMode {
            for (c, column) in layout.columns.enumerated() {
                for (w, cell) in column.windows.enumerated() {
                    let name = cell.window.map { "\($0.ownerName) '\($0.title.prefix(20))'" }
                        ?? "split(\(cell.nestedContainer?.children.count ?? 0))"
                    let frame = layout.expectedFrames[cell.id].map(desc) ?? "NO FRAME"
                    AccessibilityHelper.logDebug("drag-diag: col\(c)[\(w)] \(name) frame=\(frame)")
                }
            }
        } else {
            for (r, row) in layout.rows.enumerated() {
                for (w, cell) in row.windows.enumerated() {
                    let name = cell.window.map { "\($0.ownerName) '\($0.title.prefix(20))'" }
                        ?? "split(\(cell.nestedContainer?.children.count ?? 0))"
                    let frame = layout.expectedFrames[cell.id].map(desc) ?? "NO FRAME"
                    AccessibilityHelper.logDebug("drag-diag: row\(r)[\(w)] \(name) frame=\(frame)")
                }
            }
        }
        for tile in tiles {
            AccessibilityHelper.logDebug(
                "drag-diag: tile slot=(c\(tile.slot.columnIndex.map(String.init) ?? "-"),r\(tile.slot.rowIndex.map(String.init) ?? "-"),w\(tile.slot.windowIndex),n\(tile.slot.nestedIndex.map(String.init) ?? "-")) ax=\(desc(tile.frame)) screen=\(desc(convertFrameFromAXCoordinates(tile.frame)))"
            )
        }
    }

    /// Every place a modifier-drag can drop on a live layout, derived from
    /// where the windows actually are — the same source the seam handles use.
    func dropTargets(for layout: MonitorLayout) -> [DesktopDropTarget] {
        var tiles: [TileFrame] = []
        let columnsMode = layout.layoutMode == .columns

        func addTiles(
            containerIndex: Int, cells: [(id: UUID, window: ExternalWindow?, container: LayoutContainer?)]
        ) {
            for (w, cell) in cells.enumerated() {
                let slot = WindowSlot(
                    columnIndex: columnsMode ? containerIndex : nil,
                    rowIndex: columnsMode ? nil : containerIndex,
                    windowIndex: w, nestedIndex: nil
                )
                if let container = cell.container {
                    for (p, pane) in container.children.enumerated() {
                        guard let frame = layout.expectedFrames[pane.id] else { continue }
                        var paneSlot = slot
                        paneSlot.nestedIndex = p
                        tiles.append(TileFrame(
                            slot: paneSlot,
                            frame: convertFrameToAXCoordinates(frame),
                            splitDirection: container.direction
                        ))
                    }
                } else if let frame = layout.expectedFrames[cell.id] {
                    tiles.append(TileFrame(
                        slot: slot, frame: convertFrameToAXCoordinates(frame), splitDirection: nil
                    ))
                }
            }
        }

        if columnsMode {
            for (c, column) in layout.columns.enumerated() {
                addTiles(containerIndex: c, cells: column.windows.map { ($0.id, $0.window, $0.nestedContainer) })
            }
        } else {
            for (r, row) in layout.rows.enumerated() {
                addTiles(containerIndex: r, cells: row.windows.map { ($0.id, $0.window, $0.nestedContainer) })
            }
        }

        logDropDiagnostics(for: layout, tiles: tiles, columnsMode: columnsMode)

        var targets = buildSeams(from: tiles, columnsMode: columnsMode).map {
            DesktopDropTarget(
                destination: .seam($0.destination),
                origin: $0.origin, length: $0.length, isVertical: $0.isVertical
            )
        }

        // New-column/row boundaries at the two OUTERMOST edges only. Interior
        // column boundaries used to be targets too, and their full-height bands
        // out-competed every nearby cell seam — dragging into the middle of
        // the grid kept spawning new skinny columns instead of inserting where
        // the config window would. Inside the grid, the drop model is now
        // exactly the config window's: cells and panes. Past the outer edge,
        // and only there, a drop still means "new column/row".
        if columnsMode {
            var extents: [(index: Int, frame: CGRect)] = []
            for c in layout.columns.indices {
                let frames = tiles.filter { $0.slot.columnIndex == c }.map(\.frame)
                guard let union = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) ?? frames.first
                else { continue }
                extents.append((c, union))
            }
            guard let top = extents.map(\.frame.minY).min(),
                  let bottom = extents.map(\.frame.maxY).max(),
                  let first = extents.first, let last = extents.last else { return targets }
            let height = bottom - top
            targets.append(DesktopDropTarget(
                destination: .newColumn(index: first.index),
                origin: CGPoint(x: first.frame.minX, y: top), length: height, isVertical: true
            ))
            targets.append(DesktopDropTarget(
                destination: .newColumn(index: last.index + 1),
                origin: CGPoint(x: last.frame.maxX, y: top), length: height, isVertical: true
            ))
        } else {
            var extents: [(index: Int, frame: CGRect)] = []
            for r in layout.rows.indices {
                let frames = tiles.filter { $0.slot.rowIndex == r }.map(\.frame)
                guard let union = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) ?? frames.first
                else { continue }
                extents.append((r, union))
            }
            guard let left = extents.map(\.frame.minX).min(),
                  let right = extents.map(\.frame.maxX).max(),
                  let first = extents.first, let last = extents.last else { return targets }
            let width = right - left
            targets.append(DesktopDropTarget(
                destination: .newRow(index: first.index),
                origin: CGPoint(x: left, y: first.frame.minY), length: width, isVertical: false
            ))
            targets.append(DesktopDropTarget(
                destination: .newRow(index: last.index + 1),
                origin: CGPoint(x: left, y: last.frame.maxY), length: width, isVertical: false
            ))
        }
        return targets
    }
}
