import SwiftUI
import Combine
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
    var window: ExternalWindow?  // nil if using nestedContainer
    var nestedContainer: LayoutContainer?  // For nested splits within this cell
    /// Height proportion within the column (0.0 to 1.0)
    var heightProportion: CGFloat

    /// Check if this cell has a nested container
    var isNested: Bool { nestedContainer != nil }

    /// Get all windows (either the single window or all from nested container)
    var allWindows: [ExternalWindow] {
        if let window = window {
            return [window]
        } else if let container = nestedContainer {
            return container.allWindows
        }
        return []
    }

    init(id: UUID = UUID(), window: ExternalWindow, heightProportion: CGFloat = 1.0) {
        self.id = id
        self.window = window
        self.nestedContainer = nil
        self.heightProportion = heightProportion
    }

    init(id: UUID = UUID(), nestedContainer: LayoutContainer, heightProportion: CGFloat = 1.0) {
        self.id = id
        self.window = nil
        self.nestedContainer = nestedContainer
        self.heightProportion = heightProportion
    }

    static func == (lhs: ColumnWindow, rhs: ColumnWindow) -> Bool {
        lhs.id == rhs.id &&
        lhs.window?.id == rhs.window?.id &&
        lhs.nestedContainer?.id == rhs.nestedContainer?.id &&
        lhs.nestedContainer?.children.count == rhs.nestedContainer?.children.count &&
        lhs.nestedContainer?.children.first?.proportion == rhs.nestedContainer?.children.first?.proportion &&
        lhs.heightProportion == rhs.heightProportion
    }
}

/// A column containing vertically stacked windows
struct Column: Identifiable, Equatable {
    let id: UUID
    /// Width proportion of the screen (0.0 to 1.0)
    var widthProportion: CGFloat
    /// Windows stacked vertically in this column
    var windows: [ColumnWindow]

    init(id: UUID = UUID(), widthProportion: CGFloat, windows: [ColumnWindow]) {
        self.id = id
        self.widthProportion = widthProportion
        self.windows = windows
    }

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
    var window: ExternalWindow?  // nil if using nestedContainer
    var nestedContainer: LayoutContainer?  // For nested splits within this cell
    /// Width proportion within the row (0.0 to 1.0)
    var widthProportion: CGFloat

    /// Check if this cell has a nested container
    var isNested: Bool { nestedContainer != nil }

    /// Get all windows (either the single window or all from nested container)
    var allWindows: [ExternalWindow] {
        if let window = window {
            return [window]
        } else if let container = nestedContainer {
            return container.allWindows
        }
        return []
    }

    init(id: UUID = UUID(), window: ExternalWindow, widthProportion: CGFloat = 1.0) {
        self.id = id
        self.window = window
        self.nestedContainer = nil
        self.widthProportion = widthProportion
    }

    init(id: UUID = UUID(), nestedContainer: LayoutContainer, widthProportion: CGFloat = 1.0) {
        self.id = id
        self.window = nil
        self.nestedContainer = nestedContainer
        self.widthProportion = widthProportion
    }

    static func == (lhs: RowWindow, rhs: RowWindow) -> Bool {
        lhs.id == rhs.id &&
        lhs.window?.id == rhs.window?.id &&
        lhs.nestedContainer?.id == rhs.nestedContainer?.id &&
        lhs.nestedContainer?.children.count == rhs.nestedContainer?.children.count &&
        lhs.nestedContainer?.children.first?.proportion == rhs.nestedContainer?.children.first?.proportion &&
        lhs.widthProportion == rhs.widthProportion
    }
}

/// A row containing horizontally arranged windows
struct Row: Identifiable, Equatable {
    let id: UUID
    /// Height proportion of the screen (0.0 to 1.0)
    var heightProportion: CGFloat
    /// Windows arranged horizontally in this row
    var windows: [RowWindow]

    init(id: UUID = UUID(), heightProportion: CGFloat, windows: [RowWindow]) {
        self.id = id
        self.heightProportion = heightProportion
        self.windows = windows
    }

    static func == (lhs: Row, rhs: Row) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Nested Container Support

/// Direction for splitting a container
enum SplitDirection: String, Codable {
    case horizontal  // Children arranged left-to-right
    case vertical    // Children arranged top-to-bottom
}

/// A window node within a nested container
struct LayoutWindowNode: Identifiable, Equatable {
    let id: UUID
    var window: ExternalWindow
    var proportion: CGFloat

    init(window: ExternalWindow, proportion: CGFloat = 1.0) {
        self.id = UUID()
        self.window = window
        self.proportion = proportion
    }
}

/// A container that can hold windows or other containers
struct LayoutContainer: Identifiable, Equatable {
    let id: UUID
    var direction: SplitDirection
    var children: [LayoutNode]
    var proportion: CGFloat

    init(direction: SplitDirection, children: [LayoutNode] = [], proportion: CGFloat = 1.0) {
        self.id = UUID()
        self.direction = direction
        self.children = children
        self.proportion = proportion
    }

    /// Normalize proportions so they sum to 1.0
    mutating func normalizeProportions() {
        guard !children.isEmpty else { return }
        let total = children.reduce(0) { $0 + $1.proportion }
        if total > 0 {
            for i in children.indices {
                children[i].proportion = children[i].proportion / total
            }
        }
    }

    /// Get all windows in this container recursively
    var allWindows: [ExternalWindow] {
        children.flatMap { child -> [ExternalWindow] in
            switch child {
            case .window(let node):
                return [node.window]
            case .container(let container):
                return container.allWindows
            }
        }
    }
}

/// A node in the layout tree - either a window or a nested container
enum LayoutNode: Identifiable, Equatable {
    case window(LayoutWindowNode)
    case container(LayoutContainer)

    var id: UUID {
        switch self {
        case .window(let node): return node.id
        case .container(let container): return container.id
        }
    }

