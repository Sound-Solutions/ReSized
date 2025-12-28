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
    func addWindow(_ window: ExternalWindow, toColumn columnIndex: Int) {
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
        columns[columnIndex].windows.append(columnWindow)

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
    func addWindow(_ window: ExternalWindow, toRow rowIndex: Int) {
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
        rows[rowIndex].windows.append(rowWindow)

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

        layout.isActive = true
        layout.appState = .active
        objectWillChange.send()

        // Apply initial layout and store expected frames
        applyLayoutAndUpdateExpected(for: layout)

        // Create display link synced to this monitor's refresh rate
        setupDisplayLink(for: layout)
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

        if let link = layout.displayLink {
            CVDisplayLinkStop(link)
            layout.displayLink = nil
        }
        layout.expectedFrames.removeAll()

        // Show highlight again when not actively managing
        if let monitor = selectedMonitor {
            MonitorHighlightWindow.show(on: monitor.screen)
        }
    }

    private func applyLayoutAndUpdateExpected(for layout: MonitorLayout) {
        applyLayout()

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

                    let expectedFrame = CGRect(
                        x: currentX,
                        y: currentTop - windowHeight,
                        width: columnWidth,
                        height: windowHeight
                    )
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

                    let expectedFrame = CGRect(
                        x: currentX,
                        y: currentTop - rowHeight,
                        width: windowWidth,
                        height: rowHeight
                    )
                    layout.expectedFrames[rowWindow.id] = expectedFrame
                    currentX += windowWidth
                }
                currentTop -= rowHeight
            }
        }
    }

    private func syncLoop(for layout: MonitorLayout) {
        guard !layout.isApplyingLayout else { return }

        // Wait a couple frames after applying layout for windows to settle
        layout.framesSinceApply += 1
        guard layout.framesSinceApply > 2 else { return }

        // Check for closed windows (about once per second at 60fps)
        if layout.framesSinceApply % 60 == 0 {
            checkForClosedWindows(in: layout)
        }

        // Find window that user is actively resizing (differs most from expected)
        var maxDelta: CGFloat = 0
        var changedWindow: (primaryIndex: Int, winIndex: Int, delta: FrameDelta)?

        switch layout.layoutMode {
        case .columns:
            for (colIndex, column) in layout.columns.enumerated() {
                for (winIndex, colWindow) in column.windows.enumerated() {
                    guard let currentFrame = ExternalWindow.getFrame(from: colWindow.window.axElement),
                          let expected = layout.expectedFrames[colWindow.id] else { continue }

                    let expectedAX = convertFrameToAXCoordinates(expected)

                    if let delta = detectFrameChange(from: expectedAX, to: currentFrame) {
                        let totalDelta = abs(delta.leftEdge) + abs(delta.rightEdge) +
                                        abs(delta.topEdge) + abs(delta.bottomEdge)
                        if totalDelta > maxDelta {
                            maxDelta = totalDelta
                            changedWindow = (colIndex, winIndex, delta)
                        }
                    }
                }
            }

        case .rows:
            for (rowIndex, row) in layout.rows.enumerated() {
                for (winIndex, rowWindow) in row.windows.enumerated() {
                    guard let currentFrame = ExternalWindow.getFrame(from: rowWindow.window.axElement),
                          let expected = layout.expectedFrames[rowWindow.id] else { continue }

                    let expectedAX = convertFrameToAXCoordinates(expected)

                    if let delta = detectFrameChange(from: expectedAX, to: currentFrame) {
                        let totalDelta = abs(delta.leftEdge) + abs(delta.rightEdge) +
                                        abs(delta.topEdge) + abs(delta.bottomEdge)
                        if totalDelta > maxDelta {
                            maxDelta = totalDelta
                            changedWindow = (rowIndex, winIndex, delta)
                        }
                    }
                }
            }
        }

        // Lower threshold since we're synced to display (10px)
        if let change = changedWindow, maxDelta > 10 {
            switch layout.layoutMode {
            case .columns:
                handleWindowResize(
                    in: layout,
                    columnIndex: change.primaryIndex,
                    windowIndex: change.winIndex,
                    delta: change.delta
                )
            case .rows:
                handleRowWindowResize(
                    in: layout,
                    rowIndex: change.primaryIndex,
                    windowIndex: change.winIndex,
                    delta: change.delta
                )
            }

            layout.isApplyingLayout = true
            layout.framesSinceApply = 0
            applyLayoutAndUpdateExpected(for: layout)
            layout.isApplyingLayout = false
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
                    if ExternalWindow.getFrame(from: colWindow.window.axElement) == nil {
                        DispatchQueue.main.async { [weak self] in
                            self?.removeWindow(colWindow.id, fromColumn: colIndex, in: layout)
                        }
                    }
                }
            }
        case .rows:
            for (rowIndex, row) in layout.rows.enumerated() {
                for rowWindow in row.windows {
                    if ExternalWindow.getFrame(from: rowWindow.window.axElement) == nil {
                        DispatchQueue.main.async { [weak self] in
                            self?.removeWindow(rowWindow.id, fromRow: rowIndex, in: layout)
                        }
                    }
                }
            }
        }
    }

    private func removeWindow(_ windowId: UUID, fromColumn columnIndex: Int, in layout: MonitorLayout) {
        guard columnIndex < layout.columns.count else { return }

        layout.columns[columnIndex].windows.removeAll { $0.id == windowId }

        // Recalculate proportions
        let count = layout.columns[columnIndex].windows.count
        if count > 0 {
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

        // Recalculate proportions
        let count = layout.rows[rowIndex].windows.count
        if count > 0 {
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
    func hueForApp(_ appName: String) -> Double {
        // Get all unique app names in current layout, sorted for consistency
        var allAppNames: [String] = []
        switch layoutMode {
        case .columns:
            allAppNames = columns.flatMap { $0.windows.map { $0.window.ownerName } }
        case .rows:
            allAppNames = rows.flatMap { $0.windows.map { $0.window.ownerName } }
        }
        let uniqueApps = Array(Set(allAppNames)).sorted()

        guard !uniqueApps.isEmpty else {
            // Fallback to hash-based if no apps
            return Double(abs(appName.hashValue) % 360) / 360.0
        }

        if let index = uniqueApps.firstIndex(of: appName) {
            // Evenly space hues around the wheel
            return Double(index) / Double(uniqueApps.count)
        } else {
            // App not in layout yet - use golden angle offset from last color
            let goldenAngle = 0.618033988749895
            let baseHue = Double(uniqueApps.count) / Double(max(uniqueApps.count, 1))
            return (baseHue + goldenAngle).truncatingRemainder(dividingBy: 1.0)
        }
    }
}
