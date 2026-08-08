# Modifier-Drag Window Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**What Kennith gets:** hold fn or ⌥⇧ while dragging any real window and ReSized shows the seam it would land at; release places it there and the grid reflows — add a floating window to the grid, move one that's already in it, or drop away from any seam to float it out. Exactly the config window's drag-and-drop, on the desktop.

**Goal:** A modifier-armed drag gesture that places real windows at layout seams, using the config window's existing drop model.

**Architecture:** A listen-only CGEventTap (`ModifierDragMonitor`) watches drags and modifier flags while any layout is active. WindowManager runs the gesture session: verify the window is actually moving with the cursor, resolve the nearest drop target (reusing `buildSeams` from ContentView.swift on frames converted to top-left coordinates), draw an indicator band on the existing `SeamOverlayView`, and on release funnel into the existing `place(_:at:)` mutations (plus two new ones for new-column/new-row drops).

**Tech Stack:** Swift / AppKit, no new dependencies. Spec: `docs/superpowers/specs/2026-08-08-modifier-drag-design.md`.

## Global Constraints

- Deployment target macOS 14; `@Observable` model — any new stored property on `WindowManager` or `MonitorLayout` that isn't rendered must be `@ObservationIgnored`.
- No test target exists in this project and live-drag behavior is untestable headlessly. Each task's verification is a successful Debug build; behavior verification is the Task 6 hand-test gate. Do NOT add a test target.
- Build with: `xcodebuild -project ReSized.xcodeproj -scheme ReSized -configuration Debug build 2>&1 | tail -3` from the repo root. Expect `** BUILD SUCCEEDED **`. Ignore SourceKit editor diagnostics about types "not in scope" across files — they are indexer noise; the build is authoritative.
- Never launch the app; Kennith runs it himself.
- Comment style: sparse, explaining *why* / non-obvious constraints only, matching the surrounding files.
- **Coordinate spaces — the bug farm, be exact:**
  - *Cocoa screen coords*: y grows up, origin bottom-left of primary display. Used by `NSScreen`, `NSEvent.mouseLocation`, `layout.expectedFrames`, `DesktopSeam.rect`, `SeamOverlayView`.
  - *CG/AX top-left coords*: y grows down, origin top-left of primary display. Used by `CGEvent.location`, `kCGWindowBounds`, AX frames, and everything `buildSeams` sees in this feature.
  - Flip between them with `WindowManager.convertFrameToAXCoordinates(_:)` / `convertFrameFromAXCoordinates(_:)` (Task 1 makes them internal). For a point: `cocoaY = primaryScreenHeight - cgY`.
- Existing machinery to reuse, exact signatures (all currently internal unless noted):
  - `func place(_ drag: PendingDrag, at destination: SeamDestination)` — WindowManager.swift:2554
  - `enum PendingDrag { case placed(WindowSlot); case available(UUID) }`
  - `enum SeamDestination { case cell(columnIndex: Int?, rowIndex: Int?, index: Int); case pane(cell: WindowSlot, index: Int) }`
  - `func takeWindow(at slot: WindowSlot) -> ExternalWindow?`
  - `func buildSeams(from tiles: [TileFrame], columnsMode: Bool) -> [LayoutSeam]` — global func, ContentView.swift:154
  - `struct TileFrame { var slot: WindowSlot; var frame: CGRect; var splitDirection: SplitDirection? }`
  - `struct LayoutSeam { var destination: SeamDestination; var origin: CGPoint; var length: CGFloat; var isVertical: Bool; func distance(to: CGPoint) -> CGFloat }`
  - `class MonitorLayout` — `monitorId: String`, `columns: [Column]`, `rows: [Row]`, `layoutMode: LayoutMode`, `expectedFrames: [UUID: CGRect]`, `seamOverlay: SeamOverlayWindow?`, `isActive: Bool`
  - `WindowManager.monitorLayouts: [String: MonitorLayout]`, `availableMonitors: [Monitor]`, `selectedMonitor: Monitor?`, `availableWindows: [ExternalWindow]`
  - `WindowDiscovery.discoverAllWindows() -> [ExternalWindow]`; `ExternalWindow.windowID: CGWindowID?`, `.ownerPID: pid_t`
  - `AccessibilityHelper.logDebug(_ message: String)` — unified log + debug.txt in DEBUG.

---

### Task 1: Drop-target geometry (`DesktopDropTargets.swift`)