    var proportion: CGFloat {
        get {
            switch self {
            case .window(let node): return node.proportion
            case .container(let container): return container.proportion
            }
        }
        set {
            switch self {
            case .window(var node):
                node.proportion = newValue
                self = .window(node)
            case .container(var container):
                container.proportion = newValue
                self = .container(container)
            }
        }
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

    var windowObserver: WindowObserver?
    var expectedFrames: [UUID: CGRect] = [:]

    /// Move/resize notifications caused by our own layout writes arrive on the run
    /// loop *after* the write returns, so a synchronous "am I applying" flag never
    /// sees them and the app reacts to itself. Ignore window events until this
    /// deadline instead. Apps with size increments (Terminal) never land on exactly
    /// the frame we asked for, which is what turned that into a feedback loop:
    /// every apply looked like a user resize and triggered another apply.
    var suppressEventsUntil: Date = .distantPast

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
    private var hueCacheRevision: Int = -1

    /// Bumped whenever the layout's structure changes, so derived caches can tell
    /// they're stale without re-deriving a signature on every single read.
    private var layoutRevision: Int = 0

    /// Live drags call applyLayout on every gesture event, and each apply is a
    /// burst of synchronous cross-process AX writes. Collapse them to at most one
    /// per interval, last one wins.
    private var pendingApply = false
    private var lastApplyTime: Date = .distantPast
    private static let applyThrottleInterval: TimeInterval = 1.0 / 30.0

    /// One low-frequency timer shared by every active layout — see
    /// startMaintenanceTimerIfNeeded() for why this is not a display link.
    private var maintenanceTimer: DispatchSourceTimer?
    private static let maintenanceInterval: TimeInterval = 1.0

    /// How long to ignore window events after we move windows ourselves.
    private static let eventSuppressionInterval: TimeInterval = 0.25

    // MARK: - Computed Properties (proxy to current monitor's layout)

    var currentLayout: MonitorLayout? {
        guard let monitor = selectedMonitor else { return nil }
        return monitorLayouts[monitor.id]
    }

    /// Get the monitor where the mouse cursor is located (for hotkey detection)
    func getMonitorAtMouseLocation() -> Monitor? {
        let mouseLocation = NSEvent.mouseLocation
        // NSEvent.mouseLocation is in screen coordinates (Y=0 at bottom)
        return availableMonitors.first { monitor in
            monitor.frame.contains(mouseLocation)
        }
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
            layoutRevision &+= 1
            objectWillChange.send()
        }
    }

    var columns: [Column] {
        get { currentLayout?.columns ?? [] }
        set {
            guard let layout = currentLayout else { return }
            layout.columns = newValue
            layoutRevision &+= 1
            objectWillChange.send()
        }
    }

