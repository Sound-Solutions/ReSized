import SwiftUI
import AppKit

@main
struct ReSizedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(WindowManager.shared)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var startStopMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility permissions on launch
        if !AccessibilityHelper.checkAccessibilityPermissions() {
            AccessibilityHelper.requestAccessibilityPermissions()
        }

        setupMenuBar()

        // Observe WindowManager's isActive changes to update menu
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateMenuState),
            name: NSNotification.Name("WindowManagerActiveChanged"),
            object: nil
        )
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
        // Bring app to front and show window
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title != "Item-0" && !$0.title.isEmpty }) ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
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