**Files:**
- Create: `ReSized/DesktopDropTargets.swift`
- Modify: `ReSized/WindowManager.swift` — change `private func convertFrameToAXCoordinates` and `private func convertFrameFromAXCoordinates` (near line 3448) to internal by deleting the `private` keyword on each.

**Interfaces:**
- Consumes: `buildSeams(from:columnsMode:)`, `TileFrame`, `LayoutSeam`, `MonitorLayout`, `WindowSlot`, `convertFrameToAXCoordinates`.
- Produces (used by Task 5): `enum DesktopDropDestination`, `struct DesktopDropTarget` with `func distance(to: CGPoint) -> CGFloat` and `var indicatorRect: CGRect` (top-left coords), `WindowManager.dropTargets(for layout: MonitorLayout) -> [DesktopDropTarget]`, `func nearestDropTarget(to point: CGPoint, in targets: [DesktopDropTarget], within radius: CGFloat) -> DesktopDropTarget?`.

- [ ] **Step 1: Create the file with the destination and target types**

```swift
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
```

- [ ] **Step 2: Add the target builder as a WindowManager extension in the same file**

The cell/pane seams come from the same `buildSeams` the config grid uses, fed with the windows' REAL frames (`expectedFrames`) flipped into top-left space. New-column/new-row boundaries are appended from the column/row extents.

```swift
extension WindowManager {
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

        var targets = buildSeams(from: tiles, columnsMode: columnsMode).map {
            DesktopDropTarget(
                destination: .seam($0.destination),
                origin: $0.origin, length: $0.length, isVertical: $0.isVertical
            )
        }

        // Outer boundaries: before the first column/row, between each pair,
        // after the last — a drop there makes a NEW column/row. Extents come
        // from the tiles so they track what is really on screen.
        if columnsMode {
            var extents: [(index: Int, frame: CGRect)] = []
            for c in layout.columns.indices {
                let frames = tiles.filter { $0.slot.columnIndex == c }.map(\.frame)
                guard let union = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) ?? frames.first
                else { continue }
                extents.append((c, union))
            }
            guard let top = extents.map(\.frame.minY).min(),
                  let bottom = extents.map(\.frame.maxY).max() else { return targets }
            let height = bottom - top
            for extent in extents {
                targets.append(DesktopDropTarget(
                    destination: .newColumn(index: extent.index),
                    origin: CGPoint(x: extent.frame.minX, y: top), length: height, isVertical: true
                ))
            }
            if let last = extents.last {
                targets.append(DesktopDropTarget(
                    destination: .newColumn(index: last.index + 1),
                    origin: CGPoint(x: last.frame.maxX, y: top), length: height, isVertical: true
                ))
            }
        } else {
            var extents: [(index: Int, frame: CGRect)] = []
            for r in layout.rows.indices {
                let frames = tiles.filter { $0.slot.rowIndex == r }.map(\.frame)
                guard let union = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) ?? frames.first
                else { continue }
                extents.append((r, union))
            }
            guard let left = extents.map(\.frame.minX).min(),
                  let right = extents.map(\.frame.maxX).max() else { return targets }
            let width = right - left
            for extent in extents {
                targets.append(DesktopDropTarget(
                    destination: .newRow(index: extent.index),
                    origin: CGPoint(x: left, y: extent.frame.minY), length: width, isVertical: false
                ))
            }
            if let last = extents.last {
                targets.append(DesktopDropTarget(
                    destination: .newRow(index: last.index + 1),
                    origin: CGPoint(x: left, y: last.frame.maxY), length: width, isVertical: false
                ))
            }
        }
        return targets
    }
}
```

Note the overlap this creates on purpose: at a column's left edge there is both a `.newColumn` boundary and (for its cells) nothing else vertical — but a `.cell(index: 0)` seam and a `.newColumn` seam coexist at the TOP-left corner region. Nearest-wins resolves it; the bands differ (vertical vs horizontal) so what will happen is visible before release. Do not "fix" this.

- [ ] **Step 3: Make the two coordinate converters internal**

In `WindowManager.swift`, find `private func convertFrameToAXCoordinates` and `private func convertFrameFromAXCoordinates` and remove the `private` from both. Reason: `DesktopDropTargets.swift` and later `ModifierDragPlacement.swift` are separate files; Swift `private` is file-scoped.

- [ ] **Step 4: Build**

