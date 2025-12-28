import SwiftUI

struct ContentView: View {
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        Group {
            switch windowManager.appState {
            case .monitorSelect:
                MonitorSelectView()
            case .setup:
                SetupView()
            case .configuring:
                ConfigureColumnsView()
            case .active:
                ActiveLayoutView()
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            // Request accessibility if needed - macOS will show its own prompt
            if !AccessibilityHelper.checkAccessibilityPermissions() {
                AccessibilityHelper.requestAccessibilityPermissions()
            }
            windowManager.refreshMonitors()
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
        .padding(.top, 28) // Push below invisible title bar area
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
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

// MARK: - Setup View (Choose Column Count)

struct SetupView: View {
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        VStack(spacing: 0) {
            // Monitor tabs
            MonitorTabs()

            Divider()

            VStack(spacing: 30) {
                Spacer()

                Text("How many columns?")
                    .font(.title)
                    .fontWeight(.bold)

                HStack(spacing: 20) {
                    ForEach(1...4, id: \.self) { count in
                        ColumnCountButton(count: count) {
                            windowManager.setupColumns(count: count)
                        }
                    }
                }

                Text("You can add multiple windows to each column")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Divider with "or"
                HStack {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                    Text("or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 1)
                }
                .frame(maxWidth: 300)

                // Scan existing layout button
                Button {
                    _ = windowManager.scanExistingLayout()
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.3.group")
                            .font(.system(size: 24))
                        Text("Use Current Layout")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Scan windows on this monitor")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 180, height: 80)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
    }
}

struct ColumnCountButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                // Visual preview of columns
                HStack(spacing: 2) {
                    ForEach(0..<count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(width: 20, height: 50)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.accentColor, lineWidth: 1)
                            )
                    }
                }

                Text("\(count)")
                    .font(.title)
                    .fontWeight(.semibold)
            }
            .frame(width: 100, height: 100)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Configure Columns View

struct ConfigureColumnsView: View {
    @EnvironmentObject var windowManager: WindowManager
    @State private var selectedColumn: Int = 0
    @State private var showingWindowPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Monitor tabs
            MonitorTabs()

            Divider()

            // Header
            HStack {
                Button {
                    windowManager.resetSetup()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Columns")
                    }
                }

                Spacer()

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
                // Column layout preview
                ColumnLayoutPreview(selectedColumn: $selectedColumn)
                    .frame(minWidth: 400)

                Divider()

                // Window picker sidebar
                WindowPickerSidebar(selectedColumn: $selectedColumn)
                    .frame(width: 280)
            }
        }
    }
}

struct ColumnLayoutPreview: View {
    @EnvironmentObject var windowManager: WindowManager
    @Binding var selectedColumn: Int

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(windowManager.columns.enumerated()), id: \.element.id) { index, column in
                    ColumnPreview(
                        column: column,
                        columnIndex: index,
                        isSelected: selectedColumn == index,
                        containerSize: geometry.size
                    )
                    .onTapGesture {
                        selectedColumn = index
                    }

                    // Column divider (except after last column)
                    if index < windowManager.columns.count - 1 {
                        ColumnDividerHandle(dividerIndex: index)
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ColumnPreview: View {
    let column: Column
    let columnIndex: Int
    let isSelected: Bool
    let containerSize: CGSize
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        VStack(spacing: 0) {
            // Column header
            Text("Column \(columnIndex + 1)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? .primary : .secondary)
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
                VStack(spacing: 0) {
                    ForEach(Array(column.windows.enumerated()), id: \.element.id) { winIndex, colWindow in
                        WindowTilePreview(
                            columnWindow: colWindow,
                            columnIndex: columnIndex,
                            windowIndex: winIndex,
                            heightProportion: colWindow.heightProportion
                        )

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
        .frame(width: (containerSize.width - 32) * column.widthProportion - 8)
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
    }

    private func colorForApp(_ name: String) -> Color {
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.2, brightness: 0.95)
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

// MARK: - Window Picker Sidebar

struct WindowPickerSidebar: View {
    @EnvironmentObject var windowManager: WindowManager
    @Binding var selectedColumn: Int

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
                            AvailableWindowRow(window: window, targetColumn: selectedColumn)
                        }
                    }
                    .padding()
                }
            }

            Divider()

            // Column selector
            HStack {
                Text("Add to:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $selectedColumn) {
                    ForEach(0..<windowManager.columns.count, id: \.self) { index in
                        Text("Column \(index + 1)").tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct AvailableWindowRow: View {
    let window: ExternalWindow
    let targetColumn: Int
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        Button {
            windowManager.addWindow(window, toColumn: targetColumn)
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
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ActiveWindowTile: View {
    let columnWindow: ColumnWindow

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
        let hash = abs(name.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.25, brightness: 0.92)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        Form {
            Section("General") {
                Text("Settings coming soon...")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 400, height: 200)
    }
}

#Preview {
    ContentView()
        .environmentObject(WindowManager.shared)
}
