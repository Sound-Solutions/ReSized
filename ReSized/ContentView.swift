import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - Seams

/// Placeholder payload for a drag.
///
/// What is being dragged is recorded on WindowManager when the drag starts, so
/// the payload itself carries nothing — it exists because AppKit needs an item
/// to drag. Decoding a real payload asynchronously on drop bought nothing and
/// meant the drop handler could not answer "where will this land" until after
/// the mouse was released.
let dragToken = "resized.window" as NSString

/// The item AppKit drags around.
///
/// Built with an explicit type identifier rather than NSItemProvider(object:),
/// which picks its own — and if what it picks isn't the type the drop declares,
/// the drag still highlights but the drop is silently refused.
func makeDragItem() -> NSItemProvider {
    NSItemProvider(item: dragToken, typeIdentifier: UTType.plainText.identifier)
}

/// Transient drag state, kept in a class so the drop delegate holds one stable
/// reference to it.
///
/// It cannot be @State on the view: the delegate would capture a Binding, and
/// updating it from dropUpdated — which happens on every mouse move — rebuilds
/// the view, hands onDrop a freshly-made delegate mid-drag, and the drop lands
/// on a delegate that is no longer the one AppKit is talking to.
@Observable
final class SeamDragState {
    var highlighted: LayoutSeam?
}

// MARK: - Seam Model

/// A boundary a dragged window can be inserted at, and where to draw it.
struct LayoutSeam: Equatable {
    var destination: SeamDestination
    /// Start of the line, in the grid's coordinate space.
    var origin: CGPoint
    var length: CGFloat
    var isVertical: Bool

    /// Distance from a point to the seam, treating it as a line segment rather
    /// than an infinite line — otherwise a seam in a distant column looks close
    /// whenever the cursor happens to share its x.
    func distance(to point: CGPoint) -> CGFloat {
        if isVertical {
            let overshoot = max(origin.y - point.y, point.y - (origin.y + length), 0)
            return hypot(point.x - origin.x, overshoot)
        }
        let overshoot = max(origin.x - point.x, point.x - (origin.x + length), 0)
        return hypot(overshoot, point.y - origin.y)
    }
}

/// A tile's position, published so the grid can derive seams from where things
/// actually are rather than recomputing the layout maths a second time and
/// hoping the two agree.
struct TileFrame: Equatable {
    /// `nestedIndex` nil for a cell, set for a pane inside a split.
    var slot: WindowSlot
    var frame: CGRect
    /// Set on panes, so their seams get the right orientation.
    var splitDirection: SplitDirection?
}

struct TileFramesKey: PreferenceKey {
    static let defaultValue: [TileFrame] = []
    static func reduce(value: inout [TileFrame], nextValue: () -> [TileFrame]) {
        value += nextValue()
    }
}

extension View {
    /// Report this tile's frame to the grid.
    func reportTileFrame(_ slot: WindowSlot, splitDirection: SplitDirection? = nil) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TileFramesKey.self,
                    value: [TileFrame(
                        slot: slot,
                        frame: proxy.frame(in: .named(LayoutPreview.gridSpace)),
                        splitDirection: splitDirection
                    )]
                )
            }
        )
    }
}

/// Every place a window could be dropped, derived from where the tiles are.
///
/// A column or row of n cells has n+1 seams: before the first, between each
/// pair, and after the last. A split's panes have the same, turned whichever
/// way the split is. Dropping is then just "which of these is nearest", with no
/// regions to land in or miss.
func buildSeams(from tiles: [TileFrame], columnsMode: Bool) -> [LayoutSeam] {
    var seams: [LayoutSeam] = []

    // Cells, grouped by the column or row holding them.
    let cells = tiles.filter { $0.slot.nestedIndex == nil }
    let cellGroups = Dictionary(grouping: cells) { columnsMode ? $0.slot.columnIndex : $0.slot.rowIndex }

    for (containerIndex, group) in cellGroups {
        guard let containerIndex else { continue }
        let ordered = group.sorted { $0.slot.windowIndex < $1.slot.windowIndex }
        guard let first = ordered.first, let last = ordered.last else { continue }

        func destination(_ index: Int) -> SeamDestination {
            .cell(columnIndex: columnsMode ? containerIndex : nil,
                  rowIndex: columnsMode ? nil : containerIndex,
                  index: index)
        }

        if columnsMode {
            // Cells stack down a column, so the seams between them run across.
            let x = ordered.map(\.frame.minX).min() ?? first.frame.minX
            let width = (ordered.map(\.frame.maxX).max() ?? first.frame.maxX) - x
            for tile in ordered {
                seams.append(LayoutSeam(destination: destination(tile.slot.windowIndex),
                                        origin: CGPoint(x: x, y: tile.frame.minY),
                                        length: width, isVertical: false))
            }
            seams.append(LayoutSeam(destination: destination(last.slot.windowIndex + 1),
                                    origin: CGPoint(x: x, y: last.frame.maxY),
                                    length: width, isVertical: false))
        } else {
            // Cells run across a row, so the seams between them run down.
            let y = ordered.map(\.frame.minY).min() ?? first.frame.minY
            let height = (ordered.map(\.frame.maxY).max() ?? first.frame.maxY) - y
            for tile in ordered {
                seams.append(LayoutSeam(destination: destination(tile.slot.windowIndex),
                                        origin: CGPoint(x: tile.frame.minX, y: y),
                                        length: height, isVertical: true))
            }
            seams.append(LayoutSeam(destination: destination(last.slot.windowIndex + 1),
                                    origin: CGPoint(x: last.frame.maxX, y: y),
                                    length: height, isVertical: true))
        }
    }

    // Panes, grouped by the cell whose split holds them.
    let paneGroups = Dictionary(grouping: tiles.filter { $0.slot.nestedIndex != nil }) { $0.slot.cell }

    for (cellSlot, group) in paneGroups {
        let ordered = group.sorted { ($0.slot.nestedIndex ?? 0) < ($1.slot.nestedIndex ?? 0) }
        guard let first = ordered.first, let last = ordered.last,
              let direction = first.splitDirection else { continue }

        func destination(_ index: Int) -> SeamDestination { .pane(cell: cellSlot, index: index) }

        if direction == .horizontal {
            let y = ordered.map(\.frame.minY).min() ?? first.frame.minY
            let height = (ordered.map(\.frame.maxY).max() ?? first.frame.maxY) - y
            for tile in ordered {
                seams.append(LayoutSeam(destination: destination(tile.slot.nestedIndex ?? 0),
                                        origin: CGPoint(x: tile.frame.minX, y: y),
                                        length: height, isVertical: true))
            }
            seams.append(LayoutSeam(destination: destination((last.slot.nestedIndex ?? 0) + 1),
                                    origin: CGPoint(x: last.frame.maxX, y: y),
                                    length: height, isVertical: true))
        } else {
            let x = ordered.map(\.frame.minX).min() ?? first.frame.minX
            let width = (ordered.map(\.frame.maxX).max() ?? first.frame.maxX) - x
            for tile in ordered {
                seams.append(LayoutSeam(destination: destination(tile.slot.nestedIndex ?? 0),
                                        origin: CGPoint(x: x, y: tile.frame.minY),
                                        length: width, isVertical: false))
            }
            seams.append(LayoutSeam(destination: destination((last.slot.nestedIndex ?? 0) + 1),
                                    origin: CGPoint(x: x, y: last.frame.maxY),
                                    length: width, isVertical: false))
        }
    }

    return seams
}

/// One drop handler for the whole grid.
///
/// Every tile used to carry its own, which meant a drop landed on whichever
/// view happened to win hit-testing and each had to guess what the user meant
/// from where inside itself the drop fell. There is now a single target, a
/// single question — which seam is nearest — and an answer visible on screen
/// before the mouse is released.
struct SeamDropDelegate: DropDelegate {
    /// Read when needed rather than captured, so a layout change mid-drag can't
    /// leave the delegate deciding against seams that have moved.
    let seams: () -> [LayoutSeam]
    let windowManager: WindowManager
    let state: SeamDragState

    func validateDrop(info: DropInfo) -> Bool {
        let ok = windowManager.pendingDrag != nil
        AccessibilityHelper.logDebug("DROP validate -> \(ok)")
        return ok
    }

