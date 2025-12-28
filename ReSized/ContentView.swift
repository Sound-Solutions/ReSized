import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - Drag and Drop Data

struct WindowDragData: Codable, Transferable {
    let windowId: UUID
    let sourceColumn: Int?  // nil if from sidebar
    let sourceRow: Int?     // nil if from sidebar (rows mode)
    let sourceIndex: Int?   // position within column/row
    let externalWindowId: UUID?  // For sidebar items, the ExternalWindow.id

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

// MARK: - Permission Overlay (First Launch)

struct PermissionOverlay: View {
    var onGrantAccess: () -> Void

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
                    .frame(maxWidth: 260)

                Button("Grant Access") {
                    onGrantAccess()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding(24)
            .background(Color(NSColor.windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 20)
        }
    }
}

// MARK: - Trial Expired Overlay

struct TrialExpiredOverlay: View {
    @ObservedObject var licenseManager: LicenseManager
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
    @EnvironmentObject var windowManager: WindowManager
    @StateObject private var licenseManager = LicenseManager.shared
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
                            PermissionOverlay {
                                AccessibilityHelper.requestAccessibilityPermissions()
                                startPermissionPolling()
                            }
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
        }
    }

    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if AccessibilityHelper.checkAccessibilityPermissions() {
                timer.invalidate()
                hasAccessibilityPermission = true
                // Scan windows now that we have permission
                _ = windowManager.scanExistingLayout()
            }
        }
    }
}

// MARK: - Layout Mode Picker View

struct LayoutModePickerView: View {
    @EnvironmentObject var windowManager: WindowManager
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
    @EnvironmentObject var windowManager: WindowManager

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
    @EnvironmentObject var windowManager: WindowManager
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
    @EnvironmentObject var windowManager: WindowManager
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
    @EnvironmentObject var windowManager: WindowManager
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
    @EnvironmentObject var windowManager: WindowManager
    @Binding var selectedIndex: Int

    var body: some View {
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
                            ColumnDividerHandle(dividerIndex: index)
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
                            RowPrimaryDividerHandle(dividerIndex: index)
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
    @EnvironmentObject var windowManager: WindowManager
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
                            RowDividerHandle(columnIndex: columnIndex, dividerIndex: winIndex)
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(isDropTarget ? 1 : 0)
        )
        .dropDestination(for: WindowDragData.self) { items, location in
            guard let dragData = items.first else { return false }
            // Calculate drop index based on Y position
            let dropIndex = calculateDropIndex(at: location.y, windowCount: column.windows.count)
            windowManager.handleColumnDrop(dragData: dragData, targetColumn: columnIndex, atIndex: dropIndex)
            return true
        } isTargeted: { isTargeted in
            isDropTarget = isTargeted
        }
    }

    private func calculateDropIndex(at yPosition: CGFloat, windowCount: Int) -> Int {
        guard windowCount > 0 else { return 0 }
        // Estimate position based on equal distribution (header is ~32px)
        let contentHeight = containerSize.height - 40
        let windowHeight = contentHeight / CGFloat(windowCount)
        let adjustedY = yPosition - 32 // Account for header
        let index = Int(adjustedY / windowHeight)
        return max(0, min(index, windowCount))
    }
}