Run: `xcodebuild -project ReSized.xcodeproj -scheme ReSized -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ReSized/DesktopDropTargets.swift ReSized/WindowManager.swift
git commit -m "Derive desktop drop targets from the live layout"
```

---

### Task 2: Drop indicator band on the seam overlay

**Files:**
- Modify: `ReSized/SeamOverlay.swift` (`SeamOverlayView`)

**Interfaces:**
- Produces (used by Task 5): `SeamOverlayView.dropIndicator: (rect: CGRect, isVertical: Bool)?` — rect in COCOA SCREEN coordinates (same space as `seams`, converted to local via `screenOrigin` exactly like `localSeamRects()`).

- [ ] **Step 1: Add the property**

In `SeamOverlayView`, next to `var seams`:

```swift
    /// Where a modifier-dragged window would land, in screen coordinates.
    /// Drawn stronger than the hover band: this one announces an action that
    /// will happen on release, not a handle that could be grabbed.
    var dropIndicator: (rect: CGRect, isVertical: Bool)? {
        didSet {
            guard dropIndicator?.rect != oldValue?.rect else { return }
            needsDisplay = true
        }
    }
```

- [ ] **Step 2: Draw it**

In `draw(_:)`, the current body starts with `guard let (band, isVertical) = indicator() else { return }`. Restructure so the drop indicator draws independently of hover:

```swift
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let (rect, isVertical) = dropIndicator {
            let band = rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: band, xRadius: 2, yRadius: 2).fill()
            let centre: CGRect = isVertical
                ? band.insetBy(dx: band.width / 2 - 1.5, dy: 0)
                : band.insetBy(dx: 0, dy: band.height / 2 - 1.5)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: centre, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Invisible until pointed at. A permanent grid of lines over every
        // window would be noise; the cursor already says the seam is there.
        guard let (band, isVertical) = indicator() else { return }
        // ... existing hover-band drawing unchanged ...
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project ReSized.xcodeproj -scheme ReSized -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ReSized/SeamOverlay.swift
git commit -m "Give the seam overlay a drop-indicator band"
```

---

### Task 3: Model mutations — new column/row with a window, place-external overload

**Files:**
- Modify: `ReSized/WindowManager.swift` — add three functions near `place(_:at:)` (the "MARK: - Seam Placement" section, ~line 2545).

**Interfaces:**
- Consumes: `Column`, `Row`, `ColumnWindow(window:)`, `RowWindow(window:)`, `insert(_:at:)` (private, same file — that is why these live in WindowManager.swift, not a new file), `refreshAvailableWindows()`, `applyLayoutIfActive()`, the `columns`/`rows` proxies.
- Produces (used by Task 5): `func place(_ window: ExternalWindow, at destination: SeamDestination)`, `func insertColumn(with window: ExternalWindow, at index: Int)`, `func insertRow(with window: ExternalWindow, at index: Int)`. All operate on `currentLayout` via the existing proxies, like every other mutation.

- [ ] **Step 1: Add the functions**

```swift
    /// Place a window that is not in any layout — the desktop drop's path for
    /// pulling an unmanaged window into the grid. place(_:at:) wants a
    /// PendingDrag naming a window already known to the picker; this one takes
    /// the window itself.
    func place(_ window: ExternalWindow, at destination: SeamDestination) {
        insert(window, at: destination)
    }

    /// Put a window into a brand-new column at `index`, everything sharing
    /// equally — the desktop counterpart of dropping past the layout's edge.
    func insertColumn(with window: ExternalWindow, at index: Int) {
        var newColumns = columns
        let landing = max(0, min(index, newColumns.count))
        newColumns.insert(Column(widthProportion: 0, windows: [ColumnWindow(window: window)]), at: landing)
        let share = 1.0 / CGFloat(newColumns.count)
        for i in newColumns.indices { newColumns[i].widthProportion = share }
        columns = newColumns
        refreshAvailableWindows()
        applyLayoutIfActive()
    }

    /// Row twin of insertColumn(with:at:).
    func insertRow(with window: ExternalWindow, at index: Int) {
        var newRows = rows
        let landing = max(0, min(index, newRows.count))
        newRows.insert(Row(heightProportion: 0, windows: [RowWindow(window: window)]), at: landing)
        let share = 1.0 / CGFloat(newRows.count)
        for i in newRows.indices { newRows[i].heightProportion = share }
        rows = newRows
        refreshAvailableWindows()
        applyLayoutIfActive()
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project ReSized.xcodeproj -scheme ReSized -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ReSized/WindowManager.swift
git commit -m "Model mutations for desktop drops: new column or row holding a window"
```

