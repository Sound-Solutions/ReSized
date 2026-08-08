import AppKit

/// A modifier-drag in flight: which real window went along for the ride, and
/// what release would currently do. All geometry in CG top-left coordinates.
struct ModifierDragSession {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let startCursor: CGPoint
    let startBounds: CGRect
    /// True once the window has been seen moving WITH the cursor. Modifier +
    /// mouse movement alone is not a window drag — ⌥-drag in an editor is a
    /// column text selection, and must never read as one.
    var confirmedWindowDrag = false
    var target: DesktopDropTarget?
    var targetLayout: MonitorLayout?
}

extension WindowManager {
    /// How close (points) the cursor must be to a boundary for it to light up.
    /// Deliberately finite, unlike the config grid's nearest-always-wins: on
    /// the desktop, "no target" is itself an action (float the window out).
    static let dropSnapRadius: CGFloat = 50

    // MARK: Lifecycle — mirror the maintenance timer's call sites.

    func startModifierDragMonitorIfNeeded() {
        guard modifierDragMonitor == nil else { return }
        let monitor = ModifierDragMonitor()
        monitor.onBegin = { [weak self] point in self?.modifierDragBegan(at: point) }
        monitor.onUpdate = { [weak self] point, armed in self?.modifierDragMoved(to: point, armed: armed) }
        monitor.onEnd = { [weak self] point, armed in self?.modifierDragEnded(at: point, armed: armed) }
        monitor.start()
        modifierDragMonitor = monitor
    }

    func stopModifierDragMonitorIfIdle() {
        guard !hasAnyActiveLayout else { return }
        modifierDragMonitor?.stop()
        modifierDragMonitor = nil
        modifierDragSession = nil
        clearDropIndicator()
    }

    // MARK: The gesture

    private func modifierDragBegan(at point: CGPoint) {
        modifierDragSession = nil
        clearDropIndicator()
        // A drag starting on one of our seam handles is the seam's gesture.
        guard !cursorIsOnSeamHandle(at: point) else { return }
        guard let hit = topmostOrdinaryWindow(at: point),
              hit.pid != pid_t(ProcessInfo.processInfo.processIdentifier) else { return }
        modifierDragSession = ModifierDragSession(
            windowID: hit.windowID, ownerPID: hit.pid, startCursor: point, startBounds: hit.bounds
        )
    }

    private func modifierDragMoved(to point: CGPoint, armed: Bool) {
        guard var session = modifierDragSession else { return }

        guard armed else {
            // Releasing the modifier mid-drag turns this back into an
            // ordinary drag: indicator down, snap-back re-enabled. Suppression
            // already let the window drift while it was confirmed, and the AX
            // event that would normally trigger a snap-back may not arrive
            // again before mouse-up — force one now instead of waiting.
            if session.confirmedWindowDrag, let managed = locateManaged(windowID: session.windowID) {
                applyLayoutAndUpdateExpected(for: managed.layout)
            }
            if session.confirmedWindowDrag || session.target != nil {
                session.confirmedWindowDrag = false
                session.target = nil
                session.targetLayout = nil
                modifierDragSession = session
                clearDropIndicator()
            }
            return
        }

        if !session.confirmedWindowDrag {
            let cursorDX = point.x - session.startCursor.x
            let cursorDY = point.y - session.startCursor.y
            // Cursor travel must clear the origin-agreement tolerance below —
            // otherwise a stationary window sitting inside that tolerance
            // would confirm on travel alone, and an ⌥⇧ text column-selection
            // near a seam would read as dragging the editor window itself.
            guard hypot(cursorDX, cursorDY) > 40 else { return }
            guard let bounds = windowServerBounds(of: session.windowID) else { return }
            let originDX = bounds.origin.x - session.startBounds.origin.x
            let originDY = bounds.origin.y - session.startBounds.origin.y
            // A resize dragged from the left/top edge moves the origin in
            // lockstep with the cursor too — the size check is what tells a
            // drag apart from that.
            guard hypot(originDX, originDY) > 10,
                  abs(originDX - cursorDX) < 24, abs(originDY - cursorDY) < 24,
                  abs(bounds.size.width - session.startBounds.size.width) < 8,
                  abs(bounds.size.height - session.startBounds.size.height) < 8
            else { return }
            session.confirmedWindowDrag = true
        }

        guard let layout = activeLayout(atTopLeft: point) else {
            session.target = nil
            session.targetLayout = nil
            modifierDragSession = session
            clearDropIndicator()
            return
        }

        if let target = nearestDropTarget(
            to: point, in: dropTargets(for: layout), within: Self.dropSnapRadius
        ) {
            session.target = target
            session.targetLayout = layout
            showDropIndicator(target, on: layout)
        } else {
            session.target = nil
            session.targetLayout = nil
            clearDropIndicator()
        }
        modifierDragSession = session
    }