struct WindowTilePreview: View {
    let columnWindow: ColumnWindow
    let columnIndex: Int
    let windowIndex: Int
    let heightProportion: CGFloat
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(columnWindow.window.ownerName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(columnWindow.window.title)
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
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorForApp(columnWindow.window.ownerName))
        .draggable(WindowDragData(
            windowId: columnWindow.id,
            sourceColumn: columnIndex,
            sourceRow: nil,
            sourceIndex: windowIndex,
            externalWindowId: nil
        ))
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

struct ColumnDividerHandle: View {
    let dividerIndex: Int
    @EnvironmentObject var windowManager: WindowManager
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        windowManager.resizeColumnDivider(atIndex: dividerIndex, delta: value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
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
    @EnvironmentObject var windowManager: WindowManager
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(height: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        windowManager.resizeRowDivider(
                            inColumn: columnIndex,
                            atIndex: dividerIndex,
                            delta: value.translation.height
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
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
    @EnvironmentObject var windowManager: WindowManager
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
                            RowWindowDividerHandle(rowIndex: rowIndex, dividerIndex: winIndex)
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(isDropTarget ? 1 : 0)
        )
        .dropDestination(for: WindowDragData.self) { items, location in
            guard let dragData = items.first else { return false }
            // Calculate drop index based on X position
            let dropIndex = calculateDropIndex(at: location.x, windowCount: row.windows.count)
            windowManager.handleRowDrop(dragData: dragData, targetRow: rowIndex, atIndex: dropIndex)
            return true
        } isTargeted: { isTargeted in
            isDropTarget = isTargeted
        }
    }

    private func calculateDropIndex(at xPosition: CGFloat, windowCount: Int) -> Int {
        guard windowCount > 0 else { return 0 }
        // Estimate position based on equal distribution
        let contentWidth = containerSize.width - 40
        let windowWidth = contentWidth / CGFloat(windowCount)
        let index = Int(xPosition / windowWidth)
        return max(0, min(index, windowCount))
    }
}

struct RowWindowTilePreview: View {
    let rowWindow: RowWindow
    let rowIndex: Int
    let windowIndex: Int
    let widthProportion: CGFloat
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rowWindow.window.ownerName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(rowWindow.window.title)
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
        .background(colorForApp(rowWindow.window.ownerName))
        .draggable(WindowDragData(
            windowId: rowWindow.id,
            sourceColumn: nil,
            sourceRow: rowIndex,
            sourceIndex: windowIndex,
            externalWindowId: nil
        ))
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

/// Horizontal divider between rows (for resizing row heights)
struct RowPrimaryDividerHandle: View {
    let dividerIndex: Int
    @EnvironmentObject var windowManager: WindowManager
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(height: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        windowManager.resizeRowPrimaryDivider(atIndex: dividerIndex, delta: value.translation.height)
                    }
                    .onEnded { _ in
                        isDragging = false
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
    @EnvironmentObject var windowManager: WindowManager
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        windowManager.resizeWindowDivider(
                            inRow: rowIndex,
                            atIndex: dividerIndex,
                            delta: value.translation.width
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
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
    @EnvironmentObject var windowManager: WindowManager
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
                .environmentObject(windowManager)
        }
    }
}

struct PlaceholderAppPicker: View {
    @EnvironmentObject var windowManager: WindowManager
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
    @EnvironmentObject var windowManager: WindowManager

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
            .draggable(WindowDragData(
                windowId: UUID(),  // Placeholder, not used for sidebar
                sourceColumn: nil,
                sourceRow: nil,
                sourceIndex: nil,
                externalWindowId: window.id
            ))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active Layout View

struct ActiveLayoutView: View {
    @EnvironmentObject var windowManager: WindowManager

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
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        GeometryReader { geometry in
            if windowManager.layoutMode == .columns {
                // Columns mode
                HStack(spacing: 0) {
                    ForEach(Array(windowManager.columns.enumerated()), id: \.element.id) { index, column in
                        VStack(spacing: 0) {
                            ForEach(Array(column.windows.enumerated()), id: \.element.id) { winIndex, colWindow in
                                ActiveWindowTile(columnWindow: colWindow)
                                    .frame(height: (geometry.size.height - 20) * colWindow.heightProportion)

                                if winIndex < column.windows.count - 1 {
                                    RowDividerHandle(columnIndex: index, dividerIndex: winIndex)
                                }
                            }
                        }
                        .frame(width: (geometry.size.width - 20) * column.widthProportion)

                        if index < windowManager.columns.count - 1 {
                            ColumnDividerHandle(dividerIndex: index)
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
                                ActiveRowWindowTile(rowWindow: rowWindow)
                                    .frame(width: (geometry.size.width - 20) * rowWindow.widthProportion)

                                if winIndex < row.windows.count - 1 {
                                    RowWindowDividerHandle(rowIndex: index, dividerIndex: winIndex)
                                }
                            }
                        }
                        .frame(height: (geometry.size.height - 20) * row.heightProportion)

                        if index < windowManager.rows.count - 1 {
                            RowPrimaryDividerHandle(dividerIndex: index)
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
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        VStack(spacing: 4) {
            Text(columnWindow.window.ownerName)
                .font(.caption)
                .fontWeight(.medium)

            Text(columnWindow.window.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorForApp(columnWindow.window.ownerName))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            columnWindow.window.raise()
        }
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

struct ActiveRowWindowTile: View {
    let rowWindow: RowWindow
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        VStack(spacing: 4) {
            Text(rowWindow.window.ownerName)
                .font(.caption)
                .fontWeight(.medium)

            Text(rowWindow.window.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colorForApp(rowWindow.window.ownerName))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            rowWindow.window.raise()
        }
    }

    private func colorForApp(_ name: String) -> Color {
        let hue = windowManager.hueForApp(name)
        return Color(hue: hue, saturation: 1.0, brightness: 0.5).opacity(0.5)
    }
}

// MARK: - Layout Save/Load Menu

struct LayoutMenu: View {
    @EnvironmentObject var windowManager: WindowManager
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
                            let shortcut = saveAsWorkspace ? "⌘⌥⇧\(slot)" : "⌘⇧\(slot)"
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
    @StateObject private var licenseManager = LicenseManager.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var enteredKey: String = ""

    var body: some View {
        Form {
            // License Section
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

            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        LaunchAtLogin.setEnabled(newValue)
                    }
            }

            Section("Keyboard Shortcuts") {
                ShortcutRow(action: "Toggle Start/Stop", shortcut: "⌘⇧R")
                Divider()
                ShortcutRow(action: "Load Preset 1-9", shortcut: "⌘⇧1-9")
                Text("Load preset for current monitor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                ShortcutRow(action: "Load All Monitors", shortcut: "⌘⌥⇧1-9")
                Text("Load workspace preset (all monitors)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .environmentObject(WindowManager.shared)
}
