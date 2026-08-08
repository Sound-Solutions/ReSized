import SwiftUI
import AppKit
import Carbon

@main
struct ReSizedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("ReSized", id: "main") {
            ContentView()
                .environment(WindowManager.shared)
                .onAppear {
                    // Store openWindow action for use from AppDelegate
                    AppDelegate.openWindowAction = { [openWindow] in
                        openWindow(id: "main")
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
        }
    }
}

/// Single source of truth for the global hotkeys, so the Carbon registration and
/// every label describing it cannot drift apart.
///
/// These deliberately avoid Command+Shift+number: Command+Shift+3/4/5/6 are the
/// system screenshot shortcuts, which the OS claims first, so preset slots 3, 4
/// and 5 were effectively dead. Control+Option+number collides with nothing by
/// default (plain Control+number is Mission Control's "switch to desktop N",
/// which is why Option is in there).
enum GlobalShortcut {
    static let toggle = "⌃⌥R"
    static let monitorPresetRange = "⌃⌥1-9"
    static let workspacePresetRange = "⌃⌥⇧1-9"

    static func monitorPreset(_ slot: Int) -> String { "⌃⌥\(slot)" }
    static func workspacePreset(_ slot: Int) -> String { "⌃⌥⇧\(slot)" }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var startStopMenuItem: NSMenuItem?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    /// Hotkeys the OS refused to register, surfaced in Settings.
    ///
    /// Note this only catches hard registration failures. A hotkey already owned
    /// by a system shortcut can still register successfully here and simply never
    /// fire, so an empty list is not proof every binding works.
    /// Only touched from applicationDidFinishLaunching and the Settings view,
    /// both of which run on the main thread.
    private(set) static var failedRegistrations: [String] = []

    // Static closure to open window from SwiftUI
    static var openWindowAction: (() -> Void)?

    // Hotkey ID scheme:
    // ID 1 = toggle start/stop
    // ID 10-18 = load monitor preset 1-9 for the monitor under the pointer
    // ID 20-28 = load workspace preset 1-9 (all monitors)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Deliberately does NOT prompt for accessibility here. The system dialog
        // used to fire on every launch before the user had seen anything of ours,
        // and then sat on top of our own permission overlay saying the same thing
        // twice. PermissionOverlay owns this flow now and sends people straight
        // to the Accessibility pane.

        setupMenuBar()
        registerAllHotKeys()

        // Observe WindowManager's isActive changes to update menu
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuState),
            name: NSNotification.Name("WindowManagerActiveChanged"),
            object: nil
        )
    }

    private func registerAllHotKeys() {
        // Install single event handler for all hotkeys
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                // Extract the hotkey ID from the event
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr else { return status }

                DispatchQueue.main.async {
                    AppDelegate.handleHotKey(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            nil
        )

        let signature = OSType(0x52535A44) // "RSZD"

        AppDelegate.failedRegistrations = []

        // Toggle start/stop - ID 1
        registerSingleHotKey(
            keyCode: 15, // R
            modifiers: controlKey | optionKey,
            id: 1,
            signature: signature,
            label: GlobalShortcut.toggle
        )

        // Key codes for 1-9: 18, 19, 20, 21, 23, 22, 26, 28, 25
        let numberKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

        // Load monitor preset - IDs 10-18
        for (index, keyCode) in numberKeyCodes.enumerated() {
            registerSingleHotKey(
                keyCode: keyCode,
                modifiers: controlKey | optionKey,
                id: UInt32(10 + index),
                signature: signature,
                label: GlobalShortcut.monitorPreset(index + 1)
            )
        }

        // Load workspace preset (all monitors) - IDs 20-28
        for (index, keyCode) in numberKeyCodes.enumerated() {
            registerSingleHotKey(
                keyCode: keyCode,
                modifiers: controlKey | optionKey | shiftKey,
                id: UInt32(20 + index),
                signature: signature,
                label: GlobalShortcut.workspacePreset(index + 1)
            )
        }

        if !AppDelegate.failedRegistrations.isEmpty {
            AccessibilityHelper.logDebug(
                "Hotkeys the system refused: \(AppDelegate.failedRegistrations.joined(separator: ", "))"
            )
        }
    }

    @discardableResult
    private func registerSingleHotKey(
        keyCode: UInt32,
        modifiers: Int,
        id: UInt32,
        signature: OSType,
        label: String
    ) -> Bool {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = signature
        hotKeyID.id = id

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            // Previously this only printed, so a shortcut that never worked gave
            // the user no signal at all.
            AppDelegate.failedRegistrations.append(label)
            return false
        }

        hotKeyRefs[id] = ref
        return true
    }

    private static func handleHotKey(id: UInt32) {
        let wm = WindowManager.shared

        switch id {
        case 1:
            // Toggle start/stop
            if wm.hasAnyActiveLayout {
                wm.stopAllLayouts()
            } else {
                wm.startAllLayouts()
            }

        case 10...18:
            // Load monitor preset for focused window's monitor (Cmd+Shift+1-9)
            let slot = Int(id) - 9  // Convert ID 10-18 to slot 1-9
            wm.handleMonitorPresetLoad(slot: slot)

        case 20...28:
            // Load workspace preset - all monitors (Cmd+Option+Shift+1-9)
            let slot = Int(id) - 19  // Convert ID 20-28 to slot 1-9
            wm.loadWorkspacePresetBySlot(slot: slot)

        default:
            break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep running as menu bar app
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "ReSized")
        }

        let menu = NSMenu()

        // Start/Stop item
        startStopMenuItem = NSMenuItem(title: "Start Managing", action: #selector(toggleStartStop), keyEquivalent: "")
        startStopMenuItem?.target = self
        menu.addItem(startStopMenuItem!)

        menu.addItem(NSMenuItem.separator())

        // Show Config item
        let showConfigItem = NSMenuItem(title: "Show Config...", action: #selector(showConfig), keyEquivalent: ",")
        showConfigItem.target = self
        menu.addItem(showConfigItem)

        // Settings item
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit item
        let quitItem = NSMenuItem(title: "Quit ReSized", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func toggleStartStop() {
        let wm = WindowManager.shared
        if wm.hasAnyActiveLayout {
            wm.stopAllLayouts()
        } else {
            wm.startAllLayouts()
        }
        updateMenuState()
    }

    @objc private func showConfig() {
        NSApp.activate(ignoringOtherApps: true)

        // Try to find existing window first
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "ReSized" }) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // If no window exists, use the stored openWindow action
        if let openWindow = AppDelegate.openWindowAction {
            openWindow()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        // Send the standard action rather than synthesising a Cmd+, keystroke.
        // NSApp.activate is asynchronous, so a posted key event could land before
        // we were actually frontmost — opening whichever app still had focus and
        // its settings window instead of ours.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func updateMenuState() {
        let isActive = WindowManager.shared.hasAnyActiveLayout
        startStopMenuItem?.title = isActive ? "Stop Managing" : "Start Managing"

        // Update status bar icon
        if let button = statusItem?.button {
            let symbolName = isActive ? "rectangle.split.3x1.fill" : "rectangle.split.3x1"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ReSized")
        }
    }
}