    private func modifierDragEnded(at point: CGPoint, armed: Bool) {
        guard let session = modifierDragSession else { return }
        modifierDragSession = nil
        clearDropIndicator()
        guard armed, session.confirmedWindowDrag else {
            // The modifier could have stayed down through every onUpdate and
            // only let go right at release — modifierDragMoved's own
            // snap-back never got a chance to run. Cover it here too.
            if session.confirmedWindowDrag, let managed = locateManaged(windowID: session.windowID) {
                applyLayoutAndUpdateExpected(for: managed.layout)
            }
            return
        }

        let source = locateManaged(windowID: session.windowID)

        if let target = session.target, let targetLayout = session.targetLayout {
            performModifierDrop(source: source, session: session,
                                destination: target.destination, in: targetLayout)
        } else if let source {
            // Released clear of every boundary: the window leaves the grid and
            // floats where it was dropped; the survivors take the space.
            AccessibilityHelper.logDebug("modifier-drag: float out wid=\(session.windowID)")
            guard withLayout(source.layout, { () -> Void in
                _ = takeWindow(at: source.slot)
                pruneIfEmptied(at: source.slot, in: source.layout)
            }) != nil else { return }
            refreshAvailableWindows()
            applyLayoutAndUpdateExpected(for: source.layout)
        }
    }

    private func performModifierDrop(
        source: (layout: MonitorLayout, slot: WindowSlot)?,
        session: ModifierDragSession,
        destination: DesktopDropDestination,
        in targetLayout: MonitorLayout
    ) {
        // The tap that started this drag can outlive the layout it targets —
        // another monitor's layout can keep the tap alive after this one was
        // stopped mid-drag. A stopped layout must not be mutated.
        guard targetLayout.isActive else { return }
        AccessibilityHelper.logDebug("modifier-drag: drop wid=\(session.windowID) dest=\(destination)")

        // Same layout, seam destination: place(.placed) handles vacate +
        // renumber + no-op detection in one piece — use it. place() ends in
        // insert(), which always applies the layout itself, so there is
        // nothing left to do here once it returns.
        if let source, source.layout === targetLayout, case .seam(let seamDestination) = destination {
            withLayout(targetLayout) { place(.placed(source.slot), at: seamDestination) }
            return
        }

        // Everything else is take-then-insert.
        let window: ExternalWindow?
        var adjustedDestination = destination
        if let source {
            let columnsBefore = source.layout.columns.count
            let rowsBefore = source.layout.rows.count
            guard let taken = withLayout(source.layout, { () -> ExternalWindow? in
                let w = takeWindow(at: source.slot)
                pruneIfEmptied(at: source.slot, in: source.layout)
                return w
            }) else { return }
            window = taken
            if source.layout === targetLayout {
                // Vacating can dissolve the source's own column/row (directly,
                // or via pruneIfEmptied above once it's left with nothing in
                // it), shifting the boundary the drop was aimed at.
                if case .newColumn(let index) = destination,
                   source.layout.columns.count < columnsBefore,
                   let sourceColumn = source.slot.columnIndex, sourceColumn < index {
                    adjustedDestination = .newColumn(index: index - 1)
                }
                if case .newRow(let index) = destination,
                   source.layout.rows.count < rowsBefore,
                   let sourceRow = source.slot.rowIndex, sourceRow < index {
                    adjustedDestination = .newRow(index: index - 1)
                }
            } else {
                // takeWindow alone applies nothing — this is a different
                // layout than the one about to be applied below.
                applyLayoutAndUpdateExpected(for: source.layout)
            }
        } else {
            // locateManaged only searches active layouts, so a window parked
            // in a configured-but-inactive layout reads as "unmanaged" here
            // too. Inserting it while another model still holds it would have
            // two layouts fighting over one window the moment the other one
            // starts — so the drop takes it WITH it: evict it from every
            // stopped layout first. The drag is the user saying where this
            // window lives now.
            let discovered = WindowDiscovery.discoverAllWindows().first { $0.windowID == session.windowID }
            guard let discovered else { return }
            if placedWindowIds().contains(discovered.id) {
                for other in monitorLayouts.values where !other.isActive {
                    evictWindow(withId: discovered.id, from: other)
                }
                // Still claimed after evicting from every stopped layout means
                // an active layout holds it and locateManaged missed it —
                // refuse rather than double-place.
                guard !placedWindowIds().contains(discovered.id) else { return }
            }
            window = discovered
        }
        guard let window else { return }

        // place()/insertColumn/insertRow all apply the layout themselves.
        guard withLayout(targetLayout, { () -> Void in
            switch adjustedDestination {
            case .seam(let seamDestination): place(window, at: seamDestination)
            case .newColumn(let index): insertColumn(with: window, at: index)
            case .newRow(let index): insertRow(with: window, at: index)
            }
        }) != nil else { return }
        refreshAvailableWindows()
    }

