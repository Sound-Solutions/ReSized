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
    /// The cell's own identity, deliberately not the window's.
    ///
    /// These used to be the same id. Splitting a cell keeps the cell's id while
    /// moving its window down into the split, so the moment that window was
    /// pulled back out and placed somewhere else, two cells carried the same
    /// id. ForEach then treated them as one — splitting a cell in one column
    /// appeared to split a cell in another — and removeAll(where: id) deleted
    /// both.
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

    // Equality is synthesized. It used to be hand-written and compared only the
    // ids plus the split's child *count* and *first* child's proportion — so
    // resizing the second pane, or swapping two panes, compared equal. SwiftUI
    // skips redrawing a subtree whose inputs compare equal, and views take a
    // Column by value, so those edits reached the model and never the screen.
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

    // Synthesized. Comparing ids alone claimed a column was unchanged whenever
    // its contents changed, which is exactly what a split does to a column.
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
    /// The cell's own identity — see ColumnWindow.id for why it is not the
    /// window's.
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

    // Synthesized — see ColumnWindow for what the hand-written version missed.
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

    // Synthesized — see Column.
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

/// A split holding windows side by side or stacked.
///
/// Children are windows and only windows. A container used to be able to hold
/// another container, but nothing in the UI could build one and the preview
/// rendered it as the literal text "Nested" — so the nesting is gone and the
/// invalid state is now unrepresentable rather than merely unreachable.
struct LayoutContainer: Identifiable, Equatable {
    let id: UUID
    var direction: SplitDirection
    var children: [LayoutWindowNode]
    var proportion: CGFloat

    init(direction: SplitDirection, children: [LayoutWindowNode] = [], proportion: CGFloat = 1.0) {
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

    /// Get all windows in this container
    var allWindows: [ExternalWindow] {
        children.map(\.window)
    }

    /// Drop windows that `isDead` reports as gone. Returns true if anything was
    /// removed, so the caller knows whether to rebuild the cell.
    ///
    /// Closed-window detection only ever walked top-level cells, so a window
    /// closed inside a split stayed in the layout indefinitely.
    mutating func pruneDeadWindows(isDead: (ExternalWindow) -> Bool) -> Bool {
        let surviving = children.filter { !isDead($0.window) }
        guard surviving.count != children.count else { return false }

        children = surviving
        normalizeProportions()
        return true
    }
}

/// Where a window sits in a layout: which column or row, which cell within it,
/// and which pane of that cell's split — `nestedIndex` is nil when the cell
/// holds the window directly.
///
/// Exactly one of `columnIndex`/`rowIndex` is set, matching the layout's mode.
struct WindowSlot: Equatable, Hashable {
    var columnIndex: Int?
    var rowIndex: Int?
    var windowIndex: Int
    var nestedIndex: Int?

    /// The cell this slot lives in — itself for a plain cell, the holder of the
    /// split for a pane.
    var cell: WindowSlot {
        WindowSlot(columnIndex: columnIndex, rowIndex: rowIndex, windowIndex: windowIndex, nestedIndex: nil)
    }
}

/// A draggable boundary on the real desktop.
///
/// The same idea as the preview's LayoutSeam, pointed at screen geometry: where
/// the line is, which divider it moves, and the on-screen extent a drag has to
/// be measured against — the model stores proportions, so pixels mean nothing
/// without knowing what they are a fraction of.
struct DesktopSeam {
    enum Divider {
        /// Between two columns, or two rows, at the top level.
        case primary(index: Int)
        /// Between two cells stacked in a column.
        case cellInColumn(columnIndex: Int, index: Int)
        /// Between two cells side by side in a row.
        case cellInRow(rowIndex: Int, index: Int)
        /// Between two panes of one cell's split.
        case pane(cell: WindowSlot, index: Int)
    }

    var divider: Divider
    /// In screen coordinates, already inset to a grabbable thickness.
    var rect: CGRect
    var isVertical: Bool
    var trackSize: CGFloat
    /// The two proportions this drag redistributes, read when it starts.
    var initialFirst: CGFloat
    var initialSecond: CGFloat
}

/// Where a dragged window will land. Every drop in the preview resolves to one
/// of these — there is no "onto this thing" case, only "at this seam".
enum SeamDestination: Equatable {
    /// A new cell at `index` within a column or row, pushing the rest along.
    case cell(columnIndex: Int?, rowIndex: Int?, index: Int)
    /// A new pane at `index` within the split held by `cell`.
    case pane(cell: WindowSlot, index: Int)
}

/// What is currently being dragged, recorded when the drag starts.
///
/// The drop only needs to know which seam it landed on, so carrying the window
/// in the drag payload and decoding it asynchronously on drop buys nothing.
enum PendingDrag: Equatable {
    /// Something already in the layout, which has to be vacated first.
    case placed(WindowSlot)
    /// Something from the sidebar, identified by ExternalWindow id.
    case available(UUID)
}

/// App state for the setup flow
enum AppState {
    case modeSelect     // First open: choosing layout mode (columns vs rows)
    case monitorSelect  // Choosing which monitor
    case configuring    // Adding windows to layout
    case active         // Layout is active and managing windows
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Represents a monitor/screen
struct Monitor: Identifiable, Equatable {
    let id: String
    /// The pre-existing CGDirectDisplayID-based key. Retained only so presets
    /// saved before identities became stable can still be found.
    let legacyID: String
    let screen: NSScreen
    let name: String
    let frame: CGRect
    let isMain: Bool

    init(screen: NSScreen, index: Int) {
        self.screen = screen
        let displayID = screen.displayID
        self.id = Monitor.stableIdentifier(for: displayID, fallbackIndex: index)
        self.legacyID = "\(displayID.map(String.init) ?? String(index))"
        self.frame = screen.visibleFrame
        // NSScreen.main follows keyboard focus, so it moves as you click between
        // displays. "Main" here means the primary display — the one at the
        // coordinate origin — which is always screens.first.
        self.isMain = screen == NSScreen.screens.first
        // localizedName is non-optional, so the old `as String?` fallbacks below
        // it were unreachable.
        self.name = screen.localizedName
    }

    /// A per-display identity that survives reboots and reconnects.
    ///
    /// This used to be the raw CGDirectDisplayID, which macOS reassigns freely —
    /// so per-monitor presets keyed on it silently stopped matching after you
    /// unplugged a display or restarted, which looked like the presets had been
    /// lost. The display UUID is tied to the physical panel instead.
    static func stableIdentifier(for displayID: CGDirectDisplayID?, fallbackIndex: Int) -> String {
        guard let displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else {
            return "index-\(fallbackIndex)"
        }
        return string
    }

    static func == (lhs: Monitor, rhs: Monitor) -> Bool {
        lhs.id == rhs.id
    }
}

/// Per-monitor layout state
@Observable
class MonitorLayout {
    let monitorId: String
    @ObservationIgnored let screen: NSScreen

    var layoutMode: LayoutMode = .columns
    var columns: [Column] = []  // Used when layoutMode == .columns
    var rows: [Row] = []        // Used when layoutMode == .rows
    var appState: AppState = .modeSelect
    var containerBounds: CGRect = .zero
    var isActive: Bool = false

    /// Bookkeeping for window events, deliberately outside observation. These
    /// churn on every notification while a window is being dragged, and nothing
    /// on screen is drawn from them — observing them would redraw the layout
    /// dozens of times a second for no visible reason.
    @ObservationIgnored var windowObserver: WindowObserver?
    @ObservationIgnored var expectedFrames: [UUID: CGRect] = [:]
    /// The draggable seams drawn over this monitor while the layout is live.
    @ObservationIgnored var seamOverlay: SeamOverlayWindow?

    /// Move/resize notifications caused by our own layout writes arrive on the run
    /// loop *after* the write returns, so a synchronous "am I applying" flag never
    /// sees them and the app reacts to itself. Ignore window events until this
    /// deadline instead. Apps with size increments (Terminal) never land on exactly
    /// the frame we asked for, which is what turned that into a feedback loop:
    /// every apply looked like a user resize and triggered another apply.
    @ObservationIgnored var suppressEventsUntil: Date = .distantPast

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
@Observable
class WindowManager {
    @ObservationIgnored static let shared = WindowManager()

    /// Available monitors
    var availableMonitors: [Monitor] = []

    /// Currently selected/viewed monitor
    var selectedMonitor: Monitor?

    /// Per-monitor layouts
    var monitorLayouts: [String: MonitorLayout] = [:]

    /// All discovered windows available to add
    var availableWindows: [ExternalWindow] = []

    /// Set when a drag begins, read when it lands. Not observed — nothing on
    /// screen is drawn from it.
    @ObservationIgnored var pendingDrag: PendingDrag?

    /// The modifier-drag gesture: the tap that watches for it and the session
    /// for a drag currently in flight. Bookkeeping, nothing rendered.
    @ObservationIgnored var modifierDragMonitor: ModifierDragMonitor?
    @ObservationIgnored var modifierDragSession: ModifierDragSession?

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    /// Cache for app hue colors to avoid expensive recalculation on every render.
    ///
    /// Written from hueForApp, which every tile calls from its body — so this
    /// has to stay outside observation. Observed state mutated during a render
    /// pass is what SwiftUI warns about, and it would invalidate the very views
    /// asking for the colour.
    @ObservationIgnored private var hueCache: [String: Double] = [:]
    @ObservationIgnored private var hueCacheRevision: Int = -1

    /// Bumped whenever the layout's structure changes, so derived caches can tell
    /// they're stale without re-deriving a signature on every single read.
    @ObservationIgnored private var layoutRevision: Int = 0

    /// One low-frequency timer shared by every active layout — see
    /// startMaintenanceTimerIfNeeded() for why this is not a display link.
    @ObservationIgnored private var maintenanceTimer: DispatchSourceTimer?
    private static let maintenanceInterval: TimeInterval = 1.0

    /// How long to ignore window events after we move windows ourselves.
    ///
    /// Short on purpose: this only needs to swallow notifications already in
    /// flight when the write returns. Recognising our own work is expectedFrames'
    /// job now that those hold actual frames rather than requested ones. At 0.25s
    /// this went blind mid-drag and then lurched.
    private static let eventSuppressionInterval: TimeInterval = 0.05

    /// Coalesces reflows while the user is dragging a real window's edge.
    @ObservationIgnored private var reflowWorkItem: DispatchWorkItem?
    private static let reflowDebounceInterval: TimeInterval = 0.12

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
        }
    }

    var layoutMode: LayoutMode {
        get { currentLayout?.layoutMode ?? .columns }
        set {
            guard let layout = currentLayout else { return }
            layout.layoutMode = newValue
            layoutRevision &+= 1
        }
    }

    var columns: [Column] {
        get { currentLayout?.columns ?? [] }
        set {
            guard let layout = currentLayout else { return }
            layout.columns = newValue
            layoutRevision &+= 1
        }
    }

    var rows: [Row] {
        get { currentLayout?.rows ?? [] }
        set {
            guard let layout = currentLayout else { return }
            layout.rows = newValue
            layoutRevision &+= 1
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
        }
    }