    func dropEntered(info: DropInfo) {
        state.highlighted = nearestSeam(to: info.location)
        AccessibilityHelper.logDebug("DROP entered at \(info.location); seams=\(seams().count)")
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        state.highlighted = nearestSeam(to: info.location)
        // .copy, not .move. A SwiftUI onDrag session does not advertise move,
        // and proposing an operation the source never offered leaves the drag
        // looking live right up to release and then refuses it.
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        AccessibilityHelper.logDebug("DROP exited")
        state.highlighted = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            state.highlighted = nil
            windowManager.pendingDrag = nil
        }
        guard let drag = windowManager.pendingDrag else {
            AccessibilityHelper.logDebug("DROP perform: no pendingDrag")
            return false
        }
        guard let seam = nearestSeam(to: info.location) else {
            AccessibilityHelper.logDebug("DROP perform: no seam near \(info.location)")
            return false
        }

        AccessibilityHelper.logDebug("DROP perform: \(drag) -> \(seam.destination)")
        windowManager.place(drag, at: seam.destination)
        return true
    }

    private func nearestSeam(to point: CGPoint) -> LayoutSeam? {
        seams().min { $0.distance(to: point) < $1.distance(to: point) }
    }
}

/// Draws the highlight, and is the only thing that rebuilds as it moves.
struct SeamHighlightOverlay: View {
    let state: SeamDragState

    var body: some View {
        if let seam = state.highlighted {
            SeamHighlight(seam: seam)
        }
    }
}

/// The line showing where the window will land.
struct SeamHighlight: View {
    let seam: LayoutSeam

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor)
            .frame(
                width: seam.isVertical ? 4 : seam.length,
                height: seam.isVertical ? seam.length : 4
            )
            .position(
                x: seam.origin.x + (seam.isVertical ? 0 : seam.length / 2),
                y: seam.origin.y + (seam.isVertical ? seam.length / 2 : 0)
            )
            .shadow(color: .accentColor.opacity(0.6), radius: 4)
            .allowsHitTesting(false)
    }
}

// MARK: - Permission Overlay (First Launch)

struct PermissionOverlay: View {
    /// Opens the Accessibility pane. There is intentionally no path here that
    /// raises the system's own permission dialog — one prompt, ours.
    var onGrantAccess: () -> Void
    var onRelaunch: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text("Accessibility Permission Required")
                    .font(.headline)

                Text("ReSized needs accessibility access to scan and manage your windows.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280)

                Button("Grant Access") {
                    onGrantAccess()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)

                Text("Opens Privacy & Security → Accessibility. Tick ReSized in the list.")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280)

                Divider()
                    .frame(maxWidth: 200)

                // Escape hatch: macOS sometimes keeps reporting an already-running
                // process as untrusted until it restarts, so there has to be a way
                // out of this overlay that isn't "quit and relaunch by hand".
                Button("Already Granted — Relaunch") {
                    onRelaunch()
                }
                .controlSize(.small)
            }
            .padding(24)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
        }
    }
}

extension NSWindow {
    /// Whether this is the main config window, as opposed to Settings, the
    /// highlight ring, or one of SwiftUI's transient helper windows.
    /// Mirrors the lookup AppDelegate.showConfig uses.
    var isConfigWindow: Bool {
        guard !(self is MonitorHighlightWindow) else { return false }
        return identifier?.rawValue == "main" || title == "ReSized"
    }
}

/// Relaunches the app in place. Granting Accessibility does not always take
/// effect for an already-running process.
enum AppRelaunch {
    static func now() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Trial Expired Overlay

struct TrialExpiredOverlay: View {
    let licenseManager: LicenseManager
    @State private var enteredKey: String = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)

                Text("Trial Expired")
                    .font(.headline)

                Text("Your 7-day trial has ended. Enter a license key or purchase one to continue using ReSized.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 280)

                VStack(spacing: 12) {
                    HStack {
                        TextField("Enter license key", text: $enteredKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Button(licenseManager.isValidating ? "..." : "Activate") {
                            licenseManager.saveLicenseKey(enteredKey)
                            licenseManager.validateLicense { success, _ in
                                if success {
                                    enteredKey = ""
                                }
                            }
                        }
                        .disabled(enteredKey.isEmpty || licenseManager.isValidating)
                    }
                    .frame(maxWidth: 300)

                    if let error = licenseManager.validationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button("Buy License") {
                        licenseManager.openPurchasePage()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
            .padding(24)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
        }
    }
}

struct ContentView: View {
    @Environment(WindowManager.self) private var windowManager
    private let licenseManager = LicenseManager.shared
    @State private var hasAccessibilityPermission = false
    @State private var permissionTimer: Timer?

    var body: some View {
        Group {
            switch windowManager.appState {
            case .modeSelect:
                LayoutModePickerView()
            case .monitorSelect:
                MonitorSelectView()
            case .configuring:
                ConfigureLayoutView()
                    .overlay {
                        // Show permission overlay first if needed
                        if !hasAccessibilityPermission {
                            PermissionOverlay(
                                onGrantAccess: {
                                    AccessibilityHelper.openAccessibilityPreferences()
                                    startPermissionPolling()
                                },
                                onRelaunch: { AppRelaunch.now() }
                            )
                        }
                        // Then show trial expired overlay if applicable
                        else if case .trialExpired = licenseManager.licenseState {
                            TrialExpiredOverlay(licenseManager: licenseManager)
                        }
                    }
            case .active:
                ActiveLayoutView()
                    .overlay {
                        // Also block active state if trial expired
                        if case .trialExpired = licenseManager.licenseState {
                            TrialExpiredOverlay(licenseManager: licenseManager)
                        }
                    }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            hasAccessibilityPermission = AccessibilityHelper.checkAccessibilityPermissions()

            windowManager.isConfigWindowVisible = true
            windowManager.refreshMonitors()

            // Skip directly to editing mode for the monitor at mouse location
            if windowManager.selectedMonitor == nil {
                windowManager.skipToEditingMode()
            }

            // Start polling if permissions not yet granted
            if !hasAccessibilityPermission {
                startPermissionPolling()
            }
        }
        .onDisappear {
            permissionTimer?.invalidate()
            // Takes the highlight ring down with the window
            windowManager.isConfigWindowVisible = false
        }
        // Coming back from System Settings reactivates the app — cheaper and far
        // more responsive than waiting for the next poll tick.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionState()
        }
        // Belt and braces for the highlight ring: onDisappear is not dependable
        // for a SwiftUI Window scene closed with the red X on macOS.
        //
        // Must match only the config window. SwiftUI keeps transient helper
        // windows around (a zero-size one shows up right after launch), and
        // reacting to any close at all tore the ring down seconds into the
        // session while the config window was still sitting there open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let closing = note.object as? NSWindow, closing.isConfigWindow else { return }
            windowManager.isConfigWindowVisible = false
        }
    }

    /// Re-read the trust state, and if we've just gained it, stop polling and scan.
    @discardableResult
    private func refreshPermissionState() -> Bool {
        let trusted = AccessibilityHelper.checkAccessibilityPermissions()
        guard trusted else { return false }

        if !hasAccessibilityPermission {
            hasAccessibilityPermission = true
            _ = windowManager.scanExistingLayout()
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        return true
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()

        // .common rather than Timer.scheduledTimer's default mode: the default
        // one stops firing while a menu is open or a drag is tracking, which is
        // exactly when someone is fiddling with permissions.
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            refreshPermissionState()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }
}

// MARK: - Layout Mode Picker View

struct LayoutModePickerView: View {
    @Environment(WindowManager.self) private var windowManager
    @State private var hoveredMode: LayoutMode?

    var body: some View {
        VStack(spacing: 30) {
            Text("ReSized")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Choose your layout style")
                .font(.title2)
                .foregroundStyle(.secondary)

            HStack(spacing: 24) {
                // Columns mode card
                LayoutModeCard(
                    mode: .columns,
                    isHovered: hoveredMode == .columns,
                    isDisabled: false
                ) {
                    windowManager.setModeAndScan(.columns)
                }
                .onHover { hovering in
                    hoveredMode = hovering ? .columns : nil
                }

                // Rows mode card
                LayoutModeCard(
                    mode: .rows,
                    isHovered: hoveredMode == .rows,
                    isDisabled: false
                ) {
                    windowManager.setModeAndScan(.rows)
                }
                .onHover { hovering in
                    hoveredMode = hovering ? .rows : nil
                }

                // Mix mode card (greyed out - Phase 2)
                LayoutModeCard(
                    mode: nil,
                    isHovered: false,
                    isDisabled: true
                ) {}
            }

            Text("You can switch modes anytime from the layout editor")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct LayoutModeCard: View {
    let mode: LayoutMode?
    let isHovered: Bool
    let isDisabled: Bool
    let action: () -> Void

    private var title: String {
        mode?.rawValue ?? "Mix"
    }

    private var description: String {
        switch mode {
        case .columns:
            return "Side-by-side windows\nwith vertical dividers"
        case .rows:
            return "Stacked windows\nwith horizontal dividers"
        case nil:
            return "Nested splits\n(Coming soon)"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                // Visual preview
                LayoutModePreviewIcon(mode: mode)
                    .frame(width: 100, height: 70)

                VStack(spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 150, height: 160)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovered ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isHovered ? 2 : 1
                    )
            )
            .opacity(isDisabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .cursor(isDisabled ? .arrow : .pointingHand)
    }
}

struct LayoutModePreviewIcon: View {
    let mode: LayoutMode?

    var body: some View {
        switch mode {
        case .columns:
            // 3 vertical bars
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        )
                }
            }
        case .rows:
            // 3 horizontal bars
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        )
                }
            }
        case nil:
            // Mix mode - grid pattern
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Color.gray.opacity(0.5), lineWidth: 1)
                        )
                }
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.gray.opacity(0.5), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Monitor Selection View

