import AppKit
import ApplicationServices
import Combine

/// Helper for macOS Accessibility API interactions
struct AccessibilityHelper {

    /// Check if the app has accessibility permissions
    static func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Request accessibility permissions (shows system prompt)
    static func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Preferences to Accessibility pane
    static func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Represents an external window that can be controlled
class ExternalWindow: Identifiable, ObservableObject, Equatable {
    let id = UUID()
    let axElement: AXUIElement
    let ownerPID: pid_t
    let ownerName: String

    @Published var frame: CGRect
    @Published var title: String
    @Published var isMinimized: Bool = false

    init(axElement: AXUIElement, pid: pid_t, ownerName: String) {
        self.axElement = axElement
        self.ownerPID = pid
        self.ownerName = ownerName
        self.frame = Self.getFrame(from: axElement) ?? .zero
        self.title = Self.getTitle(from: axElement) ?? "Untitled"
    }

    static func == (lhs: ExternalWindow, rhs: ExternalWindow) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Window Properties

    static func getFrame(from element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    static func getTitle(from element: AXUIElement) -> String? {
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success else {
            return nil
        }
        return titleValue as? String
    }

    func refreshFrame() {
        if let newFrame = Self.getFrame(from: axElement) {
            DispatchQueue.main.async {
                self.frame = newFrame
            }
        }
    }

    func refreshTitle() {
        if let newTitle = Self.getTitle(from: axElement) {
            DispatchQueue.main.async {
                self.title = newTitle
            }
        }
    }

    // MARK: - Window Manipulation

    func setFrame(_ newFrame: CGRect) -> Bool {
        // Convert the frame to AX coordinates
        // NSScreen: origin is bottom-left, Y=0 at bottom, Y increases upward
        // AX/Quartz: origin is top-left, Y=0 at top, Y increases downward
        let axFrame = convertFrameToAXCoordinates(newFrame)

        // Set position first (top-left in AX coords), then size
        var pos = axFrame.origin
        guard let positionValue = AXValueCreate(.cgPoint, &pos) else { return false }
        let positionSet = AXUIElementSetAttributeValue(axElement, kAXPositionAttribute as CFString, positionValue) == .success

        var sz = axFrame.size
        guard let sizeValue = AXValueCreate(.cgSize, &sz) else { return false }
        let sizeSet = AXUIElementSetAttributeValue(axElement, kAXSizeAttribute as CFString, sizeValue) == .success

        if positionSet || sizeSet {
            DispatchQueue.main.async {
                self.frame = newFrame
            }
        }

        return positionSet && sizeSet
    }

    /// Convert a frame from NSScreen coordinates to Accessibility API (Quartz) coordinates
    /// NSScreen: origin is bottom-left of rect, Y=0 at bottom of primary screen
    /// AX/Quartz: origin is top-left of rect, Y=0 at top of primary screen
    private func convertFrameToAXCoordinates(_ frame: CGRect) -> CGRect {
        guard let mainScreen = NSScreen.screens.first else { return frame }
        let screenHeight = mainScreen.frame.height

        // In NSScreen, frame.origin.y is the bottom of the window
        // In AX, we need the top of the window
        // Top in NS coords = origin.y + height
        // AX.y = screenHeight - (NS top) = screenHeight - (origin.y + height)
        let axY = screenHeight - frame.origin.y - frame.height

        return CGRect(x: frame.origin.x, y: axY, width: frame.width, height: frame.height)
    }

    func setPosition(_ position: CGPoint) -> Bool {
        var pos = position
        guard let positionValue = AXValueCreate(.cgPoint, &pos) else { return false }
        return AXUIElementSetAttributeValue(axElement, kAXPositionAttribute as CFString, positionValue) == .success
    }

    func setSize(_ size: CGSize) -> Bool {
        var sz = size
        guard let sizeValue = AXValueCreate(.cgSize, &sz) else { return false }
        return AXUIElementSetAttributeValue(axElement, kAXSizeAttribute as CFString, sizeValue) == .success
    }

    func raise() {
        AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }

    // MARK: - Size Constraints

    var minSize: CGSize {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, "AXMinimumSize" as CFString, &value) == .success else {
            return CGSize(width: 100, height: 100)
        }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    var maxSize: CGSize {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, "AXMaximumSize" as CFString, &value) == .success else {
            return CGSize(width: 10000, height: 10000)
        }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }
}

/// Observes window changes using AX notifications (much faster than polling)
class WindowObserver {
    private var observers: [pid_t: AXObserver] = [:]
    private var observedElements: [(element: AXUIElement, pid: pid_t)] = []
    private let callback: (AXUIElement) -> Void