    var isActive: Bool {
        get { currentLayout?.isActive ?? false }
        set {
            guard let layout = currentLayout else { return }
            layout.isActive = newValue
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

        // Show highlight ring on the selected monitor (unless actively managing,
        // or the config window isn't even open)
        updateHighlight()

        // Scan windows when switching tabs (if layout is empty and not actively managing)
        if AccessibilityHelper.checkAccessibilityPermissions() && currentLayout?.isActive != true {
            let isEmpty = (currentLayout?.columns.isEmpty ?? true) && (currentLayout?.rows.isEmpty ?? true)
            if isEmpty {
                _ = scanExistingLayout()
            } else {
                // scanExistingLayout refreshes the picker itself; a non-empty
                // layout skipped it entirely, so switching tabs left the sidebar
                // showing whatever it had computed for the previous monitor.
                refreshAvailableWindows()
            }
        }

    }

    /// Whether the config window is currently on screen.
    ///
    /// The highlight ring is a borderless, always-on-top window of our own, so it
    /// has to be tied to the lifetime of the window it belongs to. Closing the
    /// config window used to leave a red rectangle floating over the desktop with
    /// no way to dismiss it short of starting management on that monitor.
    var isConfigWindowVisible = false {
        didSet { updateHighlight() }
    }

    /// Update the highlight ring visibility based on state.
    ///
    /// Single gate for the ring — every show/hide goes through here so the rules
    /// can't drift apart between call sites.
    func updateHighlight() {
        guard isConfigWindowVisible,
              let monitor = selectedMonitor,
              currentLayout?.isActive != true else {
            MonitorHighlightWindow.hide()
            return
        }
        MonitorHighlightWindow.show(on: monitor.screen)
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

        // Populate every monitor now, not lazily when its tab is first clicked
        scanAllMonitorLayouts()

        selectMonitor(monitor)

        // Ensure we're in configuring state (even if no windows found)
        if layoutMode == .columns && columns.isEmpty {
            setupColumns(count: 2)
        } else if layoutMode == .rows && rows.isEmpty {
            setupRows(count: 2)
        }

        appState = .configuring
    }

    /// Scan every connected monitor so all layouts are populated up front.
    ///
    /// Order matters and the sequence is the point: each scan skips windows
    /// already claimed by another monitor's layout, so running them all now is
    /// what makes "this window is taken" correct on every tab. Doing it lazily
    /// meant the answer was only right for tabs you had already clicked, and
    /// looked like the app was waiting for you to start the layout.
    private func scanAllMonitorLayouts() {
        guard AccessibilityHelper.checkAccessibilityPermissions() else { return }

        let previousSelection = selectedMonitor
        for monitor in availableMonitors {
            // scanExistingLayout works on the selected monitor
            selectedMonitor = monitor
            scanExistingLayout(autoSelectMode: true)
        }
        selectedMonitor = previousSelection
    }

    /// Scan all monitors on launch and select the main one
    func scanAllMonitors() {
        guard AccessibilityHelper.checkAccessibilityPermissions() else { return }

        // Create layouts for any monitor that doesn't have one yet
        for monitor in availableMonitors where monitorLayouts[monitor.id] == nil {
            monitorLayouts[monitor.id] = MonitorLayout(monitor: monitor)
        }

        scanAllMonitorLayouts()

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

    private static let edgeTolerance: CGFloat = 20  // Tolerance for edge matching

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
        var touchesLeft = frame.minX <= monitorFrame.minX + Self.edgeTolerance
        var touchesRight = frame.maxX >= monitorFrame.maxX - Self.edgeTolerance
        var touchesTop = frame.minY <= monitorFrame.minY + Self.edgeTolerance
        var touchesBottom = frame.maxY >= monitorFrame.maxY - Self.edgeTolerance

        // Check if touching other windows
        for other in allWindows where other.id != window.id {
            let otherFrame = other.frame

            // Check horizontal adjacency (windows must overlap vertically to be neighbors)
            let verticalOverlap = frame.minY < otherFrame.maxY && frame.maxY > otherFrame.minY
            if verticalOverlap {
                // Window's right edge touches other's left edge
                if isClose(frame.maxX, otherFrame.minX, tolerance: Self.edgeTolerance) {
                    touchesRight = true
                }
                // Window's left edge touches other's right edge
                if isClose(frame.minX, otherFrame.maxX, tolerance: Self.edgeTolerance) {
                    touchesLeft = true
                }
            }

            // Check vertical adjacency (windows must overlap horizontally to be neighbors)
            let horizontalOverlap = frame.minX < otherFrame.maxX && frame.maxX > otherFrame.minX
            if horizontalOverlap {
                // Window's bottom edge touches other's top edge
                if isClose(frame.maxY, otherFrame.minY, tolerance: Self.edgeTolerance) {
                    touchesBottom = true
                }
                // Window's top edge touches other's bottom edge
                if isClose(frame.minY, otherFrame.maxY, tolerance: Self.edgeTolerance) {
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
    private static func maxWindowsHorizontally(_ windows: [ExternalWindow]) -> Int {
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
                if window.frame.minX >= currentColumnMaxX - Self.edgeTolerance {
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
    private static func maxWindowsVertically(_ windows: [ExternalWindow]) -> Int {
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
                if window.frame.minY >= currentRowMaxY - Self.edgeTolerance {
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

    // MARK: - Grouping

    /// Bucket windows into vertical strips by horizontal centre. Shared by the
    /// columns scan and by the mode chooser, so the mode we pick is judged
    /// against the grouping we would actually build.
    static func groupIntoColumns(_ windows: [ExternalWindow], monitorFrameAX: CGRect) -> [[ExternalWindow]] {
        bucket(
            windows.sorted { $0.frame.minX < $1.frame.minX },
            count: maxWindowsHorizontally(windows),
            start: monitorFrameAX.minX,
            end: monitorFrameAX.maxX,
            centre: { ($0.frame.minX + $0.frame.maxX) / 2 }
        )
    }

    /// Bucket windows into horizontal bands by vertical centre.
    static func groupIntoRows(_ windows: [ExternalWindow], monitorFrameAX: CGRect) -> [[ExternalWindow]] {
        bucket(
            windows.sorted { $0.frame.minY < $1.frame.minY },
            count: maxWindowsVertically(windows),
            start: monitorFrameAX.minY,
            end: monitorFrameAX.maxY,
            centre: { ($0.frame.minY + $0.frame.maxY) / 2 }
        )
    }

    private static func bucket(
        _ sorted: [ExternalWindow],
        count: Int,
        start: CGFloat,
        end: CGFloat,
        centre: (ExternalWindow) -> CGFloat
    ) -> [[ExternalWindow]] {
        guard count > 0, end > start else { return sorted.isEmpty ? [] : [sorted] }

        let span = (end - start) / CGFloat(count)
        var groups: [[ExternalWindow]] = Array(repeating: [], count: count)

        for window in sorted {
            let offset = centre(window) - start
            let index = min(max(Int(offset / span), 0), count - 1)
            groups[index].append(window)
        }
        return groups.filter { !$0.isEmpty }
    }

    /// How badly a grouping would have to distort the windows it contains.
    ///
    /// Every member of a column is forced to that column's left and right edges,
    /// so the spread of the members' own edges is exactly how far they must move.
    /// Rows are the mirror image. Lower means the windows are already arranged
    /// that way.
    private static func conformanceCost(_ groups: [[ExternalWindow]], horizontal: Bool) -> CGFloat {
        groups.reduce(0) { total, group in
            guard group.count > 1 else { return total }
            let leading = group.map { horizontal ? $0.frame.minX : $0.frame.minY }
            let trailing = group.map { horizontal ? $0.frame.maxX : $0.frame.maxY }
            let leadSpread = (leading.max() ?? 0) - (leading.min() ?? 0)
            let trailSpread = (trailing.max() ?? 0) - (trailing.min() ?? 0)
            return total + leadSpread + trailSpread
        }
    }

    /// Pick whichever mode the windows already resemble, so applying the layout
    /// moves them as little as possible.
    ///
    /// Columns force every window in a strip to share left/right edges; rows force
    /// every window in a band to share top/bottom edges. Whichever of those the
    /// current arrangement already satisfies is the one that will shove things
    /// around least.
    static func bestFittingLayoutMode(
        for windows: [ExternalWindow],
        monitorFrameAX: CGRect
    ) -> LayoutMode? {
        guard windows.count > 1 else { return nil }

        let columnCost = conformanceCost(
            groupIntoColumns(windows, monitorFrameAX: monitorFrameAX), horizontal: true
        )
        let rowCost = conformanceCost(
            groupIntoRows(windows, monitorFrameAX: monitorFrameAX), horizontal: false
        )

        // Ties keep whatever is already selected — the caller passes nil through.
        guard columnCost != rowCost else { return nil }
        return columnCost < rowCost ? .columns : .rows
    }

    // MARK: - Layout Scanning

    /// Scan existing windows on the monitor and build layout from their positions.
    ///
    /// `autoSelectMode` lets the scan choose columns vs rows from how the windows
    /// are actually arranged, rather than inheriting the last-used mode.
    @discardableResult
    func scanExistingLayout(autoSelectMode: Bool = false) -> Bool {
        guard let monitor = selectedMonitor else { return false }
        guard AccessibilityHelper.checkAccessibilityPermissions() else { return false }

        // Stop any active management first
        stopManaging()

        let allWindows = WindowDiscovery.discoverAllWindows()

        // Convert monitor frame to AX coordinates for comparison
        // Monitor frame is in NSScreen coords (Y=0 at bottom)
        // Window frames are in AX coords (Y=0 at top)
        let monitorFrameAX = convertFrameToAXCoordinates(monitor.frame)

        // A window you have already placed on another monitor is spoken for, even
        // though it is still physically sitting on this one until the layout is
        // started. Without this, switching to a monitor's tab auto-scanned those
        // windows straight back into a second layout.
        let claimedElsewhere = placedWindowIds(excludingMonitor: monitor.id)

        // Filter to windows that overlap with this monitor
        let windowsOnMonitor = allWindows.filter { window in
            guard !claimedElsewhere.contains(window.id) else { return false }
            let frame = window.frame  // Already in AX coordinates
            // Check if window overlaps with monitor (at least 50% on this monitor)
            let intersection = frame.intersection(monitorFrameAX)
            let overlapArea = intersection.width * intersection.height
            let windowArea = frame.width * frame.height
            return windowArea > 0 && overlapArea / windowArea > 0.5
        }

        guard !windowsOnMonitor.isEmpty else { return false }

        // On an automatic scan, let the arrangement pick the mode. Only here —
        // a manual rescan must never override a mode chosen with the header
        // picker, and switching mode empties the layout, which would otherwise
        // make the next scan undo the choice.
        if autoSelectMode {
            // Taken from the arrangement's own first cut rather than a separate
            // heuristic. The two disagreeing is worse than either being wrong:
            // the scan then wraps the whole arrangement in a single primary
            // division to honour the mode, and everything lands in one column.
            let tiled = filterTiledWindows(windowsOnMonitor, monitorFrame: monitorFrameAX)
            if case .split(let vertical, _) = Self.decompose(tiled) {
                layoutMode = vertical ? .columns : .rows
            }
        }

        applyScannedArrangement(windowsOnMonitor, monitor: monitor, asColumns: layoutMode == .columns)

        appState = .configuring
        refreshAvailableWindows()

        return true
    }

    // MARK: - Reading an Arrangement

    /// A window arrangement broken down into nested splits.
    ///
    /// The scanner used to sort windows into columns and stack each one, which
    /// can only ever describe a grid running in a single direction. Anything
    /// with a split in it — two windows side by side filling the lower half of
    /// a column — had nowhere to go, so the split was lost and its windows came
    /// back as ordinary stacked cells at the wrong sizes.
    indirect enum ScanNode {
        case window(ExternalWindow)
        /// Children in order: left to right when vertical, top to bottom when
        /// not.
        case split(vertical: Bool, children: [ScanNode])
        /// Windows that overlap, so no straight cut separates them.
        case tangle([ExternalWindow])
    }

    /// Break an arrangement into nested splits by repeatedly cutting it where
    /// there is a clean gap running all the way across.
    ///
    /// Cutting every gap in one direction at once means the children of a
    /// vertical cut can never be separated vertically again — so the directions
    /// alternate on their own, without being told to.
    static func decompose(_ windows: [ExternalWindow]) -> ScanNode {
        guard windows.count > 1 else {
            return windows.first.map { ScanNode.window($0) } ?? .tangle([])
        }

        if let groups = separate(windows, vertical: true) {
            return .split(vertical: true, children: groups.map(decompose))
        }
        if let groups = separate(windows, vertical: false) {
            return .split(vertical: false, children: groups.map(decompose))
        }
        // Overlapping windows. Nothing here describes a tiling, so the caller
        // lays them out in a stack rather than inventing a structure.
        return .tangle(windows)
    }

    /// Split a set of windows at every gap that no window straddles, or nil if
    /// there is no such gap.
    private static func separate(_ windows: [ExternalWindow], vertical: Bool) -> [[ExternalWindow]]? {
        // AX coordinates put minY at the top, so sorting ascending is
        // left-to-right or top-to-bottom either way.
        let sorted = windows.sorted {
            vertical ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
        guard let first = sorted.first else { return nil }

        var groups: [[ExternalWindow]] = []
        var current = [first]
        var edge = vertical ? first.frame.maxX : first.frame.maxY

        for window in sorted.dropFirst() {
            let start = vertical ? window.frame.minX : window.frame.minY
            if start >= edge - edgeTolerance {
                groups.append(current)
                current = [window]
                edge = vertical ? window.frame.maxX : window.frame.maxY
            } else {
                current.append(window)
                edge = max(edge, vertical ? window.frame.maxX : window.frame.maxY)
            }
        }
        groups.append(current)

        return groups.count > 1 ? groups : nil
    }

    /// Every window under a node, in order.
    static func leaves(of node: ScanNode) -> [ExternalWindow] {
        switch node {
        case .window(let window): return [window]
        case .tangle(let windows): return windows
        case .split(_, let children): return children.flatMap(leaves)
        }
    }

    /// The area a node covers.
    static func bounds(of node: ScanNode) -> CGRect {
        leaves(of: node).reduce(nil) { (accumulated: CGRect?, window) in
            accumulated.map { $0.union(window.frame) } ?? window.frame
        } ?? .zero
    }

    /// Turn a scanned arrangement into a layout.
    ///
    /// Both modes share this: only the axis the primary divisions run along
    /// differs, and the tree already knows its own shape.
    private func applyScannedArrangement(_ windowsOnMonitor: [ExternalWindow], monitor: Monitor, asColumns: Bool) {
        let monitorFrameAX = convertFrameToAXCoordinates(monitor.frame)
        let tiledWindows = filterTiledWindows(windowsOnMonitor, monitorFrame: monitorFrameAX)

        guard !tiledWindows.isEmpty else {
            if asColumns { columns = [] } else { rows = [] }
            return
        }

        var tree = Self.decompose(tiledWindows)

        // The arrangement decides its own first cut, which may not run the way
        // the chosen mode does. Wrapping it in a single primary division keeps
        // the mode the user asked for without misreading the arrangement.
        if case .split(let vertical, _) = tree, vertical != asColumns {
            tree = .split(vertical: asColumns, children: [tree])
        } else if case .window = tree {
            tree = .split(vertical: asColumns, children: [tree])
        } else if case .tangle = tree {
            tree = .split(vertical: asColumns, children: [tree])
        }

        guard case .split(_, let primaries) = tree else { return }
        let area = Self.bounds(of: tree)

        if asColumns {
            columns = primaries.map { primary in
                Column(
                    widthProportion: share(Self.bounds(of: primary).width, of: area.width),
                    windows: columnCells(from: primary, area: area)
                )
            }
            normalizeColumnProportions()
            for index in columns.indices { normalizeWindowProportions(inColumn: index) }
        } else {
            rows = primaries.map { primary in
                Row(
                    heightProportion: share(Self.bounds(of: primary).height, of: area.height),
                    windows: rowCells(from: primary, area: area)
                )
            }
            normalizeRowProportions()
            for index in rows.indices { normalizeWindowProportions(inRow: index) }
        }
    }

    private func share(_ part: CGFloat, of whole: CGFloat) -> CGFloat {
        whole > 0 ? max(0.01, part / whole) : 0
    }

    /// The cells stacked inside one column, and any split each one holds.
    private func columnCells(from primary: ScanNode, area: CGRect) -> [ColumnWindow] {
        let stacked: [ScanNode]
        switch primary {
        case .split(let vertical, let children) where !vertical: stacked = children
        case .tangle(let windows): stacked = windows.map { .window($0) }
        default: stacked = [primary]
        }

        return stacked.map { cell in
            let height = share(Self.bounds(of: cell).height, of: area.height)
            if case .window(let window) = cell {
                return ColumnWindow(window: window, heightProportion: height)
            }
            // Anything else subdivides again, which is a split within the cell.
            // The model holds one level of that, so a deeper arrangement is
            // flattened into it rather than dropped.
            return ColumnWindow(
                nestedContainer: splitContainer(from: cell, direction: .horizontal),
                heightProportion: height
            )
        }
    }

    private func rowCells(from primary: ScanNode, area: CGRect) -> [RowWindow] {
        let sideBySide: [ScanNode]
        switch primary {
        case .split(let vertical, let children) where vertical: sideBySide = children
        case .tangle(let windows): sideBySide = windows.map { .window($0) }
        default: sideBySide = [primary]
        }

        return sideBySide.map { cell in
            let width = share(Self.bounds(of: cell).width, of: area.width)
            if case .window(let window) = cell {
                return RowWindow(window: window, widthProportion: width)
            }
            return RowWindow(
                nestedContainer: splitContainer(from: cell, direction: .vertical),
                widthProportion: width
            )
        }
    }

    /// Build a cell's split from a node that divides further.
    private func splitContainer(from node: ScanNode, direction fallback: SplitDirection) -> LayoutContainer {
        let direction: SplitDirection
        let parts: [ScanNode]
        if case .split(let vertical, let children) = node {
            direction = vertical ? .horizontal : .vertical
            parts = children
        } else {
            direction = fallback
            parts = Self.leaves(of: node).map { .window($0) }
        }

        let area = Self.bounds(of: node)
        var container = LayoutContainer(direction: direction, children: parts.map { part in
            let partArea = Self.bounds(of: part)
            let proportion = direction == .horizontal
                ? share(partArea.width, of: area.width)
                : share(partArea.height, of: area.height)
            // A pane that subdivides again is one level too deep for the model,
            // so its windows are laid side by side in this split instead.
            let window = Self.leaves(of: part).first
            return window.map { LayoutWindowNode(window: $0, proportion: proportion) }
        }.compactMap { $0 })

        // Panes lost to that flattening are appended so no window disappears.
        let kept = Set(container.children.map(\.window.id))
        for window in Self.leaves(of: node) where !kept.contains(window.id) {
            container.children.append(LayoutWindowNode(window: window, proportion: 0.25))
        }

        container.normalizeProportions()
        return container
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
        let placed = placedWindowIds()
        availableWindows = discovered.filter { !placed.contains($0.id) }
    }

    /// Every window currently placed in any monitor's layout, nested splits
    /// included. Placement in the config counts — nothing here waits on the
    /// layout being started.
    ///
    /// Deliberately spans all monitors: a window parked in the layout for another
    /// display is still spoken for, and offering it again invites assigning the
    /// same window to two places at once.
    ///
    /// Only the layout's active mode is counted. Each MonitorLayout keeps both a
    /// columns and a rows array and just one of them is live, so counting both
    /// would reserve windows left behind in whichever mode isn't in use.
    func placedWindowIds(excludingMonitor excludedId: String? = nil) -> Set<UUID> {
        var ids = Set<UUID>()
        for (monitorId, layout) in monitorLayouts where monitorId != excludedId {
            switch layout.layoutMode {
            case .columns:
                for column in layout.columns {
                    for cell in column.windows { ids.formUnion(cell.allWindows.map(\.id)) }
                }
            case .rows:
                for row in layout.rows {
                    for cell in row.windows { ids.formUnion(cell.allWindows.map(\.id)) }
                }
            }
        }
        return ids
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

    /// How much of a requested shift the split can actually absorb.
    ///
    /// Divider handles use this to slide exactly as far as the drag will really
    /// move things, so the line never travels somewhere the layout won't follow.
    static func achievableShift(first: CGFloat, second: CGFloat, requested: CGFloat) -> CGFloat {
        guard let (newFirst, _) = resolveSplit(first: first, second: second, delta: requested) else {
            return 0
        }
        return newFirst - first
    }

    /// Shift `delta` out of the second pane and into the first, clamping at the
    /// minimum rather than rejecting the whole gesture. Returns nil if there
    /// isn't room for two panes at all.
    static func resolveSplit(first: CGFloat, second: CGFloat, delta: CGFloat) -> (CGFloat, CGFloat)? {
        let total = first + second
        guard total > minPaneProportion * 2 else { return nil }
        let clamped = min(max(first + delta, minPaneProportion), total - minPaneProportion)
        return (clamped, total - clamped)
    }

    /// Push the model to the real windows, if any are being managed.
    ///
    /// Every divider now commits on mouse-up rather than during the drag, so
    /// there is no longer an "interactive" state to suppress: by the time any of
    /// these callers run, the gesture is already over.
    private func applyLayoutIfActive() {
        guard isActive else { return }
        applyLayout()
    }

    /// Resize a column divider (between columnIndex and columnIndex+1).
    ///
    /// Takes the proportions captured when the drag began plus the total
    /// translation since, rather than a per-event delta. Absolute beats
    /// incremental here: no accumulated rounding, and dragging back out of a
    /// clamp returns exactly where you started. `proportionalTranslation` is a
    /// fraction of the on-screen track — the caller owns that conversion because
    /// only it knows how big the track is.
    func resizeColumnDivider(
        atIndex dividerIndex: Int,
        initialFirst: CGFloat,
        initialSecond: CGFloat,
        proportionalTranslation: CGFloat
    ) {
        guard dividerIndex >= 0, dividerIndex + 1 < columns.count else { return }

        guard let (left, right) = Self.resolveSplit(
            first: initialFirst,
            second: initialSecond,
            delta: proportionalTranslation
        ) else { return }

        var updated = columns
        updated[dividerIndex].widthProportion = left
        updated[dividerIndex + 1].widthProportion = right
        columns = updated

        normalizeColumnProportions()
        applyLayoutIfActive()
    }

    /// Resize a row divider within a column (between windowIndex and windowIndex+1)
    /// This only affects the two adjacent windows in that column
    func resizeRowDivider(
        inColumn columnIndex: Int,
        atIndex dividerIndex: Int,
        initialFirst: CGFloat,
        initialSecond: CGFloat,
        proportionalTranslation: CGFloat
    ) {
        guard columnIndex >= 0, columnIndex < columns.count else { return }
        guard dividerIndex >= 0, dividerIndex + 1 < columns[columnIndex].windows.count else { return }

        guard let (top, bottom) = Self.resolveSplit(
            first: initialFirst,
            second: initialSecond,
            delta: proportionalTranslation
        ) else { return }

        var updated = columns
        updated[columnIndex].windows[dividerIndex].heightProportion = top
        updated[columnIndex].windows[dividerIndex + 1].heightProportion = bottom
        columns = updated

        normalizeWindowProportions(inColumn: columnIndex)
        applyLayoutIfActive()
    }

    // MARK: - Row Mode Resizing

    /// Resize the primary divider between rows (affects row heights)
    func resizeRowPrimaryDivider(
        atIndex dividerIndex: Int,
        initialFirst: CGFloat,
        initialSecond: CGFloat,
        proportionalTranslation: CGFloat
    ) {
        guard dividerIndex >= 0, dividerIndex + 1 < rows.count else { return }

        guard let (top, bottom) = Self.resolveSplit(
            first: initialFirst,
            second: initialSecond,
            delta: proportionalTranslation
        ) else { return }

        var updated = rows
        updated[dividerIndex].heightProportion = top
        updated[dividerIndex + 1].heightProportion = bottom
        rows = updated

        normalizeRowProportions()
        applyLayoutIfActive()
    }

    /// Resize a window divider within a row (between windowIndex and windowIndex+1)
    /// This only affects the two adjacent windows in that row
    func resizeWindowDivider(
        inRow rowIndex: Int,
        atIndex dividerIndex: Int,
        initialFirst: CGFloat,
        initialSecond: CGFloat,
        proportionalTranslation: CGFloat
    ) {
        guard rowIndex >= 0, rowIndex < rows.count else { return }
        guard dividerIndex >= 0, dividerIndex + 1 < rows[rowIndex].windows.count else { return }

        guard let (left, right) = Self.resolveSplit(
            first: initialFirst,
            second: initialSecond,
            delta: proportionalTranslation
        ) else { return }

        var updated = rows
        updated[rowIndex].windows[dividerIndex].widthProportion = left
        updated[rowIndex].windows[dividerIndex + 1].widthProportion = right
        rows = updated

        normalizeWindowProportions(inRow: rowIndex)
        applyLayoutIfActive()
    }

    // MARK: - Layout Application

    /// Apply the current layout to actual windows.
    ///
    /// This used to have its own copy of the placement maths, separate from
    /// applyLayoutForMonitor — which is how only one of the two ended up pinning
    /// the outer edges. There is now one implementation.
    func applyLayout() {
        guard let layout = currentLayout else { return }
        let placed = applyLayoutForMonitor(layout)

        if layout.isActive {
            layout.expectedFrames = placed
            armEventSuppression(for: layout)
            // The handles are positioned from those frames, so they have to be
            // refreshed by every path that moves windows — not just the one
            // that starts a layout. Without this they stayed wherever they were
            // when the layout began.
            refreshSeamOverlay(for: layout)
            refreshWindowObserver(for: layout)
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

    /// Place a split's panes inside a frame, returning where each one actually
    /// landed, keyed by pane id.
    ///
    /// Those frames are what incoming resize notifications get judged against —
    /// without them a pane's edge drag has no baseline to measure from and is
    /// discarded, which is why seams used to move for a plain window but not for
    /// a window inside a split.
    @discardableResult
    private func applyNestedContainerLayout(container: LayoutContainer, in frame: CGRect) -> [UUID: CGRect] {
        var placed: [UUID: CGRect] = [:]
        guard !container.children.isEmpty else { return placed }

        if container.direction == .horizontal {
            // Children arranged left-to-right
            var currentX = frame.minX
            for (index, child) in container.children.enumerated() {
                let isLast = index == container.children.count - 1
                let childWidth = isLast ? (frame.maxX - currentX) : (child.proportion * frame.width)
                let childFrame = CGRect(x: currentX, y: frame.minY, width: childWidth, height: frame.height)

                let actual = place(child.window, in: childFrame)
                placed[child.id] = actual
                // Butt the next pane against where this one really ended, the
                // same way the top level does, so an app that refuses its width
                // doesn't leave a strip of desktop at the seam.
                currentX += max(actual.width, 0)
            }
        } else {
            // Children arranged top-to-bottom
            var currentTop = frame.maxY
            for (index, child) in container.children.enumerated() {
                let isLast = index == container.children.count - 1
                let childHeight = isLast ? (currentTop - frame.minY) : (child.proportion * frame.height)
                let childFrame = CGRect(x: frame.minX, y: currentTop - childHeight, width: frame.width, height: childHeight)

                let actual = place(child.window, in: childFrame)
                placed[child.id] = actual
                currentTop -= max(actual.height, 0)
            }
        }

        return placed
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
            children: [windowNode],
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
            children: [windowNode],
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
        container.children.append(windowNode)
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
        container.children.append(windowNode)
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
        } else if container.children.count == 1 {
            let node = container.children[0]
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
        } else if container.children.count == 1 {
            let node = container.children[0]
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

    // MARK: - Slot Addressing

    /// The window occupying a slot, whether it sits in the cell directly or in
    /// one of the cell's split panes.
    func window(at slot: WindowSlot) -> ExternalWindow? {
        guard let cell = cell(at: slot) else { return nil }
        guard let nestedIndex = slot.nestedIndex else { return cell.window }
        guard let container = cell.container,
              container.children.indices.contains(nestedIndex) else { return nil }
        return container.children[nestedIndex].window
    }

    /// Put a window into a slot, leaving the slot's size and identity alone.
    /// Does nothing if the slot doesn't exist or names a pane of a cell that
    /// holds no split.
    private func setWindow(_ window: ExternalWindow, at slot: WindowSlot) {
        guard let cell = cell(at: slot) else { return }

        if let nestedIndex = slot.nestedIndex {
            guard var container = cell.container,
                  container.children.indices.contains(nestedIndex) else { return }
            container.children[nestedIndex].window = window
            setNestedContainer(
                container,
                columnIndex: slot.columnIndex,
                rowIndex: slot.rowIndex,
                windowIndex: slot.windowIndex
            )
            return
        }

        guard cell.window != nil else { return }
        if let columnIndex = slot.columnIndex {
            var updated = columns
            updated[columnIndex].windows[slot.windowIndex].window = window
            columns = updated
        } else if let rowIndex = slot.rowIndex {
            var updated = rows
            updated[rowIndex].windows[slot.windowIndex].window = window
            rows = updated
        }
    }

    /// The cell a slot addresses, if the indices are still in range.
    private func cell(at slot: WindowSlot) -> (window: ExternalWindow?, container: LayoutContainer?)? {
        if let columnIndex = slot.columnIndex,
           columns.indices.contains(columnIndex),
           columns[columnIndex].windows.indices.contains(slot.windowIndex) {
            let cell = columns[columnIndex].windows[slot.windowIndex]
            return (cell.window, cell.nestedContainer)
        }
        if let rowIndex = slot.rowIndex,
           rows.indices.contains(rowIndex),
           rows[rowIndex].windows.indices.contains(slot.windowIndex) {
            let cell = rows[rowIndex].windows[slot.windowIndex]
            return (cell.window, cell.nestedContainer)
        }
        return nil
    }


    /// Pull a window out of the split it lives in and hand it back.
    ///
    /// The cell collapses to a plain window when one pane is left, and is
    /// removed outright when none is — so a split never lingers as an empty
    /// box after its contents are dragged elsewhere. Returns nil for a slot
    /// that doesn't name a pane.
    @discardableResult
    private func extractNestedWindow(at slot: WindowSlot) -> ExternalWindow? {
        guard let nestedIndex = slot.nestedIndex,
              var container = nestedContainer(
                  columnIndex: slot.columnIndex,
                  rowIndex: slot.rowIndex,
                  windowIndex: slot.windowIndex
              ),
              container.children.indices.contains(nestedIndex)
        else { return nil }

        let extracted = container.children.remove(at: nestedIndex).window
        container.normalizeProportions()

        if container.children.isEmpty {
            removeCell(at: slot)
        } else if container.children.count == 1 {
            collapseCellToWindow(container.children[0].window, at: slot)
        } else {
            setNestedContainer(
                container,
                columnIndex: slot.columnIndex,
                rowIndex: slot.rowIndex,
                windowIndex: slot.windowIndex
            )
        }

        return extracted
    }

    /// Take the window at a slot out of the layout and hand it back, ready to be
    /// placed elsewhere. Panes come out of their split; a plain cell is removed
    /// from its column or row.
    func takeWindow(at slot: WindowSlot) -> ExternalWindow? {
        if slot.nestedIndex != nil {
            return extractNestedWindow(at: slot)
        }
        guard let window = window(at: slot) else { return nil }
        removeCell(at: slot)
        return window
    }


    /// Put the seam handles on screen for a live layout, and keep them where
    /// the windows are.
    ///
    /// Rebuilt after every apply rather than tracked incrementally: the frames
    /// they are derived from are refreshed by the same pass, so recomputing is
    /// both simpler and impossible to get out of step.
    func refreshSeamOverlay(for layout: MonitorLayout) {
        guard layout.isActive else {
            hideSeamOverlay(for: layout)
            return
        }

        if layout.seamOverlay == nil {
            // The live screen if the monitor is still connected, otherwise the
            // one captured when the layout was made.
            let screen = availableMonitors.first { $0.id == layout.monitorId }?.screen ?? layout.screen
            let overlay = SeamOverlayWindow(screen: screen)
            overlay.seamView?.onDrag = { [weak self] seam, translation in
                self?.dragDesktopSeam(seam, proportionalTranslation: translation)
            }
            overlay.seamView?.isPointExposed = { [weak self, weak layout] point in
                guard let self, let layout else { return true }
                return self.isSeamPointExposed(point, in: layout)
            }
            overlay.orderFront(nil)
            layout.seamOverlay = overlay
        }

        layout.seamOverlay?.seamView?.seams = desktopSeams(for: layout)
    }

    func hideSeamOverlay(for layout: MonitorLayout) {
        layout.seamOverlay?.orderOut(nil)
        layout.seamOverlay = nil
    }

    /// Whether a screen point over a live layout is actually showing that
    /// layout, or is covered by some unmanaged window floating above it.
    ///
    /// Asked by the seam overlay before it draws, changes the cursor, or takes
    /// a click — the panel sits above every ordinary window, so this is the
    /// only thing standing between the seams and rendering straight through a
    /// window that happens to be on top of the tiled ones.
    private func isSeamPointExposed(_ screenPoint: CGPoint, in layout: MonitorLayout) -> Bool {
        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return true }

        let managedIDs = Set(getAllManagedWindows(in: layout).compactMap(\.windowID))
        guard !managedIDs.isEmpty else { return true }

        // Our own chrome never occludes: the seam overlays themselves and the
        // monitor highlight ring. The config window is deliberately not in this
        // set — it is a real window, and seams should not draw through it.
        let ownChrome = Set(NSApp.windows.compactMap { window -> CGWindowID? in
            guard window is SeamOverlayWindow || window is MonitorHighlightWindow,
                  window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })

        // CGWindowList bounds are in global top-left coordinates; NSScreen's
        // are bottom-left. Both share the primary display's origin.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)

        // The entries come front-to-back. The seam is exposed unless the
        // topmost window under the point is an unmanaged one sitting in front
        // of the layout — an unmanaged window *behind* every managed one is
        // just the usual view through the gap between tiles, and must not make
        // the seam ungrabbable.
        var unmanagedHit = false
        for entry in entries {
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  !ownChrome.contains(number),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  // Below the cursor's own window and the screen-saver shields,
                  // which contain every point and would occlude everything.
                  layer < Int(CGWindowLevelForKey(.screenSaverWindow))
            else { continue }

            if unmanagedHit {
                if managedIDs.contains(number) { return false }
                continue
            }

            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(cgPoint) else { continue }

            if managedIDs.contains(number) { return true }
            unmanagedHit = true
        }
        return true
    }

    /// Union that tolerates a missing first term, for folding a list of frames.
    private func union(_ accumulated: CGRect?, _ next: CGRect) -> CGRect {
        accumulated.map { $0.union(next) } ?? next
    }

    // MARK: - Desktop Seams

    /// How thick a seam is to grab, in points. Wide enough to hit without
    /// aiming, and it is drawn at this width so there is nothing to aim at
    /// other than what you can see.
    static let seamGrabThickness: CGFloat = 12

    /// Every draggable boundary in a live layout, positioned from where the
    /// windows actually are.
    ///
    /// Derived from expectedFrames rather than recomputed from the proportions,
    /// for the same reason the preview derives its seams from the tiles' real
    /// frames: apps refuse the sizes they are given, and a handle drawn where a
    /// window was *asked* to be would sit off the edge it is supposed to move.
    func desktopSeams(for layout: MonitorLayout) -> [DesktopSeam] {
        var seams: [DesktopSeam] = []
        let bounds = layout.containerBounds
        guard bounds.width > 0, bounds.height > 0 else { return seams }

        func frame(_ id: UUID) -> CGRect? { layout.expectedFrames[id] }

        /// The area a cell covers.
        ///
        /// Only plain cells have a frame recorded against their own id — a
        /// split cell's windows are recorded against the panes. Reading the
        /// cell id alone therefore came back empty for every split, and every
        /// seam with a split on either side of it was skipped.
        func cellArea(_ id: UUID, _ container: LayoutContainer?) -> CGRect? {
            if let direct = frame(id) { return direct }
            guard let container else { return nil }
            return container.children.compactMap { frame($0.id) }.reduce(nil, union)
        }

        /// The seam between two adjacent frames, centred on the gap between
        /// them so it stays grabbable even when they are flush.
        func seam(
            between first: CGRect,
            and second: CGRect,
            vertical: Bool,
            divider: DesktopSeam.Divider,
            trackSize: CGFloat,
            proportions: (CGFloat, CGFloat)
        ) -> DesktopSeam {
            let half = Self.seamGrabThickness / 2
            let rect: CGRect
            if vertical {
                let x = (first.maxX + second.minX) / 2
                let top = max(first.maxY, second.maxY)
                let bottom = min(first.minY, second.minY)
                rect = CGRect(x: x - half, y: bottom, width: Self.seamGrabThickness, height: max(0, top - bottom))
            } else {
                // Screen coordinates grow upward, so the earlier sibling in a
                // column is the higher one.
                let y = (first.minY + second.maxY) / 2
                let left = min(first.minX, second.minX)
                let right = max(first.maxX, second.maxX)
                rect = CGRect(x: left, y: y - half, width: max(0, right - left), height: Self.seamGrabThickness)
            }
            return DesktopSeam(
                divider: divider, rect: rect, isVertical: vertical, trackSize: trackSize,
                initialFirst: proportions.0, initialSecond: proportions.1
            )
        }

        /// Seams between the panes of one cell's split.
        func paneSeams(for container: LayoutContainer, cell: WindowSlot) {
            let vertical = container.direction == .horizontal
            let track = splitTrackSize(in: layout, slot: cell, direction: container.direction)
            guard track > 0 else { return }

            for index in 0..<max(0, container.children.count - 1) {
                guard let a = frame(container.children[index].id),
                      let b = frame(container.children[index + 1].id) else { continue }
                seams.append(seam(
                    between: a, and: b, vertical: vertical,
                    divider: .pane(cell: cell, index: index),
                    trackSize: track,
                    proportions: (container.children[index].proportion,
                                  container.children[index + 1].proportion)
                ))
            }
        }

        switch layout.layoutMode {
        case .columns:
            for (columnIndex, column) in layout.columns.enumerated() {
                for (cellIndex, cell) in column.windows.enumerated() {
                    if let container = cell.nestedContainer {
                        paneSeams(for: container, cell: WindowSlot(
                            columnIndex: columnIndex, rowIndex: nil, windowIndex: cellIndex, nestedIndex: nil
                        ))
                    }
                    let next = cellIndex + 1 < column.windows.count ? column.windows[cellIndex + 1] : nil
                    guard let next,
                          let a = cellArea(cell.id, cell.nestedContainer),
                          let b = cellArea(next.id, next.nestedContainer) else { continue }
                    seams.append(seam(
                        between: a, and: b, vertical: false,
                        divider: .cellInColumn(columnIndex: columnIndex, index: cellIndex),
                        trackSize: bounds.height,
                        proportions: (cell.heightProportion, next.heightProportion)
                    ))
                }

                guard columnIndex + 1 < layout.columns.count,
                      let a = columnBounds(layout.columns[columnIndex], frame),
                      let b = columnBounds(layout.columns[columnIndex + 1], frame) else { continue }
                seams.append(seam(
                    between: a, and: b, vertical: true,
                    divider: .primary(index: columnIndex),
                    trackSize: bounds.width,
                    proportions: (column.widthProportion, layout.columns[columnIndex + 1].widthProportion)
                ))
            }

        case .rows:
            for (rowIndex, row) in layout.rows.enumerated() {
                for (cellIndex, cell) in row.windows.enumerated() {
                    if let container = cell.nestedContainer {
                        paneSeams(for: container, cell: WindowSlot(
                            columnIndex: nil, rowIndex: rowIndex, windowIndex: cellIndex, nestedIndex: nil
                        ))
                    }
                    let next = cellIndex + 1 < row.windows.count ? row.windows[cellIndex + 1] : nil
                    guard let next,
                          let a = cellArea(cell.id, cell.nestedContainer),
                          let b = cellArea(next.id, next.nestedContainer) else { continue }
                    seams.append(seam(
                        between: a, and: b, vertical: true,
                        divider: .cellInRow(rowIndex: rowIndex, index: cellIndex),
                        trackSize: bounds.width,
                        proportions: (cell.widthProportion, next.widthProportion)
                    ))
                }

                guard rowIndex + 1 < layout.rows.count,
                      let a = rowBounds(layout.rows[rowIndex], frame),
                      let b = rowBounds(layout.rows[rowIndex + 1], frame) else { continue }
                seams.append(seam(
                    between: a, and: b, vertical: false,
                    divider: .primary(index: rowIndex),
                    trackSize: bounds.height,
                    proportions: (row.heightProportion, layout.rows[rowIndex + 1].heightProportion)
                ))
            }
        }

        return seams
    }

    /// The area a column covers, as the union of what its cells actually got.
    private func columnBounds(_ column: Column, _ frame: (UUID) -> CGRect?) -> CGRect? {
        column.windows.compactMap { cell -> CGRect? in
            frame(cell.id) ?? cell.nestedContainer?.children.compactMap { frame($0.id) }.reduce(nil, union)
        }.reduce(nil, union)
    }

    private func rowBounds(_ row: Row, _ frame: (UUID) -> CGRect?) -> CGRect? {
        row.windows.compactMap { cell -> CGRect? in
            frame(cell.id) ?? cell.nestedContainer?.children.compactMap { frame($0.id) }.reduce(nil, union)
        }.reduce(nil, union)
    }

    /// Apply a divider drag that started on the desktop, in the same terms the
    /// preview's handles use.
    func dragDesktopSeam(_ seam: DesktopSeam, proportionalTranslation: CGFloat) {
        switch seam.divider {
        case .primary(let index):
            switch layoutMode {
            case .columns:
                resizeColumnDivider(atIndex: index, initialFirst: seam.initialFirst,
                                    initialSecond: seam.initialSecond,
                                    proportionalTranslation: proportionalTranslation)
            case .rows:
                resizeRowPrimaryDivider(atIndex: index, initialFirst: seam.initialFirst,
                                        initialSecond: seam.initialSecond,
                                        proportionalTranslation: proportionalTranslation)
            }

        case .cellInColumn(let columnIndex, let index):
            resizeRowDivider(inColumn: columnIndex, atIndex: index, initialFirst: seam.initialFirst,
                             initialSecond: seam.initialSecond,
                             proportionalTranslation: proportionalTranslation)

        case .cellInRow(let rowIndex, let index):
            resizeWindowDivider(inRow: rowIndex, atIndex: index, initialFirst: seam.initialFirst,
                                initialSecond: seam.initialSecond,
                                proportionalTranslation: proportionalTranslation)

        case .pane(let cell, let index):
            if let columnIndex = cell.columnIndex {
                resizeNestedColumnDividerFromInitial(
                    columnIndex: columnIndex, windowIndex: cell.windowIndex, dividerIndex: index,
                    initialProp1: seam.initialFirst, initialProp2: seam.initialSecond,
                    proportionalTranslation: proportionalTranslation
                )
            } else if let rowIndex = cell.rowIndex {
                resizeNestedRowDividerFromInitial(
                    rowIndex: rowIndex, windowIndex: cell.windowIndex, dividerIndex: index,
                    initialProp1: seam.initialFirst, initialProp2: seam.initialSecond,
                    proportionalTranslation: proportionalTranslation
                )
            }
        }
    }

    // MARK: - Seam Placement

    /// Put the dragged window at a seam.
    ///
    /// This is the only way anything is placed in the preview. A drop is never
    /// "onto" a cell — it is always at a boundary, and whatever is already there
    /// moves aside. That keeps one rule for every case: out of a split into its
    /// own cell, past a split, between two cells, or into a split alongside its
    /// panes.
    func place(_ drag: PendingDrag, at destination: SeamDestination) {
        switch drag {
        case .available(let windowId):
            guard let window = availableWindows.first(where: { $0.id == windowId }) else { return }
            insert(window, at: destination)

        case .placed(let source):
            // A cell that is already exactly where the seam would put it, and a
            // pane dropped back at its own boundary, both mean "no change" —
            // but taking the window out first would renumber everything, so
            // these are checked before anything moves.
            guard !isNoOp(moving: source, to: destination) else { return }

            // Shuffling panes within one split is a reorder, not a move. Taking
            // the window out first would drain a two-pane split to one, which
            // collapses the cell to a plain window — and then there is no split
            // left to put it back into.
            if case .pane(let cell, let index) = destination,
               source.nestedIndex != nil, source.cell == cell {
                reorderPane(in: cell, from: source.nestedIndex ?? 0, toSeam: index)
                return
            }

            // A pane destination names its cell by index, and lifting the
            // source out can renumber the cells — so remember which cell it
            // meant, and find it again once the source is gone.
            var destinationCellId: UUID?
            if case .pane(let cell, _) = destination {
                destinationCellId = cellId(at: cell)
                guard destinationCellId != nil else { return }
            }

            let adjusted = destinationAfterVacating(source, destination)
            guard let window = takeWindow(at: source) else { return }

            var landing = adjusted
            if case .pane(_, let index) = adjusted,
               let destinationCellId,
               let current = slot(ofCell: destinationCellId) {
                landing = .pane(cell: current, index: index)
            }
            insert(window, at: landing)
        }
    }

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

    /// Move a pane to a different position within its own split.
    ///
    /// `toSeam` is a boundary index — n+1 of them for n panes — so dropping
    /// after the last pane is index n, one past the last valid pane position.
    private func reorderPane(in cell: WindowSlot, from: Int, toSeam: Int) {
        guard var container = nestedContainer(
                  columnIndex: cell.columnIndex, rowIndex: cell.rowIndex, windowIndex: cell.windowIndex
              ),
              container.children.indices.contains(from)
        else { return }

        let pane = container.children.remove(at: from)
        // Removing shifts everything after it down one.
        let landing = max(0, min(toSeam > from ? toSeam - 1 : toSeam, container.children.count))
        container.children.insert(pane, at: landing)

        setNestedContainer(
            container,
            columnIndex: cell.columnIndex,
            rowIndex: cell.rowIndex,
            windowIndex: cell.windowIndex
        )
        applyLayoutIfActive()
    }

    private func insert(_ window: ExternalWindow, at destination: SeamDestination) {
        switch destination {
        case .cell(let columnIndex, let rowIndex, let index):
            if let columnIndex {
                addWindow(window, toColumn: columnIndex, atIndex: index)
            } else if let rowIndex {
                addWindow(window, toRow: rowIndex, atIndex: index)
            }

        case .pane(let cell, let index):
            insertPane(window, intoSplitAt: cell, at: index)
        }
    }

    /// Add a window to a split at a given position among its panes, giving it
    /// an equal share and shrinking the others to make room.
    private func insertPane(_ window: ExternalWindow, intoSplitAt cell: WindowSlot, at index: Int) {
        guard var container = nestedContainer(
            columnIndex: cell.columnIndex, rowIndex: cell.rowIndex, windowIndex: cell.windowIndex
        ) else {
            // The split went away between the window being lifted out and put
            // back — it is already out of the layout at this point, so put it
            // down beside where the split was rather than dropping it entirely.
            insert(window, at: .cell(
                columnIndex: cell.columnIndex, rowIndex: cell.rowIndex, index: cell.windowIndex
            ))
            return
        }

        let share = 1.0 / CGFloat(container.children.count + 1)
        for i in container.children.indices {
            container.children[i].proportion *= (1 - share)
        }
        let landing = max(0, min(index, container.children.count))
        container.children.insert(LayoutWindowNode(window: window, proportion: share), at: landing)
        container.normalizeProportions()

        setNestedContainer(
            container,
            columnIndex: cell.columnIndex,
            rowIndex: cell.rowIndex,
            windowIndex: cell.windowIndex
        )
        refreshAvailableWindows()
        applyLayoutIfActive()
    }

    /// Whether moving `source` to `destination` would leave the layout exactly
    /// as it is. Worth catching: the alternative is a take-and-replace that
    /// renumbers cells and makes the preview jump for no reason.
    private func isNoOp(moving source: WindowSlot, to destination: SeamDestination) -> Bool {
        switch destination {
        case .cell(let columnIndex, let rowIndex, let index):
            guard source.nestedIndex == nil,
                  source.columnIndex == columnIndex,
                  source.rowIndex == rowIndex
            else { return false }
            return index == source.windowIndex || index == source.windowIndex + 1

        case .pane(let cell, let index):
            guard let nestedIndex = source.nestedIndex,
                  source.columnIndex == cell.columnIndex,
                  source.rowIndex == cell.rowIndex,
                  source.windowIndex == cell.windowIndex
            else { return false }
            return index == nestedIndex || index == nestedIndex + 1
        }
    }

    /// The same seam, renumbered for the layout that exists once the source has
    /// been lifted out.
    ///
    /// Taking a window out can remove a cell or a pane that sits before the
    /// seam, which shifts everything after it down one. Collapsing a split to a
    /// single pane leaves the cell in place and shifts nothing, so this compares
    /// what actually happens rather than assuming either.
    private func destinationAfterVacating(_ source: WindowSlot, _ destination: SeamDestination) -> SeamDestination {
        switch destination {
        case .cell(let columnIndex, let rowIndex, let index):
            // Only a plain cell being lifted out removes a cell; a pane leaving
            // a split of three leaves the cell behind.
            let sameContainer = source.columnIndex == columnIndex && source.rowIndex == rowIndex
            let removesACell = source.nestedIndex == nil
                || paneCount(at: source) == 1
            guard sameContainer, removesACell, source.windowIndex < index else { return destination }
            return .cell(columnIndex: columnIndex, rowIndex: rowIndex, index: index - 1)

        case .pane(let cell, let index):
            guard let nestedIndex = source.nestedIndex,
                  source.columnIndex == cell.columnIndex,
                  source.rowIndex == cell.rowIndex,
                  source.windowIndex == cell.windowIndex,
                  nestedIndex < index
            else { return destination }
            return .pane(cell: cell, index: index - 1)
        }
    }

    private func paneCount(at slot: WindowSlot) -> Int {
        nestedContainer(
            columnIndex: slot.columnIndex, rowIndex: slot.rowIndex, windowIndex: slot.windowIndex
        )?.children.count ?? 0
    }


    private func cellCount(columnIndex: Int?, rowIndex: Int?) -> Int {
        if let columnIndex, columns.indices.contains(columnIndex) {
            return columns[columnIndex].windows.count
        }
        if let rowIndex, rows.indices.contains(rowIndex) {
            return rows[rowIndex].windows.count
        }
        return 0
    }

    /// The id of the cell a slot addresses — stable across the reindexing that
    /// removing another cell causes.
    private func cellId(at slot: WindowSlot) -> UUID? {
        if let columnIndex = slot.columnIndex,
           columns.indices.contains(columnIndex),
           columns[columnIndex].windows.indices.contains(slot.windowIndex) {
            return columns[columnIndex].windows[slot.windowIndex].id
        }
        if let rowIndex = slot.rowIndex,
           rows.indices.contains(rowIndex),
           rows[rowIndex].windows.indices.contains(slot.windowIndex) {
            return rows[rowIndex].windows[slot.windowIndex].id
        }
        return nil
    }

    /// Where a cell currently sits, looked up by id.
    private func slot(ofCell id: UUID) -> WindowSlot? {
        for (columnIndex, column) in columns.enumerated() {
            if let windowIndex = column.windows.firstIndex(where: { $0.id == id }) {
                return WindowSlot(columnIndex: columnIndex, rowIndex: nil, windowIndex: windowIndex, nestedIndex: nil)
            }
        }
        for (rowIndex, row) in rows.enumerated() {
            if let windowIndex = row.windows.firstIndex(where: { $0.id == id }) {
                return WindowSlot(columnIndex: nil, rowIndex: rowIndex, windowIndex: windowIndex, nestedIndex: nil)
            }
        }
        return nil
    }

    /// Undo a split, keeping the window that is already sitting in it.
    ///
    /// Only meaningful while the split still holds a single pane, which is
    /// exactly when the empty half — and the close button offering this — is on
    /// screen. A split that has been filled is unmade by closing its panes
    /// instead; the last one standing collapses the cell on its own.
    func unsplitCell(columnIndex: Int?, rowIndex: Int?, windowIndex: Int) {
        guard let container = nestedContainer(
                  columnIndex: columnIndex, rowIndex: rowIndex, windowIndex: windowIndex
              ),
              container.children.count == 1
        else { return }

        collapseCellToWindow(
            container.children[0].window,
            at: WindowSlot(
                columnIndex: columnIndex,
                rowIndex: rowIndex,
                windowIndex: windowIndex,
                nestedIndex: nil
            )
        )
        applyLayoutIfActive()
    }

    /// Replace a cell's split with a single window, keeping the cell's id and
    /// share of the column or row.
    private func collapseCellToWindow(_ window: ExternalWindow, at slot: WindowSlot) {
        if let columnIndex = slot.columnIndex, columns.indices.contains(columnIndex),
           columns[columnIndex].windows.indices.contains(slot.windowIndex) {
            var updated = columns
            let cell = updated[columnIndex].windows[slot.windowIndex]
            updated[columnIndex].windows[slot.windowIndex] = ColumnWindow(
                id: cell.id, window: window, heightProportion: cell.heightProportion
            )
            columns = updated
        } else if let rowIndex = slot.rowIndex, rows.indices.contains(rowIndex),
                  rows[rowIndex].windows.indices.contains(slot.windowIndex) {
            var updated = rows
            let cell = updated[rowIndex].windows[slot.windowIndex]
            updated[rowIndex].windows[slot.windowIndex] = RowWindow(
                id: cell.id, window: window, widthProportion: cell.widthProportion
            )
            rows = updated
        }
    }

    /// Drop a cell from its column or row and re-share the space between what
    /// is left. The column or row itself survives even if it empties — the user
    /// is mid-drag and an empty column is a legitimate drop target.
    private func removeCell(at slot: WindowSlot) {
        if let columnIndex = slot.columnIndex, columns.indices.contains(columnIndex),
           columns[columnIndex].windows.indices.contains(slot.windowIndex) {
            var updated = columns
            updated[columnIndex].windows.remove(at: slot.windowIndex)
            let count = updated[columnIndex].windows.count
            if count > 0 {
                for i in 0..<count {
                    updated[columnIndex].windows[i].heightProportion = 1.0 / CGFloat(count)
                }
            }
            columns = updated
        } else if let rowIndex = slot.rowIndex, rows.indices.contains(rowIndex),
                  rows[rowIndex].windows.indices.contains(slot.windowIndex) {
            var updated = rows
            updated[rowIndex].windows.remove(at: slot.windowIndex)
            let count = updated[rowIndex].windows.count
            if count > 0 {
                for i in 0..<count {
                    updated[rowIndex].windows[i].widthProportion = 1.0 / CGFloat(count)
                }
            }
            rows = updated
        }
    }

    // MARK: - Nested Container Access

    /// Read the split held by a cell, addressed the same way in either mode.
    private func nestedContainer(columnIndex: Int?, rowIndex: Int?, windowIndex: Int) -> LayoutContainer? {
        if let columnIndex, columns.indices.contains(columnIndex),
           columns[columnIndex].windows.indices.contains(windowIndex) {
            return columns[columnIndex].windows[windowIndex].nestedContainer
        }
        if let rowIndex, rows.indices.contains(rowIndex),
           rows[rowIndex].windows.indices.contains(windowIndex) {
            return rows[rowIndex].windows[windowIndex].nestedContainer
        }
        return nil
    }

    private func setNestedContainer(
        _ container: LayoutContainer,
        columnIndex: Int?,
        rowIndex: Int?,
        windowIndex: Int
    ) {
        if let columnIndex, columns.indices.contains(columnIndex),
           columns[columnIndex].windows.indices.contains(windowIndex) {
            var updated = columns
            let cell = updated[columnIndex].windows[windowIndex]
            updated[columnIndex].windows[windowIndex] = ColumnWindow(
                id: cell.id, nestedContainer: container, heightProportion: cell.heightProportion
            )
            columns = updated
        } else if let rowIndex, rows.indices.contains(rowIndex),
                  rows[rowIndex].windows.indices.contains(windowIndex) {
            var updated = rows
            let cell = updated[rowIndex].windows[windowIndex]
            updated[rowIndex].windows[windowIndex] = RowWindow(
                id: cell.id, nestedContainer: container, widthProportion: cell.widthProportion
            )
            rows = updated
        }
    }

    /// Resize a divider inside a nested container in a column.
    ///
    /// `proportionalTranslation` is the total drag since the gesture began, as a
    /// fraction of the container's on-screen size. This used to take raw pixels
    /// against a hardcoded containerSize of 200 and then scale by an arbitrary
    /// 0.5, so sensitivity had no relationship to how big the split actually was.
    func resizeNestedColumnDividerFromInitial(
        columnIndex: Int,
        windowIndex: Int,
        dividerIndex: Int,
        initialProp1: CGFloat,
        initialProp2: CGFloat,
        proportionalTranslation: CGFloat
    ) {
        guard columnIndex < columns.count else { return }
        guard windowIndex < columns[columnIndex].windows.count else { return }
        guard var container = columns[columnIndex].windows[windowIndex].nestedContainer else { return }
        guard dividerIndex >= 0, dividerIndex + 1 < container.children.count else { return }

        guard let (prop1, prop2) = Self.resolveSplit(
            first: initialProp1,
            second: initialProp2,
            delta: proportionalTranslation
        ) else { return }

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

        applyLayoutIfActive()
    }

    /// Resize a divider inside a nested container in a row. See the column
    /// variant above for why this takes a proportion rather than pixels.
    func resizeNestedRowDividerFromInitial(
        rowIndex: Int,
        windowIndex: Int,
        dividerIndex: Int,
        initialProp1: CGFloat,
        initialProp2: CGFloat,
        proportionalTranslation: CGFloat
    ) {
        guard rowIndex < rows.count else { return }
        guard windowIndex < rows[rowIndex].windows.count else { return }
        guard var container = rows[rowIndex].windows[windowIndex].nestedContainer else { return }
        guard dividerIndex >= 0, dividerIndex + 1 < container.children.count else { return }

        guard let (prop1, prop2) = Self.resolveSplit(
            first: initialProp1,
            second: initialProp2,
            delta: proportionalTranslation
        ) else { return }

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

        applyLayoutIfActive()
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

        // Apply initial layout and store expected frames. This also registers
        // the windows for event-driven observation, which replaces polling.
        applyLayoutAndUpdateExpected(for: layout)

        // Shared 1Hz timer handles closed-window detection for every active layout
        startMaintenanceTimerIfNeeded()
        startModifierDragMonitorIfNeeded()

        // Notify menu bar
        NotificationCenter.default.post(name: NSNotification.Name("WindowManagerActiveChanged"), object: nil)
    }

    /// Point the layout's observer at whatever windows it holds right now.
    ///
    /// Registration used to happen once, when the layout started, so a window
    /// added to a running layout produced no move/resize notifications at all:
    /// its seam handles went stale and dragging its edge did nothing. This runs
    /// from every path that applies a layout instead, and is cheap to repeat —
    /// the observer diffs its own registrations, so an unchanged window set
    /// costs a scan and nothing else.
    private func refreshWindowObserver(for layout: MonitorLayout) {
        guard layout.isActive else { return }

        let windows = getAllManagedWindows(in: layout)
        guard !windows.isEmpty else {
            layout.windowObserver?.stopObserving()
            layout.windowObserver = nil
            return
        }

        if layout.windowObserver == nil {
            layout.windowObserver = WindowObserver { [weak self, weak layout] element, notification in
                guard let self = self, let layout = layout, layout.isActive else { return }
                if notification == kAXWindowMiniaturizedNotification as String
                    || notification == kAXWindowDeminiaturizedNotification as String {
                    // Minimize hands the window's space to its neighbours;
                    // restore takes it back. The apply pass itself skips
                    // minimized windows, so reflowing is all there is to do.
                    self.applyLayoutAndUpdateExpected(for: layout)
                    return
                }
                self.handleWindowEvent(element: element, for: layout)
            }
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

        // Find which window changed and compare to expected. No frame usually
        // means the window just closed — the destroyed notification lands here
        // — so run the closed-window sweep now rather than leaving the hole on
        // screen until the maintenance timer next fires. The sweep re-checks
        // with the window server, so a mere AX timeout removes nothing.
        guard let currentFrame = ExternalWindow.getFrame(from: element) else {
            AccessibilityHelper.logDebug("event with unreadable frame -> sweep (destroyed notification or AX timeout)")
            checkForClosedWindows(in: layout)
            return
        }

        guard let found = locate(element: element, in: layout),
              let expected = layout.expectedFrames[found.frameKey],
              let delta = detectFrameChange(
                  from: convertFrameToAXCoordinates(expected),
                  to: currentFrame
              )
        else { return }

        // A window dragged by its title bar keeps its size and changes only its
        // position. There is no way to refuse that — nothing can stop another
        // app's window being dragged — so put it straight back instead, before
        // it is left sitting on top of its neighbours.
        //
        // This has to be handled on its own. Moving shifts both edges by the
        // same amount, so the resize handlers see no change in width or height,
        // adjust nothing, and leave the window wherever it was dropped.
        if isMove(delta) {
            // A modifier-drag in flight owns exactly one window; scope the
            // suppression to it so every other window in the layout still
            // snaps back if it drifts. Release decides this one's fate.
            if modifierDragSession?.confirmedWindowDrag == true,
               found.window.windowID == modifierDragSession?.windowID {
                return
            }
            reflowWorkItem?.cancel()
            applyLayoutAndUpdateExpected(for: layout)
            return
        }

        if found.slot.nestedIndex != nil {
            handleNestedWindowResize(in: layout, slot: found.slot, delta: delta)
        } else {
            switch layout.layoutMode {
            case .columns:
                handleWindowResize(in: layout, columnIndex: found.slot.columnIndex ?? 0,
                                   windowIndex: found.slot.windowIndex, delta: delta)
            case .rows:
                handleRowWindowResize(in: layout, rowIndex: found.slot.rowIndex ?? 0,
                                      windowIndex: found.slot.windowIndex, delta: delta)
            }
        }

        // Re-baseline this window right now, against where it actually is.
        //
        // handleWindowResize ADDS the delta to the current proportion, and the
        // reflow that refreshes every expected frame is debounced — so without
        // this, every event during a drag measures from the same stale baseline
        // and adds it again: 10px, then 20px, then 30px. The window ends up
        // nowhere near where the mouse was released.
        layout.expectedFrames[found.frameKey] = convertFrameFromAXCoordinates(currentFrame)

        scheduleReflow(for: layout)
    }

    /// Find where an AX element sits in a layout — cells and split panes alike.
    ///
    /// `frameKey` is what expectedFrames stores this window's last known frame
    /// under: a cell's own id for a plain window, the pane's id for a window
    /// inside a split. `window` is the matched ExternalWindow itself, so
    /// callers can identify which real window this event belongs to without
    /// a second traversal.
    private func locate(
        element: AXUIElement,
        in layout: MonitorLayout
    ) -> (slot: WindowSlot, frameKey: UUID, window: ExternalWindow)? {
        func search(
            _ cells: [(id: UUID, window: ExternalWindow?, container: LayoutContainer?)],
            _ slotAt: (Int, Int?) -> WindowSlot
        ) -> (slot: WindowSlot, frameKey: UUID, window: ExternalWindow)? {
            for (windowIndex, cell) in cells.enumerated() {
                if let window = cell.window, CFEqual(window.axElement, element) {
                    return (slotAt(windowIndex, nil), cell.id, window)
                }
                guard let container = cell.container else { continue }
                for (nestedIndex, pane) in container.children.enumerated()
                where CFEqual(pane.window.axElement, element) {
                    return (slotAt(windowIndex, nestedIndex), pane.id, pane.window)
                }
            }
            return nil
        }

        switch layout.layoutMode {
        case .columns:
            for (columnIndex, column) in layout.columns.enumerated() {
                let cells = column.windows.map { (id: $0.id, window: $0.window, container: $0.nestedContainer) }
                if let hit = search(cells, { windowIndex, nestedIndex in
                    WindowSlot(columnIndex: columnIndex, rowIndex: nil,
                               windowIndex: windowIndex, nestedIndex: nestedIndex)
                }) {
                    return hit
                }
            }
        case .rows:
            for (rowIndex, row) in layout.rows.enumerated() {
                let cells = row.windows.map { (id: $0.id, window: $0.window, container: $0.nestedContainer) }
                if let hit = search(cells, { windowIndex, nestedIndex in
                    WindowSlot(columnIndex: nil, rowIndex: rowIndex,
                               windowIndex: windowIndex, nestedIndex: nestedIndex)
                }) {
                    return hit
                }
            }
        }
        return nil
    }

    /// Reflow the rest of the layout once the user stops dragging a real window's
    /// edge, rather than on every notification.
    ///
    /// Dragging a window edge emits a stream of resize notifications, and
    /// re-applying the whole layout on each one meant every other window was
    /// commanded to move dozens of times a second while you dragged — the same
    /// reason divider drags now only commit on release.
    private func scheduleReflow(for layout: MonitorLayout) {
        reflowWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self, weak layout] in
            guard let self, let layout, layout.isActive else { return }
            self.applyLayoutAndUpdateExpected(for: layout)
        }
        reflowWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reflowDebounceInterval, execute: item)
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

        // Stop window observer
        layout.windowObserver?.stopObserving()
        layout.windowObserver = nil
        hideSeamOverlay(for: layout)

        layout.expectedFrames.removeAll()
        stopMaintenanceTimerIfIdle()
        stopModifierDragMonitorIfIdle()

        // Show highlight again when not actively managing — but only if the
        // config window is actually open. Stopping from the menu bar with no
        // window on screen should not paint a ring on the desktop.
        updateHighlight()

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
            // This also registers the windows for event-driven observation.
            applyLayoutAndUpdateExpected(for: layout)
        }
        startMaintenanceTimerIfNeeded()
        startModifierDragMonitorIfNeeded()
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
            hideSeamOverlay(for: layout)

            layout.expectedFrames.removeAll()
        }
        stopMaintenanceTimerIfIdle()
        stopModifierDragMonitorIfIdle()
        MonitorHighlightWindow.hide()
        NotificationCenter.default.post(name: NSNotification.Name("WindowManagerActiveChanged"), object: nil)
    }

    /// Set a window's frame and report what it actually became, in the same
    /// NSScreen coordinate space the layout maths uses.
    ///
    /// Apps routinely refuse the size they are handed — Terminal snaps to
    /// character cells, plenty of apps have minimum widths, some are fixed
    /// aspect. Callers use the real result to butt the next pane against this
    /// one instead of leaving the shortfall as a visible gap.
    private func place(_ window: ExternalWindow, in frame: CGRect) -> CGRect {
        let target = constrainFrame(frame, for: window)
        window.setFrame(target)

        guard let actualAX = ExternalWindow.getFrame(from: window.axElement) else { return target }
        return convertFrameFromAXCoordinates(actualAX)
    }

    /// Apply a layout to real windows, returning the frame each cell's window
    /// actually ended up with, keyed by cell id.
    ///
    /// Panes are placed in order, and each starts where the previous one really
    /// ended rather than where it was asked to end. The old version advanced by
    /// the requested size no matter what the app did with it, so any shortfall
    /// became a permanent gap at the seam.
    /// The layout minus its minimized windows, proportions re-shared so the
    /// space they gave up is actually used. The real model is untouched —
    /// cells keep their place and proportion, so restoring a window puts it
    /// straight back where it was.
    private func visibleColumns(of layout: MonitorLayout) -> [Column] {
        var visible: [Column] = []
        for column in layout.columns {
            var cells: [ColumnWindow] = []
            for cell in column.windows {
                if let window = cell.window {
                    if !window.isCurrentlyMinimized { cells.append(cell) }
                } else if var container = cell.nestedContainer {
                    container.children = container.children.filter { !$0.window.isCurrentlyMinimized }
                    guard !container.children.isEmpty else { continue }
                    container.normalizeProportions()
                    var copy = cell
                    copy.nestedContainer = container
                    cells.append(copy)
                }
            }
            guard !cells.isEmpty else { continue }
            let sum = cells.reduce(0) { $0 + $1.heightProportion }
            if sum > 0 {
                for i in cells.indices { cells[i].heightProportion /= sum }
            }
            visible.append(Column(id: column.id, widthProportion: column.widthProportion, windows: cells))
        }
        let widthSum = visible.reduce(0) { $0 + $1.widthProportion }
        if widthSum > 0 {
            for i in visible.indices { visible[i].widthProportion /= widthSum }
        }
        return visible
    }

    /// Row twin of visibleColumns(of:).
    private func visibleRows(of layout: MonitorLayout) -> [Row] {
        var visible: [Row] = []
        for row in layout.rows {
            var cells: [RowWindow] = []
            for cell in row.windows {
                if let window = cell.window {
                    if !window.isCurrentlyMinimized { cells.append(cell) }
                } else if var container = cell.nestedContainer {
                    container.children = container.children.filter { !$0.window.isCurrentlyMinimized }
                    guard !container.children.isEmpty else { continue }
                    container.normalizeProportions()
                    var copy = cell
                    copy.nestedContainer = container
                    cells.append(copy)
                }
            }
            guard !cells.isEmpty else { continue }
            let sum = cells.reduce(0) { $0 + $1.widthProportion }
            if sum > 0 {
                for i in cells.indices { cells[i].widthProportion /= sum }
            }
            visible.append(Row(id: row.id, heightProportion: row.heightProportion, windows: cells))
        }
        let heightSum = visible.reduce(0) { $0 + $1.heightProportion }
        if heightSum > 0 {
            for i in visible.indices { visible[i].heightProportion /= heightSum }
        }
        return visible
    }

    @discardableResult
    private func applyLayoutForMonitor(_ layout: MonitorLayout) -> [UUID: CGRect] {
        let bounds = layout.containerBounds
        var placed: [UUID: CGRect] = [:]
        guard bounds.width > 0, bounds.height > 0 else { return placed }

        switch layout.layoutMode {
        case .columns:
            let columns = visibleColumns(of: layout)
            var currentX = bounds.minX

            for (colIndex, column) in columns.enumerated() {
                let isLastColumn = (colIndex == columns.count - 1)
                let intendedWidth = isLastColumn
                    ? max(0, bounds.maxX - currentX)
                    : column.widthProportion * bounds.width

                var currentTop = bounds.maxY
                var columnWidth: CGFloat = 0

                for (winIndex, cell) in column.windows.enumerated() {
                    let isLastWindow = (winIndex == column.windows.count - 1)
                    let intendedHeight = isLastWindow
                        ? max(0, currentTop - bounds.minY)
                        : cell.heightProportion * bounds.height

                    let frame = CGRect(
                        x: currentX,
                        y: currentTop - intendedHeight,
                        width: intendedWidth,
                        height: intendedHeight
                    )

                    if let window = cell.window {
                        var actual = place(window, in: frame)

                        // Pin the outer edges both ways: an app that cannot
                        // FILL the last slot is pushed flush to the screen edge
                        // rather than leaving desktop showing, and one that
                        // cannot SHRINK to it (Finder's minimum height) is
                        // pulled back on screen rather than hanging off the
                        // bottom — it overlaps its neighbour instead, which at
                        // least stays visible.
                        var adjusted = actual
                        if isLastColumn, actual.width != intendedWidth {
                            adjusted.origin.x = bounds.maxX - actual.width
                        }
                        if isLastWindow, actual.height != intendedHeight {
                            adjusted.origin.y = bounds.minY
                        }
                        if adjusted.origin != actual.origin {
                            window.setFrame(adjusted)
                            actual = adjusted
                        }

                        placed[cell.id] = actual
                        currentTop -= actual.height
                        columnWidth = max(columnWidth, actual.width)
                    } else if let container = cell.nestedContainer {
                        placed.merge(applyNestedContainerLayout(container: container, in: frame)) { _, new in new }
                        currentTop -= intendedHeight
                        columnWidth = max(columnWidth, intendedWidth)
                    }
                }

                currentX += (columnWidth > 0 ? columnWidth : intendedWidth)
            }

        case .rows:
            let rows = visibleRows(of: layout)
            var currentTop = bounds.maxY

            for (rowIndex, row) in rows.enumerated() {
                let isLastRow = (rowIndex == rows.count - 1)
                let intendedHeight = isLastRow
                    ? max(0, currentTop - bounds.minY)
                    : row.heightProportion * bounds.height

                var currentX = bounds.minX
                var rowHeight: CGFloat = 0

                for (winIndex, cell) in row.windows.enumerated() {
                    let isLastWindow = (winIndex == row.windows.count - 1)
                    let intendedWidth = isLastWindow
                        ? max(0, bounds.maxX - currentX)
                        : cell.widthProportion * bounds.width

                    let frame = CGRect(
                        x: currentX,
                        y: currentTop - intendedHeight,
                        width: intendedWidth,
                        height: intendedHeight
                    )

                    if let window = cell.window {
                        var actual = place(window, in: frame)

                        // Same both-ways edge pinning as the columns pass.
                        var adjusted = actual
                        if isLastWindow, actual.width != intendedWidth {
                            adjusted.origin.x = bounds.maxX - actual.width
                        }
                        if isLastRow, actual.height != intendedHeight {
                            adjusted.origin.y = bounds.minY
                        }
                        if adjusted.origin != actual.origin {
                            window.setFrame(adjusted)
                            actual = adjusted
                        }

                        placed[cell.id] = actual
                        currentX += actual.width
                        rowHeight = max(rowHeight, actual.height)
                    } else if let container = cell.nestedContainer {
                        placed.merge(applyNestedContainerLayout(container: container, in: frame)) { _, new in new }
                        currentX += intendedWidth
                        rowHeight = max(rowHeight, intendedHeight)
                    }
                }

                currentTop -= (rowHeight > 0 ? rowHeight : intendedHeight)
            }
        }

        return placed
    }

    func applyLayoutAndUpdateExpected(for layout: MonitorLayout) {
        // expectedFrames now holds what the windows ACTUALLY became, not what we
        // asked for. Incoming notifications are judged against these, so an app
        // that lands slightly off (size increments) no longer reads as a user
        // resize and no longer triggers a corrective re-apply.
        layout.expectedFrames = applyLayoutForMonitor(layout)
        armEventSuppression(for: layout)
        refreshSeamOverlay(for: layout)
        refreshWindowObserver(for: layout)
    }

    /// Briefly ignore incoming move/resize notifications, so the windows we just
    /// moved don't read back as user edits.
    ///
    /// This only has to cover notifications already in flight when we finish
    /// writing — recognising our own work is expectedFrames' job. It was long
    /// enough to be a problem: while you dragged a real window's edge the app
    /// went blind for a quarter second and then lurched to catch up.
    private func armEventSuppression(for layout: MonitorLayout) {
        layout.suppressEventsUntil = Date().addingTimeInterval(Self.eventSuppressionInterval)
    }

    /// Convert NSScreen frame to AX coordinates for comparison
    func convertFrameToAXCoordinates(_ frame: CGRect) -> CGRect {
        guard let mainScreen = NSScreen.screens.first else { return frame }
        let screenHeight = mainScreen.frame.height
        let axY = screenHeight - frame.origin.y - frame.height
        return CGRect(x: frame.origin.x, y: axY, width: frame.width, height: frame.height)
    }

    /// The Y flip is its own inverse; this exists so call sites read as intent.
    func convertFrameFromAXCoordinates(_ frame: CGRect) -> CGRect {
        convertFrameToAXCoordinates(frame)
    }

    private func checkForClosedWindows(in layout: MonitorLayout) {
        // The window server "forgets" the whole session's windows while the
        // screen is locked or the session is off-console — one blackout
        // reported five live Terminal windows gone in the same second and the
        // sweep dismantled their layout. Believe nothing it says until it can
        // at least see a window we own.
        guard windowServerIsTrustworthy() else { return }

        // Collect first, mutate afterwards. Removing during the walk invalidates
        // the indices the remaining iterations are about to use, so two windows
        // disappearing at once could delete the wrong column entirely.
        var closedCellIds: [UUID] = []
        var prunedNested = false

        for cell in managedCells(in: layout) {
            if let window = cell.window {
                if isWindowGone(window) {
                    closedCellIds.append(cell.id)
                }
            } else if cell.hasNestedContainer {
                // Splits are pruned in place; the cell only dies if it empties.
                if pruneNestedCell(cell.id, in: layout, isDead: isWindowGone) {
                    prunedNested = true
                    if nestedCellIsEmpty(cell.id, in: layout) {
                        closedCellIds.append(cell.id)
                    }
                }
            }
        }

        guard !closedCellIds.isEmpty || prunedNested else { return }

        AccessibilityHelper.logDebug("prune: removing \(closedCellIds.count) cell(s), prunedNested=\(prunedNested), reflowing")

        for cellId in closedCellIds {
            removeClosedCell(cellId, in: layout)
        }
        refreshAvailableWindows()

        // The survivors inherit the freed space. Pruning used to stop at the
        // model, so closing a window left a hole on screen until something else
        // happened to re-apply the layout.
        applyLayoutAndUpdateExpected(for: layout)
    }

    /// One window's description straight from the window server, nil when the
    /// server doesn't know the id.
    ///
    /// CGWindowListCreateDescriptionFromArray requires a callback-free CFArray
    /// whose elements ARE the ids cast to pointers. A Swift-bridged NSNumber
    /// array type-checks, compiles, and returns an empty array for every
    /// window that exists — which read as "closed" for live windows and
    /// dismantled layouts on every AX hiccup. Verified empirically on macOS
    /// 26.3: bridged form 0 entries for an on-screen window, this form 1, and
    /// 0 for a bogus id. Nothing else may call the API directly.
    func windowServerDescription(of windowID: CGWindowID) -> [String: Any]? {
        var pointer = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard pointer != nil else { return nil }
        let array = CFArrayCreate(nil, &pointer, 1, nil)
        let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        return descriptions?.first
    }

    /// Whether the window server's answers can be believed right now.
    ///
    /// Locked or off-console sessions get empty answers for every window in
    /// them — indistinguishable, window by window, from the window genuinely
    /// being closed. Two checks: the session says it is on console and
    /// unlocked, and the server can describe one of our own overlay panels
    /// (which we know exists). If it can't see ours, it can't be trusted
    /// about anyone else's.
    private func windowServerIsTrustworthy() -> Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole {
                AccessibilityHelper.logDebug("sweep skipped: session off console")
                return false
            }
            if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked {
                AccessibilityHelper.logDebug("sweep skipped: screen locked")
                return false
            }
        }

        guard let sentinel = monitorLayouts.values
            .first(where: { $0.isActive })?.seamOverlay?.windowNumber,
            sentinel > 0
        else { return true }

        if windowServerDescription(of: CGWindowID(sentinel)) == nil {
            AccessibilityHelper.logDebug("sweep skipped: window server cannot see our own overlay")
            return false
        }
        return true
    }

    /// A window counts as gone only when its frame is unreadable AND either the
    /// owning process is dead or the window server no longer knows the window.
    ///
    /// The process check alone missed the everyday case — closing one window of
    /// an app that keeps running. The extra question is asked of the window
    /// server rather than the app deliberately: AX calls time out during system
    /// sleep and app hangs, and treating a timeout as "closed" is what used to
    /// empty layouts overnight. The server still lists the window through both.
    private func isWindowGone(_ window: ExternalWindow) -> Bool {
        guard ExternalWindow.getFrame(from: window.axElement) == nil else { return false }
        if kill(window.ownerPID, 0) != 0 {
            AccessibilityHelper.logDebug("gone(pid-dead): \(window.ownerName) '\(window.title)' wid=\(window.windowID.map(String.init) ?? "nil")")
            return true
        }

        guard let windowID = window.windowID else {
            AccessibilityHelper.logDebug("frame unreadable, kept (no wid): \(window.ownerName) '\(window.title)'")
            return false
        }
        if windowServerDescription(of: windowID) == nil {
            AccessibilityHelper.logDebug("gone(server): \(window.ownerName) '\(window.title)' wid=\(windowID)")
            return true
        }
        AccessibilityHelper.logDebug("frame unreadable, kept (server alive): \(window.ownerName) '\(window.title)' wid=\(windowID)")
        return false
    }

    /// Every top-level cell in a layout, paired with its window if it holds one.
    private func managedCells(
        in layout: MonitorLayout
    ) -> [(id: UUID, window: ExternalWindow?, hasNestedContainer: Bool)] {
        switch layout.layoutMode {
        case .columns:
            return layout.columns.flatMap { column in
                column.windows.map { (id: $0.id, window: $0.window, hasNestedContainer: $0.isNested) }
            }
        case .rows:
            return layout.rows.flatMap { row in
                row.windows.map { (id: $0.id, window: $0.window, hasNestedContainer: $0.isNested) }
            }
        }
    }

    /// Prune matching windows from the split held by `cellId`, collapsing the
    /// cell back to a plain window when exactly one survives. Returns true if
    /// the split changed at all.
    private func pruneNestedCell(
        _ cellId: UUID, in layout: MonitorLayout, isDead: (ExternalWindow) -> Bool
    ) -> Bool {
        switch layout.layoutMode {
        case .columns:
            guard let col = layout.columns.firstIndex(where: { column in
                column.windows.contains { $0.id == cellId }
            }),
            let idx = layout.columns[col].windows.firstIndex(where: { $0.id == cellId }),
            var container = layout.columns[col].windows[idx].nestedContainer else { return false }

            guard container.pruneDeadWindows(isDead: isDead) else { return false }

            let cell = layout.columns[col].windows[idx]
            if container.children.count == 1 {
                let node = container.children[0]
                layout.columns[col].windows[idx] = ColumnWindow(
                    id: cell.id, window: node.window, heightProportion: cell.heightProportion
                )
            } else {
                layout.columns[col].windows[idx].nestedContainer = container
            }
            return true

        case .rows:
            guard let row = layout.rows.firstIndex(where: { row in
                row.windows.contains { $0.id == cellId }
            }),
            let idx = layout.rows[row].windows.firstIndex(where: { $0.id == cellId }),
            var container = layout.rows[row].windows[idx].nestedContainer else { return false }

            guard container.pruneDeadWindows(isDead: isDead) else { return false }

            let cell = layout.rows[row].windows[idx]
            if container.children.count == 1 {
                let node = container.children[0]
                layout.rows[row].windows[idx] = RowWindow(
                    id: cell.id, window: node.window, widthProportion: cell.widthProportion
                )
            } else {
                layout.rows[row].windows[idx].nestedContainer = container
            }
            return true
        }
    }

    /// Pull a window out of a layout's model by its window id — for when a
    /// desktop drop claims a window that a stopped layout still holds. Model
    /// surgery only: an inactive layout has nothing on screen to re-apply.
    func evictWindow(withId windowId: UUID, from layout: MonitorLayout) {
        var deadCellIds: [UUID] = []
        for cell in managedCells(in: layout) {
            if let window = cell.window, window.id == windowId {
                deadCellIds.append(cell.id)
            } else if cell.hasNestedContainer {
                if pruneNestedCell(cell.id, in: layout, isDead: { $0.id == windowId }),
                   nestedCellIsEmpty(cell.id, in: layout) {
                    deadCellIds.append(cell.id)
                }
            }
        }
        for cellId in deadCellIds {
            removeClosedCell(cellId, in: layout)
        }
    }

    /// Whether a cell now holds neither a window nor any surviving split child.
    private func nestedCellIsEmpty(_ cellId: UUID, in layout: MonitorLayout) -> Bool {
        let cell: (window: ExternalWindow?, container: LayoutContainer?)?
        switch layout.layoutMode {
        case .columns:
            cell = layout.columns.flatMap(\.windows)
                .first { $0.id == cellId }
                .map { ($0.window, $0.nestedContainer) }
        case .rows:
            cell = layout.rows.flatMap(\.windows)
                .first { $0.id == cellId }
                .map { ($0.window, $0.nestedContainer) }
        }
        guard let cell else { return true }
        return cell.window == nil && (cell.container?.children.isEmpty ?? true)
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

    /// Whether a change is a move rather than a resize: every edge travelled
    /// together, so the window is the same size somewhere else.
    ///
    /// The tolerance is generous because apps rarely land on the exact pixel
    /// asked of them — Terminal snaps to character cells, and a few points of
    /// slop while being dragged should not read as a resize.
    private func isMove(_ delta: FrameDelta) -> Bool {
        let widthChange = delta.rightEdge - delta.leftEdge
        let heightChange = delta.bottomEdge - delta.topEdge
        let travelled = max(abs(delta.leftEdge), abs(delta.topEdge))

        return travelled > 5 && abs(widthChange) <= 8 && abs(heightChange) <= 8
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

    /// Route a split pane's edge drag.
    ///
    /// A pane has two kinds of edge. The ones facing another pane of the same
    /// split move that split's own divider. The rest are the outside of the
    /// split, which is the cell's boundary — so they move whatever seam the cell
    /// sits against, exactly as if the cell held a plain window. Splitting the
    /// delta and handing each half to the right place is all this does; both
    /// halves are handled by code that already worked for cells.
    private func handleNestedWindowResize(in layout: MonitorLayout, slot: WindowSlot, delta: FrameDelta) {
        guard let nestedIndex = slot.nestedIndex,
              let container = nestedContainer(in: layout, at: slot),
              container.children.indices.contains(nestedIndex)
        else { return }

        let isFirst = nestedIndex == 0
        let isLast = nestedIndex == container.children.count - 1

        var inner = FrameDelta()
        var outer = delta

        switch container.direction {
        case .horizontal:
            if !isFirst { inner.leftEdge = delta.leftEdge; outer.leftEdge = 0 }
            if !isLast { inner.rightEdge = delta.rightEdge; outer.rightEdge = 0 }
        case .vertical:
            if !isFirst { inner.topEdge = delta.topEdge; outer.topEdge = 0 }
            if !isLast { inner.bottomEdge = delta.bottomEdge; outer.bottomEdge = 0 }
        }

        resizeSplitPane(in: layout, slot: slot, container: container, delta: inner)

        switch layout.layoutMode {
        case .columns:
            handleWindowResize(in: layout, columnIndex: slot.columnIndex ?? 0,
                               windowIndex: slot.windowIndex, delta: outer)
        case .rows:
            handleRowWindowResize(in: layout, rowIndex: slot.rowIndex ?? 0,
                                  windowIndex: slot.windowIndex, delta: outer)
        }
    }

    /// Move the divider between a pane and its neighbour, mirroring what
    /// handleWindowResize does for cells — same sign conventions, same 10%
    /// floor, but measured against the split's own track rather than the whole
    /// monitor.
    private func resizeSplitPane(
        in layout: MonitorLayout,
        slot: WindowSlot,
        container: LayoutContainer,
        delta: FrameDelta
    ) {
        let threshold: CGFloat = 8
        guard let index = slot.nestedIndex else { return }

        let track = splitTrackSize(in: layout, slot: slot, direction: container.direction)
        guard track > 0 else { return }

        var updated = container
        let neighbourIndex: Int
        let proportionalDelta: CGFloat

        switch container.direction {
        case .horizontal:
            guard abs(delta.rightEdge - delta.leftEdge) > threshold else { return }
            if abs(delta.leftEdge) > abs(delta.rightEdge) {
                // Left edge moved right = this pane narrows, the one before widens.
                neighbourIndex = index - 1
                proportionalDelta = -delta.leftEdge / track
            } else {
                neighbourIndex = index + 1
                proportionalDelta = delta.rightEdge / track
            }
        case .vertical:
            guard abs(delta.bottomEdge - delta.topEdge) > threshold else { return }
            if abs(delta.topEdge) > abs(delta.bottomEdge) {
                // AX y grows downward: top edge moving up is a negative delta
                // and makes this pane taller.
                neighbourIndex = index - 1
                proportionalDelta = -delta.topEdge / track
            } else {
                neighbourIndex = index + 1
                proportionalDelta = delta.bottomEdge / track
            }
        }

        guard updated.children.indices.contains(neighbourIndex) else { return }

        let mine = updated.children[index].proportion + proportionalDelta
        let theirs = updated.children[neighbourIndex].proportion - proportionalDelta
        guard mine >= 0.1, theirs >= 0.1 else { return }

        updated.children[index].proportion = mine
        updated.children[neighbourIndex].proportion = theirs
        updated.normalizeProportions()

        setNestedContainer(updated, in: layout, at: slot)
    }

    /// How wide or tall a split is on screen, which is what turns a pixel drag
    /// into a share of the split. A split's panes divide the cell, so the track
    /// is the cell's own size — not the monitor's, which is the track for the
    /// column and row proportions one level up.
    private func splitTrackSize(
        in layout: MonitorLayout,
        slot: WindowSlot,
        direction: SplitDirection
    ) -> CGFloat {
        let bounds = layout.containerBounds

        switch layout.layoutMode {
        case .columns:
            guard let columnIndex = slot.columnIndex,
                  layout.columns.indices.contains(columnIndex),
                  layout.columns[columnIndex].windows.indices.contains(slot.windowIndex)
            else { return 0 }
            return direction == .horizontal
                ? layout.columns[columnIndex].widthProportion * bounds.width
                : layout.columns[columnIndex].windows[slot.windowIndex].heightProportion * bounds.height

        case .rows:
            guard let rowIndex = slot.rowIndex,
                  layout.rows.indices.contains(rowIndex),
                  layout.rows[rowIndex].windows.indices.contains(slot.windowIndex)
            else { return 0 }
            return direction == .horizontal
                ? layout.rows[rowIndex].windows[slot.windowIndex].widthProportion * bounds.width
                : layout.rows[rowIndex].heightProportion * bounds.height
        }
    }

    /// The split held by a cell of a given layout. The `columns`/`rows`
    /// accessors elsewhere proxy the *selected* monitor; event handling runs
    /// for whichever layout raised the notification, so these read and write
    /// the layout they are handed.
    private func nestedContainer(in layout: MonitorLayout, at slot: WindowSlot) -> LayoutContainer? {
        if let columnIndex = slot.columnIndex,
           layout.columns.indices.contains(columnIndex),
           layout.columns[columnIndex].windows.indices.contains(slot.windowIndex) {
            return layout.columns[columnIndex].windows[slot.windowIndex].nestedContainer
        }
        if let rowIndex = slot.rowIndex,
           layout.rows.indices.contains(rowIndex),
           layout.rows[rowIndex].windows.indices.contains(slot.windowIndex) {
            return layout.rows[rowIndex].windows[slot.windowIndex].nestedContainer
        }
        return nil
    }

    private func setNestedContainer(_ container: LayoutContainer, in layout: MonitorLayout, at slot: WindowSlot) {
        if let columnIndex = slot.columnIndex,
           layout.columns.indices.contains(columnIndex),
           layout.columns[columnIndex].windows.indices.contains(slot.windowIndex) {
            layout.columns[columnIndex].windows[slot.windowIndex].nestedContainer = container
        } else if let rowIndex = slot.rowIndex,
                  layout.rows.indices.contains(rowIndex),
                  layout.rows[rowIndex].windows.indices.contains(slot.windowIndex) {
            layout.rows[rowIndex].windows[slot.windowIndex].nestedContainer = container
        }
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
            let keys = storageKeys(for: monitorId)
            var presets = loadMonitorPresetsList()
            // Clear any legacy-keyed entry for this same monitor too, or the stale
            // one could win the lookup in getMonitorPreset.
            presets.removeAll { $0.presetSlot == slot && $0.monitorId.map(keys.contains) == true }
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
                    windows: col.windows.compactMap { colWin in
                        savedSlot(
                            window: colWin.window,
                            nestedContainer: colWin.nestedContainer,
                            proportion: colWin.heightProportion
                        )
                    }
                )
            } : nil,
            rows: layout.layoutMode == .rows ? layout.rows.map { row in
                SavedRow(
                    heightProportion: row.heightProportion,
                    windows: row.windows.compactMap { rowWin in
                        savedSlot(
                            window: rowWin.window,
                            nestedContainer: rowWin.nestedContainer,
                            proportion: rowWin.widthProportion
                        )
                    }
                )
            } : nil,
            presetSlot: presetSlot
        )
    }

    /// Encode one cell — either a window or a whole split — into a saved slot.
    private func savedSlot(
        window: ExternalWindow?,
        nestedContainer: LayoutContainer?,
        proportion: CGFloat
    ) -> SavedWindowSlot? {
        if let window {
            return savedSlot(for: window, proportion: proportion)
        }
        if let nestedContainer {
            return SavedWindowSlot(
                ownerName: "",
                windowTitle: nil,
                proportion: proportion,
                nested: savedContainer(from: nestedContainer)
            )
        }
        return nil
    }

    private func savedSlot(for window: ExternalWindow, proportion: CGFloat) -> SavedWindowSlot {
        SavedWindowSlot(
            ownerName: window.ownerName,
            windowTitle: window.title,
            bundleIdentifier: AppLauncher.getBundleIdentifier(for: window.ownerName),
            proportion: proportion,
            isPlaceholder: false,
            frame: window.frame  // Store frame for better matching
        )
    }

    private func savedContainer(from container: LayoutContainer) -> SavedNestedContainer {
        SavedNestedContainer(
            direction: container.direction.rawValue,
            children: container.children.map { savedSlot(for: $0.window, proportion: $0.proportion) }
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

        // Hotkeys can fire before the config window has ever been opened
        ensureLayoutsForAllMonitors()

        if let existing = getMonitorPreset(slot: slot, monitorId: monitor.id),
           let layout = monitorLayouts[monitor.id] {
            loadLayoutIntoMonitor(saved: existing, layout: layout)
            startManaging(layout: layout)  // Use specific layout, not currentLayout
        }
    }

    /// Every key a monitor's presets might be stored under: its stable id, plus
    /// the legacy display-id key used before identities became stable, so an
    /// upgrade doesn't orphan presets people already saved.
    private func storageKeys(for monitorId: String) -> Set<String> {
        guard let monitor = availableMonitors.first(where: { $0.id == monitorId }) else {
            return [monitorId]
        }
        return [monitor.id, monitor.legacyID]
    }

    func getMonitorPreset(slot: Int, monitorId: String) -> SavedLayout? {
        let keys = storageKeys(for: monitorId)
        let presets = loadMonitorPresetsList()
        return presets.first { preset in
            preset.presetSlot == slot && preset.monitorId.map(keys.contains) == true
        }
    }

    /// Get names of presets in each slot for the current monitor (for UI display)
    func getMonitorPresetNames() -> [Int: String] {
        guard let monitorId = selectedMonitor?.id else { return [:] }
        let keys = storageKeys(for: monitorId)
        let presets = loadMonitorPresetsList().filter { $0.monitorId.map(keys.contains) == true }
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
        // A workspace preset can be triggered by hotkey before the config window
        // has ever been opened, which is the normal case for a launch-at-login
        // menu bar app — so make sure the layouts it expects actually exist.
        ensureLayoutsForAllMonitors()

        for savedLayout in workspace.monitorLayouts {
            guard let monitorId = savedLayout.monitorId,
                  let layout = layout(forStoredMonitorId: monitorId) else { continue }
            loadLayoutIntoMonitor(saved: savedLayout, layout: layout)
        }

        // Start managing after loading
        startAllLayouts()
    }

    /// Make sure every connected monitor has a layout object.
    ///
    /// These were only ever created by the config window, so workspace hotkeys
    /// silently did nothing until it had been opened once — every boot, for a
    /// menu bar app that launches at login with no window.
    func ensureLayoutsForAllMonitors() {
        let mode = loadLastUsedLayoutMode()
        for monitor in availableMonitors where monitorLayouts[monitor.id] == nil {
            let layout = MonitorLayout(monitor: monitor)
            layout.layoutMode = mode
            layout.appState = .configuring
            monitorLayouts[monitor.id] = layout
        }
    }

    /// Resolve a stored monitor identifier to a live layout, tolerating the legacy
    /// display-id keys written before identities became stable.
    private func layout(forStoredMonitorId storedId: String) -> MonitorLayout? {
        if let layout = monitorLayouts[storedId] { return layout }
        guard let monitor = availableMonitors.first(where: { $0.legacyID == storedId }) else {
            return nil
        }
        return monitorLayouts[monitor.id]
    }

    /// Load a saved layout into a monitor layout
    private func loadLayoutIntoMonitor(saved: SavedLayout, layout: MonitorLayout) {
        // Set layout mode
        if let mode = LayoutMode(rawValue: saved.layoutMode) {
            layout.layoutMode = mode
        }

        // Release this layout's current windows before refreshing the pool.
        // availableWindows now excludes anything placed in any layout, so leaving
        // the old contents in place would mark them taken and the preset being
        // loaded could not reclaim its own windows.
        layout.columns = []
        layout.rows = []
        refreshAvailableWindows()

        // Re-match windows to slots
        switch layout.layoutMode {
        case .columns:
            guard let savedColumns = saved.columns else { return }
            var usedWindowIds = Set<UUID>()

            layout.columns = savedColumns.map { savedCol in
                let matchedWindows = savedCol.windows.compactMap { slot -> ColumnWindow? in
                    if let saved = slot.nested {
                        guard let container = restoreContainer(from: saved, excluding: &usedWindowIds) else {
                            return nil
                        }
                        return ColumnWindow(
                            id: UUID(),
                            nestedContainer: container,
                            heightProportion: slot.proportion
                        )
                    }
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
                    if let saved = slot.nested {
                        guard let container = restoreContainer(from: saved, excluding: &usedWindowIds) else {
                            return nil
                        }
                        return RowWindow(
                            id: UUID(),
                            nestedContainer: container,
                            widthProportion: slot.proportion
                        )
                    }
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
    }

    /// Rebuild a split from its saved form, matching each leaf back to a live
    /// window. Returns nil if nothing in the split could be matched — a split
    /// with no windows left in it is not worth restoring as an empty box.
    private func restoreContainer(
        from saved: SavedNestedContainer,
        excluding usedIds: inout Set<UUID>
    ) -> LayoutContainer? {
        let direction = SplitDirection(rawValue: saved.direction) ?? .horizontal
        var children: [LayoutWindowNode] = []

        for slot in saved.children {
            if let nestedSaved = slot.nested {
                // Splits can no longer hold splits, but presets written before
                // that could. Flatten the old shape into this level — scaling
                // each grandchild by its parent's share — rather than dropping
                // windows the user had placed.
                for grandchild in flattenedLeaves(of: nestedSaved, scaledBy: slot.proportion, excluding: &usedIds) {
                    children.append(grandchild)
                }
            } else if let match = findMatchingWindow(for: slot, excluding: usedIds) {
                usedIds.insert(match.id)
                children.append(LayoutWindowNode(window: match, proportion: slot.proportion))
            }
        }

        guard !children.isEmpty else { return nil }

        var container = LayoutContainer(direction: direction, children: children)
        container.normalizeProportions()
        return container
    }

    /// Every window leaf of a legacy nested-inside-nested split, with each leaf's
    /// proportion multiplied through its ancestors' shares so a flattened split
    /// keeps roughly the sizes the user last saw. Only ever reached by presets
    /// saved while containers could hold containers.
    private func flattenedLeaves(
        of saved: SavedNestedContainer,
        scaledBy scale: CGFloat,
        excluding usedIds: inout Set<UUID>
    ) -> [LayoutWindowNode] {
        var leaves: [LayoutWindowNode] = []

        for slot in saved.children {
            if let nestedSaved = slot.nested {
                leaves += flattenedLeaves(
                    of: nestedSaved,
                    scaledBy: scale * slot.proportion,
                    excluding: &usedIds
                )
            } else if let match = findMatchingWindow(for: slot, excluding: usedIds) {
                usedIds.insert(match.id)
                leaves.append(LayoutWindowNode(window: match, proportion: scale * slot.proportion))
            }
        }

        return leaves
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

/// A saved split. Children are SavedWindowSlots, which the encoder now only ever
/// writes as plain windows — splits can no longer hold splits. The recursion is
/// kept in the shape so presets written before that still decode; restore
/// flattens any it finds. See `flattenedLeaves`.
struct SavedNestedContainer: Codable {
    let direction: String           // SplitDirection.rawValue
    let children: [SavedWindowSlot]
}

struct SavedWindowSlot: Codable {
    let ownerName: String
    let windowTitle: String?
    let bundleIdentifier: String?   // For launching apps
    let proportion: CGFloat
    let isPlaceholder: Bool         // true = app wasn't open when saved

    /// Non-nil when this slot holds a split rather than a single window.
    ///
    /// Splits used to be dropped on the floor when saving: the encoder
    /// compactMapped nested cells to nil, so saving a preset silently destroyed
    /// them and reloading gave you a layout with a pane missing.
    let nested: SavedNestedContainer?

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
         proportion: CGFloat, isPlaceholder: Bool = false, frame: CGRect? = nil,
         nested: SavedNestedContainer? = nil) {
        self.ownerName = ownerName
        self.windowTitle = windowTitle
        self.bundleIdentifier = bundleIdentifier
        self.proportion = proportion
        self.isPlaceholder = isPlaceholder
        self.nested = nested
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
        // nil for saves written before splits were persisted
        nested = try container.decodeIfPresent(SavedNestedContainer.self, forKey: .nested)
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
