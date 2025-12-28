import SwiftUI
import Combine
import CoreVideo
import AppKit

// MARK: - Monitor Highlight Overlay

/// Shows a red ring around the selected monitor (like Arrange Displays)
class MonitorHighlightWindow: NSWindow {
    init(for screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Above most windows
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]

        // Create the red ring view
        let ringView = MonitorRingView(frame: screen.frame)
        self.contentView = ringView
    }

    static var currentHighlight: MonitorHighlightWindow?

    static func show(on screen: NSScreen) {
        hide()
        let window = MonitorHighlightWindow(for: screen)
        window.orderFront(nil)
        currentHighlight = window
    }

    static func hide() {
        currentHighlight?.orderOut(nil)
        currentHighlight = nil
    }
}

class MonitorRingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let borderWidth: CGFloat = 6
        let insetRect = bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)

        NSColor.systemRed.setStroke()
        let path = NSBezierPath(roundedRect: insetRect, xRadius: 8, yRadius: 8)
        path.lineWidth = borderWidth
        path.stroke()
    }
}

/// A window placed in a column with its height proportion within that column
struct ColumnWindow: Identifiable, Equatable {
    let id: UUID
    var window: ExternalWindow
    /// Height proportion within the column (0.0 to 1.0)
    var heightProportion: CGFloat

    static func == (lhs: ColumnWindow, rhs: ColumnWindow) -> Bool {
        lhs.id == rhs.id
    }
}

/// A column containing vertically stacked windows
struct Column: Identifiable, Equatable {
    let id = UUID()
    /// Width proportion of the screen (0.0 to 1.0)
    var widthProportion: CGFloat
    /// Windows stacked vertically in this column
    var windows: [ColumnWindow]

    static func == (lhs: Column, rhs: Column) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Row-Based Layout (alternative to columns)

/// Layout mode determines primary division direction
enum LayoutMode: String, CaseIterable {
    case columns = "Columns"  // Vertical primary splits (side-by-side)
    case rows = "Rows"        // Horizontal primary splits (stacked)
    // case mix = "Mix"       // Phase 2: Tree-based nested splits
}

/// A window placed in a row with its width proportion within that row
struct RowWindow: Identifiable, Equatable {
    let id: UUID
    var window: ExternalWindow
    /// Width proportion within the row (0.0 to 1.0)
    var widthProportion: CGFloat

    static func == (lhs: RowWindow, rhs: RowWindow) -> Bool {
        lhs.id == rhs.id
    }
}

/// A row containing horizontally arranged windows
struct Row: Identifiable, Equatable {
    let id = UUID()
    /// Height proportion of the screen (0.0 to 1.0)
    var heightProportion: CGFloat
    /// Windows arranged horizontally in this row
    var windows: [RowWindow]

    static func == (lhs: Row, rhs: Row) -> Bool {
        lhs.id == rhs.id
    }
}

/// App state for the setup flow
enum AppState {
    case modeSelect     // First open: choosing layout mode (columns vs rows)
    case monitorSelect  // Choosing which monitor
    case configuring    // Adding windows to layout
    case active         // Layout is active and managing windows
}

/// Represents a monitor/screen
struct Monitor: Identifiable, Equatable {
    let id: String
    let screen: NSScreen
    let name: String
    let frame: CGRect
    let isMain: Bool

    init(screen: NSScreen, index: Int) {
        self.screen = screen
        self.id = "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? index)"
        self.frame = screen.visibleFrame
        self.isMain = screen == NSScreen.main

        // Try to get a meaningful name
        if let name = screen.localizedName as String? {
            self.name = name
        } else if isMain {
            self.name = "Main Display"
        } else {
            self.name = "Display \(index + 1)"
        }
    }

    static func == (lhs: Monitor, rhs: Monitor) -> Bool {
        lhs.id == rhs.id
    }
}

/// Per-monitor layout state
class MonitorLayout: ObservableObject {
    let monitorId: String
    let screen: NSScreen

    @Published var layoutMode: LayoutMode = .columns
    @Published var columns: [Column] = []  // Used when layoutMode == .columns
    @Published var rows: [Row] = []        // Used when layoutMode == .rows
    @Published var appState: AppState = .modeSelect
    @Published var containerBounds: CGRect = .zero
    @Published var isActive: Bool = false

    var displayLink: CVDisplayLink?
    var windowObserver: WindowObserver?
    var expectedFrames: [UUID: CGRect] = [:]
    var framesSinceApply: Int = 0
    var isApplyingLayout = false

    /// Small margin to account for apps that can't fill exactly (size increments, min sizes)
    static let edgeMargin: CGFloat = 8

    init(monitor: Monitor) {
        self.monitorId = monitor.id
        self.screen = monitor.screen
        // Apply margin to give apps some slack
        self.containerBounds = monitor.frame.insetBy(dx: 0, dy: MonitorLayout.edgeMargin / 2)
    }

    /// Update bounds with margin applied
    func updateBounds(from frame: CGRect) {
        containerBounds = frame.insetBy(dx: 0, dy: MonitorLayout.edgeMargin / 2)
    }
}

/// The main window manager with column-based layout
class WindowManager: ObservableObject {
    static let shared = WindowManager()

    /// Available monitors
    @Published var availableMonitors: [Monitor] = []

    /// Currently selected/viewed monitor
    @Published var selectedMonitor: Monitor?

    /// Per-monitor layouts
    @Published var monitorLayouts: [String: MonitorLayout] = [:]

    /// All discovered windows available to add
    @Published var availableWindows: [ExternalWindow] = []

    private var cancellables = Set<AnyCancellable>()

    /// Cache for app hue colors to avoid expensive recalculation on every render
    private var hueCache: [String: Double] = [:]
    private var hueCacheLayoutHash: Int = 0

    // MARK: - Computed Properties (proxy to current monitor's layout)

    var currentLayout: MonitorLayout? {
        guard let monitor = selectedMonitor else { return nil }
        return monitorLayouts[monitor.id]
    }

    var appState: AppState {
        get { currentLayout?.appState ?? .monitorSelect }
        set {
            guard let layout = currentLayout else { return }
            layout.appState = newValue
            objectWillChange.send()
        }
    }

    var layoutMode: LayoutMode {
        get { currentLayout?.layoutMode ?? .columns }
        set {
            guard let layout = currentLayout else { return }
            layout.layoutMode = newValue
            objectWillChange.send()
        }
    }

    var columns: [Column] {
        get { currentLayout?.columns ?? [] }
        set {
            guard let layout = currentLayout else { return }
            layout.columns = newValue
            objectWillChange.send()
        }
    }

    var rows: [Row] {
        get { currentLayout?.rows ?? [] }
        set {
            guard let layout = currentLayout else { return }
            layout.rows = newValue
            objectWillChange.send()
        }
    }

    /// Count of primary divisions (columns or rows based on mode)
    var primaryCount: Int {
        switch layoutMode {
        case .columns: return columns.count
        case .rows: return rows.count
        }
    }

    var containerBounds: CGRect {
        get { currentLayout?.containerBounds ?? .zero }
        set {
            guard let layout = currentLayout else { return }
            layout.containerBounds = newValue
            objectWillChange.send()
        }
    }

    var isActive: Bool {
        get { currentLayout?.isActive ?? false }
        set {
            guard let layout = currentLayout else { return }
            layout.isActive = newValue
            objectWillChange.send()
        }
    }

    init() {
        refreshMonitors()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.refreshMonitors()
            }
            .store(in: &cancellables)

        // Observe app launches for auto-filling placeholder slots
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    @objc private func handleAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleId = app.bundleIdentifier,
              let appName = app.localizedName else { return }

