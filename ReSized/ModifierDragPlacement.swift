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
            // ordinary drag: indicator down, snap-back re-enabled.
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
            // Judge only after real travel, then the window must have come along.
            guard hypot(cursorDX, cursorDY) > 15 else { return }
            guard let bounds = windowServerBounds(of: session.windowID) else { return }
            let originDX = bounds.origin.x - session.startBounds.origin.x
            let originDY = bounds.origin.y - session.startBounds.origin.y
            guard abs(originDX - cursorDX) < 24, abs(originDY - cursorDY) < 24 else { return }
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
        guard armed, session.confirmedWindowDrag else { return }

        let source = locateManaged(windowID: session.windowID)

        if let target = session.target, let targetLayout = session.targetLayout {
            performModifierDrop(source: source, session: session,
                                destination: target.destination, in: targetLayout)
        } else if let source {
            // Released clear of every boundary: the window leaves the grid and
            // floats where it was dropped; the survivors take the space.
            AccessibilityHelper.logDebug("modifier-drag: float out wid=\(session.windowID)")
            withLayout(source.layout) { _ = takeWindow(at: source.slot) }
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
        AccessibilityHelper.logDebug("modifier-drag: drop wid=\(session.windowID) dest=\(destination)")

        // Same layout, seam destination: place(.placed) handles vacate +
        // renumber + no-op detection in one piece — use it.
        if let source, source.layout === targetLayout, case .seam(let seamDestination) = destination {
            withLayout(targetLayout) { place(.placed(source.slot), at: seamDestination) }
            applyLayoutAndUpdateExpected(for: targetLayout)
            return
        }

        // Everything else is take-then-insert.
        let window: ExternalWindow?
        var adjustedDestination = destination
        if let source {
            let columnsBefore = source.layout.columns.count
            let rowsBefore = source.layout.rows.count
            window = withLayout(source.layout) { takeWindow(at: source.slot) }
            if source.layout === targetLayout {
                // Vacating can dissolve the source's own column/row, shifting
                // the boundary the drop was aimed at.
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
                applyLayoutAndUpdateExpected(for: source.layout)
            }
        } else {
            window = WindowDiscovery.discoverAllWindows().first { $0.windowID == session.windowID }
        }
        guard let window else { return }

        withLayout(targetLayout) {
            switch adjustedDestination {
            case .seam(let seamDestination): place(window, at: seamDestination)
            case .newColumn(let index): insertColumn(with: window, at: index)
            case .newRow(let index): insertRow(with: window, at: index)
            }
        }
        refreshAvailableWindows()
        applyLayoutAndUpdateExpected(for: targetLayout)
    }

    // MARK: Helpers

    /// Run a mutation against a specific monitor's layout. Every existing
    /// mutation routes through the currentLayout proxies, so the smallest
    /// correct lever is to point them at the right monitor for the duration.
    @discardableResult
    func withLayout<T>(_ layout: MonitorLayout, _ body: () -> T) -> T {
        let saved = selectedMonitor
        if let monitor = availableMonitors.first(where: { $0.id == layout.monitorId }) {
            selectedMonitor = monitor
        }
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
                  bounds.contains(point)
            else { continue }
            return (number, pid, bounds)
        }
        return nil
    }

    /// Current window-server bounds (top-left coords) for one window.
    private func windowServerBounds(of windowID: CGWindowID) -> CGRect? {
        guard let entries = CGWindowListCreateDescriptionFromArray([windowID] as CFArray) as? [[String: Any]],
              let entry = entries.first,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }

    /// Whether a top-left-coords point sits on one of the desktop seam handles.
    private func cursorIsOnSeamHandle(at point: CGPoint) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        for layout in monitorLayouts.values where layout.isActive {
            if desktopSeams(for: layout).contains(where: { $0.rect.contains(cocoaPoint) }) {
                return true
            }
        }
        return false
    }

    private func showDropIndicator(_ target: DesktopDropTarget, on layout: MonitorLayout) {
        let screenRect = convertFrameFromAXCoordinates(target.indicatorRect)
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
