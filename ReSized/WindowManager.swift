import SwiftUI
import Combine
import CoreVideo

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

/// App state for the setup flow
enum AppState {
    case monitorSelect  // Choosing which monitor
    case setup          // Choosing column count
    case configuring    // Adding windows to columns
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

    @Published var columns: [Column] = []
    @Published var appState: AppState = .setup
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

    var columns: [Column] {
        get { currentLayout?.columns ?? [] }
        set {
            guard let layout = currentLayout else { return }
            layout.columns = newValue
            objectWillChange.send()
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

        // Notify SwiftUI of the change
        objectWillChange.send()
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

    /// Initialize with a specific number of columns
    func setupColumns(count: Int) {
        let proportion = 1.0 / CGFloat(count)
        columns = (0..<count).map { _ in
            Column(widthProportion: proportion, windows: [])
        }
        appState = .configuring
        refreshAvailableWindows()
    }

    /// Scan existing windows on the monitor and build layout from their positions
    func scanExistingLayout() -> Bool {
        guard let monitor = selectedMonitor else { return false }
        guard AccessibilityHelper.checkAccessibilityPermissions() else { return false }

        let allWindows = WindowDiscovery.discoverAllWindows()

        // Filter to windows that overlap with this monitor
        let monitorFrame = monitor.frame
        let windowsOnMonitor = allWindows.filter { window in
            let frame = window.frame
            // Check if window overlaps with monitor (at least 50% on this monitor)
            let intersection = frame.intersection(monitorFrame)
            let overlapArea = intersection.width * intersection.height
            let windowArea = frame.width * frame.height
            return windowArea > 0 && overlapArea / windowArea > 0.5
        }

        guard !windowsOnMonitor.isEmpty else { return false }

        // Sort windows by X position to detect columns
        let sortedByX = windowsOnMonitor.sorted { $0.frame.minX < $1.frame.minX }

        // Group windows into columns (windows with similar X positions)
        var columnGroups: [[ExternalWindow]] = []
        let columnThreshold: CGFloat = 50 // Windows within 50px are in same column

        for window in sortedByX {
            if let lastGroup = columnGroups.last,
               let lastWindow = lastGroup.first,
               abs(window.frame.minX - lastWindow.frame.minX) < columnThreshold {
                // Add to existing column
                columnGroups[columnGroups.count - 1].append(window)
            } else {
                // Start new column
                columnGroups.append([window])
            }
        }

        // Build columns with proportions
        let totalWidth = monitorFrame.width
        var newColumns: [Column] = []

        for group in columnGroups {
            // Sort windows in column by Y (top to bottom in screen coords)
            // Note: higher Y = higher on screen in NSScreen coords
            let sortedByY = group.sorted { $0.frame.maxY > $1.frame.maxY }

            // Calculate column width from first window (they should all be similar)
            let columnWidth = group.first?.frame.width ?? totalWidth / CGFloat(columnGroups.count)
            let widthProportion = columnWidth / totalWidth

            // Build windows with height proportions
            let totalHeight = monitorFrame.height
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
        appState = .configuring
        refreshAvailableWindows()

        return true
    }

    /// Reset to setup state
    func resetSetup() {
        stopManaging()
        columns = []
        appState = .setup
    }

    /// Reset completely to monitor selection
    func resetToMonitorSelect() {
        stopManaging()
        columns = []
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

        // Filter out windows already in columns
        let usedIds = Set(columns.flatMap { $0.windows.map { $0.window.id } })
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

    // MARK: - Layout Application

    /// Apply the current layout to actual windows
    func applyLayout() {
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
                let frame = CGRect(
                    x: currentX,
                    y: currentTop - windowHeight,
                    width: columnWidth,
                    height: windowHeight
                )

                // Respect window's min/max size constraints
                let constrained = constrainFrame(frame, for: columnWindow.window)
                _ = columnWindow.window.setFrame(constrained)

                // Move down for next window
                currentTop -= windowHeight
            }

            currentX += columnWidth
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
    }

    private func applyLayoutAndUpdateExpected(for layout: MonitorLayout) {
        applyLayout()

        // Store what we expect each window's frame to be
        layout.expectedFrames.removeAll()
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
        var changedWindow: (colIndex: Int, winIndex: Int, delta: FrameDelta)?

        for (colIndex, column) in layout.columns.enumerated() {
            for (winIndex, colWindow) in column.windows.enumerated() {
                guard let currentFrame = ExternalWindow.getFrame(from: colWindow.window.axElement),
                      let expected = layout.expectedFrames[colWindow.id] else { continue }

                // Convert expected to AX coordinates for comparison
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

        // Lower threshold since we're synced to display (10px)
        if let change = changedWindow, maxDelta > 10 {
            handleWindowResize(
                in: layout,
                columnIndex: change.colIndex,
                windowIndex: change.winIndex,
                delta: change.delta
            )

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
        for (colIndex, column) in layout.columns.enumerated() {
            for colWindow in column.windows {
                if ExternalWindow.getFrame(from: colWindow.window.axElement) == nil {
                    DispatchQueue.main.async { [weak self] in
                        self?.removeWindow(colWindow.id, fromColumn: colIndex, in: layout)
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

    // MARK: - Helpers

    /// Check if any column has windows
    var hasAnyWindows: Bool {
        columns.contains { !$0.windows.isEmpty }
    }

    /// Total window count
    var totalWindowCount: Int {
        columns.reduce(0) { $0 + $1.windows.count }
    }
}