        // Check if any active layout has a placeholder waiting for this app
        for layout in monitorLayouts.values where layout.isActive {
            // Delay slightly to let the app create its window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.tryFillPlaceholder(appName: appName, bundleId: bundleId, in: layout)
            }
        }
    }

    private func tryFillPlaceholder(appName: String, bundleId: String, in layout: MonitorLayout) {
        // Refresh windows to find the new app's window
        refreshAvailableWindows()

        // Find any empty placeholder slots matching this app
        // For now, this is a simplified implementation - full placeholder
        // tracking would require storing placeholder info in the layout model

        // Try to find a window for this app that isn't already assigned
        guard let window = availableWindows.first(where: { $0.ownerName == appName }) else { return }

        // If we found a window, refresh the layout to pick it up
        print("Auto-filled placeholder for \(appName)")
        objectWillChange.send()
    }

    deinit {
        // Stop all display links
        for layout in monitorLayouts.values {
            if let link = layout.displayLink {
                CVDisplayLinkStop(link)
            }
        }
    }

    // MARK: - Monitor Management

    func refreshMonitors() {
        availableMonitors = NSScreen.screens.enumerated().map { index, screen in
            Monitor(screen: screen, index: index)
        }
    }

    func selectMonitor(_ monitor: Monitor) {
        selectedMonitor = monitor

        // Create layout for this monitor if it doesn't exist
        if monitorLayouts[monitor.id] == nil {
            monitorLayouts[monitor.id] = MonitorLayout(monitor: monitor)
        }

        // Update container bounds in case screen changed
        currentLayout?.updateBounds(from: monitor.frame)

        // Show highlight ring on the selected monitor (unless actively managing)
        if currentLayout?.isActive != true {
            MonitorHighlightWindow.show(on: monitor.screen)
        }

        // Notify SwiftUI of the change
        objectWillChange.send()
    }

    /// Update the highlight ring visibility based on state
    func updateHighlight() {
        if let monitor = selectedMonitor, currentLayout?.isActive != true {
            MonitorHighlightWindow.show(on: monitor.screen)
        } else {
            MonitorHighlightWindow.hide()
        }
    }

    private func updateContainerBounds() {
        if let monitor = selectedMonitor {
            currentLayout?.updateBounds(from: monitor.screen.visibleFrame)
        }
    }

    /// Check if a monitor has a configured layout
    func hasLayout(for monitor: Monitor) -> Bool {
        guard let layout = monitorLayouts[monitor.id] else { return false }
        return !layout.columns.isEmpty
    }

    /// Check if a monitor is actively managing windows
    func isManaging(monitor: Monitor) -> Bool {
        return monitorLayouts[monitor.id]?.isActive ?? false
    }

    // MARK: - Setup

    /// Set layout mode for all monitors and proceed with scanning
    func setModeAndScan(_ mode: LayoutMode) {
        guard AccessibilityHelper.checkAccessibilityPermissions() else { return }

        // Create layouts for all monitors with the chosen mode
        for monitor in availableMonitors {
            if monitorLayouts[monitor.id] == nil {
                monitorLayouts[monitor.id] = MonitorLayout(monitor: monitor)
            }
            monitorLayouts[monitor.id]?.layoutMode = mode
        }

        // Now scan all monitors
        scanAllMonitors()
    }

    /// Scan all monitors on launch and select the main one
    func scanAllMonitors() {
        guard AccessibilityHelper.checkAccessibilityPermissions() else { return }

        // Scan each monitor
        for monitor in availableMonitors {
            // Create layout for this monitor if needed
            if monitorLayouts[monitor.id] == nil {
                monitorLayouts[monitor.id] = MonitorLayout(monitor: monitor)
            }

            // Temporarily select to scan
            selectedMonitor = monitor
            _ = scanExistingLayout()
        }

        // Select main monitor and go to configuring
        if let mainMonitor = availableMonitors.first(where: { $0.isMain }) ?? availableMonitors.first {
            selectMonitor(mainMonitor)

            // Ensure we're in configuring state (even if no windows found)
            if layoutMode == .columns && columns.isEmpty {
                setupColumns(count: 2)  // Default to 2 columns
            } else if layoutMode == .rows && rows.isEmpty {
                setupRows(count: 2)  // Default to 2 rows
            }
            appState = .configuring
        }
    }

    /// Initialize with a specific number of columns
    func setupColumns(count: Int) {
        // Stop any active management first
        stopManaging()

        let proportion = 1.0 / CGFloat(count)
        columns = (0..<count).map { _ in
            Column(widthProportion: proportion, windows: [])
        }
        appState = .configuring
        refreshAvailableWindows()
    }

    /// Initialize with a specific number of rows
    func setupRows(count: Int) {
        // Stop any active management first
        stopManaging()

        let proportion = 1.0 / CGFloat(count)
        rows = (0..<count).map { _ in
            Row(heightProportion: proportion, windows: [])
        }
        appState = .configuring
        refreshAvailableWindows()
    }

    // MARK: - Tiled Window Detection

    private let edgeTolerance: CGFloat = 20  // Tolerance for edge matching

    /// Check if two values are approximately equal within tolerance
    private func isClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 20) -> Bool {
        abs(a - b) <= tolerance
    }

    /// Determine which edges a window touches (monitor edges or other window edges)
    private func detectTouchedEdges(
        window: ExternalWindow,
        allWindows: [ExternalWindow],
        monitorFrame: CGRect
    ) -> (left: Bool, right: Bool, top: Bool, bottom: Bool) {
        let frame = window.frame

        // Check if touching monitor edges
        var touchesLeft = frame.minX <= monitorFrame.minX + edgeTolerance
        var touchesRight = frame.maxX >= monitorFrame.maxX - edgeTolerance
        var touchesTop = frame.minY <= monitorFrame.minY + edgeTolerance
        var touchesBottom = frame.maxY >= monitorFrame.maxY - edgeTolerance

        // Check if touching other windows
        for other in allWindows where other.id != window.id {
            let otherFrame = other.frame

            // Check horizontal adjacency (windows must overlap vertically to be neighbors)
            let verticalOverlap = frame.minY < otherFrame.maxY && frame.maxY > otherFrame.minY
            if verticalOverlap {
                // Window's right edge touches other's left edge
                if isClose(frame.maxX, otherFrame.minX, tolerance: edgeTolerance) {
                    touchesRight = true
                }
                // Window's left edge touches other's right edge
                if isClose(frame.minX, otherFrame.maxX, tolerance: edgeTolerance) {
                    touchesLeft = true
                }
            }

            // Check vertical adjacency (windows must overlap horizontally to be neighbors)
            let horizontalOverlap = frame.minX < otherFrame.maxX && frame.maxX > otherFrame.minX
            if horizontalOverlap {
                // Window's bottom edge touches other's top edge
                if isClose(frame.maxY, otherFrame.minY, tolerance: edgeTolerance) {
                    touchesBottom = true
                }
                // Window's top edge touches other's bottom edge
                if isClose(frame.minY, otherFrame.maxY, tolerance: edgeTolerance) {
                    touchesTop = true
                }
            }
        }

        return (touchesLeft, touchesRight, touchesTop, touchesBottom)
    }

    /// Check if a window is part of a tiled layout (not floating)
    private func isTiledWindow(
        window: ExternalWindow,
        allWindows: [ExternalWindow],
        monitorFrame: CGRect
    ) -> Bool {
        let edges = detectTouchedEdges(window: window, allWindows: allWindows, monitorFrame: monitorFrame)

        // Count how many edges are touched (monitor or neighbor)
        let touchCount = [edges.left, edges.right, edges.top, edges.bottom].filter { $0 }.count

        // Tiled = touches at least 2 edges
        // Floating = touches 0 or 1 edges (isolated)
        return touchCount >= 2
    }

    /// Filter windows to only include tiled ones (falls back to all if none are tiled)
    private func filterTiledWindows(
        _ windows: [ExternalWindow],
        monitorFrame: CGRect
    ) -> [ExternalWindow] {
        let tiled = windows.filter { isTiledWindow(window: $0, allWindows: windows, monitorFrame: monitorFrame) }

        // Fall back to all windows if none are detected as tiled
        return tiled.isEmpty ? windows : tiled
    }

    /// Count max windows at any horizontal slice (for determining column count)
    /// Windows at the same X level (overlapping horizontally) count as one column
    private func maxWindowsHorizontally(_ windows: [ExternalWindow]) -> Int {
        guard !windows.isEmpty else { return 1 }

        var maxCount = 1
        let allYPositions = windows.flatMap { [$0.frame.minY, $0.frame.maxY, ($0.frame.minY + $0.frame.maxY) / 2] }

        for y in allYPositions {
            // Get windows that span this Y coordinate
            let windowsAtY = windows.filter { $0.frame.minY <= y && $0.frame.maxY >= y }
            guard !windowsAtY.isEmpty else { continue }

            // Sort by left edge (minX)
            let sortedByX = windowsAtY.sorted { $0.frame.minX < $1.frame.minX }

            // Merge overlapping windows into columns and count distinct columns
            var columnCount = 1
            var currentColumnMaxX = sortedByX[0].frame.maxX

            for window in sortedByX.dropFirst() {
                // If this window's left is past the current column's right (with tolerance),
                // it's a new column. Otherwise it overlaps/is stacked = same column.
                if window.frame.minX >= currentColumnMaxX - edgeTolerance {
                    columnCount += 1
                    currentColumnMaxX = window.frame.maxX
                } else {
                    // Window overlaps with current column, extend the column's right edge
                    currentColumnMaxX = max(currentColumnMaxX, window.frame.maxX)
                }
            }

            maxCount = max(maxCount, columnCount)
        }

        return maxCount
    }

    /// Count max windows at any vertical slice (for determining row count)
    /// Windows at the same Y level (overlapping vertically) count as one row
    private func maxWindowsVertically(_ windows: [ExternalWindow]) -> Int {
        guard !windows.isEmpty else { return 1 }

        var maxCount = 1
        let allXPositions = windows.flatMap { [$0.frame.minX, $0.frame.maxX, ($0.frame.minX + $0.frame.maxX) / 2] }

        for x in allXPositions {
            // Get windows that span this X coordinate
            let windowsAtX = windows.filter { $0.frame.minX <= x && $0.frame.maxX >= x }
            guard !windowsAtX.isEmpty else { continue }

            // Sort by top edge (minY in AX coords = top of screen)
            let sortedByY = windowsAtX.sorted { $0.frame.minY < $1.frame.minY }

            // Merge overlapping windows into rows and count distinct rows
            var rowCount = 1
            var currentRowMaxY = sortedByY[0].frame.maxY

            for window in sortedByY.dropFirst() {
                // If this window's top is below the current row's bottom (with tolerance),
                // it's a new row. Otherwise it overlaps/is side-by-side = same row.
                if window.frame.minY >= currentRowMaxY - edgeTolerance {
                    rowCount += 1
                    currentRowMaxY = window.frame.maxY
                } else {
                    // Window overlaps with current row, extend the row's bottom
                    currentRowMaxY = max(currentRowMaxY, window.frame.maxY)
                }
            }

            maxCount = max(maxCount, rowCount)
        }

        return maxCount
    }

    // MARK: - Layout Scanning

    /// Scan existing windows on the monitor and build layout from their positions
    func scanExistingLayout() -> Bool {
        guard let monitor = selectedMonitor else { return false }
        guard AccessibilityHelper.checkAccessibilityPermissions() else { return false }

        // Stop any active management first
        stopManaging()

        let allWindows = WindowDiscovery.discoverAllWindows()

        // Convert monitor frame to AX coordinates for comparison
        // Monitor frame is in NSScreen coords (Y=0 at bottom)
        // Window frames are in AX coords (Y=0 at top)
        let monitorFrameAX = convertFrameToAXCoordinates(monitor.frame)

        // Filter to windows that overlap with this monitor
        let windowsOnMonitor = allWindows.filter { window in
            let frame = window.frame  // Already in AX coordinates
            // Check if window overlaps with monitor (at least 50% on this monitor)
            let intersection = frame.intersection(monitorFrameAX)
            let overlapArea = intersection.width * intersection.height
            let windowArea = frame.width * frame.height
            return windowArea > 0 && overlapArea / windowArea > 0.5
        }

        guard !windowsOnMonitor.isEmpty else { return false }

        // Scan based on current layout mode
        switch layoutMode {
        case .columns:
            scanAsColumns(windowsOnMonitor, monitor: monitor)
        case .rows:
            scanAsRows(windowsOnMonitor, monitor: monitor)
        }

        appState = .configuring
        refreshAvailableWindows()

        return true
    }

    /// Scan windows as column-based layout
    private func scanAsColumns(_ windowsOnMonitor: [ExternalWindow], monitor: Monitor) {
        // Convert monitor frame to AX coordinates for edge detection
        let monitorFrameAX = convertFrameToAXCoordinates(monitor.frame)

        // Filter to tiled windows only (excludes floating windows)
        let tiledWindows = filterTiledWindows(windowsOnMonitor, monitorFrame: monitorFrameAX)

        // Determine column count from max horizontal windows at any Y
        let columnCount = maxWindowsHorizontally(tiledWindows)

        guard columnCount > 0 else {
            columns = []
            return
        }

        // Sort windows by X position (left to right)
        let sortedByX = tiledWindows.sorted { $0.frame.minX < $1.frame.minX }

        // Create exactly columnCount evenly-spaced boundaries
        let monitorWidth = monitorFrameAX.width
        let columnWidth = monitorWidth / CGFloat(columnCount)
        var columnBoundaries: [CGFloat] = []
        for i in 0..<columnCount {
            columnBoundaries.append(monitorFrameAX.minX + CGFloat(i) * columnWidth)
        }

        // Assign windows to columns based on which boundary range they fall into
        var columnGroups: [[ExternalWindow]] = Array(repeating: [], count: columnCount)

        for window in sortedByX {
            // Use window's horizontal center to determine column
            let windowCenterX = (window.frame.minX + window.frame.maxX) / 2
            var columnIndex = 0
            for (i, boundary) in columnBoundaries.enumerated() {
                let nextBoundary = (i < columnBoundaries.count - 1) ? columnBoundaries[i + 1] : monitorFrameAX.maxX
                if windowCenterX >= boundary && windowCenterX < nextBoundary {
                    columnIndex = i
                    break
                }
            }
            // Clamp to valid range
            columnIndex = min(columnIndex, columnCount - 1)
            columnGroups[columnIndex].append(window)
        }

        // Remove empty columns
        columnGroups = columnGroups.filter { !$0.isEmpty }

        // Build columns with proportions
        let totalWidth = monitor.frame.width
        var newColumns: [Column] = []

        for group in columnGroups {
            // Sort windows in column by Y (top to bottom in AX coords)
            let sortedByY = group.sorted { $0.frame.minY < $1.frame.minY }

            // Calculate column width from average of windows in this column
            let avgWidth = group.reduce(0) { $0 + $1.frame.width } / CGFloat(group.count)
            let widthProportion = avgWidth / totalWidth

            // Build windows with height proportions
            let totalHeight = monitor.frame.height
            var columnWindows: [ColumnWindow] = []

            for window in sortedByY {
                let heightProportion = window.frame.height / totalHeight
                let colWindow = ColumnWindow(
                    id: window.id,
                    window: window,
                    heightProportion: heightProportion
                )
                columnWindows.append(colWindow)
            }

            // Normalize height proportions within column
            let heightSum = columnWindows.reduce(0) { $0 + $1.heightProportion }
            if heightSum > 0 {
                for i in 0..<columnWindows.count {
                    columnWindows[i].heightProportion /= heightSum
                }
            }

            newColumns.append(Column(widthProportion: widthProportion, windows: columnWindows))
        }

        // Normalize column width proportions
        let widthSum = newColumns.reduce(0) { $0 + $1.widthProportion }
        if widthSum > 0 {
            for i in 0..<newColumns.count {
                newColumns[i].widthProportion /= widthSum
            }
        }

        columns = newColumns
    }

    /// Scan windows as row-based layout
    private func scanAsRows(_ windowsOnMonitor: [ExternalWindow], monitor: Monitor) {
        // Convert monitor frame to AX coordinates for edge detection
        let monitorFrameAX = convertFrameToAXCoordinates(monitor.frame)

        // Filter to tiled windows only (excludes floating windows)
        let tiledWindows = filterTiledWindows(windowsOnMonitor, monitorFrame: monitorFrameAX)

        // Determine row count from max vertical windows at any X
        let rowCount = maxWindowsVertically(tiledWindows)

        guard rowCount > 0 else {
            rows = []
            return
        }

        // Sort windows by Y position (top to bottom in AX coords)
        let sortedByY = tiledWindows.sorted { $0.frame.minY < $1.frame.minY }

        // Create exactly rowCount evenly-spaced boundaries
        let monitorHeight = monitorFrameAX.height
        let rowHeight = monitorHeight / CGFloat(rowCount)
        var rowBoundaries: [CGFloat] = []
        for i in 0..<rowCount {
            rowBoundaries.append(monitorFrameAX.minY + CGFloat(i) * rowHeight)
        }

        // Assign windows to rows based on which boundary range they fall into
        var rowGroups: [[ExternalWindow]] = Array(repeating: [], count: rowCount)

        for window in sortedByY {
            // Use window's vertical center to determine row
            let windowCenterY = (window.frame.minY + window.frame.maxY) / 2
            var rowIndex = 0
            for (i, boundary) in rowBoundaries.enumerated() {
                let nextBoundary = (i < rowBoundaries.count - 1) ? rowBoundaries[i + 1] : monitorFrameAX.maxY
                if windowCenterY >= boundary && windowCenterY < nextBoundary {
                    rowIndex = i
                    break
                }
            }
            // Clamp to valid range
            rowIndex = min(rowIndex, rowCount - 1)
            rowGroups[rowIndex].append(window)
        }

        // Remove empty rows
        rowGroups = rowGroups.filter { !$0.isEmpty }

        // Build rows with proportions
        let totalHeight = monitor.frame.height
        var newRows: [Row] = []

        for group in rowGroups {
            // Sort windows in row by X (left to right)
            let sortedByX = group.sorted { $0.frame.minX < $1.frame.minX }

            // Calculate row height from average of windows in this row
            let avgHeight = group.reduce(0) { $0 + $1.frame.height } / CGFloat(group.count)
            let heightProportion = avgHeight / totalHeight

            // Build windows with width proportions
            let totalWidth = monitor.frame.width
            var rowWindows: [RowWindow] = []

            for window in sortedByX {
                let widthProportion = window.frame.width / totalWidth
                let rowWindow = RowWindow(
                    id: window.id,
                    window: window,
                    widthProportion: widthProportion
                )
                rowWindows.append(rowWindow)
            }

            // Normalize width proportions within row
            let widthSum = rowWindows.reduce(0) { $0 + $1.widthProportion }
            if widthSum > 0 {
                for i in 0..<rowWindows.count {
                    rowWindows[i].widthProportion /= widthSum
                }
            }

            newRows.append(Row(heightProportion: heightProportion, windows: rowWindows))
        }

        // Normalize row height proportions
        let heightSum = newRows.reduce(0) { $0 + $1.heightProportion }
        if heightSum > 0 {
            for i in 0..<newRows.count {
                newRows[i].heightProportion /= heightSum
            }
        }

        rows = newRows
    }

    /// Reset to setup state
    func resetSetup() {
        stopManaging()
        columns = []
        rows = []
        appState = .modeSelect
    }

    /// Reset completely to monitor selection
    func resetToMonitorSelect() {
        stopManaging()
        columns = []
        rows = []
        selectedMonitor = nil
        appState = .monitorSelect
    }

    // MARK: - Window Discovery

    func refreshAvailableWindows() {
        guard AccessibilityHelper.checkAccessibilityPermissions() else {
            availableWindows = []
            return
        }

        let discovered = WindowDiscovery.discoverAllWindows()

        // Filter out windows already in columns or rows
        var usedIds = Set(columns.flatMap { $0.windows.map { $0.window.id } })
        usedIds.formUnion(rows.flatMap { $0.windows.map { $0.window.id } })
        availableWindows = discovered.filter { !usedIds.contains($0.id) }
    }

    // MARK: - Column Management

    /// Add a window to a specific column
    func addWindow(_ window: ExternalWindow, toColumn columnIndex: Int, atIndex: Int = -1) {
        guard columnIndex < columns.count else { return }

        // Calculate new equal proportions for all windows in this column
        let currentCount = columns[columnIndex].windows.count
        let newProportion = 1.0 / CGFloat(currentCount + 1)

        // Update existing windows' proportions
        for i in 0..<columns[columnIndex].windows.count {
            columns[columnIndex].windows[i].heightProportion = newProportion
        }

        // Add new window
        let columnWindow = ColumnWindow(
            id: window.id,
            window: window,
            heightProportion: newProportion
        )

        // Insert at specified index or append
        if atIndex >= 0 && atIndex < columns[columnIndex].windows.count {
            columns[columnIndex].windows.insert(columnWindow, at: atIndex)
        } else {
            columns[columnIndex].windows.append(columnWindow)
        }

        refreshAvailableWindows()

        if isActive {
            applyLayout()
        }
    }

    /// Remove a window from its column
    func removeWindow(_ windowId: UUID, fromColumn columnIndex: Int) {
        guard columnIndex < columns.count else { return }

        columns[columnIndex].windows.removeAll { $0.id == windowId }

        // Recalculate proportions
        let count = columns[columnIndex].windows.count
        if count > 0 {
            let newProportion = 1.0 / CGFloat(count)
            for i in 0..<count {
                columns[columnIndex].windows[i].heightProportion = newProportion
            }
        }

        refreshAvailableWindows()

        if isActive {
            applyLayout()
        }
    }

    /// Move a window between columns
    func moveWindow(_ windowId: UUID, fromColumn: Int, toColumn: Int) {
        guard fromColumn < columns.count, toColumn < columns.count else { return }
        guard let windowIndex = columns[fromColumn].windows.firstIndex(where: { $0.id == windowId }) else { return }

        let window = columns[fromColumn].windows[windowIndex].window
        removeWindow(windowId, fromColumn: fromColumn)
        addWindow(window, toColumn: toColumn)
    }

    // MARK: - Drag and Drop Handlers

    /// Handle dropping a window onto a column
    func handleColumnDrop(dragData: WindowDragData, targetColumn: Int, atIndex: Int = -1) {
        guard targetColumn < columns.count else { return }

        // Case 1: Dragging from sidebar (externalWindowId is set)
        if let externalWindowId = dragData.externalWindowId {
            // Find the window in availableWindows
            if let window = availableWindows.first(where: { $0.id == externalWindowId }) {
                addWindow(window, toColumn: targetColumn, atIndex: atIndex)
            }
            return
        }

        // Case 2: Dragging within same column (reordering)
        if let sourceColumn = dragData.sourceColumn, sourceColumn == targetColumn {
            if let sourceIndex = dragData.sourceIndex {
                reorderWindowInColumn(columnIndex: sourceColumn, fromIndex: sourceIndex, toIndex: atIndex)
            }
            return
        }

        // Case 3: Dragging from another column
        if let sourceColumn = dragData.sourceColumn {
            // Find the window and move it
            if let windowIndex = columns[sourceColumn].windows.firstIndex(where: { $0.id == dragData.windowId }) {
                let window = columns[sourceColumn].windows[windowIndex].window
                removeWindow(dragData.windowId, fromColumn: sourceColumn)
                addWindow(window, toColumn: targetColumn, atIndex: atIndex)
            }
        }
    }

    /// Reorder a window within a column
    func reorderWindowInColumn(columnIndex: Int, fromIndex: Int, toIndex: Int) {
        guard columnIndex < columns.count else { return }
        guard fromIndex < columns[columnIndex].windows.count else { return }
        guard fromIndex != toIndex else { return }

        let window = columns[columnIndex].windows.remove(at: fromIndex)
        let adjustedToIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        let insertIndex = min(adjustedToIndex, columns[columnIndex].windows.count)
        columns[columnIndex].windows.insert(window, at: max(0, insertIndex))

        if isActive {
            applyLayout()
        }
    }

    /// Handle dropping a window onto a row
    func handleRowDrop(dragData: WindowDragData, targetRow: Int, atIndex: Int = -1) {
        guard targetRow < rows.count else { return }

        // Case 1: Dragging from sidebar (externalWindowId is set)
        if let externalWindowId = dragData.externalWindowId {
            // Find the window in availableWindows
            if let window = availableWindows.first(where: { $0.id == externalWindowId }) {
                addWindow(window, toRow: targetRow, atIndex: atIndex)
            }
            return
        }

        // Case 2: Dragging within same row (reordering)
        if let sourceRow = dragData.sourceRow, sourceRow == targetRow {
            if let sourceIndex = dragData.sourceIndex {
                reorderWindowInRow(rowIndex: sourceRow, fromIndex: sourceIndex, toIndex: atIndex)
            }
            return
        }

        // Case 3: Dragging from another row
        if let sourceRow = dragData.sourceRow {
            // Find the window and move it
            if let windowIndex = rows[sourceRow].windows.firstIndex(where: { $0.id == dragData.windowId }) {
                let window = rows[sourceRow].windows[windowIndex].window
                removeWindow(dragData.windowId, fromRow: sourceRow)
                addWindow(window, toRow: targetRow, atIndex: atIndex)
            }
        }
    }

    /// Reorder a window within a row
    func reorderWindowInRow(rowIndex: Int, fromIndex: Int, toIndex: Int) {
        guard rowIndex < rows.count else { return }
        guard fromIndex < rows[rowIndex].windows.count else { return }
        guard fromIndex != toIndex else { return }

        let window = rows[rowIndex].windows.remove(at: fromIndex)
        let adjustedToIndex = toIndex > fromIndex ? toIndex - 1 : toIndex
        let insertIndex = min(adjustedToIndex, rows[rowIndex].windows.count)
        rows[rowIndex].windows.insert(window, at: max(0, insertIndex))

        if isActive {
            applyLayout()
        }
    }

    /// Add a new empty column
    func addColumn() {
        // Recalculate proportions to make room for new column
        let newCount = columns.count + 1
        let newProportion = 1.0 / CGFloat(newCount)

        for i in 0..<columns.count {
            columns[i].widthProportion = newProportion
        }

        columns.append(Column(widthProportion: newProportion, windows: []))
        normalizeColumnProportions()
    }

    /// Remove a column (and redistribute its width to remaining columns)
    func removeColumn(at index: Int) {
        guard index < columns.count, columns.count > 1 else { return }

        columns.remove(at: index)

        // Redistribute widths equally
        let newProportion = 1.0 / CGFloat(columns.count)
        for i in 0..<columns.count {
            columns[i].widthProportion = newProportion
        }

        refreshAvailableWindows()
    }

    // MARK: - Row Management

    /// Add a window to a specific row
    func addWindow(_ window: ExternalWindow, toRow rowIndex: Int, atIndex: Int = -1) {
        guard rowIndex < rows.count else { return }

        // Calculate new equal proportions for all windows in this row
        let currentCount = rows[rowIndex].windows.count
        let newProportion = 1.0 / CGFloat(currentCount + 1)

        // Update existing windows' proportions
        for i in 0..<rows[rowIndex].windows.count {
            rows[rowIndex].windows[i].widthProportion = newProportion
        }

        // Add new window
        let rowWindow = RowWindow(
            id: window.id,
            window: window,
            widthProportion: newProportion
        )

        // Insert at specified index or append
        if atIndex >= 0 && atIndex < rows[rowIndex].windows.count {
            rows[rowIndex].windows.insert(rowWindow, at: atIndex)
        } else {
            rows[rowIndex].windows.append(rowWindow)
        }

        refreshAvailableWindows()

        if isActive {
            applyLayout()
        }
    }

    /// Remove a window from its row
    func removeWindow(_ windowId: UUID, fromRow rowIndex: Int) {
        guard rowIndex < rows.count else { return }

        rows[rowIndex].windows.removeAll { $0.id == windowId }

        // Recalculate proportions
        let count = rows[rowIndex].windows.count
        if count > 0 {
            let newProportion = 1.0 / CGFloat(count)
            for i in 0..<count {
                rows[rowIndex].windows[i].widthProportion = newProportion
            }
        }

        refreshAvailableWindows()

        if isActive {
            applyLayout()
        }
    }

    /// Add a new empty row
    func addRow() {
        // Recalculate proportions to make room for new row
        let newCount = rows.count + 1
        let newProportion = 1.0 / CGFloat(newCount)

        for i in 0..<rows.count {
            rows[i].heightProportion = newProportion
        }

        rows.append(Row(heightProportion: newProportion, windows: []))
        normalizeRowProportions()
    }

    /// Remove a row (and redistribute its height to remaining rows)
    func removeRow(at index: Int) {
        guard index < rows.count, rows.count > 1 else { return }

        rows.remove(at: index)

        // Redistribute heights equally
        let newProportion = 1.0 / CGFloat(rows.count)
        for i in 0..<rows.count {
            rows[i].heightProportion = newProportion
        }

        refreshAvailableWindows()
    }

    /// Ensure all row height proportions sum to exactly 1.0
    private func normalizeRowProportions() {
        let total = rows.reduce(0) { $0 + $1.heightProportion }
        guard total > 0 && abs(total - 1.0) > 0.0001 else { return }
        for i in 0..<rows.count {
            rows[i].heightProportion /= total
        }
    }

    /// Ensure all window width proportions in a row sum to exactly 1.0
    private func normalizeWindowProportions(inRow rowIndex: Int) {
        guard rowIndex < rows.count else { return }
        let total = rows[rowIndex].windows.reduce(0) { $0 + $1.widthProportion }
        guard total > 0 && abs(total - 1.0) > 0.0001 else { return }
        for i in 0..<rows[rowIndex].windows.count {
            rows[rowIndex].windows[i].widthProportion /= total
        }
    }

    // MARK: - Proportion Normalization

    /// Ensure all column width proportions sum to exactly 1.0
    private func normalizeColumnProportions() {
        let total = columns.reduce(0) { $0 + $1.widthProportion }
        guard total > 0 && abs(total - 1.0) > 0.0001 else { return }
        for i in 0..<columns.count {
            columns[i].widthProportion /= total
        }
    }

    /// Ensure all window height proportions in a column sum to exactly 1.0
    private func normalizeWindowProportions(inColumn columnIndex: Int) {
        guard columnIndex < columns.count else { return }
        let total = columns[columnIndex].windows.reduce(0) { $0 + $1.heightProportion }
        guard total > 0 && abs(total - 1.0) > 0.0001 else { return }
        for i in 0..<columns[columnIndex].windows.count {
            columns[columnIndex].windows[i].heightProportion /= total
        }
    }

    /// Layout-specific normalization for column widths
    private func normalizeColumnProportions(in layout: MonitorLayout) {
        let total = layout.columns.reduce(0) { $0 + $1.widthProportion }
        guard total > 0 && abs(total - 1.0) > 0.0001 else { return }
        for i in 0..<layout.columns.count {
            layout.columns[i].widthProportion /= total
        }
    }

    /// Layout-specific normalization for window heights
    private func normalizeWindowProportions(inColumn columnIndex: Int, in layout: MonitorLayout) {
        guard columnIndex < layout.columns.count else { return }
        let total = layout.columns[columnIndex].windows.reduce(0) { $0 + $1.heightProportion }
        guard total > 0 && abs(total - 1.0) > 0.0001 else { return }
        for i in 0..<layout.columns[columnIndex].windows.count {
            layout.columns[columnIndex].windows[i].heightProportion /= total
        }
    }

    // MARK: - Resizing

    /// Resize a column divider (between columnIndex and columnIndex+1)
    /// This affects all windows in both adjacent columns
    func resizeColumnDivider(atIndex dividerIndex: Int, delta: CGFloat) {
        guard dividerIndex < columns.count - 1 else { return }

        let proportionalDelta = delta / containerBounds.width

        let leftCol = dividerIndex
        let rightCol = dividerIndex + 1

        // Minimum column width (10% of screen)
        let minWidth: CGFloat = 0.1

        let newLeftWidth = columns[leftCol].widthProportion + proportionalDelta
        let newRightWidth = columns[rightCol].widthProportion - proportionalDelta

        // Apply if both columns remain above minimum
        if newLeftWidth >= minWidth && newRightWidth >= minWidth {
            columns[leftCol].widthProportion = newLeftWidth
            columns[rightCol].widthProportion = newRightWidth
            normalizeColumnProportions()

            if isActive {
                applyLayout()
            }
        }
    }

    /// Resize a row divider within a column (between windowIndex and windowIndex+1)
    /// This only affects the two adjacent windows in that column
    func resizeRowDivider(inColumn columnIndex: Int, atIndex dividerIndex: Int, delta: CGFloat) {
        guard columnIndex < columns.count else { return }
        guard dividerIndex < columns[columnIndex].windows.count - 1 else { return }

        // Calculate the column's actual height
        let columnHeight = containerBounds.height

        let proportionalDelta = delta / columnHeight

        let topWindow = dividerIndex
        let bottomWindow = dividerIndex + 1

        // Minimum window height (10% of column)
        let minHeight: CGFloat = 0.1

        let newTopHeight = columns[columnIndex].windows[topWindow].heightProportion + proportionalDelta
        let newBottomHeight = columns[columnIndex].windows[bottomWindow].heightProportion - proportionalDelta

        // Apply if both windows remain above minimum
        if newTopHeight >= minHeight && newBottomHeight >= minHeight {
            columns[columnIndex].windows[topWindow].heightProportion = newTopHeight
            columns[columnIndex].windows[bottomWindow].heightProportion = newBottomHeight
            normalizeWindowProportions(inColumn: columnIndex)

            if isActive {
                applyLayout()
            }
        }
    }

    // MARK: - Row Mode Resizing

    /// Resize the primary divider between rows (affects row heights)
    func resizeRowPrimaryDivider(atIndex dividerIndex: Int, delta: CGFloat) {
        guard dividerIndex < rows.count - 1 else { return }

        let proportionalDelta = delta / containerBounds.height

        let topRow = dividerIndex
        let bottomRow = dividerIndex + 1

        // Minimum row height (10% of screen)
        let minHeight: CGFloat = 0.1

        let newTopHeight = rows[topRow].heightProportion + proportionalDelta
        let newBottomHeight = rows[bottomRow].heightProportion - proportionalDelta

        // Apply if both rows remain above minimum
        if newTopHeight >= minHeight && newBottomHeight >= minHeight {
            rows[topRow].heightProportion = newTopHeight
            rows[bottomRow].heightProportion = newBottomHeight
            normalizeRowProportions()

            if isActive {
                applyLayout()
            }
        }
    }

    /// Resize a window divider within a row (between windowIndex and windowIndex+1)
    /// This only affects the two adjacent windows in that row
    func resizeWindowDivider(inRow rowIndex: Int, atIndex dividerIndex: Int, delta: CGFloat) {
        guard rowIndex < rows.count else { return }
        guard dividerIndex < rows[rowIndex].windows.count - 1 else { return }

        let proportionalDelta = delta / containerBounds.width

        let leftWindow = dividerIndex
        let rightWindow = dividerIndex + 1

        // Minimum window width (10% of row)
        let minWidth: CGFloat = 0.1

        let newLeftWidth = rows[rowIndex].windows[leftWindow].widthProportion + proportionalDelta
        let newRightWidth = rows[rowIndex].windows[rightWindow].widthProportion - proportionalDelta

        // Apply if both windows remain above minimum
        if newLeftWidth >= minWidth && newRightWidth >= minWidth {
            rows[rowIndex].windows[leftWindow].widthProportion = newLeftWidth
            rows[rowIndex].windows[rightWindow].widthProportion = newRightWidth
            normalizeWindowProportions(inRow: rowIndex)

            if isActive {
                applyLayout()
            }
        }
    }

    // MARK: - Layout Application

    /// Apply the current layout to actual windows
    func applyLayout() {
        switch layoutMode {
        case .columns:
            applyColumnsLayout()
        case .rows:
            applyRowsLayout()
        }
    }

    /// Apply column-based layout (vertical primary divisions)
    private func applyColumnsLayout() {
        var currentX = containerBounds.minX
        let rightEdge = containerBounds.maxX
        let bottomEdge = containerBounds.minY

        for (colIndex, column) in columns.enumerated() {
            let isLastColumn = (colIndex == columns.count - 1)

            // Last column fills to right edge exactly to avoid gaps
            let columnWidth: CGFloat
            if isLastColumn {
                columnWidth = rightEdge - currentX
            } else {
                columnWidth = column.widthProportion * containerBounds.width
            }

            // Start from top of screen (maxY) and work down
            // In macOS, Y=0 is at bottom, so higher Y = higher on screen
            var currentTop = containerBounds.maxY

            for (winIndex, columnWindow) in column.windows.enumerated() {
                let isLastWindow = (winIndex == column.windows.count - 1)

                // Last window fills to bottom edge exactly to avoid gaps
                let windowHeight: CGFloat
                if isLastWindow {
                    windowHeight = currentTop - bottomEdge
                } else {
                    windowHeight = columnWindow.heightProportion * containerBounds.height
                }

                // Window origin is bottom-left, so y = top - height
                var frame = CGRect(
                    x: currentX,
                    y: currentTop - windowHeight,
                    width: columnWidth,
                    height: windowHeight
                )

                // Respect window's min/max size constraints
                frame = constrainFrame(frame, for: columnWindow.window)

                // For last column, keep right edge aligned (adjust x if width was constrained)
                if isLastColumn && frame.width < columnWidth {
                    frame.origin.x = rightEdge - frame.width
                }

                // For last window, keep bottom edge aligned (adjust y if height was constrained)
                if isLastWindow && frame.height < windowHeight {
                    frame.origin.y = bottomEdge
                }

                _ = columnWindow.window.setFrame(frame)

                // Move down for next window
                currentTop -= windowHeight
            }

            currentX += columnWidth
        }
    }

    /// Apply row-based layout (horizontal primary divisions)
    private func applyRowsLayout() {
        // Start from top of screen and work down
        var currentTop = containerBounds.maxY
        let bottomEdge = containerBounds.minY
        let rightEdge = containerBounds.maxX

        for (rowIndex, row) in rows.enumerated() {
            let isLastRow = (rowIndex == rows.count - 1)

            // Last row fills to bottom edge exactly to avoid gaps
            let rowHeight: CGFloat
            if isLastRow {
                rowHeight = currentTop - bottomEdge
            } else {
                rowHeight = row.heightProportion * containerBounds.height
            }

            // Start from left edge and work right
            var currentX = containerBounds.minX

            for (winIndex, rowWindow) in row.windows.enumerated() {
                let isLastWindow = (winIndex == row.windows.count - 1)

                // Last window fills to right edge exactly to avoid gaps
                let windowWidth: CGFloat
                if isLastWindow {
                    windowWidth = rightEdge - currentX
                } else {
                    windowWidth = rowWindow.widthProportion * containerBounds.width
                }

                // Window origin is bottom-left, so y = top - height
                var frame = CGRect(
                    x: currentX,
                    y: currentTop - rowHeight,
                    width: windowWidth,
                    height: rowHeight
                )

                // Respect window's min/max size constraints
                frame = constrainFrame(frame, for: rowWindow.window)

                // For last window in row, keep right edge aligned
                if isLastWindow && frame.width < windowWidth {
                    frame.origin.x = rightEdge - frame.width
                }

                // For last row, keep bottom edge aligned
                if isLastRow && frame.height < rowHeight {
                    frame.origin.y = bottomEdge
                }

                _ = rowWindow.window.setFrame(frame)

                // Move right for next window
                currentX += windowWidth
            }

            // Move down for next row
            currentTop -= rowHeight
        }
    }

    private func constrainFrame(_ frame: CGRect, for window: ExternalWindow) -> CGRect {
        let minSize = window.minSize
        let maxSize = window.maxSize

        var constrained = frame
        constrained.size.width = max(minSize.width, min(maxSize.width, frame.width))
        constrained.size.height = max(minSize.height, min(maxSize.height, frame.height))

        return constrained
    }

    // MARK: - Active Management

    func startManaging() {
        guard let layout = currentLayout else { return }

        // Hide monitor highlight when actively managing
        MonitorHighlightWindow.hide()

        // Check for placeholder apps that need launching
        let placeholdersToLaunch = findPlaceholderAppsToLaunch(in: layout)
        if !placeholdersToLaunch.isEmpty {
            // Launch apps and wait for windows, then continue
            launchPlaceholderApps(placeholdersToLaunch) { [weak self, weak layout] in
                guard let self = self, let layout = layout else { return }
                self.refreshAvailableWindows()
                self.rematchPlaceholderSlots(in: layout, for: placeholdersToLaunch)
                self.finishStartManaging(layout: layout)
            }
        } else {
            finishStartManaging(layout: layout)
        }
    }

    private func finishStartManaging(layout: MonitorLayout) {
        layout.isActive = true
        layout.appState = .active
        objectWillChange.send()

        // Apply initial layout and store expected frames
        applyLayoutAndUpdateExpected(for: layout)

        // Set up event-driven window observation (replaces constant polling)
        setupWindowObserver(for: layout)

        // Create display link for periodic tasks (closed window detection only, ~1/sec)
        setupDisplayLink(for: layout)

        // Notify menu bar
        NotificationCenter.default.post(name: NSNotification.Name("WindowManagerActiveChanged"), object: nil)
    }

    /// Find placeholder slots that need apps launched
    private func findPlaceholderAppsToLaunch(in layout: MonitorLayout) -> [(bundleId: String, appName: String)] {
        var appsToLaunch: [(bundleId: String, appName: String)] = []
        var seenBundleIds = Set<String>()

        // Check column windows for empty slots with known bundle IDs
        for column in layout.columns {
            // Empty slots would need a way to track - for now, check if windows match expected apps
            // This is a simplified check - full implementation would track placeholder slots
        }

        // For now, return empty - full placeholder tracking needs more model changes
        return appsToLaunch
    }

    /// Launch placeholder apps and wait for windows
    private func launchPlaceholderApps(_ apps: [(bundleId: String, appName: String)], completion: @escaping () -> Void) {
        guard !apps.isEmpty else {
            completion()
            return
        }

        // Launch all apps
        for app in apps {
            AppLauncher.launchApp(bundleId: app.bundleId)
            print("Launched placeholder app: \(app.appName)")
        }

        // Wait for windows to appear (up to 5 seconds)
        let bundleIds = Set(apps.map { $0.bundleId })
        waitForWindows(bundleIds: bundleIds, timeout: 5.0) {
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    /// Wait for all specified apps to have windows
    private func waitForWindows(bundleIds: Set<String>, timeout: TimeInterval, completion: @escaping () -> Void) {
        let startTime = Date()

        func check() {
            let elapsed = Date().timeIntervalSince(startTime)

            if elapsed >= timeout {
                print("Placeholder timeout - continuing with available windows")
                completion()
                return
            }

            // Check if all apps have windows
            var allReady = true
            for bundleId in bundleIds {
                if !AppLauncher.hasWindows(bundleId: bundleId) {
                    allReady = false
                    break
                }
            }

            if allReady {
                print("All placeholder apps ready")
                completion()
            } else {
                // Check again in 200ms
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    check()
                }
            }
        }

        check()
    }

    /// Re-match placeholder slots after apps are launched
    private func rematchPlaceholderSlots(in layout: MonitorLayout, for apps: [(bundleId: String, appName: String)]) {
        // Refresh and try to match windows to empty slots
        let appNames = Set(apps.map { $0.appName })

        switch layout.layoutMode {
        case .columns:
            for i in layout.columns.indices {
                for j in layout.columns[i].windows.indices {
                    // If this slot has no window but matches a launched app, try to fill it
                    // This requires tracking placeholder slots - simplified for now
                }
            }
        case .rows:
            // Similar for rows
            break
        }
    }

    private func setupWindowObserver(for layout: MonitorLayout) {
        // Get all windows being managed in this layout
        let windows = getAllManagedWindows(in: layout)
        guard !windows.isEmpty else { return }

        // Create observer that fires callback when windows move/resize
        layout.windowObserver = WindowObserver { [weak self, weak layout] element in
            guard let self = self, let layout = layout, layout.isActive else { return }
            self.handleWindowEvent(element: element, for: layout)
        }

        layout.windowObserver?.observeWindows(windows)
    }

    private func getAllManagedWindows(in layout: MonitorLayout) -> [ExternalWindow] {
        var windows: [ExternalWindow] = []
        switch layout.layoutMode {
        case .columns:
            for column in layout.columns {
                for colWindow in column.windows {
                    windows.append(colWindow.window)
                }
            }
        case .rows:
            for row in layout.rows {
                for rowWindow in row.windows {
                    windows.append(rowWindow.window)
                }
            }
        }
        return windows
    }

    private func handleWindowEvent(element: AXUIElement, for layout: MonitorLayout) {
        guard !layout.isApplyingLayout else { return }

        // Find which window changed and compare to expected
        guard let currentFrame = ExternalWindow.getFrame(from: element) else { return }

        // Find the window in our layout and check delta
        var changedWindow: (primaryIndex: Int, winIndex: Int, delta: FrameDelta)?

        switch layout.layoutMode {
        case .columns:
            for (colIndex, column) in layout.columns.enumerated() {
                for (winIndex, colWindow) in column.windows.enumerated() {
                    // Check if this is the element that changed
                    if CFEqual(colWindow.window.axElement, element) {
                        guard let expected = layout.expectedFrames[colWindow.id] else { continue }
                        let expectedAX = convertFrameToAXCoordinates(expected)
                        if let delta = detectFrameChange(from: expectedAX, to: currentFrame) {
                            changedWindow = (colIndex, winIndex, delta)
                        }
                        break
                    }
                }
            }
        case .rows:
            for (rowIndex, row) in layout.rows.enumerated() {
                for (winIndex, rowWindow) in row.windows.enumerated() {
                    if CFEqual(rowWindow.window.axElement, element) {
                        guard let expected = layout.expectedFrames[rowWindow.id] else { continue }
                        let expectedAX = convertFrameToAXCoordinates(expected)
                        if let delta = detectFrameChange(from: expectedAX, to: currentFrame) {
                            changedWindow = (rowIndex, winIndex, delta)
                        }
                        break
                    }
                }
            }
        }

        // If significant change detected, handle it
        if let change = changedWindow {
            switch layout.layoutMode {
            case .columns:
                handleWindowResize(in: layout, columnIndex: change.primaryIndex,
                                   windowIndex: change.winIndex, delta: change.delta)
            case .rows:
                handleRowWindowResize(in: layout, rowIndex: change.primaryIndex,
                                      windowIndex: change.winIndex, delta: change.delta)
            }

            layout.isApplyingLayout = true
            layout.framesSinceApply = 0
            applyLayoutAndUpdateExpected(for: layout)
            layout.isApplyingLayout = false
        }
    }

    private func setupDisplayLink(for layout: MonitorLayout) {
        // Create display link
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else {
            print("Failed to create display link")
            return
        }

        // Set it to this monitor's display
        if let screenNumber = layout.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            CVDisplayLinkSetCurrentCGDisplay(displayLink, screenNumber)
        }

        // Set the callback - passes the layout's monitor ID
        let callback: CVDisplayLinkOutputCallback = { displayLink, inNow, inOutputTime, flagsIn, flagsOut, context in
            guard let context = context else { return kCVReturnSuccess }
            let manager = Unmanaged<WindowManager>.fromOpaque(context).takeUnretainedValue()
            // We need to sync all active layouts
            manager.displayLinkFired()
            return kCVReturnSuccess
        }

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, callback, pointer)

        // Start the display link
        CVDisplayLinkStart(displayLink)
        layout.displayLink = displayLink

        // Log the refresh rate
        let refreshPeriod = CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
        if refreshPeriod > 0 {
            let fps = 1.0 / refreshPeriod
            print("Display link started for \(layout.monitorId) at \(Int(fps)) Hz")
        }
    }

    private func displayLinkFired() {
        // CVDisplayLink fires on a background thread, dispatch to main for UI/AX work
        DispatchQueue.main.async { [weak self] in
            self?.syncAllActiveLayouts()
        }
    }

    /// Sync all active monitor layouts
    private func syncAllActiveLayouts() {
        for layout in monitorLayouts.values where layout.isActive {
            syncLoop(for: layout)
        }
    }

    func stopManaging() {
        guard let layout = currentLayout else { return }

        layout.isActive = false
        objectWillChange.send()

        // Stop window observer
        layout.windowObserver?.stopObserving()
        layout.windowObserver = nil

        if let link = layout.displayLink {
            CVDisplayLinkStop(link)
            layout.displayLink = nil
        }
        layout.expectedFrames.removeAll()

        // Show highlight again when not actively managing
        if let monitor = selectedMonitor {
            MonitorHighlightWindow.show(on: monitor.screen)
        }

        // Notify menu bar
        NotificationCenter.default.post(name: NSNotification.Name("WindowManagerActiveChanged"), object: nil)
    }

    // MARK: - Global Start/Stop (for menu bar)

    /// Check if any monitor has an active layout
    var hasAnyActiveLayout: Bool {
        monitorLayouts.values.contains { $0.isActive }
    }

    /// Start managing all configured monitors
    func startAllLayouts() {
        for (monitorId, layout) in monitorLayouts {
            // Only start if layout has windows configured
            let hasWindows = !layout.columns.isEmpty || !layout.rows.isEmpty
            guard hasWindows else { continue }

            layout.isActive = true
            layout.appState = .active

            // Apply initial layout and store expected frames
            applyLayoutForMonitor(layout)
            applyLayoutAndUpdateExpected(for: layout)

            // Set up event-driven window observation
            setupWindowObserver(for: layout)

            // Create display link (now only for closed window detection)
            setupDisplayLink(for: layout)
        }
        objectWillChange.send()
        NotificationCenter.default.post(name: NSNotification.Name("WindowManagerActiveChanged"), object: nil)
    }

    /// Stop managing all monitors
    func stopAllLayouts() {
        for layout in monitorLayouts.values where layout.isActive {
            layout.isActive = false
            layout.appState = .configuring

            // Stop window observer
            layout.windowObserver?.stopObserving()
            layout.windowObserver = nil

            if let link = layout.displayLink {
                CVDisplayLinkStop(link)
                layout.displayLink = nil
            }
            layout.expectedFrames.removeAll()
        }
        MonitorHighlightWindow.hide()
        objectWillChange.send()
        NotificationCenter.default.post(name: NSNotification.Name("WindowManagerActiveChanged"), object: nil)
    }

    /// Apply layout for a specific monitor (used by startAllLayouts)
    private func applyLayoutForMonitor(_ layout: MonitorLayout) {
        let bounds = layout.containerBounds
        guard bounds.width > 0 && bounds.height > 0 else { return }

        switch layout.layoutMode {
        case .columns:
            var currentX = bounds.minX
            for (colIndex, column) in layout.columns.enumerated() {
                let isLastColumn = (colIndex == layout.columns.count - 1)
                let columnWidth = isLastColumn ? (bounds.maxX - currentX) : (column.widthProportion * bounds.width)

                var currentTop = bounds.maxY
                for (winIndex, colWindow) in column.windows.enumerated() {
                    let isLastWindow = (winIndex == column.windows.count - 1)
                    let windowHeight = isLastWindow ? (currentTop - bounds.minY) : (colWindow.heightProportion * bounds.height)

                    let frame = CGRect(x: currentX, y: currentTop - windowHeight, width: columnWidth, height: windowHeight)
                    let constrained = constrainFrame(frame, for: colWindow.window)
                    _ = colWindow.window.setFrame(constrained)
                    currentTop -= windowHeight
                }
                currentX += columnWidth
            }

        case .rows:
            var currentTop = bounds.maxY
            for (rowIndex, row) in layout.rows.enumerated() {
                let isLastRow = (rowIndex == layout.rows.count - 1)
                let rowHeight = isLastRow ? (currentTop - bounds.minY) : (row.heightProportion * bounds.height)

                var currentX = bounds.minX
                for (winIndex, rowWindow) in row.windows.enumerated() {
                    let isLastWindow = (winIndex == row.windows.count - 1)
                    let windowWidth = isLastWindow ? (bounds.maxX - currentX) : (rowWindow.widthProportion * bounds.width)

                    let frame = CGRect(x: currentX, y: currentTop - rowHeight, width: windowWidth, height: rowHeight)
                    let constrained = constrainFrame(frame, for: rowWindow.window)
                    _ = rowWindow.window.setFrame(constrained)
                    currentX += windowWidth
                }
                currentTop -= rowHeight
            }
        }
    }

    private func applyLayoutAndUpdateExpected(for layout: MonitorLayout) {
        applyLayoutForMonitor(layout)

        // Store what we expect each window's frame to be
        layout.expectedFrames.removeAll()

        switch layout.layoutMode {
        case .columns:
            var currentX = layout.containerBounds.minX
            let rightEdge = layout.containerBounds.maxX
            let bottomEdge = layout.containerBounds.minY

            for (colIndex, column) in layout.columns.enumerated() {
                let isLastColumn = (colIndex == layout.columns.count - 1)

                let columnWidth: CGFloat
                if isLastColumn {
                    columnWidth = rightEdge - currentX
                } else {
                    columnWidth = column.widthProportion * layout.containerBounds.width
                }

                var currentTop = layout.containerBounds.maxY

                for (winIndex, colWindow) in column.windows.enumerated() {
                    let isLastWindow = (winIndex == column.windows.count - 1)

                    let windowHeight: CGFloat
                    if isLastWindow {
                        windowHeight = currentTop - bottomEdge
                    } else {
                        windowHeight = colWindow.heightProportion * layout.containerBounds.height
                    }

                    var expectedFrame = CGRect(
                        x: currentX,
                        y: currentTop - windowHeight,
                        width: columnWidth,
                        height: windowHeight
                    )
                    // Constrain expected frame to window's min/max size to avoid perpetual sync
                    expectedFrame = constrainFrame(expectedFrame, for: colWindow.window)
                    layout.expectedFrames[colWindow.id] = expectedFrame
                    currentTop -= windowHeight
                }
                currentX += columnWidth
            }

        case .rows:
            var currentTop = layout.containerBounds.maxY
            let bottomEdge = layout.containerBounds.minY
            let rightEdge = layout.containerBounds.maxX

            for (rowIndex, row) in layout.rows.enumerated() {
                let isLastRow = (rowIndex == layout.rows.count - 1)

                let rowHeight: CGFloat
                if isLastRow {
                    rowHeight = currentTop - bottomEdge
                } else {
                    rowHeight = row.heightProportion * layout.containerBounds.height
                }

                var currentX = layout.containerBounds.minX

                for (winIndex, rowWindow) in row.windows.enumerated() {
                    let isLastWindow = (winIndex == row.windows.count - 1)

                    let windowWidth: CGFloat
                    if isLastWindow {
                        windowWidth = rightEdge - currentX
                    } else {
                        windowWidth = rowWindow.widthProportion * layout.containerBounds.width
                    }

                    var expectedFrame = CGRect(
                        x: currentX,
                        y: currentTop - rowHeight,
                        width: windowWidth,
                        height: rowHeight
                    )
                    // Constrain expected frame to window's min/max size to avoid perpetual sync
                    expectedFrame = constrainFrame(expectedFrame, for: rowWindow.window)
                    layout.expectedFrames[rowWindow.id] = expectedFrame
                    currentX += windowWidth
                }
                currentTop -= rowHeight
            }
        }
    }

    private func syncLoop(for layout: MonitorLayout) {
        // With event-driven sync via WindowObserver, this loop now only handles:
        // 1. Periodic closed window detection
        // 2. Counter maintenance for debouncing

        layout.framesSinceApply += 1

        // Check for closed windows approximately once per second (60 frames at 60fps)
        // This is now the only regular AX API call we make
        if layout.framesSinceApply % 60 == 0 {
            checkForClosedWindows(in: layout)
        }
    }

    /// Convert NSScreen frame to AX coordinates for comparison
    private func convertFrameToAXCoordinates(_ frame: CGRect) -> CGRect {
        guard let mainScreen = NSScreen.screens.first else { return frame }
        let screenHeight = mainScreen.frame.height
        let axY = screenHeight - frame.origin.y - frame.height
        return CGRect(x: frame.origin.x, y: axY, width: frame.width, height: frame.height)
    }

    private func checkForClosedWindows(in layout: MonitorLayout) {
        switch layout.layoutMode {
        case .columns:
            for (colIndex, column) in layout.columns.enumerated() {
                for colWindow in column.windows {
                    // Only remove if we can't get the frame AND the process is dead
                    // This prevents removing windows during sleep when AX calls timeout
                    if ExternalWindow.getFrame(from: colWindow.window.axElement) == nil {
                        let processExists = kill(colWindow.window.ownerPID, 0) == 0
                        if !processExists {
                            DispatchQueue.main.async { [weak self] in
                                self?.removeWindow(colWindow.id, fromColumn: colIndex, in: layout)
                            }
                        }
                    }
                }
            }
        case .rows:
            for (rowIndex, row) in layout.rows.enumerated() {
                for rowWindow in row.windows {
                    // Only remove if we can't get the frame AND the process is dead
                    if ExternalWindow.getFrame(from: rowWindow.window.axElement) == nil {
                        let processExists = kill(rowWindow.window.ownerPID, 0) == 0
                        if !processExists {
                            DispatchQueue.main.async { [weak self] in
                                self?.removeWindow(rowWindow.id, fromRow: rowIndex, in: layout)
                            }
                        }
                    }
                }
            }
        }
    }

    private func removeWindow(_ windowId: UUID, fromColumn columnIndex: Int, in layout: MonitorLayout) {
        guard columnIndex < layout.columns.count else { return }

        layout.columns[columnIndex].windows.removeAll { $0.id == windowId }

        // Remove empty column and redistribute widths
        if layout.columns[columnIndex].windows.isEmpty {
            layout.columns.remove(at: columnIndex)
            if !layout.columns.isEmpty {
                let newWidth = 1.0 / CGFloat(layout.columns.count)
                for i in 0..<layout.columns.count {
                    layout.columns[i].widthProportion = newWidth
                }
            }
        } else {
            // Recalculate height proportions within column
            let count = layout.columns[columnIndex].windows.count
            let newProportion = 1.0 / CGFloat(count)
            for i in 0..<count {
                layout.columns[columnIndex].windows[i].heightProportion = newProportion
            }
        }

        refreshAvailableWindows()
        objectWillChange.send()
    }

    private func removeWindow(_ windowId: UUID, fromRow rowIndex: Int, in layout: MonitorLayout) {
        guard rowIndex < layout.rows.count else { return }

        layout.rows[rowIndex].windows.removeAll { $0.id == windowId }

        // Remove empty row and redistribute heights
        if layout.rows[rowIndex].windows.isEmpty {
            layout.rows.remove(at: rowIndex)
            if !layout.rows.isEmpty {
                let newHeight = 1.0 / CGFloat(layout.rows.count)
                for i in 0..<layout.rows.count {
                    layout.rows[i].heightProportion = newHeight
                }
            }
        } else {
            // Recalculate width proportions within row
            let count = layout.rows[rowIndex].windows.count
            let newProportion = 1.0 / CGFloat(count)
            for i in 0..<count {
                layout.rows[rowIndex].windows[i].widthProportion = newProportion
            }
        }

        refreshAvailableWindows()
        objectWillChange.send()
    }

    struct FrameDelta {
        var leftEdge: CGFloat = 0   // positive = moved right
        var rightEdge: CGFloat = 0  // positive = moved right
        var topEdge: CGFloat = 0    // positive = moved down (in AX coords)
        var bottomEdge: CGFloat = 0 // positive = moved down (in AX coords)
    }

    private func detectFrameChange(from oldFrame: CGRect, to newFrame: CGRect) -> FrameDelta? {
        let threshold: CGFloat = 5 // Ignore tiny changes

        let leftDelta = newFrame.minX - oldFrame.minX
        let rightDelta = newFrame.maxX - oldFrame.maxX
        let topDelta = newFrame.minY - oldFrame.minY      // In AX coords, minY is top
        let bottomDelta = newFrame.maxY - oldFrame.maxY

        // Check if any edge moved significantly
        if abs(leftDelta) < threshold && abs(rightDelta) < threshold &&
           abs(topDelta) < threshold && abs(bottomDelta) < threshold {
            return nil
        }

        return FrameDelta(
            leftEdge: leftDelta,
            rightEdge: rightDelta,
            topEdge: topDelta,
            bottomEdge: bottomDelta
        )
    }

    private func handleWindowResize(in layout: MonitorLayout, columnIndex: Int, windowIndex: Int, delta: FrameDelta) {
        let threshold: CGFloat = 8

        // Calculate size changes
        let widthChange = delta.rightEdge - delta.leftEdge   // positive = got wider
        let heightChange = delta.bottomEdge - delta.topEdge  // positive = got taller (in AX coords)

        // HORIZONTAL: Determine which column edge was dragged
        if abs(widthChange) > threshold {
            // Left edge dragged (window position changed, right edge stayed relatively fixed)
            if abs(delta.leftEdge) > abs(delta.rightEdge) && columnIndex > 0 {
                let proportionalDelta = delta.leftEdge / layout.containerBounds.width
                let newWidth = layout.columns[columnIndex].widthProportion - proportionalDelta
                let neighborWidth = layout.columns[columnIndex - 1].widthProportion + proportionalDelta

                if newWidth >= 0.1 && neighborWidth >= 0.1 {
                    layout.columns[columnIndex].widthProportion = newWidth
                    layout.columns[columnIndex - 1].widthProportion = neighborWidth
                }
            }
            // Right edge dragged (left edge stayed fixed)
            else if abs(delta.rightEdge) > abs(delta.leftEdge) && columnIndex < layout.columns.count - 1 {
                let proportionalDelta = delta.rightEdge / layout.containerBounds.width
                let newWidth = layout.columns[columnIndex].widthProportion + proportionalDelta
                let neighborWidth = layout.columns[columnIndex + 1].widthProportion - proportionalDelta

                if newWidth >= 0.1 && neighborWidth >= 0.1 {
                    layout.columns[columnIndex].widthProportion = newWidth
                    layout.columns[columnIndex + 1].widthProportion = neighborWidth
                }
            }
        }

        // VERTICAL: Determine which row edge was dragged
        if abs(heightChange) > threshold {
            // Top edge dragged (bottom stayed relatively fixed)
            // In AX coords: top edge moving UP = negative topEdge delta, window gets taller
            if abs(delta.topEdge) > abs(delta.bottomEdge) && windowIndex > 0 {
                // topEdge negative = moved up = this window gets taller, neighbor shrinks
                let proportionalDelta = -delta.topEdge / layout.containerBounds.height  // negate so positive = taller
                let newHeight = layout.columns[columnIndex].windows[windowIndex].heightProportion + proportionalDelta
                let neighborHeight = layout.columns[columnIndex].windows[windowIndex - 1].heightProportion - proportionalDelta

                if newHeight >= 0.1 && neighborHeight >= 0.1 {
                    layout.columns[columnIndex].windows[windowIndex].heightProportion = newHeight
                    layout.columns[columnIndex].windows[windowIndex - 1].heightProportion = neighborHeight
                }
            }
            // Bottom edge dragged (top stayed relatively fixed)
            // In AX coords: bottom edge moving DOWN = positive bottomEdge delta, window gets taller
            else if abs(delta.bottomEdge) > abs(delta.topEdge) && windowIndex < layout.columns[columnIndex].windows.count - 1 {
                let proportionalDelta = delta.bottomEdge / layout.containerBounds.height
                let newHeight = layout.columns[columnIndex].windows[windowIndex].heightProportion + proportionalDelta
                let neighborHeight = layout.columns[columnIndex].windows[windowIndex + 1].heightProportion - proportionalDelta

                if newHeight >= 0.1 && neighborHeight >= 0.1 {
                    layout.columns[columnIndex].windows[windowIndex].heightProportion = newHeight
                    layout.columns[columnIndex].windows[windowIndex + 1].heightProportion = neighborHeight
                }
            }
        }

        // Normalize proportions to prevent floating-point drift
        normalizeColumnProportions(in: layout)
        normalizeWindowProportions(inColumn: columnIndex, in: layout)
    }

    private func handleRowWindowResize(in layout: MonitorLayout, rowIndex: Int, windowIndex: Int, delta: FrameDelta) {
        let threshold: CGFloat = 8

        // Calculate size changes
        let widthChange = delta.rightEdge - delta.leftEdge   // positive = got wider
        let heightChange = delta.bottomEdge - delta.topEdge  // positive = got taller (in AX coords)

        // VERTICAL: Determine which row edge was dragged (affects row heights)
        if abs(heightChange) > threshold {
            // Top edge dragged (bottom stayed relatively fixed)
            if abs(delta.topEdge) > abs(delta.bottomEdge) && rowIndex > 0 {
                let proportionalDelta = -delta.topEdge / layout.containerBounds.height
                let newHeight = layout.rows[rowIndex].heightProportion + proportionalDelta
                let neighborHeight = layout.rows[rowIndex - 1].heightProportion - proportionalDelta

                if newHeight >= 0.1 && neighborHeight >= 0.1 {
                    layout.rows[rowIndex].heightProportion = newHeight
                    layout.rows[rowIndex - 1].heightProportion = neighborHeight
                }
            }
            // Bottom edge dragged (top stayed relatively fixed)
            else if abs(delta.bottomEdge) > abs(delta.topEdge) && rowIndex < layout.rows.count - 1 {
                let proportionalDelta = delta.bottomEdge / layout.containerBounds.height
                let newHeight = layout.rows[rowIndex].heightProportion + proportionalDelta
                let neighborHeight = layout.rows[rowIndex + 1].heightProportion - proportionalDelta

                if newHeight >= 0.1 && neighborHeight >= 0.1 {
                    layout.rows[rowIndex].heightProportion = newHeight
                    layout.rows[rowIndex + 1].heightProportion = neighborHeight
                }
            }
        }

        // HORIZONTAL: Determine which window edge was dragged (affects window widths within row)
        if abs(widthChange) > threshold {
            // Left edge dragged
            if abs(delta.leftEdge) > abs(delta.rightEdge) && windowIndex > 0 {
                let proportionalDelta = delta.leftEdge / layout.containerBounds.width
                let newWidth = layout.rows[rowIndex].windows[windowIndex].widthProportion - proportionalDelta
                let neighborWidth = layout.rows[rowIndex].windows[windowIndex - 1].widthProportion + proportionalDelta

                if newWidth >= 0.1 && neighborWidth >= 0.1 {
                    layout.rows[rowIndex].windows[windowIndex].widthProportion = newWidth
                    layout.rows[rowIndex].windows[windowIndex - 1].widthProportion = neighborWidth
                }
            }
            // Right edge dragged
            else if abs(delta.rightEdge) > abs(delta.leftEdge) && windowIndex < layout.rows[rowIndex].windows.count - 1 {
                let proportionalDelta = delta.rightEdge / layout.containerBounds.width
                let newWidth = layout.rows[rowIndex].windows[windowIndex].widthProportion + proportionalDelta
                let neighborWidth = layout.rows[rowIndex].windows[windowIndex + 1].widthProportion - proportionalDelta

                if newWidth >= 0.1 && neighborWidth >= 0.1 {
                    layout.rows[rowIndex].windows[windowIndex].widthProportion = newWidth
                    layout.rows[rowIndex].windows[windowIndex + 1].widthProportion = neighborWidth
                }
            }
        }

        // Normalize proportions to prevent floating-point drift
        normalizeRowProportions(in: layout)
        normalizeWindowProportions(inRow: rowIndex, in: layout)
    }

    /// Layout-specific normalization for row heights
    private func normalizeRowProportions(in layout: MonitorLayout) {
        let total = layout.rows.reduce(0) { $0 + $1.heightProportion }
        guard total > 0 && abs(total - 1.0) > 0.0001 else { return }
        for i in 0..<layout.rows.count {
            layout.rows[i].heightProportion /= total
        }
    }

    /// Layout-specific normalization for window widths in a row
    private func normalizeWindowProportions(inRow rowIndex: Int, in layout: MonitorLayout) {
        guard rowIndex < layout.rows.count else { return }
        let total = layout.rows[rowIndex].windows.reduce(0) { $0 + $1.widthProportion }
        guard total > 0 && abs(total - 1.0) > 0.0001 else { return }
        for i in 0..<layout.rows[rowIndex].windows.count {
            layout.rows[rowIndex].windows[i].widthProportion /= total
        }
    }

    // MARK: - Helpers

    /// Check if any column/row has windows
    var hasAnyWindows: Bool {
        switch layoutMode {
        case .columns:
            return columns.contains { !$0.windows.isEmpty }
        case .rows:
            return rows.contains { !$0.windows.isEmpty }
        }
    }

    /// Total window count
    var totalWindowCount: Int {
        switch layoutMode {
        case .columns:
            return columns.reduce(0) { $0 + $1.windows.count }
        case .rows:
            return rows.reduce(0) { $0 + $1.windows.count }
        }
    }

    /// Get evenly-spaced hue for an app name based on unique apps in current layout
    /// Uses caching to avoid expensive recalculation on every render
    func hueForApp(_ appName: String) -> Double {
        // Get all unique app names in current layout
        var allAppNames: [String] = []
        switch layoutMode {
        case .columns:
            allAppNames = columns.flatMap { $0.windows.map { $0.window.ownerName } }
        case .rows:
            allAppNames = rows.flatMap { $0.windows.map { $0.window.ownerName } }
        }

        // Check if cache is still valid (layout hasn't changed)
        let currentHash = allAppNames.sorted().hashValue
        if currentHash != hueCacheLayoutHash {
            // Layout changed, invalidate cache
            hueCache.removeAll()
            hueCacheLayoutHash = currentHash
        }

        // Return cached value if available
        if let cached = hueCache[appName] {
            return cached
        }

        // Calculate hue
        let uniqueApps = Array(Set(allAppNames)).sorted()
        let hue: Double

        if uniqueApps.isEmpty {
            // Fallback to hash-based if no apps
            hue = Double(abs(appName.hashValue) % 360) / 360.0
        } else if let index = uniqueApps.firstIndex(of: appName) {
            // Evenly space hues around the wheel
            hue = Double(index) / Double(uniqueApps.count)
        } else {
            // App not in layout yet - use golden angle offset from last color
            let goldenAngle = 0.618033988749895
            let baseHue = Double(uniqueApps.count) / Double(max(uniqueApps.count, 1))
            hue = (baseHue + goldenAngle).truncatingRemainder(dividingBy: 1.0)
        }

        // Cache and return
        hueCache[appName] = hue
        return hue
    }

    // MARK: - Layout Persistence

    private static let savedLayoutsKey = "SavedLayouts"
    private static let monitorPresetsKey = "MonitorPresets_v1"
    private static let workspacePresetsKey = "WorkspacePresets_v1"

    /// Save the current layout configuration with a name
    func saveCurrentLayout(name: String, asWorkspace: Bool = false, presetSlot: Int? = nil) {
        if asWorkspace {
            saveWorkspaceLayout(name: name, presetSlot: presetSlot)
        } else {
            saveMonitorLayout(name: name, presetSlot: presetSlot)
        }
    }

    /// Save current monitor's layout
    private func saveMonitorLayout(name: String, presetSlot: Int? = nil) {
        guard let layout = currentLayout else { return }

        let saved = createSavedLayout(from: layout, name: name, presetSlot: presetSlot)

        var layouts = loadSavedLayoutsList()
        layouts.removeAll { $0.name == name }
        layouts.append(saved)

        if let data = try? JSONEncoder().encode(layouts) {
            UserDefaults.standard.set(data, forKey: Self.savedLayoutsKey)
        }
    }

    /// Save all monitors' layouts as a workspace
    private func saveWorkspaceLayout(name: String, presetSlot: Int? = nil) {
        var monitorSavedLayouts: [SavedLayout] = []

        for (monitorId, layout) in monitorLayouts {
            let hasWindows = !layout.columns.isEmpty || !layout.rows.isEmpty
            guard hasWindows else { continue }

            let saved = createSavedLayout(from: layout, name: "\(name)_\(monitorId)", presetSlot: nil)
            monitorSavedLayouts.append(saved)
        }

        guard !monitorSavedLayouts.isEmpty else { return }

        let workspace = WorkspaceLayout(
            name: name,
            monitorLayouts: monitorSavedLayouts,
            presetSlot: presetSlot
        )

        // Store workspace in the saved layouts list with isWorkspace = true
        let workspaceSaved = SavedLayout(
            name: name,
            monitorId: nil,
            isWorkspace: true,
            layoutMode: "workspace",
            columns: nil,
            rows: nil,
            presetSlot: presetSlot
        )

        var layouts = loadSavedLayoutsList()
        layouts.removeAll { $0.name == name }
        layouts.append(workspaceSaved)

        if let data = try? JSONEncoder().encode(layouts) {
            UserDefaults.standard.set(data, forKey: Self.savedLayoutsKey)
        }

        // Store the actual workspace data separately
        var workspaces = loadWorkspacesList()
        workspaces.removeAll { $0.name == name }
        workspaces.append(workspace)

        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: Self.workspacePresetsKey)
        }
    }

    /// Create a SavedLayout from a MonitorLayout
    private func createSavedLayout(from layout: MonitorLayout, name: String, presetSlot: Int?) -> SavedLayout {
        SavedLayout(
            name: name,
            monitorId: layout.monitorId,
            isWorkspace: false,
            layoutMode: layout.layoutMode.rawValue,
            columns: layout.layoutMode == .columns ? layout.columns.map { col in
                SavedColumn(
                    widthProportion: col.widthProportion,
                    windows: col.windows.map { colWin in
                        SavedWindowSlot(
                            ownerName: colWin.window.ownerName,
                            windowTitle: colWin.window.title,
                            bundleIdentifier: AppLauncher.getBundleIdentifier(for: colWin.window.ownerName),
                            proportion: colWin.heightProportion,
                            isPlaceholder: false
                        )
                    }
                )
            } : nil,
            rows: layout.layoutMode == .rows ? layout.rows.map { row in
                SavedRow(
                    heightProportion: row.heightProportion,
                    windows: row.windows.map { rowWin in
                        SavedWindowSlot(
                            ownerName: rowWin.window.ownerName,
                            windowTitle: rowWin.window.title,
                            bundleIdentifier: AppLauncher.getBundleIdentifier(for: rowWin.window.ownerName),
                            proportion: rowWin.widthProportion,
                            isPlaceholder: false
                        )
                    }
                )
            } : nil,
            presetSlot: presetSlot
        )
    }

    private func loadWorkspacesList() -> [WorkspaceLayout] {
        guard let data = UserDefaults.standard.data(forKey: Self.workspacePresetsKey),
              let workspaces = try? JSONDecoder().decode([WorkspaceLayout].self, from: data) else {
            return []
        }
        return workspaces
    }

    // MARK: - Monitor Presets (Cmd+Shift+1-9)

    /// Handle monitor preset hotkey: save if empty, load if filled
    func handleMonitorPreset(slot: Int) {
        guard let monitor = selectedMonitor ?? availableMonitors.first else { return }

        if let existing = getMonitorPreset(slot: slot, monitorId: monitor.id) {
            // Load existing preset
            loadMonitorPreset(existing)
            print("Loaded monitor preset \(slot)")
        } else {
            // Save current layout to this slot
            guard currentLayout != nil, hasAnyWindows else {
                print("No layout to save for preset \(slot)")
                return
            }
            saveMonitorPreset(slot: slot, monitorId: monitor.id)
            print("Saved monitor preset \(slot)")
        }
    }

    func getMonitorPreset(slot: Int, monitorId: String) -> SavedLayout? {
        let presets = loadMonitorPresetsList()
        return presets.first { $0.presetSlot == slot && $0.monitorId == monitorId }
    }

    func saveMonitorPreset(slot: Int, monitorId: String) {
        guard let layout = currentLayout else { return }

        let saved = createSavedLayout(from: layout, name: "Preset \(slot)", presetSlot: slot)

        var presets = loadMonitorPresetsList()
        presets.removeAll { $0.presetSlot == slot && $0.monitorId == monitorId }
        presets.append(saved)

        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.monitorPresetsKey)
        }
    }

    func loadMonitorPreset(_ preset: SavedLayout) {
        guard let layout = currentLayout else { return }
        loadLayoutIntoMonitor(saved: preset, layout: layout)
        // Auto-start managing after loading a preset via hotkey
        startManaging()
    }

    func deleteMonitorPreset(slot: Int, monitorId: String) {
        var presets = loadMonitorPresetsList()
        presets.removeAll { $0.presetSlot == slot && $0.monitorId == monitorId }
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.monitorPresetsKey)
        }
    }

    private func loadMonitorPresetsList() -> [SavedLayout] {
        guard let data = UserDefaults.standard.data(forKey: Self.monitorPresetsKey),
              let presets = try? JSONDecoder().decode([SavedLayout].self, from: data) else {
            return []
        }
        return presets
    }

    // MARK: - Workspace Presets (Cmd+Option+Shift+1-9)

    /// Handle workspace preset hotkey: save if empty, load if filled
    func handleWorkspacePreset(slot: Int) {
        if let existing = getWorkspacePreset(slot: slot) {
            // Load existing workspace
            loadWorkspacePreset(existing)
            print("Loaded workspace preset \(slot)")
        } else {
            // Save current workspace to this slot
            let hasAnyContent = monitorLayouts.values.contains { !$0.columns.isEmpty || !$0.rows.isEmpty }
            guard hasAnyContent else {
                print("No layouts to save for workspace preset \(slot)")
                return
            }
            saveWorkspacePreset(slot: slot)
            print("Saved workspace preset \(slot)")
        }
    }

    func getWorkspacePreset(slot: Int) -> WorkspaceLayout? {
        loadWorkspacesList().first { $0.presetSlot == slot }
    }

    func saveWorkspacePreset(slot: Int) {
        var monitorSavedLayouts: [SavedLayout] = []

        for (_, layout) in monitorLayouts {
            let hasWindows = !layout.columns.isEmpty || !layout.rows.isEmpty
            guard hasWindows else { continue }

            let saved = createSavedLayout(from: layout, name: "Workspace \(slot)", presetSlot: nil)
            monitorSavedLayouts.append(saved)
        }

        guard !monitorSavedLayouts.isEmpty else { return }

        let workspace = WorkspaceLayout(
            name: "Workspace \(slot)",
            monitorLayouts: monitorSavedLayouts,
            presetSlot: slot
        )

        var workspaces = loadWorkspacesList()
        workspaces.removeAll { $0.presetSlot == slot }
        workspaces.append(workspace)

        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: Self.workspacePresetsKey)
        }
    }

    func loadWorkspacePreset(_ workspace: WorkspaceLayout) {
        for savedLayout in workspace.monitorLayouts {
            guard let monitorId = savedLayout.monitorId,
                  let layout = monitorLayouts[monitorId] else { continue }
            loadLayoutIntoMonitor(saved: savedLayout, layout: layout)
        }

        // Start managing after loading
        startAllLayouts()
    }

    /// Load a saved layout into a monitor layout
    private func loadLayoutIntoMonitor(saved: SavedLayout, layout: MonitorLayout) {
        // Set layout mode
        if let mode = LayoutMode(rawValue: saved.layoutMode) {
            layout.layoutMode = mode
        }

        // Refresh available windows
        refreshAvailableWindows()

        // Re-match windows to slots
        switch layout.layoutMode {
        case .columns:
            guard let savedColumns = saved.columns else { return }
            var usedWindowIds = Set<UUID>()

            layout.columns = savedColumns.map { savedCol in
                let matchedWindows = savedCol.windows.compactMap { slot -> ColumnWindow? in
                    guard let match = findMatchingWindow(for: slot, excluding: usedWindowIds) else {
                        return nil
                    }
                    usedWindowIds.insert(match.id)
                    return ColumnWindow(
                        id: UUID(),
                        window: match,
                        heightProportion: slot.proportion
                    )
                }
                return Column(
                    widthProportion: savedCol.widthProportion,
                    windows: matchedWindows
                )
            }

        case .rows:
            guard let savedRows = saved.rows else { return }
            var usedWindowIds = Set<UUID>()

            layout.rows = savedRows.map { savedRow in
                let matchedWindows = savedRow.windows.compactMap { slot -> RowWindow? in
                    guard let match = findMatchingWindow(for: slot, excluding: usedWindowIds) else {
                        return nil
                    }
                    usedWindowIds.insert(match.id)
                    return RowWindow(
                        id: UUID(),
                        window: match,
                        widthProportion: slot.proportion
                    )
                }
                return Row(
                    heightProportion: savedRow.heightProportion,
                    windows: matchedWindows
                )
            }
        }

        layout.appState = .configuring
        objectWillChange.send()
    }

    /// List all saved layouts
    func listSavedLayouts() -> [String] {
        loadSavedLayoutsList().map { $0.name }
    }

    /// List all saved layouts with full info for UI display
    func listSavedLayoutsWithInfo() -> [(name: String, isWorkspace: Bool, presetSlot: Int?)] {
        loadSavedLayoutsList().map { ($0.name, $0.isWorkspace, $0.presetSlot) }
    }

    /// Load a saved layout by name
    func loadLayout(name: String) {
        guard let saved = loadSavedLayoutsList().first(where: { $0.name == name }) else { return }

        if saved.isWorkspace {
            // Load workspace layout
            if let workspace = loadWorkspacesList().first(where: { $0.name == name }) {
                loadWorkspacePreset(workspace)
            }
        } else {
            // Load single-monitor layout
            guard let layout = currentLayout else { return }
            loadLayoutIntoMonitor(saved: saved, layout: layout)
        }
    }

    /// Delete a saved layout
    func deleteLayout(name: String) {
        var layouts = loadSavedLayoutsList()
        layouts.removeAll { $0.name == name }
        if let data = try? JSONEncoder().encode(layouts) {
            UserDefaults.standard.set(data, forKey: Self.savedLayoutsKey)
        }
    }

    private func loadSavedLayoutsList() -> [SavedLayout] {
        guard let data = UserDefaults.standard.data(forKey: Self.savedLayoutsKey),
              let layouts = try? JSONDecoder().decode([SavedLayout].self, from: data) else {
            return []
        }
        return layouts
    }

    private func findMatchingWindow(for slot: SavedWindowSlot, excluding usedIds: Set<UUID>) -> ExternalWindow? {
        // First try exact title match
        if let exactMatch = availableWindows.first(where: {
            !usedIds.contains($0.id) &&
            $0.ownerName == slot.ownerName &&
            $0.title == slot.windowTitle
        }) {
            return exactMatch
        }

        // Fall back to app name only
        return availableWindows.first {
            !usedIds.contains($0.id) && $0.ownerName == slot.ownerName
        }
    }
}