    init(callback: @escaping (AXUIElement) -> Void) {
        self.callback = callback
    }

    deinit {
        stopObserving()
    }

    func observeWindows(_ windows: [ExternalWindow]) {
        stopObserving() // Clean up any existing observers

        // Group by PID - each process needs its own observer
        let byPID = Dictionary(grouping: windows, by: { $0.ownerPID })

        for (pid, windowsForPID) in byPID {
            var obs: AXObserver?
            let result = AXObserverCreate(pid, { (observer, element, notification, refcon) in
                guard let refcon = refcon else { return }
                let this = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
                this.handleNotification(element: element, notification: notification as String)
            }, &obs)

            guard result == .success, let observer = obs else {
                print("Failed to create observer for PID \(pid)")
                continue
            }

            let refcon = Unmanaged.passUnretained(self).toOpaque()

            for window in windowsForPID {
                let addMoved = AXObserverAddNotification(observer, window.axElement, kAXMovedNotification as CFString, refcon)
                let addResized = AXObserverAddNotification(observer, window.axElement, kAXResizedNotification as CFString, refcon)

                if addMoved == .success || addResized == .success {
                    observedElements.append((window.axElement, pid))
                }
            }

            // Add observer to run loop
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )

            observers[pid] = observer
        }

        print("WindowObserver: Watching \(observedElements.count) windows across \(observers.count) apps")
    }

    private func handleNotification(element: AXUIElement, notification: String) {
        // Call immediately on main thread
        if Thread.isMainThread {
            self.callback(element)
        } else {
            DispatchQueue.main.async {
                self.callback(element)
            }
        }
    }

    func stopObserving() {
        for (pid, observer) in observers {
            // Remove notifications for elements belonging to this PID
            for (element, elementPid) in observedElements where elementPid == pid {
                AXObserverRemoveNotification(observer, element, kAXMovedNotification as CFString)
                AXObserverRemoveNotification(observer, element, kAXResizedNotification as CFString)
            }

            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }

        observers.removeAll()
        observedElements.removeAll()
    }
}

/// Discovers windows from running applications
class WindowDiscovery {

    /// Get all visible windows from all applications
    static func discoverAllWindows() -> [ExternalWindow] {
        var windows: [ExternalWindow] = []

        // Get our own bundle identifier to exclude ourselves
        let ourBundleId = Bundle.main.bundleIdentifier

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            $0.bundleIdentifier != ourBundleId  // Exclude ReSized
        }

        for app in runningApps {
            let appWindows = getWindows(for: app)
            windows.append(contentsOf: appWindows)
        }

        return windows
    }

    /// Get windows for a specific application
    static func getWindows(for app: NSRunningApplication) -> [ExternalWindow] {
        var windows: [ExternalWindow] = []

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windowList = windowsValue as? [AXUIElement] else {
            return windows
        }

        let appName = app.localizedName ?? "Unknown"

        for windowElement in windowList {
            // Skip minimized windows
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(windowElement, kAXMinimizedAttribute as CFString, &minimized) == .success,
               let isMinimized = minimized as? Bool, isMinimized {
                continue
            }

            // Skip windows without a valid frame
            guard ExternalWindow.getFrame(from: windowElement) != nil else {
                continue
            }

            let window = ExternalWindow(axElement: windowElement, pid: pid, ownerName: appName)
            windows.append(window)
        }

        return windows
    }

    /// Get the frontmost window
    static func getFrontmostWindow() -> ExternalWindow? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else {
            return nil
        }

        let appName = frontApp.localizedName ?? "Unknown"
        return ExternalWindow(axElement: focusedWindow as! AXUIElement, pid: pid, ownerName: appName)
    }
}