    var rows: [Row] {
        get { currentLayout?.rows ?? [] }
        set {
            guard let layout = currentLayout else { return }
            layout.rows = newValue
            layoutRevision &+= 1
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

        // NOTE: a didLaunchApplicationNotification observer used to live here. It
        // scheduled a full AX rescan of every running app, per active layout,
        // every time any app launched — to call a placeholder-filling routine
        // whose entire body was a print. Real placeholder support needs the
        // layout model to represent an unfilled slot; that is where this hooks
        // back in once it does.
    }

    deinit {
        maintenanceTimer?.cancel()
    }

    // MARK: - Monitor Management

    func refreshMonitors() {
        availableMonitors = NSScreen.screens.enumerated().map { index, screen in
            Monitor(screen: screen, index: index)
        }
    }

    func selectMonitor(_ monitor: Monitor) {
        let isNewLayout = monitorLayouts[monitor.id] == nil

        // Create layout for this monitor BEFORE selecting it (so currentLayout isn't nil)
        if isNewLayout {
            let layout = MonitorLayout(monitor: monitor)
            layout.appState = .configuring  // Don't show mode picker when switching tabs
            layout.layoutMode = loadLastUsedLayoutMode()  // Use saved mode preference
            monitorLayouts[monitor.id] = layout
        }

        // Now select the monitor (currentLayout will return the layout we just created)
        selectedMonitor = monitor

        // Update container bounds in case screen changed
        currentLayout?.updateBounds(from: monitor.frame)

        // Show highlight ring on the selected monitor (unless actively managing)
        if currentLayout?.isActive != true {
            MonitorHighlightWindow.show(on: monitor.screen)
        }

        // Scan windows when switching tabs (if layout is empty and not actively managing)
        if AccessibilityHelper.checkAccessibilityPermissions() && currentLayout?.isActive != true {
            let isEmpty = (currentLayout?.columns.isEmpty ?? true) && (currentLayout?.rows.isEmpty ?? true)
            if isEmpty {
                _ = scanExistingLayout()
            }
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

        // Save the mode choice for future launches
        saveLayoutMode(mode)

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

    /// Skip initial pages and go directly to editing mode for the monitor at mouse location
    func skipToEditingMode() {
        // Load last used mode or default to columns
        let mode = loadLastUsedLayoutMode()

        // Create layouts for all monitors with the chosen mode and configuring state
        for monitor in availableMonitors {
            if monitorLayouts[monitor.id] == nil {
                monitorLayouts[monitor.id] = MonitorLayout(monitor: monitor)
            }
            monitorLayouts[monitor.id]?.layoutMode = mode
            monitorLayouts[monitor.id]?.appState = .configuring  // All monitors start in configuring
        }

        // Get the monitor at mouse location, or fall back to main/first
        let targetMonitor = getMonitorAtMouseLocation()
            ?? availableMonitors.first(where: { $0.isMain })
            ?? availableMonitors.first

        guard let monitor = targetMonitor else { return }

        // Select and scan just this monitor
        selectMonitor(monitor)

        // Only scan if we have accessibility permissions
        if AccessibilityHelper.checkAccessibilityPermissions() {
            _ = scanExistingLayout()
        }

        // Ensure we're in configuring state (even if no windows found)
        if layoutMode == .columns && columns.isEmpty {
            setupColumns(count: 2)
        } else if layoutMode == .rows && rows.isEmpty {
            setupRows(count: 2)
        }

        appState = .configuring
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

        // Filter out windows already in columns or rows (including nested containers)
        var usedIds = Set(columns.flatMap { $0.windows.flatMap { $0.allWindows.map { $0.id } } })
        usedIds.formUnion(rows.flatMap { $0.windows.flatMap { $0.allWindows.map { $0.id } } })
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

        guard let window = columns[fromColumn].windows[windowIndex].window else { return }
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
            if let windowIndex = columns[sourceColumn].windows.firstIndex(where: { $0.id == dragData.windowId }),
               let window = columns[sourceColumn].windows[windowIndex].window {
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
            if let windowIndex = rows[sourceRow].windows.firstIndex(where: { $0.id == dragData.windowId }),
               let window = rows[sourceRow].windows[windowIndex].window {
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

    /// Minimum share of a track that any single pane may occupy
    static let minPaneProportion: CGFloat = 0.1

    /// Shift `delta` out of the second pane and into the first, clamping at the
    /// minimum rather than rejecting the whole gesture. Returns nil if there
    /// isn't room for two panes at all.
    private static func resolveSplit(first: CGFloat, second: CGFloat, delta: CGFloat) -> (CGFloat, CGFloat)? {
        let total = first + second
        guard total > minPaneProportion * 2 else { return nil }
        let clamped = min(max(first + delta, minPaneProportion), total - minPaneProportion)
        return (clamped, total - clamped)
    }

    /// Resize a column divider (between columnIndex and columnIndex+1)
    /// This affects all windows in both adjacent columns.
    /// `proportionalDelta` is the change since the previous drag event expressed as a
    /// fraction of the track the columns are drawn in — not a pixel distance. The
    /// caller owns that conversion because only it knows the on-screen track size.
    func resizeColumnDivider(atIndex dividerIndex: Int, proportionalDelta: CGFloat) {
        guard dividerIndex >= 0, dividerIndex + 1 < columns.count else { return }

        var updated = columns
        guard let (left, right) = Self.resolveSplit(
            first: updated[dividerIndex].widthProportion,
            second: updated[dividerIndex + 1].widthProportion,
            delta: proportionalDelta
        ) else { return }

        updated[dividerIndex].widthProportion = left
        updated[dividerIndex + 1].widthProportion = right
        columns = updated

        normalizeColumnProportions()

        if isActive {
            applyLayoutThrottled()
        }
    }

    /// Resize a row divider within a column (between windowIndex and windowIndex+1)
    /// This only affects the two adjacent windows in that column
    func resizeRowDivider(inColumn columnIndex: Int, atIndex dividerIndex: Int, proportionalDelta: CGFloat) {
        guard columnIndex >= 0, columnIndex < columns.count else { return }
        guard dividerIndex >= 0, dividerIndex + 1 < columns[columnIndex].windows.count else { return }

        var updated = columns
        guard let (top, bottom) = Self.resolveSplit(
            first: updated[columnIndex].windows[dividerIndex].heightProportion,
            second: updated[columnIndex].windows[dividerIndex + 1].heightProportion,
            delta: proportionalDelta
        ) else { return }

        updated[columnIndex].windows[dividerIndex].heightProportion = top
        updated[columnIndex].windows[dividerIndex + 1].heightProportion = bottom
        columns = updated

        normalizeWindowProportions(inColumn: columnIndex)

        if isActive {
            applyLayoutThrottled()
        }
    }

    // MARK: - Row Mode Resizing

    /// Resize the primary divider between rows (affects row heights)
    func resizeRowPrimaryDivider(atIndex dividerIndex: Int, proportionalDelta: CGFloat) {
        guard dividerIndex >= 0, dividerIndex + 1 < rows.count else { return }

        var updated = rows
        guard let (top, bottom) = Self.resolveSplit(
            first: updated[dividerIndex].heightProportion,
            second: updated[dividerIndex + 1].heightProportion,
            delta: proportionalDelta
        ) else { return }

        updated[dividerIndex].heightProportion = top
        updated[dividerIndex + 1].heightProportion = bottom
        rows = updated

        normalizeRowProportions()

        if isActive {
            applyLayoutThrottled()
        }
    }

    /// Resize a window divider within a row (between windowIndex and windowIndex+1)
    /// This only affects the two adjacent windows in that row
    func resizeWindowDivider(inRow rowIndex: Int, atIndex dividerIndex: Int, proportionalDelta: CGFloat) {
        guard rowIndex >= 0, rowIndex < rows.count else { return }
        guard dividerIndex >= 0, dividerIndex + 1 < rows[rowIndex].windows.count else { return }

        var updated = rows
        guard let (left, right) = Self.resolveSplit(
            first: updated[rowIndex].windows[dividerIndex].widthProportion,
            second: updated[rowIndex].windows[dividerIndex + 1].widthProportion,
            delta: proportionalDelta
        ) else { return }

        updated[rowIndex].windows[dividerIndex].widthProportion = left
        updated[rowIndex].windows[dividerIndex + 1].widthProportion = right
        rows = updated

        normalizeWindowProportions(inRow: rowIndex)

        if isActive {
            applyLayoutThrottled()
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

        // Keep the observer's baseline in step with what we just did, and don't
        // let our own writes bounce back in as user resizes.
        if let layout = currentLayout, layout.isActive {
            updateExpectedFrames(for: layout)
            armEventSuppression(for: layout)
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

                if let window = columnWindow.window {
                    // Single window - position it directly
                    frame = constrainFrame(frame, for: window)

                    // For last column, keep right edge aligned (adjust x if width was constrained)
                    if isLastColumn && frame.width < columnWidth {
                        frame.origin.x = rightEdge - frame.width
                    }

                    // For last window, keep bottom edge aligned (adjust y if height was constrained)
                    if isLastWindow && frame.height < windowHeight {
                        frame.origin.y = bottomEdge
                    }

                    _ = window.setFrame(frame)
                } else if let container = columnWindow.nestedContainer {
                    // Nested container - position all children
                    applyNestedContainerLayout(container: container, in: frame)
                }

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

                if let window = rowWindow.window {
                    // Single window - position it directly
                    frame = constrainFrame(frame, for: window)

                    // For last window in row, keep right edge aligned
                    if isLastWindow && frame.width < windowWidth {
                        frame.origin.x = rightEdge - frame.width
                    }

                    // For last row, keep bottom edge aligned
                    if isLastRow && frame.height < rowHeight {
                        frame.origin.y = bottomEdge
                    }

                    _ = window.setFrame(frame)
                } else if let container = rowWindow.nestedContainer {
                    // Nested container - position all children
                    applyNestedContainerLayout(container: container, in: frame)
                }

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

    /// Apply layout to a nested container within a given frame
    private func applyNestedContainerLayout(container: LayoutContainer, in frame: CGRect) {
        guard !container.children.isEmpty else { return }

        if container.direction == .horizontal {
            // Children arranged left-to-right
            var currentX = frame.minX
            for (index, child) in container.children.enumerated() {
                let isLast = index == container.children.count - 1
                let childWidth = isLast ? (frame.maxX - currentX) : (child.proportion * frame.width)
                let childFrame = CGRect(x: currentX, y: frame.minY, width: childWidth, height: frame.height)

                applyLayoutToNode(child, in: childFrame)
                currentX += childWidth
            }
        } else {
            // Children arranged top-to-bottom
            var currentTop = frame.maxY
            for (index, child) in container.children.enumerated() {
                let isLast = index == container.children.count - 1
                let childHeight = isLast ? (currentTop - frame.minY) : (child.proportion * frame.height)
                let childFrame = CGRect(x: frame.minX, y: currentTop - childHeight, width: frame.width, height: childHeight)

                applyLayoutToNode(child, in: childFrame)
                currentTop -= childHeight
            }
        }
    }

    /// Apply layout to a single layout node (window or container)
    private func applyLayoutToNode(_ node: LayoutNode, in frame: CGRect) {
        switch node {
        case .window(let windowNode):
            let constrainedFrame = constrainFrame(frame, for: windowNode.window)
            _ = windowNode.window.setFrame(constrainedFrame)
        case .container(let nestedContainer):
            applyNestedContainerLayout(container: nestedContainer, in: frame)
        }
    }

    // MARK: - Split Functions for Nested Containers

    /// Split a window cell in a column into a nested container
    func splitColumnCell(columnIndex: Int, windowIndex: Int, direction: SplitDirection) {
        guard columnIndex < columns.count else { return }
        guard windowIndex < columns[columnIndex].windows.count else { return }

        let cell = columns[columnIndex].windows[windowIndex]
        guard let window = cell.window else { return }

        // Create a nested container with the original window
        let windowNode = LayoutWindowNode(window: window, proportion: 0.5)
        let container = LayoutContainer(
            direction: direction,
            children: [.window(windowNode)],
            proportion: 1.0
        )

        // Create the new cell with nested container
        let newCell = ColumnWindow(
            id: cell.id,
            nestedContainer: container,
            heightProportion: cell.heightProportion
        )

        // Force complete struct recreation for SwiftUI change detection
        var newWindows = columns[columnIndex].windows
        newWindows[windowIndex] = newCell
        let newColumn = Column(
            id: columns[columnIndex].id,
            widthProportion: columns[columnIndex].widthProportion,
            windows: newWindows
        )
        var newColumns = columns
        newColumns[columnIndex] = newColumn
        columns = newColumns

        // Force objectWillChange notification
        objectWillChange.send()

        if isActive {
            applyLayout()
        }
    }

    /// Split a window cell in a row into a nested container
    func splitRowCell(rowIndex: Int, windowIndex: Int, direction: SplitDirection) {
        guard rowIndex < rows.count else { return }
        guard windowIndex < rows[rowIndex].windows.count else { return }

        let cell = rows[rowIndex].windows[windowIndex]
        guard let window = cell.window else { return }

        // Create a nested container with the original window
        let windowNode = LayoutWindowNode(window: window, proportion: 0.5)
        let container = LayoutContainer(
            direction: direction,
            children: [.window(windowNode)],
            proportion: 1.0
        )

        // Create the new cell with nested container
        let newCell = RowWindow(
            id: cell.id,
            nestedContainer: container,
            widthProportion: cell.widthProportion
        )

        // Force complete struct recreation for SwiftUI change detection
        var newWindows = rows[rowIndex].windows
        newWindows[windowIndex] = newCell
        let newRow = Row(
            id: rows[rowIndex].id,
            heightProportion: rows[rowIndex].heightProportion,
            windows: newWindows
        )
        var newRows = rows
        newRows[rowIndex] = newRow
        rows = newRows

        // Force objectWillChange notification
        objectWillChange.send()

        if isActive {
            applyLayout()
        }
    }

    /// Add a window to a nested container within a column cell
    func addWindowToColumnNested(columnIndex: Int, windowIndex: Int, window: ExternalWindow) {
        guard columnIndex < columns.count else { return }
        guard windowIndex < columns[columnIndex].windows.count else { return }
        guard var container = columns[columnIndex].windows[windowIndex].nestedContainer else { return }

        // Add window to the container
        let windowNode = LayoutWindowNode(window: window, proportion: 0.5)
        container.children.append(.window(windowNode))
        container.normalizeProportions()

        // Create new cell with updated container
        let cell = columns[columnIndex].windows[windowIndex]
        let newCell = ColumnWindow(
            id: cell.id,
            nestedContainer: container,
            heightProportion: cell.heightProportion
        )

        // Force complete struct recreation for SwiftUI
        var newWindows = columns[columnIndex].windows
        newWindows[windowIndex] = newCell
        let newColumn = Column(
            id: columns[columnIndex].id,
            widthProportion: columns[columnIndex].widthProportion,
            windows: newWindows
        )
        var newColumns = columns
        newColumns[columnIndex] = newColumn
        columns = newColumns

        objectWillChange.send()
        refreshAvailableWindows()

        if isActive {
            applyLayout()
        }
    }

    /// Add a window to a nested container within a row cell
    func addWindowToRowNested(rowIndex: Int, windowIndex: Int, window: ExternalWindow) {
        guard rowIndex < rows.count else { return }
        guard windowIndex < rows[rowIndex].windows.count else { return }
        guard var container = rows[rowIndex].windows[windowIndex].nestedContainer else { return }

        // Add window to the container
        let windowNode = LayoutWindowNode(window: window, proportion: 0.5)
        container.children.append(.window(windowNode))
        container.normalizeProportions()

        // Create new cell with updated container
        let cell = rows[rowIndex].windows[windowIndex]
        let newCell = RowWindow(
            id: cell.id,
            nestedContainer: container,
            widthProportion: cell.widthProportion
        )

        // Force complete struct recreation for SwiftUI
        var newWindows = rows[rowIndex].windows
        newWindows[windowIndex] = newCell
        let newRow = Row(
            id: rows[rowIndex].id,
            heightProportion: rows[rowIndex].heightProportion,
            windows: newWindows
        )
        var newRows = rows
        newRows[rowIndex] = newRow
        rows = newRows

        objectWillChange.send()
        refreshAvailableWindows()

        if isActive {
            applyLayout()
        }
    }

    /// Remove a window from a nested container within a column cell
    func removeWindowFromColumnNested(columnIndex: Int, windowIndex: Int, nestedIndex: Int) {
        guard columnIndex < columns.count else { return }
        guard windowIndex < columns[columnIndex].windows.count else { return }
        guard var container = columns[columnIndex].windows[windowIndex].nestedContainer else { return }
        guard nestedIndex < container.children.count else { return }

        container.children.remove(at: nestedIndex)
        container.normalizeProportions()

        // Force complete array reassignment for SwiftUI
        var updatedColumns = columns
        if container.children.isEmpty {
            // Remove the entire cell if empty
            updatedColumns[columnIndex].windows.remove(at: windowIndex)
            // Normalize remaining proportions
            let count = updatedColumns[columnIndex].windows.count
            if count > 0 {
                let newProportion = 1.0 / CGFloat(count)
                for i in 0..<count {
                    updatedColumns[columnIndex].windows[i].heightProportion = newProportion
                }
            }
        } else if container.children.count == 1, case .window(let node) = container.children[0] {
            // Convert back to a single window cell
            updatedColumns[columnIndex].windows[windowIndex] = ColumnWindow(
                id: updatedColumns[columnIndex].windows[windowIndex].id,
                window: node.window,
                heightProportion: updatedColumns[columnIndex].windows[windowIndex].heightProportion
            )
        } else {
            updatedColumns[columnIndex].windows[windowIndex].nestedContainer = container
        }
        columns = updatedColumns

        refreshAvailableWindows()

        if isActive {
            applyLayout()
        }
    }

    /// Remove a window from a nested container within a row cell
    func removeWindowFromRowNested(rowIndex: Int, windowIndex: Int, nestedIndex: Int) {
        guard rowIndex < rows.count else { return }
        guard windowIndex < rows[rowIndex].windows.count else { return }
        guard var container = rows[rowIndex].windows[windowIndex].nestedContainer else { return }
        guard nestedIndex < container.children.count else { return }

        container.children.remove(at: nestedIndex)
        container.normalizeProportions()

        // Force complete array reassignment for SwiftUI
        var updatedRows = rows
        if container.children.isEmpty {
            // Remove the entire cell if empty
            updatedRows[rowIndex].windows.remove(at: windowIndex)
            // Normalize remaining proportions
            let count = updatedRows[rowIndex].windows.count
            if count > 0 {
                let newProportion = 1.0 / CGFloat(count)
                for i in 0..<count {
                    updatedRows[rowIndex].windows[i].widthProportion = newProportion
                }
            }
        } else if container.children.count == 1, case .window(let node) = container.children[0] {
            // Convert back to a single window cell
            updatedRows[rowIndex].windows[windowIndex] = RowWindow(
                id: updatedRows[rowIndex].windows[windowIndex].id,
                window: node.window,
                widthProportion: updatedRows[rowIndex].windows[windowIndex].widthProportion
            )
        } else {
            updatedRows[rowIndex].windows[windowIndex].nestedContainer = container
        }
        rows = updatedRows

        refreshAvailableWindows()

        if isActive {
            applyLayout()
        }
    }

    /// Resize divider within a nested container in a column (using initial proportions)
    func resizeNestedColumnDividerFromInitial(columnIndex: Int, windowIndex: Int, dividerIndex: Int, initialProp1: CGFloat, initialProp2: CGFloat, delta: CGFloat, containerSize: CGFloat) {
        guard columnIndex < columns.count else { return }
        guard windowIndex < columns[columnIndex].windows.count else { return }
        guard var container = columns[columnIndex].windows[windowIndex].nestedContainer else { return }
        guard dividerIndex < container.children.count - 1 else { return }

        // Calculate proportional delta (scale factor for sensitivity)
        let totalProportion = initialProp1 + initialProp2
        let deltaProportion = (delta / containerSize) * totalProportion * 0.5
        let minProportion: CGFloat = 0.1

        var prop1 = initialProp1 + deltaProportion
        var prop2 = initialProp2 - deltaProportion

        // Clamp proportions
        if prop1 < minProportion {
            prop2 = totalProportion - minProportion
            prop1 = minProportion
        }
        if prop2 < minProportion {
            prop1 = totalProportion - minProportion
            prop2 = minProportion
        }

        container.children[dividerIndex].proportion = prop1
        container.children[dividerIndex + 1].proportion = prop2

        // Force SwiftUI update
        let cell = columns[columnIndex].windows[windowIndex]
        let newCell = ColumnWindow(id: cell.id, nestedContainer: container, heightProportion: cell.heightProportion)
        var newWindows = columns[columnIndex].windows
        newWindows[windowIndex] = newCell
        let newColumn = Column(id: columns[columnIndex].id, widthProportion: columns[columnIndex].widthProportion, windows: newWindows)
        var newColumns = columns
        newColumns[columnIndex] = newColumn
        columns = newColumns

        if isActive {
            applyLayoutThrottled()
        }
    }

    /// Resize divider within a nested container in a row (using initial proportions)
    func resizeNestedRowDividerFromInitial(rowIndex: Int, windowIndex: Int, dividerIndex: Int, initialProp1: CGFloat, initialProp2: CGFloat, delta: CGFloat, containerSize: CGFloat) {
        guard rowIndex < rows.count else { return }
        guard windowIndex < rows[rowIndex].windows.count else { return }
        guard var container = rows[rowIndex].windows[windowIndex].nestedContainer else { return }
        guard dividerIndex < container.children.count - 1 else { return }

        // Calculate proportional delta (scale factor for sensitivity)
        let totalProportion = initialProp1 + initialProp2
        let deltaProportion = (delta / containerSize) * totalProportion * 0.5
        let minProportion: CGFloat = 0.1

        var prop1 = initialProp1 + deltaProportion
        var prop2 = initialProp2 - deltaProportion

        // Clamp proportions
        if prop1 < minProportion {
            prop2 = totalProportion - minProportion
            prop1 = minProportion
        }
        if prop2 < minProportion {
            prop1 = totalProportion - minProportion
            prop2 = minProportion
        }

        container.children[dividerIndex].proportion = prop1
        container.children[dividerIndex + 1].proportion = prop2

        // Force SwiftUI update
        let cell = rows[rowIndex].windows[windowIndex]
        let newCell = RowWindow(id: cell.id, nestedContainer: container, widthProportion: cell.widthProportion)
        var newWindows = rows[rowIndex].windows
        newWindows[windowIndex] = newCell
        let newRow = Row(id: rows[rowIndex].id, heightProportion: rows[rowIndex].heightProportion, windows: newWindows)
        var newRows = rows
        newRows[rowIndex] = newRow
        rows = newRows

        if isActive {
            applyLayoutThrottled()
        }
    }

    // MARK: - Active Management

    func startManaging() {
        guard let layout = currentLayout else { return }
        startManaging(layout: layout)
    }

    /// Start managing a specific layout (used by hotkey preset loading)
    func startManaging(layout: MonitorLayout) {
        // Hide monitor highlight when actively managing
        MonitorHighlightWindow.hide()

        // Placeholder apps (launch-on-load for slots whose app isn't running) were
        // scaffolded here, but the discovery step always returned an empty list, so
        // the launch/wait/rematch machinery could never run. Removed rather than
        // left to rot; it needs a layout model that can hold an unfilled slot.
        finishStartManaging(layout: layout)
    }

    private func finishStartManaging(layout: MonitorLayout) {
        layout.isActive = true
        layout.appState = .active
        objectWillChange.send()

        // Apply initial layout and store expected frames
        applyLayoutAndUpdateExpected(for: layout)

        // Set up event-driven window observation (replaces constant polling)
        setupWindowObserver(for: layout)

        // Shared 1Hz timer handles closed-window detection for every active layout
        startMaintenanceTimerIfNeeded()

        // Notify menu bar
        NotificationCenter.default.post(name: NSNotification.Name("WindowManagerActiveChanged"), object: nil)
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
                    windows.append(contentsOf: colWindow.allWindows)
                }
            }
        case .rows:
            for row in layout.rows {
                for rowWindow in row.windows {
                    windows.append(contentsOf: rowWindow.allWindows)
                }
            }
        }
        return windows
    }

    private func handleWindowEvent(element: AXUIElement, for layout: MonitorLayout) {
        // Drop notifications caused by our own writes — see suppressEventsUntil.
        guard Date() >= layout.suppressEventsUntil else { return }

        // Find which window changed and compare to expected
        guard let currentFrame = ExternalWindow.getFrame(from: element) else { return }

        // Find the window in our layout and check delta
        var changedWindow: (primaryIndex: Int, winIndex: Int, delta: FrameDelta)?

        switch layout.layoutMode {
        case .columns:
            for (colIndex, column) in layout.columns.enumerated() {
                for (winIndex, colWindow) in column.windows.enumerated() {
                    // Check if this is the element that changed
                    if let window = colWindow.window, CFEqual(window.axElement, element) {
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
                    if let window = rowWindow.window, CFEqual(window.axElement, element) {
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

            applyLayoutAndUpdateExpected(for: layout)
        }
    }

    /// Start the shared maintenance timer if it isn't already running.
    ///
    /// This replaces what used to be a 60Hz CVDisplayLink *per monitor*, each of
    /// whose callbacks looped over every active layout — so N monitors cost N²
    /// work per frame, and the once-per-second closed-window check actually ran N
    /// times a second. Everything that needs to be responsive is event-driven via
    /// WindowObserver; all this timer does is notice windows that have gone away,
    /// so 1Hz with generous leeway is plenty and lets the CPU stay asleep.
    /// (CVDisplayLink is also deprecated as of macOS 15.)
    private func startMaintenanceTimerIfNeeded() {
        guard maintenanceTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.maintenanceInterval,
            repeating: Self.maintenanceInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            self?.performMaintenance()
        }
        timer.resume()
        maintenanceTimer = timer
    }

    /// Tear the timer down once nothing is being managed, so an idle menu bar app
    /// schedules no wakeups at all.
    private func stopMaintenanceTimerIfIdle() {
        guard !hasAnyActiveLayout else { return }
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
    }

    private func performMaintenance() {
        for layout in monitorLayouts.values where layout.isActive {
            checkForClosedWindows(in: layout)
        }
    }

    func stopManaging() {
        guard let layout = currentLayout else { return }

        layout.isActive = false
        objectWillChange.send()

        // Stop window observer
        layout.windowObserver?.stopObserving()
        layout.windowObserver = nil

        layout.expectedFrames.removeAll()
        stopMaintenanceTimerIfIdle()

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
        for layout in monitorLayouts.values {
            // Only start if layout has windows configured
            let hasWindows = !layout.columns.isEmpty || !layout.rows.isEmpty
            guard hasWindows else { continue }

            layout.isActive = true
            layout.appState = .active

            // Apply initial layout and store expected frames.
            // applyLayoutAndUpdateExpected applies the layout itself — calling
            // applyLayoutForMonitor first as well meant every start moved every
            // window twice.
            applyLayoutAndUpdateExpected(for: layout)

            // Set up event-driven window observation
            setupWindowObserver(for: layout)
        }
        startMaintenanceTimerIfNeeded()
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

            layout.expectedFrames.removeAll()
        }
        stopMaintenanceTimerIfIdle()
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
                    if let window = colWindow.window {
                        let constrained = constrainFrame(frame, for: window)
                        _ = window.setFrame(constrained)
                    } else if let container = colWindow.nestedContainer {
                        applyNestedContainerLayout(container: container, in: frame)
                    }
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
                    if let window = rowWindow.window {
                        let constrained = constrainFrame(frame, for: window)
                        _ = window.setFrame(constrained)
                    } else if let container = rowWindow.nestedContainer {
                        applyNestedContainerLayout(container: container, in: frame)
                    }
                    currentX += windowWidth
                }
                currentTop -= rowHeight
            }
        }
    }

    private func applyLayoutAndUpdateExpected(for layout: MonitorLayout) {
        applyLayoutForMonitor(layout)
        updateExpectedFrames(for: layout)
        armEventSuppression(for: layout)
    }

    /// Briefly ignore incoming move/resize notifications, so the windows we just
    /// moved don't read back as user edits.
    private func armEventSuppression(for layout: MonitorLayout) {
        layout.suppressEventsUntil = Date().addingTimeInterval(Self.eventSuppressionInterval)
    }

    /// Recompute the frame we believe each managed window now occupies. Incoming
    /// window events are judged against these, so every path that moves windows
    /// has to refresh them — including live divider drags, which previously left
    /// them stale and so made each drag look like a user resize to undo.
    private func updateExpectedFrames(for layout: MonitorLayout) {
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
                    if let window = colWindow.window {
                        expectedFrame = constrainFrame(expectedFrame, for: window)
                        layout.expectedFrames[colWindow.id] = expectedFrame
                    }
                    // TODO: Handle nested container expected frames
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
                    if let window = rowWindow.window {
                        expectedFrame = constrainFrame(expectedFrame, for: window)
                        layout.expectedFrames[rowWindow.id] = expectedFrame
                    }
                    // TODO: Handle nested container expected frames
                    currentX += windowWidth
                }
                currentTop -= rowHeight
            }
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
        // Collect first, mutate afterwards. Removing during the walk invalidates
        // the indices the remaining iterations are about to use, so two windows
        // disappearing at once could delete the wrong column entirely.
        var closedCellIds: [UUID] = []

        for cell in managedCells(in: layout) {
            guard let window = cell.window else { continue }
            // Only treat as closed when the frame is unreadable AND the owning
            // process is gone — AX calls also time out during system sleep, and
            // dropping windows then is what used to empty layouts overnight.
            if ExternalWindow.getFrame(from: window.axElement) == nil,
               kill(window.ownerPID, 0) != 0 {
                closedCellIds.append(cell.id)
            }
            // TODO: Check nested container windows
        }

        guard !closedCellIds.isEmpty else { return }

        for cellId in closedCellIds {
            removeClosedCell(cellId, in: layout)
        }
        refreshAvailableWindows()
        objectWillChange.send()
    }

    /// Every top-level cell in a layout, paired with its window if it holds one.
    private func managedCells(in layout: MonitorLayout) -> [(id: UUID, window: ExternalWindow?)] {
        switch layout.layoutMode {
        case .columns:
            return layout.columns.flatMap { $0.windows.map { (id: $0.id, window: $0.window) } }
        case .rows:
            return layout.rows.flatMap { $0.windows.map { (id: $0.id, window: $0.window) } }
        }
    }

    /// Remove a cell from whichever column/row currently holds it, collapsing the
    /// container if that empties it. Resolves the position by id at call time
    /// rather than trusting an index captured earlier.
    private func removeClosedCell(_ cellId: UUID, in layout: MonitorLayout) {
        switch layout.layoutMode {
        case .columns:
            guard let colIndex = layout.columns.firstIndex(where: { column in
                column.windows.contains { $0.id == cellId }
            }) else { return }

            layout.columns[colIndex].windows.removeAll { $0.id == cellId }

            if layout.columns[colIndex].windows.isEmpty {
                layout.columns.remove(at: colIndex)
                if !layout.columns.isEmpty {
                    let newWidth = 1.0 / CGFloat(layout.columns.count)
                    for i in layout.columns.indices {
                        layout.columns[i].widthProportion = newWidth
                    }
                }
            } else {
                let newProportion = 1.0 / CGFloat(layout.columns[colIndex].windows.count)
                for i in layout.columns[colIndex].windows.indices {
                    layout.columns[colIndex].windows[i].heightProportion = newProportion
                }
            }

        case .rows:
            guard let rowIndex = layout.rows.firstIndex(where: { row in
                row.windows.contains { $0.id == cellId }
            }) else { return }

            layout.rows[rowIndex].windows.removeAll { $0.id == cellId }

            if layout.rows[rowIndex].windows.isEmpty {
                layout.rows.remove(at: rowIndex)
                if !layout.rows.isEmpty {
                    let newHeight = 1.0 / CGFloat(layout.rows.count)
                    for i in layout.rows.indices {
                        layout.rows[i].heightProportion = newHeight
                    }
                }
            } else {
                let newProportion = 1.0 / CGFloat(layout.rows[rowIndex].windows.count)
                for i in layout.rows[rowIndex].windows.indices {
                    layout.rows[rowIndex].windows[i].widthProportion = newProportion
                }
            }
        }
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

    /// Evenly-spaced hue for an app, distributed across the apps in the layout.
    ///
    /// Called from every tile's body on every render, so it must not walk the whole
    /// layout each time — the previous version flat-mapped every window, sorted the
    /// names and hashed them before it even consulted the cache. The palette is now
    /// rebuilt only when the layout revision actually moves.
    func hueForApp(_ appName: String) -> Double {
        if hueCacheRevision != layoutRevision {
            rebuildHuePalette()
        }
        if let cached = hueCache[appName] {
            return cached
        }

        // Not part of the layout (sidebar rows, windows mid-add): derive a stable
        // hue from the name rather than rebuilding the whole palette for it.
        let fallback = Double(abs(appName.hashValue) % 360) / 360.0
        hueCache[appName] = fallback
        return fallback
    }

    private func rebuildHuePalette() {
        hueCacheRevision = layoutRevision
        hueCache.removeAll()

        let appNames: [String]
        switch layoutMode {
        case .columns:
            appNames = columns.flatMap { $0.windows.flatMap { $0.allWindows.map(\.ownerName) } }
        case .rows:
            appNames = rows.flatMap { $0.windows.flatMap { $0.allWindows.map(\.ownerName) } }
        }

        let uniqueApps = Array(Set(appNames)).sorted()
        guard !uniqueApps.isEmpty else { return }
        for (index, name) in uniqueApps.enumerated() {
            hueCache[name] = Double(index) / Double(uniqueApps.count)
        }
    }

    /// Coalescing wrapper around applyLayout for gesture-driven callers.
    func applyLayoutThrottled() {
        guard !pendingApply else { return }

        let elapsed = Date().timeIntervalSince(lastApplyTime)
        guard elapsed < Self.applyThrottleInterval else {
            applyLayout()
            lastApplyTime = Date()
            return
        }

        pendingApply = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.applyThrottleInterval - elapsed)) { [weak self] in
            guard let self else { return }
            self.pendingApply = false
            self.applyLayout()
            self.lastApplyTime = Date()
        }
    }

    // MARK: - Layout Persistence

    private static let savedLayoutsKey = "SavedLayouts"
    private static let monitorPresetsKey = "MonitorPresets_v1"
    private static let workspacePresetsKey = "WorkspacePresets_v1"
    private static let lastUsedLayoutModeKey = "LastUsedLayoutMode"

    /// Load the last used layout mode from UserDefaults
    func loadLastUsedLayoutMode() -> LayoutMode {
        if let modeString = UserDefaults.standard.string(forKey: Self.lastUsedLayoutModeKey),
           let mode = LayoutMode(rawValue: modeString) {
            return mode
        }
        return .columns  // Default to columns
    }

    /// Save the layout mode to UserDefaults
    func saveLayoutMode(_ mode: LayoutMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.lastUsedLayoutModeKey)
    }

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
        guard let layout = currentLayout,
              let monitorId = selectedMonitor?.id else { return }

        let saved = createSavedLayout(from: layout, name: name, presetSlot: presetSlot)

        // Save to named layouts list (for menu)
        var layouts = loadSavedLayoutsList()
        layouts.removeAll { $0.name == name }
        layouts.append(saved)

        if let data = try? JSONEncoder().encode(layouts) {
            UserDefaults.standard.set(data, forKey: Self.savedLayoutsKey)
        }

        // Also save to monitor presets if a slot was assigned (for hotkeys)
        if let slot = presetSlot {
            var presets = loadMonitorPresetsList()
            presets.removeAll { $0.presetSlot == slot && $0.monitorId == monitorId }
            presets.append(saved)

            if let data = try? JSONEncoder().encode(presets) {
                UserDefaults.standard.set(data, forKey: Self.monitorPresetsKey)
            }
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
                    windows: col.windows.compactMap { colWin -> SavedWindowSlot? in
                        guard let window = colWin.window else {
                            // TODO: Handle nested containers in saved layouts
                            return nil
                        }
                        return SavedWindowSlot(
                            ownerName: window.ownerName,
                            windowTitle: window.title,
                            bundleIdentifier: AppLauncher.getBundleIdentifier(for: window.ownerName),
                            proportion: colWin.heightProportion,
                            isPlaceholder: false,
                            frame: window.frame  // Store frame for better matching
                        )
                    }
                )
            } : nil,
            rows: layout.layoutMode == .rows ? layout.rows.map { row in
                SavedRow(
                    heightProportion: row.heightProportion,
                    windows: row.windows.compactMap { rowWin -> SavedWindowSlot? in
                        guard let window = rowWin.window else {
                            // TODO: Handle nested containers in saved layouts
                            return nil
                        }
                        return SavedWindowSlot(
                            ownerName: window.ownerName,
                            windowTitle: window.title,
                            bundleIdentifier: AppLauncher.getBundleIdentifier(for: window.ownerName),
                            proportion: rowWin.widthProportion,
                            isPlaceholder: false,
                            frame: window.frame  // Store frame for better matching
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

    // MARK: - Monitor Presets (⌘⇧1-9 = load for focused window's monitor)

    /// Handle monitor preset LOAD hotkey (⌘⇧1-9): Loads preset for monitor where mouse is
    func handleMonitorPresetLoad(slot: Int) {
        // Use the monitor where the mouse cursor is located
        guard let monitor = getMonitorAtMouseLocation() ?? availableMonitors.first else {
            return
        }

        // Create layout for this monitor if it doesn't exist
        if monitorLayouts[monitor.id] == nil {
            monitorLayouts[monitor.id] = MonitorLayout(monitor: monitor)
        }

        if let existing = getMonitorPreset(slot: slot, monitorId: monitor.id),
           let layout = monitorLayouts[monitor.id] {
            loadLayoutIntoMonitor(saved: existing, layout: layout)
            startManaging(layout: layout)  // Use specific layout, not currentLayout
        }
    }

    func getMonitorPreset(slot: Int, monitorId: String) -> SavedLayout? {
        let presets = loadMonitorPresetsList()
        return presets.first { $0.presetSlot == slot && $0.monitorId == monitorId }
    }

    /// Get names of presets in each slot for the current monitor (for UI display)
    func getMonitorPresetNames() -> [Int: String] {
        guard let monitorId = selectedMonitor?.id else { return [:] }
        let presets = loadMonitorPresetsList().filter { $0.monitorId == monitorId }
        var result: [Int: String] = [:]
        for preset in presets {
            if let slot = preset.presetSlot {
                result[slot] = preset.name
            }
        }
        return result
    }

    /// Get names of workspace presets in each slot (for UI display)
    func getWorkspacePresetNames() -> [Int: String] {
        let workspaces = loadWorkspacesList()
        var result: [Int: String] = [:]
        for workspace in workspaces {
            if let slot = workspace.presetSlot {
                result[slot] = workspace.name
            }
        }
        return result
    }

    // NOTE: saveMonitorPreset/deleteMonitorPreset/loadMonitorPreset(_:into:) used
    // to sit here, all unreachable. loadMonitorPreset was also wrong — it took a
    // monitorId, then called startManaging(), which acts on whichever monitor is
    // *selected*. The live paths are saveCurrentLayout(presetSlot:) for saving and
    // handleMonitorPresetLoad(slot:) for loading; anything new should use those.

    private func loadMonitorPresetsList() -> [SavedLayout] {
        guard let data = UserDefaults.standard.data(forKey: Self.monitorPresetsKey),
              let presets = try? JSONDecoder().decode([SavedLayout].self, from: data) else {
            return []
        }
        return presets
    }

    // MARK: - Workspace Presets (⌘⌥⇧1-9 = load all monitors)

    /// Handle workspace preset LOAD hotkey (⌘⌥⇧1-9): Loads preset for all monitors
    func loadWorkspacePresetBySlot(slot: Int) {
        if let existing = getWorkspacePreset(slot: slot) {
            loadWorkspacePreset(existing)
        }
    }

    func getWorkspacePreset(slot: Int) -> WorkspaceLayout? {
        loadWorkspacesList().first { $0.presetSlot == slot }
    }

    // NOTE: saveWorkspacePreset(slot:) was here and unreachable — a near-duplicate
    // of saveWorkspaceLayout(name:presetSlot:), which is what the Save dialog
    // actually calls. Removed so there's one way to write a workspace preset.

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

        // Fall back to app name matching
        let candidates = availableWindows.filter {
            !usedIds.contains($0.id) && $0.ownerName == slot.ownerName
        }

        // If only one candidate, return it
        if candidates.count == 1 {
            return candidates.first
        }

        // Multiple candidates (e.g., multiple Terminal windows)
        // Use frame proximity to pick the best match
        if candidates.count > 1, let savedFrame = slot.savedFrame {
            return candidates.min(by: { window1, window2 in
                frameDistance(window1.frame, savedFrame) < frameDistance(window2.frame, savedFrame)
            })
        }

        // No saved frame, just return first available
        return candidates.first
    }

    /// Calculate distance between two frames (center-to-center)
    private func frameDistance(_ frame1: CGRect, _ frame2: CGRect) -> CGFloat {
        let center1 = CGPoint(x: frame1.midX, y: frame1.midY)
        let center2 = CGPoint(x: frame2.midX, y: frame2.midY)
        let dx = center1.x - center2.x
        let dy = center1.y - center2.y
        return sqrt(dx * dx + dy * dy)
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

    // Frame position for matching windows with same app name (e.g., multiple Terminal windows)
    let frameX: CGFloat?
    let frameY: CGFloat?
    let frameWidth: CGFloat?
    let frameHeight: CGFloat?

    var savedFrame: CGRect? {
        guard let x = frameX, let y = frameY, let w = frameWidth, let h = frameHeight else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // Backwards compatibility
    init(ownerName: String, windowTitle: String?, bundleIdentifier: String? = nil,
         proportion: CGFloat, isPlaceholder: Bool = false, frame: CGRect? = nil) {
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.bundleIdentifier = bundleIdentifier
        self.proportion = proportion
        self.isPlaceholder = isPlaceholder
        self.frameX = frame?.origin.x
        self.frameY = frame?.origin.y
        self.frameWidth = frame?.width
        self.frameHeight = frame?.height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        proportion = try container.decode(CGFloat.self, forKey: .proportion)
        isPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
        // Frame fields - nil for old saves that don't have them
        frameX = try container.decodeIfPresent(CGFloat.self, forKey: .frameX)
        frameY = try container.decodeIfPresent(CGFloat.self, forKey: .frameY)
        frameWidth = try container.decodeIfPresent(CGFloat.self, forKey: .frameWidth)
        frameHeight = try container.decodeIfPresent(CGFloat.self, forKey: .frameHeight)
    }
}

/// Groups multiple monitor layouts into a single workspace preset
struct WorkspaceLayout: Codable {
    let name: String
    let monitorLayouts: [SavedLayout]
    let presetSlot: Int?            // 1-9 if assigned to a hotkey slot
}