// MARK: - Layout Persistence Models

struct SavedLayout: Codable {
    let name: String
    let monitorId: String?          // nil for workspace-level layouts
    let isWorkspace: Bool           // true = all monitors, false = single monitor
    let layoutMode: String
    let columns: [SavedColumn]?
    let rows: [SavedRow]?
    let presetSlot: Int?            // 1-9 if assigned to a hotkey slot

    // Backwards compatibility: provide defaults for new fields
    init(name: String, monitorId: String?, isWorkspace: Bool = false, layoutMode: String,
         columns: [SavedColumn]?, rows: [SavedRow]?, presetSlot: Int? = nil) {
        self.name = name
        self.monitorId = monitorId
        self.isWorkspace = isWorkspace
        self.layoutMode = layoutMode
        self.columns = columns
        self.rows = rows
        self.presetSlot = presetSlot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        monitorId = try container.decodeIfPresent(String.self, forKey: .monitorId)
        isWorkspace = try container.decodeIfPresent(Bool.self, forKey: .isWorkspace) ?? false
        layoutMode = try container.decode(String.self, forKey: .layoutMode)
        columns = try container.decodeIfPresent([SavedColumn].self, forKey: .columns)
        rows = try container.decodeIfPresent([SavedRow].self, forKey: .rows)
        presetSlot = try container.decodeIfPresent(Int.self, forKey: .presetSlot)
    }
}

struct SavedColumn: Codable {
    let widthProportion: CGFloat
    let windows: [SavedWindowSlot]
}

struct SavedRow: Codable {
    let heightProportion: CGFloat
    let windows: [SavedWindowSlot]
}

struct SavedWindowSlot: Codable {
    let ownerName: String
    let windowTitle: String?
    let bundleIdentifier: String?   // For launching apps
    let proportion: CGFloat
    let isPlaceholder: Bool         // true = app wasn't open when saved

    // Backwards compatibility
    init(ownerName: String, windowTitle: String?, bundleIdentifier: String? = nil,
         proportion: CGFloat, isPlaceholder: Bool = false) {
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.bundleIdentifier = bundleIdentifier
        self.proportion = proportion
        self.isPlaceholder = isPlaceholder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        proportion = try container.decode(CGFloat.self, forKey: .proportion)
        isPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
    }
}

/// Groups multiple monitor layouts into a single workspace preset
struct WorkspaceLayout: Codable {
    let name: String
    let monitorLayouts: [SavedLayout]
    let presetSlot: Int?            // 1-9 if assigned to a hotkey slot
}