---

### Task 4: The event tap (`ModifierDrag.swift`)

**Files:**
- Create: `ReSized/ModifierDrag.swift`

**Interfaces:**
- Produces (used by Task 5): `final class ModifierDragMonitor` with `var onBegin: ((CGPoint) -> Void)?`, `var onUpdate: ((CGPoint, Bool) -> Void)?`, `var onEnd: ((CGPoint, Bool) -> Void)?`, `func start()`, `func stop()`. **All points delivered in CG top-left coordinates** (`CGEvent.location` raw) — the same space as `DesktopDropTarget`. The Bool is "modifier armed".

- [ ] **Step 1: Write the monitor**

```swift
import AppKit

/// Watches global mouse drags and modifier flags for the placement gesture.
///
/// Listen-only: nothing is intercepted or altered, the tap is a wiretap. It
/// exists only while a layout is live, and it deliberately knows nothing about
/// windows or layouts — it reports "a drag began / moved / ended, and whether
/// the modifier was down", in CG top-left coordinates, and WindowManager does
/// the thinking.
final class ModifierDragMonitor {
    var onBegin: ((CGPoint) -> Void)?
    /// Cursor and armed state, on every drag movement and on modifier changes
    /// mid-drag — pressing the modifier late or releasing it early must both
    /// register without the mouse moving.
    var onUpdate: ((CGPoint, Bool) -> Void)?
    var onEnd: ((CGPoint, Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dragging = false

    /// fn, or option+shift. fn is the wanted gesture; ⌥⇧ is the fallback for
    /// keyboards that never report fn. If fn proves flaky, delete its line.
    static func isArmed(_ flags: CGEventFlags) -> Bool {
        if flags.contains(.maskSecondaryFn) { return true }
        return flags.contains(.maskAlternate) && flags.contains(.maskShift)
    }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<ModifierDragMonitor>.fromOpaque(refcon)
                        .takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            // Accessibility covers listen-only taps, so this failing means
            // something odd; the feature just stays off.
            AccessibilityHelper.logDebug("modifier-drag: event tap creation failed")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
        dragging = false
    }

    deinit { stop() }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        // The system disables taps it thinks are slow, even listen-only ones.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let cursor = event.location
        let armed = Self.isArmed(event.flags)

        switch type {
        case .leftMouseDown:
            dragging = true
            onBegin?(cursor)
        case .leftMouseDragged:
            if dragging { onUpdate?(cursor, armed) }
        case .flagsChanged:
            // Only meaningful mid-drag, and only while the button is down —
            // a flagsChanged after mouse-up belongs to no gesture.
            if dragging, NSEvent.pressedMouseButtons & 1 == 1 { onUpdate?(cursor, armed) }
        case .leftMouseUp:
            if dragging {
                dragging = false
                onEnd?(cursor, armed)
            }
        default:
            break
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project ReSized.xcodeproj -scheme ReSized -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add ReSized/ModifierDrag.swift
git commit -m "Listen-only event tap for the modifier-drag gesture"
```

---

### Task 5: Gesture session in WindowManager (`ModifierDragPlacement.swift`)

**Files:**
- Create: `ReSized/ModifierDragPlacement.swift` (extension — the session logic)
- Modify: `ReSized/WindowManager.swift`:
  - Add stored state to the class body (extensions cannot hold stored properties), next to the other `@ObservationIgnored` bookkeeping (~line 450).
  - Change `private func applyLayoutAndUpdateExpected` to internal (delete `private`).
  - Suppress snap-back in `handleWindowEvent`'s `isMove` branch.
  - Start/stop the monitor beside every `startMaintenanceTimerIfNeeded()` / `stopMaintenanceTimerIfIdle()` call (grep for the call sites; mirror each).

**Interfaces:**
- Consumes: everything produced by Tasks 1–4, plus `takeWindow(at:)`, `place(_:at:)` both overloads, `insertColumn/insertRow(with:at:)`, `WindowDiscovery.discoverAllWindows()`, `applyLayoutAndUpdateExpected(for:)`, `refreshAvailableWindows()`, `desktopSeams(for:)`, `Monitor.frame`.
- Produces: `startModifierDragMonitorIfNeeded()`, `stopModifierDragMonitorIfIdle()` (called from the lifecycle sites), plus the session internals below.