    /// After takeWindow empties a slot, drop the column/row it lived in if
    /// nothing is left there and re-share what remains equally.
    ///
    /// removeCell deliberately leaves an emptied column/row in place — on the
    /// config grid an empty column is a legitimate live drop target mid-drag
    /// — but a desktop drop has already landed, and nothing else ever comes
    /// back to prune it: left alone, the vacated space stays permanently
    /// blank. Mirrors removeClosedCell's emptied-column/row branch. Operates
    /// on `layout` directly rather than through the currentLayout proxy, like
    /// removeClosedCell does, so it works regardless of selectedMonitor.
    private func pruneIfEmptied(at slot: WindowSlot, in layout: MonitorLayout) {
        if let columnIndex = slot.columnIndex, layout.columns.indices.contains(columnIndex),
           layout.columns[columnIndex].windows.isEmpty {
            layout.columns.remove(at: columnIndex)
            if !layout.columns.isEmpty {
                let share = 1.0 / CGFloat(layout.columns.count)
                for i in layout.columns.indices { layout.columns[i].widthProportion = share }
            }
        } else if let rowIndex = slot.rowIndex, layout.rows.indices.contains(rowIndex),
                  layout.rows[rowIndex].windows.isEmpty {
            layout.rows.remove(at: rowIndex)
            if !layout.rows.isEmpty {
                let share = 1.0 / CGFloat(layout.rows.count)
                for i in layout.rows.indices { layout.rows[i].heightProportion = share }
            }
        }
    }

    // MARK: Helpers

    /// Run a mutation against a specific monitor's layout, or do nothing if
    /// that monitor isn't available right now (e.g. unplugged mid-drag).
    /// Every existing mutation routes through the currentLayout proxies, so
    /// the smallest correct lever is to point them at the right monitor for
    /// the duration — failing closed here beats silently mutating whatever
    /// layout selectedMonitor already happened to be pointing at.
    @discardableResult
    func withLayout<T>(_ layout: MonitorLayout, _ body: () -> T) -> T? {
        guard let monitor = availableMonitors.first(where: { $0.id == layout.monitorId }) else { return nil }
        let saved = selectedMonitor
        selectedMonitor = monitor
        defer { selectedMonitor = saved }
        return body()
    }

