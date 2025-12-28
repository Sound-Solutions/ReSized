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
                .environmentObject(WindowManager.shared)
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

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var startStopMenuItem: NSMenuItem?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]

    // Static closure to open window from SwiftUI
    static var openWindowAction: (() -> Void)?

    // Hotkey ID scheme:
    // ID 1 = Cmd+Shift+R (toggle start/stop)
    // ID 10-18 = Cmd+Shift+1-9 (load monitor preset for focused window's monitor)
    // ID 20-28 = Cmd+Option+Shift+1-9 (load workspace preset - all monitors)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permissions on launch
        if !AccessibilityHelper.checkAccessibilityPermissions() {
            AccessibilityHelper.requestAccessibilityPermissions()
        }

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

        // Register Cmd+Shift+R (toggle) - ID 1
        registerSingleHotKey(keyCode: 15, modifiers: cmdKey | shiftKey, id: 1, signature: signature)

        // Key codes for 1-9: 18, 19, 20, 21, 23, 22, 26, 28, 25
        let numberKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

        // Register Cmd+Shift+1-9 (load monitor preset) - IDs 10-18
        for (index, keyCode) in numberKeyCodes.enumerated() {
            registerSingleHotKey(
                keyCode: keyCode,
                modifiers: cmdKey | shiftKey,
                id: UInt32(10 + index),
                signature: signature
            )
        }

        // Register Cmd+Option+Shift+1-9 (load workspace preset) - IDs 20-28
        for (index, keyCode) in numberKeyCodes.enumerated() {
            registerSingleHotKey(
                keyCode: keyCode,
                modifiers: cmdKey | optionKey | shiftKey,
                id: UInt32(20 + index),
                signature: signature
            )
        }

        print("Registered 19 global hotkeys")
    }

    private func registerSingleHotKey(keyCode: UInt32, modifiers: Int, id: UInt32, signature: OSType) {
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

        if status == noErr, let ref = ref {
            hotKeyRefs[id] = ref
        } else {
            print("Failed to register hotkey ID \(id): \(status)")
        }
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

        // Simulate Cmd+, keyboard shortcut to open Settings
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: comma with command modifier
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x2B, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x2B, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
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