- [ ] **Step 1: Add stored state to WindowManager (class body, WindowManager.swift)**

```swift
    /// The modifier-drag gesture: the tap that watches for it and the session
    /// for a drag currently in flight. Bookkeeping, nothing rendered.
    @ObservationIgnored var modifierDragMonitor: ModifierDragMonitor?
    @ObservationIgnored var modifierDragSession: ModifierDragSession?
```

- [ ] **Step 2: Create ModifierDragPlacement.swift**

```swift
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
```

- [ ] **Step 3: Suppress snap-back while a modifier-drag is confirmed**

In `handleWindowEvent` (WindowManager.swift), the `isMove(delta)` branch currently reads:

```swift
        if isMove(delta) {
            reflowWorkItem?.cancel()
            applyLayoutAndUpdateExpected(for: layout)
            return
        }
```

Change to:

```swift
        if isMove(delta) {
            // A modifier-drag in flight owns this window; snapping it back
            // mid-gesture would fight the user's hand. Release decides.
            if modifierDragSession?.confirmedWindowDrag == true { return }
            reflowWorkItem?.cancel()
            applyLayoutAndUpdateExpected(for: layout)
            return
        }
```

- [ ] **Step 4: Make `applyLayoutAndUpdateExpected` internal**

Delete the `private` from `private func applyLayoutAndUpdateExpected(for layout: MonitorLayout)`.

- [ ] **Step 5: Wire the lifecycle**

Grep `startMaintenanceTimerIfNeeded()` call sites and add `startModifierDragMonitorIfNeeded()` immediately after each. Grep `stopMaintenanceTimerIfIdle()` call sites and add `stopModifierDragMonitorIfIdle()` immediately after each.

- [ ] **Step 6: Build**

Run: `xcodebuild -project ReSized.xcodeproj -scheme ReSized -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add ReSized/ModifierDragPlacement.swift ReSized/WindowManager.swift
git commit -m "Modifier-drag places real windows at layout seams"
```

Note for the implementer: new `.swift` files may need adding to the Xcode target. This project's target uses `PBXFileSystemSynchronizedRootGroup` if created recently — check whether Tasks 1 and 4's files compiled without project edits (the build will fail with "cannot find type" LINKER-level errors if not). If project.pbxproj edits are needed, mirror how `SeamOverlay.swift` is referenced.

---

### Task 6: Hand-test gate (Kennith on the mouse)

**Files:** none — behavior verification.

- [ ] **Step 1: Build, then tell Kennith the build is ready to relaunch when convenient** (do not kill a running instance he may be testing in).

- [ ] **Step 2: Run-through list** (from the spec):

1. Re-place a managed window at each destination kind: between two cells, at a column's top/bottom, between panes of a split, and past the layout's outer edge (new column).
2. Drag an unmanaged window onto a seam — it joins the grid.
3. Release a managed window away from any seam — it floats where dropped, others reflow.
4. Press the modifier only mid-drag (arms late); release the modifier before mouse-up (ordinary snap-back).
5. ⌥-drag a text selection inside an editor — nothing arms, the selection works normally.
6. Drag a window across monitors into another monitor's active layout.
7. Both fn and ⌥⇧ arm the gesture on the built-in keyboard.

- [ ] **Step 3: Fix what the run-through surfaces, commit each fix separately, push.**

---

## Self-Review Notes

- Spec coverage: arming rules (Task 4 isArmed + Task 5 moved/ended), landing rules incl. new column/row (Tasks 1, 3, 5), snap radius (Task 5 `dropSnapRadius`), indicator (Task 2), text-selection guard (Task 5 confirmedWindowDrag), snap-back suppression (Task 5 Step 3), tap lifecycle + silent failure (Tasks 4, 5), multi-monitor (Task 5 `activeLayout(atTopLeft:)` + cross-layout branch of `performModifierDrop`), float-out (Task 5 `modifierDragEnded`). Config-window slimming: out of scope per spec.
- Type consistency: `DesktopDropTarget`/`DesktopDropDestination` defined Task 1, consumed Task 5; `dropIndicator` tuple shape matches between Tasks 2 and 5; both `place` overloads distinct by first parameter type.
- `layoutRevision` is bumped by the `columns`/`rows` setters used in Task 3, so the config preview stays fresh if open.