struct MonitorSelectView: View {
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        VStack(spacing: 30) {
            Text("ReSized")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Click a monitor to manage")
                .font(.title2)
                .foregroundStyle(.secondary)

            // Clickable monitor layout - centered
            MonitorLayoutPreview(onSelectMonitor: { monitor in
                windowManager.selectMonitor(monitor)
            })
            .frame(height: 280)

            Text("Each monitor can have its own layout")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct MonitorLayoutPreview: View {
    @Environment(WindowManager.self) private var windowManager
    var onSelectMonitor: ((Monitor) -> Void)?
    @State private var hoveredMonitorId: String?

    var body: some View {
        GeometryReader { geometry in
            let monitors = windowManager.availableMonitors
            let allBounds = monitors.map { $0.frame }
            let minX = allBounds.map { $0.minX }.min() ?? 0
            let maxX = allBounds.map { $0.maxX }.max() ?? 1920
            let maxY = allBounds.map { $0.maxY }.max() ?? 1080
            let minYBounds = allBounds.map { $0.minY }.min() ?? 0
            let totalWidth = maxX - minX
            let totalHeight = maxY - minYBounds

            let scale = min(
                (geometry.size.width - 40) / totalWidth,
                (geometry.size.height - 20) / totalHeight
            )

            // Calculate the total scaled size for centering
            let scaledTotalWidth = totalWidth * scale
            let scaledTotalHeight = totalHeight * scale
            let offsetX = (geometry.size.width - scaledTotalWidth) / 2
            let offsetY = (geometry.size.height - scaledTotalHeight) / 2

            ZStack {
                ForEach(monitors) { monitor in
                    let isHovered = hoveredMonitorId == monitor.id
                    let scaledFrame = CGRect(
                        x: (monitor.frame.minX - minX) * scale,
                        y: (maxY - monitor.frame.maxY) * scale,
                        width: monitor.frame.width * scale,
                        height: monitor.frame.height * scale
                    )

                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.accentColor.opacity(0.3) :
                              (monitor.isMain ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(isHovered ? Color.accentColor :
                                              (monitor.isMain ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor)),
                                              lineWidth: isHovered ? 3 : 2)
                        )
                        .overlay(
                            VStack(spacing: 4) {
                                Text(monitor.name)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)

                                Text("\(Int(monitor.frame.width)) x \(Int(monitor.frame.height))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                if monitor.isMain {
                                    Text("Main")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                            .padding(8)
                        )
                        .frame(width: scaledFrame.width, height: scaledFrame.height)
                        .position(
                            x: offsetX + scaledFrame.midX,
                            y: offsetY + scaledFrame.midY
                        )
                        .onHover { hovering in
                            if onSelectMonitor != nil {
                                hoveredMonitorId = hovering ? monitor.id : nil
                            }
                        }
                        .onTapGesture {
                            onSelectMonitor?(monitor)
                        }
                        .cursor(onSelectMonitor != nil ? .pointingHand : .arrow)
                }
            }
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Monitor Tabs

struct MonitorTabs: View {
    @Environment(WindowManager.self) private var windowManager
    @State private var hoveredMonitorId: String?

    var body: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(windowManager.availableMonitors) { monitor in
                        MonitorTab(
                            monitor: monitor,
                            isSelected: windowManager.selectedMonitor?.id == monitor.id,
                            hasLayout: windowManager.hasLayout(for: monitor),
                            isManaging: windowManager.isManaging(monitor: monitor),
                            isHovered: hoveredMonitorId == monitor.id
                        ) {
                            windowManager.selectMonitor(monitor)
                        }
                        .onHover { hovering in
                            hoveredMonitorId = hovering ? monitor.id : nil
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            Spacer()

            Text("ReSized")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .padding(.trailing, 16)
        }
        .padding(.top, 6)
        .background(Color(white: 0.08))
    }
}

struct MonitorTab: View {
    let monitor: Monitor
    let isSelected: Bool
    let hasLayout: Bool
    let isManaging: Bool
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "display")
                .font(.caption)

            Text(monitor.name)
                .font(.caption)
                .lineLimit(1)

            if isManaging {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            } else if hasLayout {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) :
                      (isHovered ? Color(nsColor: .controlBackgroundColor) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .simultaneousGesture(TapGesture().onEnded {
            action()
        })
        .cursor(.pointingHand)
    }
}

// MARK: - Configure Layout View

struct ConfigureLayoutView: View {
    @Environment(WindowManager.self) private var windowManager
    @State private var selectedIndex: Int = 0
    @State private var showingWindowPicker = false
    @State private var useCurrentLayout: Bool = true  // Use scanned layout by default

    var body: some View {
        VStack(spacing: 0) {
            // Monitor tabs
            MonitorTabs()

            Divider()

            // Header
            HStack {
                Button {
                    windowManager.appState = .modeSelect
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Mode")
                    }
                }

                Spacer()

                // Mode toggle
                Picker("Mode", selection: Binding(
                    get: { windowManager.layoutMode },
                    set: { newMode in
                        windowManager.layoutMode = newMode
                        windowManager.saveLayoutMode(newMode)  // Remember for next launch
                        // Clear other mode's data and rescan with new mode
                        if newMode == .columns {
                            windowManager.rows = []
                        } else {
                            windowManager.columns = []
                        }
                        if useCurrentLayout {
                            _ = windowManager.scanExistingLayout()
                        } else {
                            if newMode == .columns {
                                windowManager.setupColumns(count: 2)
                            } else {
                                windowManager.setupRows(count: 2)
                            }
                        }
                        selectedIndex = 0
                    }
                )) {
                    Text("Columns").tag(LayoutMode.columns)
                    Text("Rows").tag(LayoutMode.rows)
                }
                .pickerStyle(.segmented)
                // Without this the "Mode" label is laid out inside the 160pt
                // frame and wraps to "Mo/de". The back button beside it already
                // says Mode, so the label is redundant anyway.
                .labelsHidden()
                .frame(width: 160)

                // Scan toggle button
                Button {
                    useCurrentLayout.toggle()
                    if useCurrentLayout {
                        _ = windowManager.scanExistingLayout()
                    } else {
                        // Switch to blank layout
                        if windowManager.layoutMode == .columns {
                            windowManager.setupColumns(count: 2)
                        } else {
                            windowManager.setupRows(count: 2)
                        }
                    }
                    selectedIndex = 0
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: useCurrentLayout ? "rectangle.3.group.fill" : "rectangle.3.group")
                        Text(useCurrentLayout ? "Scanned" : "Blank")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(useCurrentLayout ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Spacer()

                // Primary division controls (columns or rows)
                HStack(spacing: 8) {
                    Button {
                        if windowManager.layoutMode == .columns {
                            if windowManager.columns.count > 1 {
                                windowManager.removeColumn(at: windowManager.columns.count - 1)
                            }
                        } else {
                            if windowManager.rows.count > 1 {
                                windowManager.removeRow(at: windowManager.rows.count - 1)
                            }
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(windowManager.primaryCount <= 1)

                    Text("\(windowManager.primaryCount) \(windowManager.layoutMode == .columns ? "columns" : "rows")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        if windowManager.layoutMode == .columns {
                            windowManager.addColumn()
                        } else {
                            windowManager.addRow()
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }

                Spacer()

                // Layout save/load menu
                LayoutMenu()

                Button("Start") {
                    windowManager.startManaging()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!windowManager.hasAnyWindows)
            }
            .padding()

            Divider()

            // Main content
            HStack(spacing: 0) {
                // Layout preview - flexible, takes ALL remaining space
                LayoutPreview(selectedIndex: $selectedIndex)
                    .frame(maxWidth: .infinity)

                Divider()

                // Window picker sidebar - fixed 280px, always on right
                WindowPickerSidebar(selectedIndex: $selectedIndex)
                    .frame(width: 280)
            }
        }
    }
}

struct LayoutPreview: View {
    /// Shared coordinate space for tile frames, seams and the drop location, so
    /// all three are directly comparable.
    static let gridSpace = "ReSizedGrid"

    @Environment(WindowManager.self) private var windowManager
    @Binding var selectedIndex: Int
    @State private var tileFrames: [TileFrame] = []
    @State private var dragState = SeamDragState()

    var body: some View {
        grid
            .coordinateSpace(name: Self.gridSpace)
            .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
            // The highlight is read inside its own view, deliberately. Reading
            // it here would make every mouse move during a drag rebuild this
            // body — and with it the drop delegate AppKit is mid-conversation
            // with.
            .overlay { SeamHighlightOverlay(state: dragState) }
            .onDrop(
                of: [.plainText],
                delegate: SeamDropDelegate(
                    seams: { [tileFrames, columnsMode = windowManager.layoutMode == .columns] in
                        buildSeams(from: tileFrames, columnsMode: columnsMode)
                    },
                    windowManager: windowManager,
                    state: dragState
                )
            )
    }

    private var grid: some View {
        GeometryReader { geometry in
            if windowManager.layoutMode == .columns {
                // Columns mode: horizontal arrangement
                HStack(spacing: 0) {
                    ForEach(Array(windowManager.columns.enumerated()), id: \.element.id) { index, column in
                        ColumnPreview(
                            column: column,
                            columnIndex: index,
                            isSelected: selectedIndex == index,
                            containerSize: geometry.size,
                            canRemove: windowManager.columns.count > 1,
                            onRemove: {
                                windowManager.removeColumn(at: index)
                                if selectedIndex >= windowManager.columns.count {
                                    selectedIndex = max(0, windowManager.columns.count - 1)
                                }
                            },
                            totalColumns: windowManager.columns.count
                        )
                        .onTapGesture {
                            selectedIndex = index
                        }

                        if index < windowManager.columns.count - 1 {
                            // Must match the width ColumnPreview lays itself out in
                            ColumnDividerHandle(
                                dividerIndex: index,
                                trackWidth: (geometry.size.width - 32)
                                    - CGFloat(windowManager.columns.count - 1) * 8
                            )
                        }
                    }
                }
                .padding()
            } else {
                // Rows mode: vertical arrangement
                VStack(spacing: 0) {
                    ForEach(Array(windowManager.rows.enumerated()), id: \.element.id) { index, row in
                        RowPreview(
                            row: row,
                            rowIndex: index,
                            isSelected: selectedIndex == index,
                            containerSize: geometry.size,
                            canRemove: windowManager.rows.count > 1,
                            onRemove: {
                                windowManager.removeRow(at: index)
                                if selectedIndex >= windowManager.rows.count {
                                    selectedIndex = max(0, windowManager.rows.count - 1)
                                }
                            },
                            totalRows: windowManager.rows.count
                        )
                        .onTapGesture {
                            selectedIndex = index
                        }

                        if index < windowManager.rows.count - 1 {
                            // Must match the height RowPreview lays itself out in
                            RowPrimaryDividerHandle(
                                dividerIndex: index,
                                trackHeight: (geometry.size.height - 32)
                                    - CGFloat(windowManager.rows.count - 1) * 8
                            )
                        }
                    }
                }
                .padding()
            }
        }
        .background(Color(white: 0.1))
    }
}

struct ColumnPreview: View {
    let column: Column
    let columnIndex: Int
    let isSelected: Bool
    let containerSize: CGSize
    let canRemove: Bool
    let onRemove: () -> Void
    let totalColumns: Int
    @Environment(WindowManager.self) private var windowManager
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            // Column header with remove button
            HStack(spacing: 4) {
                Text("Column \(columnIndex + 1)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if canRemove {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)

            // Windows in column
            if column.windows.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "plus.rectangle.on.rectangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Add windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 1,
                            antialiased: true
                        )
                )
            } else {
                // Calculate available height for windows (container minus header ~24px and padding)
                let availableHeight = max(100, containerSize.height - 40)
                let dividerCount = CGFloat(column.windows.count - 1)
                let totalDividerHeight = dividerCount * 6 // 6px per divider
                let windowsHeight = availableHeight - totalDividerHeight

                VStack(spacing: 0) {
                    ForEach(Array(column.windows.enumerated()), id: \.element.id) { winIndex, colWindow in
                        WindowTilePreview(
                            columnWindow: colWindow,
                            columnIndex: columnIndex,
                            windowIndex: winIndex,
                            heightProportion: colWindow.heightProportion
                        )
                        .frame(height: max(40, windowsHeight * colWindow.heightProportion))

                        // Row divider (except after last window)
                        if winIndex < column.windows.count - 1 {
                            RowDividerHandle(
                                columnIndex: columnIndex,
                                dividerIndex: winIndex,
                                trackHeight: windowsHeight
                            )
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
            }
        }
        .frame(width: max(60, ((containerSize.width - 32) - CGFloat(totalColumns - 1) * 8) * column.widthProportion))
        // Drops are handled once, by the grid — see SeamDropDelegate. The
        // column used to catch them itself and then guess a position by
        // dividing its height evenly, which put windows in the wrong slot the
        // moment its cells weren't all the same size.
    }
}

struct WindowTilePreview: View {
    let columnWindow: ColumnWindow
    let columnIndex: Int
    let windowIndex: Int
    let heightProportion: CGFloat
    @Environment(WindowManager.self) private var windowManager
    @State private var isHovered = false

    private var slot: WindowSlot {
        WindowSlot(columnIndex: columnIndex, rowIndex: nil, windowIndex: windowIndex, nestedIndex: nil)
    }

    var body: some View {
        Group {
            if let window = columnWindow.window {
                singleWindowView(window: window)
            } else if let container = columnWindow.nestedContainer {
                // Nested container view
                NestedContainerPreview(
                    container: container,
                    columnIndex: columnIndex,
                    windowIndex: windowIndex,
                    isInColumn: true
                )
            }
        }
        .reportTileFrame(slot)
    }

    @ViewBuilder
    private func singleWindowView(window: ExternalWindow) -> some View {
        VStack(spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.ownerName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(window.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    windowManager.removeWindow(columnWindow.id, fromColumn: columnIndex)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Split button when hovered - columns can add horizontal splits (sub-columns)
            if isHovered {
                Button {
                    windowManager.splitColumnCell(columnIndex: columnIndex, windowIndex: windowIndex, direction: .horizontal)
                } label: {
                    Image(systemName: "rectangle.split.1x2")
                        .rotationEffect(.degrees(90))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Split into columns")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorForApp(window.ownerName))
        .onHover { hovering in
            isHovered = hovering
        }
        .onDrag {
            windowManager.pendingDrag = .placed(slot)
            return makeDragItem()
        }
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

// MARK: - Nested Container Views

/// Preview for a nested container within a column or row cell
struct NestedContainerPreview: View {
    let container: LayoutContainer
    let columnIndex: Int?
    let windowIndex: Int
    let isInColumn: Bool
    var rowIndex: Int? = nil
    @Environment(WindowManager.self) private var windowManager
    @State private var isDropTarget = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if container.direction == .horizontal {
                    HStack(spacing: 0) {
                        nestedChildrenView(size: geometry.size)
                    }
                } else {
                    VStack(spacing: 0) {
                        nestedChildrenView(size: geometry.size)
                    }
                }
            }
        }
        .padding(4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func nestedChildrenView(size: CGSize) -> some View {
        ForEach(Array(container.children.enumerated()), id: \.element.id) { index, child in
            let childSize = container.direction == .horizontal
                ? CGSize(width: size.width * child.proportion, height: size.height)
                : CGSize(width: size.width, height: size.height * child.proportion)

            NestedWindowTile(
                windowNode: child,
                nestedIndex: index,
                columnIndex: columnIndex,
                rowIndex: rowIndex,
                windowIndex: windowIndex,
                isInColumn: isInColumn,
                splitDirection: container.direction
            )
            .frame(width: childSize.width, height: childSize.height)

            // Add divider between children (not after last)
            if index < container.children.count - 1 {
                NestedDividerHandle(
                    dividerIndex: index,
                    columnIndex: columnIndex,
                    rowIndex: rowIndex,
                    windowIndex: windowIndex,
                    isHorizontal: container.direction == .horizontal,
                    isInColumn: isInColumn,
                    containerSize: container.direction == .horizontal ? size.width : size.height
                )
            }
        }

        // The empty half a fresh split leaves behind. Purely an affordance now:
        // it shows the space is waiting to be filled, and the seam running
        // along its edge is what a drop actually lands on.
        if container.children.count == 1 {
            NestedDropZone(
                columnIndex: columnIndex,
                rowIndex: rowIndex,
                windowIndex: windowIndex,
                isInColumn: isInColumn
            )
                .frame(
                    width: container.direction == .horizontal ? size.width * 0.5 : size.width,
                    height: container.direction == .vertical ? size.height * 0.5 : size.height
                )
        }
    }
}

/// A window tile within a nested container
struct NestedWindowTile: View {
    let windowNode: LayoutWindowNode
    let nestedIndex: Int
    let columnIndex: Int?
    let rowIndex: Int?
    let windowIndex: Int
    let isInColumn: Bool
    /// Which way the split runs, so the grid can orient this pane's seams.
    let splitDirection: SplitDirection
    @Environment(WindowManager.self) private var windowManager

    private var slot: WindowSlot {
        WindowSlot(
            columnIndex: columnIndex,
            rowIndex: rowIndex,
            windowIndex: windowIndex,
            nestedIndex: nestedIndex
        )
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(windowNode.window.ownerName)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(windowNode.window.title)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                if isInColumn, let colIndex = columnIndex {
                    windowManager.removeWindowFromColumnNested(columnIndex: colIndex, windowIndex: windowIndex, nestedIndex: nestedIndex)
                } else if let rIndex = rowIndex {
                    windowManager.removeWindowFromRowNested(rowIndex: rIndex, windowIndex: windowIndex, nestedIndex: nestedIndex)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorForApp(windowNode.window.ownerName))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .reportTileFrame(slot, splitDirection: splitDirection)
        .onDrag {
            windowManager.pendingDrag = .placed(slot)
            return makeDragItem()
        }
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

/// Divider handle for resizing within a nested container
struct NestedDividerHandle: View {
    let dividerIndex: Int
    let columnIndex: Int?
    let rowIndex: Int?
    let windowIndex: Int
    let isHorizontal: Bool  // true = horizontal layout (vertical divider)
    let isInColumn: Bool
    /// On-screen size of the split this divider sits in, along the drag axis.
    let containerSize: CGFloat
    @Environment(WindowManager.self) private var windowManager
    @State private var isDragging = false
    @State private var initialProp1: CGFloat = 0
    @State private var initialProp2: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: isHorizontal ? 6 : nil, height: isHorizontal ? nil : 6)
            .offset(x: isHorizontal ? dragOffset : 0, y: isHorizontal ? 0 : dragOffset)
            .contentShape(Rectangle())
            .gesture(
                // .global for the same reason as the primary dividers: the handle
                // moves with the split it controls, so a local-space translation
                // measures against a frame that is chasing the cursor.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            // Store initial proportions at drag start
                            isDragging = true
                            if isInColumn, let colIndex = columnIndex {
                                if let container = windowManager.columns[colIndex].windows[windowIndex].nestedContainer {
                                    initialProp1 = container.children[dividerIndex].proportion
                                    initialProp2 = container.children[dividerIndex + 1].proportion
                                }
                            } else if let rIndex = rowIndex {
                                if let container = windowManager.rows[rIndex].windows[windowIndex].nestedContainer {
                                    initialProp1 = container.children[dividerIndex].proportion
                                    initialProp2 = container.children[dividerIndex + 1].proportion
                                }
                            }
                        }
                        guard containerSize > 0 else { return }
                        let delta = isHorizontal ? value.translation.width : value.translation.height
                        let shift = WindowManager.achievableShift(
                            first: initialProp1,
                            second: initialProp2,
                            requested: delta / containerSize
                        )
                        dragOffset = shift * containerSize
                    }
                    .onEnded { value in
                        isDragging = false
                        dragOffset = 0
                        guard containerSize > 0 else { return }
                        let delta = isHorizontal ? value.translation.width : value.translation.height
                        let translation = delta / containerSize

                        if isInColumn, let colIndex = columnIndex {
                            windowManager.resizeNestedColumnDividerFromInitial(
                                columnIndex: colIndex,
                                windowIndex: windowIndex,
                                dividerIndex: dividerIndex,
                                initialProp1: initialProp1,
                                initialProp2: initialProp2,
                                proportionalTranslation: translation
                            )
                        } else if let rIndex = rowIndex {
                            windowManager.resizeNestedRowDividerFromInitial(
                                rowIndex: rIndex,
                                windowIndex: windowIndex,
                                dividerIndex: dividerIndex,
                                initialProp1: initialProp1,
                                initialProp2: initialProp2,
                                proportionalTranslation: translation
                            )
                        }
                    }
            )
            .onHover { hovering in
                if hovering {
                    if isHorizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }
}

/// The empty half a fresh split leaves behind.
///
/// It shows the space is waiting to be filled and offers a way to undo the
/// split. It is no longer a drop target: dropping is the grid's job, and this
/// box carrying its own handler is what made a drop mean different things in
/// different places.
struct NestedDropZone: View {
    let columnIndex: Int?
    let rowIndex: Int?
    let windowIndex: Int
    let isInColumn: Bool
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        VStack {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 30, minHeight: 30)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // Undo the split. Lives in the empty half rather than over the pane, so
        // it cannot be mistaken for the button that removes the window itself.
        .overlay(alignment: .topTrailing) {
            Button {
                windowManager.unsplitCell(
                    columnIndex: columnIndex,
                    rowIndex: rowIndex,
                    windowIndex: windowIndex
                )
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(4)
            .help("Remove this split and keep the window")
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(Color(nsColor: .separatorColor))
        )
    }
}

struct ColumnDividerHandle: View {
    let dividerIndex: Int
    /// On-screen width of the track the columns are drawn in. Drag distance is
    /// meaningless to the layout model without it — the model stores proportions,
    /// and the preview is a different size from the monitor it represents.
    let trackWidth: CGFloat
    @Environment(WindowManager.self) private var windowManager
    @State private var isDragging = false
    @State private var initialFirst: CGFloat = 0
    @State private var initialSecond: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: 8)
            // Purely visual while dragging — the layout itself is untouched until
            // the mouse comes up.
            .offset(x: dragOffset)
            .contentShape(Rectangle())
            .gesture(
                // .global on purpose: the default .local space is the handle's own
                // frame, and the handle travels with the divider as it resizes. In
                // local space a divider that keeps up with the cursor sees its own
                // translation collapse back to zero and stalls.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            let columns = windowManager.columns
                            guard dividerIndex + 1 < columns.count else { return }
                            initialFirst = columns[dividerIndex].widthProportion
                            initialSecond = columns[dividerIndex + 1].widthProportion
                        }
                        guard trackWidth > 0 else { return }
                        // Slide only as far as the split will actually absorb, so
                        // the line never sits somewhere the layout won't follow.
                        let shift = WindowManager.achievableShift(
                            first: initialFirst,
                            second: initialSecond,
                            requested: value.translation.width / trackWidth
                        )
                        dragOffset = shift * trackWidth
                    }
                    .onEnded { value in
                        isDragging = false
                        dragOffset = 0
                        guard trackWidth > 0 else { return }
                        windowManager.resizeColumnDivider(
                            atIndex: dividerIndex,
                            initialFirst: initialFirst,
                            initialSecond: initialSecond,
                            proportionalTranslation: value.translation.width / trackWidth
                        )
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

struct RowDividerHandle: View {
    let columnIndex: Int
    let dividerIndex: Int
    /// On-screen height of the track the stacked windows are drawn in.
    let trackHeight: CGFloat
    @Environment(WindowManager.self) private var windowManager
    @State private var isDragging = false
    @State private var initialFirst: CGFloat = 0
    @State private var initialSecond: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(height: 6)
            .offset(y: dragOffset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            let columns = windowManager.columns
                            guard columnIndex < columns.count,
                                  dividerIndex + 1 < columns[columnIndex].windows.count else { return }
                            initialFirst = columns[columnIndex].windows[dividerIndex].heightProportion
                            initialSecond = columns[columnIndex].windows[dividerIndex + 1].heightProportion
                        }
                        guard trackHeight > 0 else { return }
                        let shift = WindowManager.achievableShift(
                            first: initialFirst,
                            second: initialSecond,
                            requested: value.translation.height / trackHeight
                        )
                        dragOffset = shift * trackHeight
                    }
                    .onEnded { value in
                        isDragging = false
                        dragOffset = 0
                        guard trackHeight > 0 else { return }
                        windowManager.resizeRowDivider(
                            inColumn: columnIndex,
                            atIndex: dividerIndex,
                            initialFirst: initialFirst,
                            initialSecond: initialSecond,
                            proportionalTranslation: value.translation.height / trackHeight
                        )
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// MARK: - Row Mode Views

struct RowPreview: View {
    let row: Row
    let rowIndex: Int
    let isSelected: Bool
    let containerSize: CGSize
    let canRemove: Bool
    let onRemove: () -> Void
    let totalRows: Int
    @Environment(WindowManager.self) private var windowManager
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            // Row header with remove button
            HStack(spacing: 4) {
                Text("Row \(rowIndex + 1)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if canRemove {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)

            // Windows in row
            if row.windows.isEmpty {
                HStack {
                    Spacer()
                    VStack {
                        Image(systemName: "plus.rectangle.on.rectangle")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Add windows")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 1,
                            antialiased: true
                        )
                )
            } else {
                // Calculate available width for windows (container minus padding)
                let availableWidth = max(100, containerSize.width - 40)
                let dividerCount = CGFloat(row.windows.count - 1)
                let totalDividerWidth = dividerCount * 6 // 6px per divider
                let windowsWidth = availableWidth - totalDividerWidth

                HStack(spacing: 0) {
                    ForEach(Array(row.windows.enumerated()), id: \.element.id) { winIndex, rowWindow in
                        RowWindowTilePreview(
                            rowWindow: rowWindow,
                            rowIndex: rowIndex,
                            windowIndex: winIndex,
                            widthProportion: rowWindow.widthProportion
                        )
                        .frame(width: max(40, windowsWidth * rowWindow.widthProportion))

                        // Window divider within row (except after last window)
                        if winIndex < row.windows.count - 1 {
                            RowWindowDividerHandle(
                                rowIndex: rowIndex,
                                dividerIndex: winIndex,
                                trackWidth: windowsWidth
                            )
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
            }
        }
        .frame(height: max(60, ((containerSize.height - 32) - CGFloat(totalRows - 1) * 8) * row.heightProportion))
        // Drops belong to the grid — see the columns equivalent.
    }
}

struct RowWindowTilePreview: View {
    let rowWindow: RowWindow
    let rowIndex: Int
    let windowIndex: Int
    let widthProportion: CGFloat
    @Environment(WindowManager.self) private var windowManager
    @State private var isHovered = false

    private var slot: WindowSlot {
        WindowSlot(columnIndex: nil, rowIndex: rowIndex, windowIndex: windowIndex, nestedIndex: nil)
    }

    var body: some View {
        Group {
            if let window = rowWindow.window {
                singleWindowView(window: window)
            } else if let container = rowWindow.nestedContainer {
                // Shared with columns mode. The rows-only version this replaced
                // was a plain VStack of intrinsically-sized children, so a split
                // rendered as a ~90pt huddle at the top of the cell with the rest
                // left empty — and that empty area belonged to the row behind it,
                // which is why drops there never reached the split.
                NestedContainerPreview(
                    container: container,
                    columnIndex: nil,
                    windowIndex: windowIndex,
                    isInColumn: false,
                    rowIndex: rowIndex
                )
            }
        }
        .reportTileFrame(slot)
    }

    @ViewBuilder
    private func singleWindowView(window: ExternalWindow) -> some View {
        ZStack(alignment: .topTrailing) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.ownerName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(window.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    windowManager.removeWindow(rowWindow.id, fromRow: rowIndex)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colorForApp(window.ownerName))
            .onDrag {
                windowManager.pendingDrag = .placed(slot)
                return makeDragItem()
            }

            // Split button (vertical split to add sub-rows)
            if isHovered {
                Button {
                    windowManager.splitRowCell(rowIndex: rowIndex, windowIndex: windowIndex, direction: .vertical)
                } label: {
                    Image(systemName: "square.split.1x2")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

/// Horizontal divider between rows (for resizing row heights)
struct RowPrimaryDividerHandle: View {
    let dividerIndex: Int
    /// On-screen height of the track the rows are drawn in.
    let trackHeight: CGFloat
    @Environment(WindowManager.self) private var windowManager
    @State private var isDragging = false
    @State private var initialFirst: CGFloat = 0
    @State private var initialSecond: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(height: 8)
            .offset(y: dragOffset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            let rows = windowManager.rows
                            guard dividerIndex + 1 < rows.count else { return }
                            initialFirst = rows[dividerIndex].heightProportion
                            initialSecond = rows[dividerIndex + 1].heightProportion
                        }
                        guard trackHeight > 0 else { return }
                        let shift = WindowManager.achievableShift(
                            first: initialFirst,
                            second: initialSecond,
                            requested: value.translation.height / trackHeight
                        )
                        dragOffset = shift * trackHeight
                    }
                    .onEnded { value in
                        isDragging = false
                        dragOffset = 0
                        guard trackHeight > 0 else { return }
                        windowManager.resizeRowPrimaryDivider(
                            atIndex: dividerIndex,
                            initialFirst: initialFirst,
                            initialSecond: initialSecond,
                            proportionalTranslation: value.translation.height / trackHeight
                        )
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

/// Vertical divider between windows within a row (for resizing window widths)
struct RowWindowDividerHandle: View {
    let rowIndex: Int
    let dividerIndex: Int
    /// On-screen width of the track the side-by-side windows are drawn in.
    let trackWidth: CGFloat
    @Environment(WindowManager.self) private var windowManager
    @State private var isDragging = false
    @State private var initialFirst: CGFloat = 0
    @State private var initialSecond: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: 6)
            .offset(x: dragOffset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            let rows = windowManager.rows
                            guard rowIndex < rows.count,
                                  dividerIndex + 1 < rows[rowIndex].windows.count else { return }
                            initialFirst = rows[rowIndex].windows[dividerIndex].widthProportion
                            initialSecond = rows[rowIndex].windows[dividerIndex + 1].widthProportion
                        }
                        guard trackWidth > 0 else { return }
                        let shift = WindowManager.achievableShift(
                            first: initialFirst,
                            second: initialSecond,
                            requested: value.translation.width / trackWidth
                        )
                        dragOffset = shift * trackWidth
                    }
                    .onEnded { value in
                        isDragging = false
                        dragOffset = 0
                        guard trackWidth > 0 else { return }
                        windowManager.resizeWindowDivider(
                            inRow: rowIndex,
                            atIndex: dividerIndex,
                            initialFirst: initialFirst,
                            initialSecond: initialSecond,
                            proportionalTranslation: value.translation.width / trackWidth
                        )
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// MARK: - Window Picker Sidebar

struct WindowPickerSidebar: View {
    @Environment(WindowManager.self) private var windowManager
    @Binding var selectedIndex: Int
    @State private var showingAppPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Available Windows")
                    .font(.headline)

                Spacer()

                Button {
                    windowManager.refreshAvailableWindows()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            if windowManager.availableWindows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "macwindow")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No windows available")
                        .foregroundStyle(.secondary)
                    Text("Open some apps first")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(windowManager.availableWindows) { window in
                            AvailableWindowRow(window: window, targetIndex: selectedIndex)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Add placeholder app button
            Button {
                showingAppPicker = true
            } label: {
                HStack {
                    Image(systemName: "plus.app")
                    Text("Add App (Not Open)")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showingAppPicker) {
            PlaceholderAppPicker(targetIndex: selectedIndex)
                .environment(windowManager)
        }
    }
}

struct PlaceholderAppPicker: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(\.dismiss) var dismiss
    let targetIndex: Int

    @State private var searchText = ""
    @State private var installedApps: [(name: String, bundleId: String, path: String)] = []

    var filteredApps: [(name: String, bundleId: String, path: String)] {
        if searchText.isEmpty {
            return installedApps
        }
        return installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Placeholder App")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            TextField("Search apps...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Divider()
                .padding(.top, 8)

            List(filteredApps, id: \.bundleId) { app in
                Button {
                    addPlaceholderApp(app)
                    dismiss()
                } label: {
                    HStack {
                        if let icon = NSWorkspace.shared.icon(forFile: app.path) as NSImage? {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }
                        Text(app.name)
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 320, height: 400)
        .onAppear {
            installedApps = AppLauncher.getInstalledApps()
        }
    }

    private func addPlaceholderApp(_ app: (name: String, bundleId: String, path: String)) {
        // Launch the app first
        AppLauncher.launchApp(bundleId: app.bundleId)

        // Wait a bit for the window to appear, then refresh and add
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            windowManager.refreshAvailableWindows()

            // Try to find and add the window
            if let window = windowManager.availableWindows.first(where: { $0.ownerName == app.name }) {
                if windowManager.layoutMode == .columns {
                    windowManager.addWindow(window, toColumn: targetIndex)
                } else {
                    windowManager.addWindow(window, toRow: targetIndex)
                }
            }
        }
    }
}

struct AvailableWindowRow: View {
    let window: ExternalWindow
    let targetIndex: Int
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        Button {
            if windowManager.layoutMode == .columns {
                windowManager.addWindow(window, toColumn: targetIndex)
            } else {
                windowManager.addWindow(window, toRow: targetIndex)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.ownerName)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(window.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
            .onDrag {
                windowManager.pendingDrag = .available(window.id)
                return makeDragItem()
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active Layout View

struct ActiveLayoutView: View {
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        VStack(spacing: 0) {
            // Monitor tabs
            MonitorTabs()

            Divider()

            // Header
            HStack {
                Button("Stop & Edit") {
                    windowManager.stopManaging()
                    windowManager.appState = .configuring
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)

                    Text("Managing \(windowManager.totalWindowCount) windows")
                        .font(.headline)
                }

                Spacer()

                // Save/Load menu - available while running
                LayoutMenu()

                Button("Reset") {
                    windowManager.resetToMonitorSelect()
                }
                .foregroundStyle(.red)
            }
            .padding()

            Divider()

            // Active layout preview
            ActiveLayoutPreview()
        }
    }
}

struct ActiveLayoutPreview: View {
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        GeometryReader { geometry in
            if windowManager.layoutMode == .columns {
                // Columns mode
                HStack(spacing: 0) {
                    ForEach(Array(windowManager.columns.enumerated()), id: \.element.id) { index, column in
                        VStack(spacing: 0) {
                            ForEach(Array(column.windows.enumerated()), id: \.element.id) { winIndex, colWindow in
                                ActiveWindowTile(columnWindow: colWindow, columnIndex: index, windowIndex: winIndex)
                                    .frame(height: (geometry.size.height - 20) * colWindow.heightProportion)

                                if winIndex < column.windows.count - 1 {
                                    RowDividerHandle(
                                        columnIndex: index,
                                        dividerIndex: winIndex,
                                        trackHeight: geometry.size.height - 20
                                    )
                                }
                            }
                        }
                        .frame(width: (geometry.size.width - 20) * column.widthProportion)

                        if index < windowManager.columns.count - 1 {
                            ColumnDividerHandle(
                                dividerIndex: index,
                                trackWidth: geometry.size.width - 20
                            )
                        }
                    }
                }
                .padding(10)
            } else {
                // Rows mode
                VStack(spacing: 0) {
                    ForEach(Array(windowManager.rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.windows.enumerated()), id: \.element.id) { winIndex, rowWindow in
                                ActiveRowWindowTile(rowWindow: rowWindow, rowIndex: index, windowIndex: winIndex)
                                    .frame(width: (geometry.size.width - 20) * rowWindow.widthProportion)

                                if winIndex < row.windows.count - 1 {
                                    RowWindowDividerHandle(
                                        rowIndex: index,
                                        dividerIndex: winIndex,
                                        trackWidth: geometry.size.width - 20
                                    )
                                }
                            }
                        }
                        .frame(height: (geometry.size.height - 20) * row.heightProportion)

                        if index < windowManager.rows.count - 1 {
                            RowPrimaryDividerHandle(
                                dividerIndex: index,
                                trackHeight: geometry.size.height - 20
                            )
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ActiveWindowTile: View {
    let columnWindow: ColumnWindow
    let columnIndex: Int
    let windowIndex: Int
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        Group {
            if let window = columnWindow.window {
                VStack(spacing: 4) {
                    Text(window.ownerName)
                        .font(.caption)
                        .fontWeight(.medium)

                    Text(window.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorForApp(window.ownerName))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    window.raise()
                }
            } else if let container = columnWindow.nestedContainer {
                // Show nested container
                ActiveNestedContainerTile(container: container, isColumn: true, columnIndex: columnIndex, windowIndex: windowIndex)
            }
        }
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

struct ActiveRowWindowTile: View {
    let rowWindow: RowWindow
    let rowIndex: Int
    let windowIndex: Int
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        Group {
            if let window = rowWindow.window {
                VStack(spacing: 4) {
                    Text(window.ownerName)
                        .font(.caption)
                        .fontWeight(.medium)

                    Text(window.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorForApp(window.ownerName))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture {
                    window.raise()
                }
            } else if let container = rowWindow.nestedContainer {
                // Show nested container
                ActiveNestedContainerTile(container: container, isColumn: false, rowIndex: rowIndex, windowIndex: windowIndex)
            }
        }
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

// MARK: - Nested Container Views for Active Layout

struct ActiveNestedContainerTile: View {
    let container: LayoutContainer
    let isColumn: Bool
    var columnIndex: Int? = nil
    var rowIndex: Int? = nil
    var windowIndex: Int = 0
    @Environment(WindowManager.self) private var windowManager

    var body: some View {
        GeometryReader { geometry in
            Group {
                if container.direction == .horizontal {
                    HStack(spacing: 0) {
                        ForEach(Array(container.children.enumerated()), id: \.element.id) { index, node in
                            nodeView(node, proportion: node.proportion)
                                .frame(width: geometry.size.width * node.proportion)

                            // Add divider between children
                            if index < container.children.count - 1 {
                                ActiveNestedDivider(
                                    dividerIndex: index,
                                    columnIndex: columnIndex,
                                    rowIndex: rowIndex,
                                    windowIndex: windowIndex,
                                    isHorizontal: true,
                                    isColumn: isColumn,
                                    containerSize: geometry.size.width
                                )
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(container.children.enumerated()), id: \.element.id) { index, node in
                            nodeView(node, proportion: node.proportion)
                                .frame(height: geometry.size.height * node.proportion)

                            // Add divider between children
                            if index < container.children.count - 1 {
                                ActiveNestedDivider(
                                    dividerIndex: index,
                                    columnIndex: columnIndex,
                                    rowIndex: rowIndex,
                                    windowIndex: windowIndex,
                                    isHorizontal: false,
                                    isColumn: isColumn,
                                    containerSize: geometry.size.height
                                )
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func nodeView(_ node: LayoutWindowNode, proportion: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(node.window.ownerName)
                .font(.caption2)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(node.window.title)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorForApp(node.window.ownerName))
        .onTapGesture {
            node.window.raise()
        }
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

/// Divider handle in active nested container view
struct ActiveNestedDivider: View {
    let dividerIndex: Int
    let columnIndex: Int?
    let rowIndex: Int?
    let windowIndex: Int
    let isHorizontal: Bool  // true = horizontal layout (vertical divider line)
    let isColumn: Bool
    let containerSize: CGFloat
    @Environment(WindowManager.self) private var windowManager
    @State private var isDragging = false
    @State private var initialProp1: CGFloat = 0
    @State private var initialProp2: CGFloat = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: isHorizontal ? 4 : nil, height: isHorizontal ? nil : 4)
            .offset(x: isHorizontal ? dragOffset : 0, y: isHorizontal ? 0 : dragOffset)
            .contentShape(Rectangle())
            .gesture(
                // .global for the same reason as the primary dividers: the handle
                // moves with the split it controls, so a local-space translation
                // measures against a frame that is chasing the cursor.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            // Store initial proportions at drag start
                            isDragging = true
                            if isColumn, let colIndex = columnIndex {
                                if let container = windowManager.columns[colIndex].windows[windowIndex].nestedContainer {
                                    initialProp1 = container.children[dividerIndex].proportion
                                    initialProp2 = container.children[dividerIndex + 1].proportion
                                }
                            } else if let rIndex = rowIndex {
                                if let container = windowManager.rows[rIndex].windows[windowIndex].nestedContainer {
                                    initialProp1 = container.children[dividerIndex].proportion
                                    initialProp2 = container.children[dividerIndex + 1].proportion
                                }
                            }
                        }
                        guard containerSize > 0 else { return }
                        let delta = isHorizontal ? value.translation.width : value.translation.height
                        let shift = WindowManager.achievableShift(
                            first: initialProp1,
                            second: initialProp2,
                            requested: delta / containerSize
                        )
                        dragOffset = shift * containerSize
                    }
                    .onEnded { value in
                        isDragging = false
                        dragOffset = 0
                        guard containerSize > 0 else { return }
                        let delta = isHorizontal ? value.translation.width : value.translation.height
                        let translation = delta / containerSize

                        if isColumn, let colIndex = columnIndex {
                            windowManager.resizeNestedColumnDividerFromInitial(
                                columnIndex: colIndex,
                                windowIndex: windowIndex,
                                dividerIndex: dividerIndex,
                                initialProp1: initialProp1,
                                initialProp2: initialProp2,
                                proportionalTranslation: translation
                            )
                        } else if let rIndex = rowIndex {
                            windowManager.resizeNestedRowDividerFromInitial(
                                rowIndex: rIndex,
                                windowIndex: windowIndex,
                                dividerIndex: dividerIndex,
                                initialProp1: initialProp1,
                                initialProp2: initialProp2,
                                proportionalTranslation: translation
                            )
                        }
                    }
            )
            .onHover { hovering in
                if hovering {
                    if isHorizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// MARK: - Layout Save/Load Menu

struct LayoutMenu: View {
    @Environment(WindowManager.self) private var windowManager
    @State private var showingSaveDialog = false
    @State private var layoutName = ""
    @State private var saveAsWorkspace = false
    @State private var selectedPresetSlot = 0  // 0 = None, 1-9 = slot
    @State private var savedLayouts: [SavedLayoutInfo] = []
    @State private var monitorPresetNames: [Int: String] = [:]
    @State private var workspacePresetNames: [Int: String] = [:]

    struct SavedLayoutInfo: Identifiable {
        let id = UUID()
        let name: String
        let isWorkspace: Bool
        let presetSlot: Int?
    }

    var body: some View {
        Menu {
            Button("Save Layout...") {
                showingSaveDialog = true
            }
            .disabled(!windowManager.hasAnyWindows)

            if !savedLayouts.isEmpty {
                Divider()

                ForEach(savedLayouts) { layout in
                    Button {
                        windowManager.loadLayout(name: layout.name)
                    } label: {
                        HStack {
                            Text(layout.name)
                            if layout.isWorkspace {
                                Text("(Workspace)")
                                    .foregroundStyle(.secondary)
                            }
                            if let slot = layout.presetSlot {
                                Text("[\(slot)]")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                Menu("Delete Layout") {
                    ForEach(savedLayouts) { layout in
                        Button(layout.name, role: .destructive) {
                            windowManager.deleteLayout(name: layout.name)
                            refreshLayouts()
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .onAppear {
            refreshLayouts()
        }
        .sheet(isPresented: $showingSaveDialog) {
            VStack(spacing: 16) {
                Text("Save Layout")
                    .font(.headline)
                    .onAppear {
                        monitorPresetNames = windowManager.getMonitorPresetNames()
                        workspacePresetNames = windowManager.getWorkspacePresetNames()
                    }

                TextField("Layout Name", text: $layoutName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)

                // Scope picker
                Picker("Scope", selection: $saveAsWorkspace) {
                    Text("Current Monitor Only").tag(false)
                    Text("Full Workspace (All Monitors)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .frame(width: 280)

                // Preset slot picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assign to hotkey:")
                        .font(.subheadline)

                    Picker("", selection: $selectedPresetSlot) {
                        Text("None").tag(0)
                        ForEach(1...9, id: \.self) { slot in
                            let presetNames = saveAsWorkspace ? workspacePresetNames : monitorPresetNames
                            let shortcut = saveAsWorkspace
                                ? GlobalShortcut.workspacePreset(slot)
                                : GlobalShortcut.monitorPreset(slot)
                            if let existingName = presetNames[slot] {
                                Text("\(shortcut): \(existingName)").tag(slot)
                            } else {
                                Text("\(shortcut): (empty)").tag(slot)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 280)
                }

                HStack {
                    Button("Cancel") {
                        resetDialog()
                    }

                    Button("Save") {
                        if !layoutName.isEmpty {
                            windowManager.saveCurrentLayout(
                                name: layoutName,
                                asWorkspace: saveAsWorkspace,
                                presetSlot: selectedPresetSlot > 0 ? selectedPresetSlot : nil
                            )
                            refreshLayouts()
                            resetDialog()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(layoutName.isEmpty)
                }
            }
            .padding()
            .frame(width: 320)
        }
    }

    private func resetDialog() {
        showingSaveDialog = false
        layoutName = ""
        saveAsWorkspace = false
        selectedPresetSlot = 0
    }

    private func refreshLayouts() {
        savedLayouts = windowManager.listSavedLayoutsWithInfo().map {
            SavedLayoutInfo(name: $0.name, isWorkspace: $0.isWorkspace, presetSlot: $0.presetSlot)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    private let licenseManager = LicenseManager.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var enteredKey: String = ""

    var body: some View {
        Form {
            // License Section — hidden entirely while licensing is switched off,
            // rather than showing a "Licensed" row for a licence nobody bought.
            if LicenseManager.isEnabled {
                Section("License") {
                    LicenseStatusRow(state: licenseManager.licenseState)

                    if case .licensed = licenseManager.licenseState {
                        // Already licensed
                        HStack {
                            Text("License Key")
                            Spacer()
                            Text(maskedKey(licenseManager.licenseKey))
                                .foregroundStyle(.secondary)
                                .font(.system(.body, design: .monospaced))
                        }
                    } else {
                        // Trial or expired - show key entry
                        HStack {
                            TextField("Enter license key", text: $enteredKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))

                            Button(licenseManager.isValidating ? "Validating..." : "Activate") {
                                licenseManager.saveLicenseKey(enteredKey)
                                licenseManager.validateLicense { success, error in
                                    if success {
                                        enteredKey = ""
                                    }
                                }
                            }
                            .disabled(enteredKey.isEmpty || licenseManager.isValidating)
                        }

                        if let error = licenseManager.validationError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button("Buy License") {
                            licenseManager.openPurchasePage()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.setEnabled(newValue)
                    }
            }

            Section("Keyboard Shortcuts") {
                ShortcutRow(action: "Toggle Start/Stop", shortcut: GlobalShortcut.toggle)
                Divider()
                ShortcutRow(action: "Load Preset 1-9", shortcut: GlobalShortcut.monitorPresetRange)
                Text("Load preset for the monitor under the pointer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                ShortcutRow(action: "Load All Monitors", shortcut: GlobalShortcut.workspacePresetRange)
                Text("Load workspace preset (all monitors)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !AppDelegate.failedRegistrations.isEmpty {
                    Divider()
                    Label(
                        "Not registered: \(AppDelegate.failedRegistrations.joined(separator: ", "))",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    Text("Another app already owns these shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 400, height: 380)
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return key }
        let prefix = key.prefix(4)
        let suffix = key.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

struct LicenseStatusRow: View {
    let state: LicenseState

    var body: some View {
        HStack {
            Text("Status")
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state {
        case .trial(let daysRemaining):
            HStack(spacing: 4) {
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                Text("Trial - \(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left")
                    .foregroundStyle(.secondary)
            }
        case .trialExpired:
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Trial Expired")
                    .foregroundStyle(.red)
            }
        case .licensed:
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Licensed")
                    .foregroundStyle(.green)
            }
        }
    }
}

struct ShortcutRow: View {
    let action: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Launch at Login Helper

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("LaunchAtLogin error: \(error)")
        }
    }
}

#Preview {
    ContentView()
        .environment(WindowManager.shared)
}