    /// Which active layout owns the monitor under a top-left-coords point.
    private func activeLayout(atTopLeft point: CGPoint) -> MonitorLayout? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        guard let monitor = availableMonitors.first(where: { $0.screen.frame.contains(cocoaPoint) })
        else { return nil }
        guard let layout = monitorLayouts[monitor.id], layout.isActive else { return nil }
        return layout
    }

    /// The managed window carrying this CGWindowID, wherever it is.
    private func locateManaged(windowID: CGWindowID) -> (layout: MonitorLayout, slot: WindowSlot)? {
        for layout in monitorLayouts.values where layout.isActive {
            func search(
                _ cells: [(window: ExternalWindow?, container: LayoutContainer?)],
                _ slotAt: (Int, Int?) -> WindowSlot
            ) -> WindowSlot? {
                for (w, cell) in cells.enumerated() {
                    if cell.window?.windowID == windowID { return slotAt(w, nil) }
                    if let container = cell.container {
                        for (p, pane) in container.children.enumerated()
                        where pane.window.windowID == windowID { return slotAt(w, p) }
                    }
                }
                return nil
            }
            switch layout.layoutMode {
            case .columns:
                for (c, column) in layout.columns.enumerated() {
                    if let slot = search(column.windows.map { ($0.window, $0.nestedContainer) },
                                         { WindowSlot(columnIndex: c, rowIndex: nil, windowIndex: $0, nestedIndex: $1) }) {
                        return (layout, slot)
                    }
                }
            case .rows:
                for (r, row) in layout.rows.enumerated() {
                    if let slot = search(row.windows.map { ($0.window, $0.nestedContainer) },
                                         { WindowSlot(columnIndex: nil, rowIndex: r, windowIndex: $0, nestedIndex: $1) }) {
                        return (layout, slot)
                    }
                }
            }
        }
        return nil
    }

    /// Topmost normal-level window under a top-left-coords point, from the
    /// window server. Layer 0 only: palettes and panels don't join grids.
    private func topmostOrdinaryWindow(
        at point: CGPoint
    ) -> (windowID: CGWindowID, pid: pid_t, bounds: CGRect)? {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for entry in entries {
            guard let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point),
                  // Matches discoverAllWindows' filter — an accessory-app
                  // window (menu bar extras, panels) would light up a drop
                  // indicator that then has nowhere real to land it.
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            else { continue }
            return (number, pid, bounds)
        }
        return nil
    }

    /// Current window-server bounds (top-left coords) for one window.
    private func windowServerBounds(of windowID: CGWindowID) -> CGRect? {
        guard let entry = windowServerDescription(of: windowID),
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }

    /// Whether a top-left-coords point sits on one of the desktop seam
    /// handles — and that handle is actually exposed (not covered by a real
    /// window on top of it). An occluded seam draws nothing and eats no
    /// clicks, so the gesture underneath it must stay live, or the point
    /// becomes a dead band where neither the seam handle nor the drag works.
    private func cursorIsOnSeamHandle(at point: CGPoint) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        for layout in monitorLayouts.values where layout.isActive {
            // The overlay's own cached seams — same ones it hit-tests against
            // — rather than recomputing them on every system-wide click.
            guard let seamView = layout.seamOverlay?.seamView,
                  seamView.seams.contains(where: { $0.rect.contains(cocoaPoint) })
            else { continue }
            if seamView.isPointExposed?(cocoaPoint) ?? true {
                return true
            }
        }
        return false
    }

    private func showDropIndicator(_ target: DesktopDropTarget, on layout: MonitorLayout) {
        let screenRect = convertFrameFromAXCoordinates(target.indicatorRect)
        if layout.seamOverlay?.seamView?.dropIndicator?.rect != screenRect {
            AccessibilityHelper.logDebug(
                "drag-diag: band dest=\(target.destination) screen=(\(Int(screenRect.minX)),\(Int(screenRect.minY)) \(Int(screenRect.width))x\(Int(screenRect.height)))"
            )
        }
        for other in monitorLayouts.values where other !== layout {
            other.seamOverlay?.seamView?.dropIndicator = nil
        }
        layout.seamOverlay?.seamView?.dropIndicator = (screenRect, target.isVertical)
    }

    private func clearDropIndicator() {
        for layout in monitorLayouts.values {
            layout.seamOverlay?.seamView?.dropIndicator = nil
        }
    }
}
