import AppKit
import ApplicationServices
import Combine
import os.log

/// Logger for debugging AX issues - writes to debug.txt
private let axLogger = Logger(subsystem: "com.resized", category: "Accessibility")

/// Resolves the Quartz window id behind an accessibility element.
///
/// There is no public API bridging the Accessibility API to Quartz Window
/// Services, so every serious macOS window manager (yabai, Rectangle, AeroSpace)
/// reaches for the private `_AXUIElementGetWindow`. We look it up with dlsym
/// rather than linking it directly on purpose: a direct link to a symbol that a
/// future macOS removes is a launch-time dyld failure — the app simply would not
/// start. This way a missing symbol degrades to the fallback identity below.
private let axGetWindowID: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    // RTLD_DEFAULT on Darwin
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
        axLogger.error("_AXUIElementGetWindow unavailable; falling back to heuristic window identity")
        return nil
    }
    return unsafeBitCast(
        symbol,
        to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self
    )
}()

/// Helper for macOS Accessibility API interactions
struct AccessibilityHelper {

    /// Check if the app has accessibility permissions
    static func checkAccessibilityPermissions() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // NOTE: there is deliberately no requestAccessibilityPermissions() here.
    // Passing kAXTrustedCheckOptionPrompt: true raises the system dialog, which
    // duplicated our own overlay and popped up unbidden at launch. We drive the
    // user to the Accessibility pane ourselves instead — checkAccessibilityPermissions()
    // above passes prompt: false and never raises anything.

    /// Open System Settings to the Accessibility pane
    static func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Log an AX diagnostic. Always goes to the unified log (Console.app, or
    /// `log stream --predicate 'subsystem == "com.resized"'`), and additionally to
    /// debug.txt in the project root for DEBUG builds.
    static func logDebug(_ message: String) {
        axLogger.debug("\(message, privacy: .public)")
        #if DEBUG
        DebugFileLog.append(message)
        #endif
    }
}

#if DEBUG
/// Appends to debug.txt beside the .xcodeproj.
///
/// The previous implementation resolved the path against the process working
/// directory, which is "/" for a bundled app — so every write failed, silently,
/// because the failure was swallowed by `try?`. #filePath is resolved at compile
/// time and points at the real source tree.
private enum DebugFileLog {
    private static let queue = DispatchQueue(label: "com.resized.debuglog")
    private static let timestamps = ISO8601DateFormatter()

    /// #filePath is <root>/ReSized/AccessibilityHelper.swift
    private static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("debug.txt")

    static func append(_ message: String) {
        let line = "[\(timestamps.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
#endif

/// Represents an external window that can be controlled
class ExternalWindow: Identifiable, ObservableObject, Equatable {
    /// Stable for the lifetime of the underlying OS window — see stableID.
    let id: UUID
    /// The Quartz window id, when it could be resolved.
    let windowID: CGWindowID?
    let axElement: AXUIElement
    let ownerPID: pid_t
    let ownerName: String

    @Published var frame: CGRect
    @Published var title: String
    @Published var isMinimized: Bool = false

    /// Timeout for every AX message sent to this window. Set once per element at
    /// construction rather than before each accessor — it is itself an IPC call.
    static let messagingTimeout: Float = 0.1

    /// A window's min/max size are fixed in practice, and each read is a synchronous
    /// cross-process call. constrainFrame() reads both for every window on every
    /// layout apply, so resolve them lazily and keep them.
    private var cachedMinSize: CGSize?
    private var cachedMaxSize: CGSize?

    init(axElement: AXUIElement, pid: pid_t, ownerName: String) {
        self.axElement = axElement
        self.ownerPID = pid
        self.ownerName = ownerName
        AXUIElementSetMessagingTimeout(axElement, Self.messagingTimeout)

        let resolvedTitle = Self.getTitle(from: axElement) ?? "Untitled"
        let resolvedWindowID = Self.windowID(for: axElement)
        self.windowID = resolvedWindowID
        self.id = Self.stableID(
            windowID: resolvedWindowID,
            pid: pid,
            fallbackKey: "\(ownerName)\u{1}\(resolvedTitle)"
        )

        self.frame = Self.getFrame(from: axElement) ?? .zero
        self.title = resolvedTitle
    }

    static func == (lhs: ExternalWindow, rhs: ExternalWindow) -> Bool {
        lhs.id == rhs.id
    }

    /// The Quartz window id for an AX element, or nil if it can't be resolved.
    static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let axGetWindowID else { return nil }
        var wid = CGWindowID(0)
        guard axGetWindowID(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    /// Derive an identity that stays the same across repeated discovery passes.
    ///
    /// This used to be a plain `UUID()`, and discoverAllWindows() rebuilds every
    /// ExternalWindow on each call — so the same on-screen window got a brand new
    /// id every scan. Every comparison against a previously stored id therefore
    /// failed, which is why windows already placed in a layout kept reappearing in
    /// the "available windows" picker.
    private static func stableID(windowID: CGWindowID?, pid: pid_t, fallbackKey: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)

        if let windowID {
            // pid + Quartz window id is genuinely unique and survives retitling.
            bytes[0] = UInt8(ascii: "W")
            withUnsafeBytes(of: pid.littleEndian) { raw in
                for (offset, byte) in raw.enumerated() { bytes[1 + offset] = byte }
            }
            withUnsafeBytes(of: windowID.littleEndian) { raw in
                for (offset, byte) in raw.enumerated() { bytes[9 + offset] = byte }
            }
        } else {
            // Fallback when the private symbol is gone: pid + owner + title. Weaker
            // — a window that retitles changes identity — but still far better than
            // a fresh id per scan. Hasher is per-process seeded, which is fine
            // because identity only has to hold within a single run.
            bytes[0] = UInt8(ascii: "F")
            var hasher = Hasher()
            hasher.combine(pid)
            hasher.combine(fallbackKey)
            withUnsafeBytes(of: Int64(hasher.finalize()).littleEndian) { raw in
                for (offset, byte) in raw.enumerated() { bytes[1 + offset] = byte }
            }
        }

        return bytes.withUnsafeBufferPointer { buffer in
            NSUUID(uuidBytes: buffer.baseAddress) as UUID
        }
    }

    // MARK: - Window Properties

    /// AX API error codes for better debugging
    private static func describeAXError(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(error.rawValue))"
        }
    }

    static func getFrame(from element: AXUIElement) -> CGRect? {
        // Set a short timeout to prevent hanging on dead windows
        AXUIElementSetMessagingTimeout(element, 0.1)

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        let posResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        // Check for invalid element errors specifically
        if posResult == .invalidUIElement || sizeResult == .invalidUIElement {
            return nil  // Window is gone, don't log - this is expected
        }

        guard posResult == .success, sizeResult == .success else {
            // Only log unexpected errors
            if posResult != .success && posResult != .cannotComplete {
                AccessibilityHelper.logDebug("getFrame position error: \(describeAXError(posResult))")
            }
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        // Safely cast with nil checks
        guard let posValue = positionValue, CFGetTypeID(posValue) == AXValueGetTypeID(),
              let szValue = sizeValue, CFGetTypeID(szValue) == AXValueGetTypeID() else {
            return nil
        }

        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(szValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    static func getTitle(from element: AXUIElement) -> String? {
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success else {
            return nil
        }
        return titleValue as? String
    }

    // MARK: - Window Manipulation

    @discardableResult
    func setFrame(_ newFrame: CGRect) -> Bool {
        // No isValid pre-check: a dead element simply returns .invalidUIElement
        // from the sets below, so probing first only costs an extra round trip.

        // Convert the frame to AX coordinates
        // NSScreen: origin is bottom-left, Y=0 at bottom, Y increases upward
        // AX/Quartz: origin is top-left, Y=0 at top, Y increases downward
        let axFrame = convertFrameToAXCoordinates(newFrame)

        var pos = axFrame.origin
        var sz = axFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &pos),
              let sizeValue = AXValueCreate(.cgSize, &sz) else { return false }

        // Position, then size, then position again. The window server clamps a
        // requested size against whichever display the window currently occupies,
        // so a single position+size pass lands short whenever a window is moving
        // to a larger display or growing past the bounds of its current screen.
        // The second position call re-seats it once the size has been accepted.
        let firstPos = AXUIElementSetAttributeValue(axElement, kAXPositionAttribute as CFString, positionValue)
        let sizeResult = AXUIElementSetAttributeValue(axElement, kAXSizeAttribute as CFString, sizeValue)
        let secondPos = AXUIElementSetAttributeValue(axElement, kAXPositionAttribute as CFString, positionValue)

        let positionSet = firstPos == .success || secondPos == .success
        let sizeSet = sizeResult == .success

        // Log failures for debugging (but not invalidUIElement - that's expected when windows close)
        if !positionSet && firstPos != .invalidUIElement {
            AccessibilityHelper.logDebug("setFrame position failed for \(ownerName): \(Self.describeAXError(firstPos))")
        }
        if !sizeSet && sizeResult != .invalidUIElement {
            AccessibilityHelper.logDebug("setFrame size failed for \(ownerName): \(Self.describeAXError(sizeResult))")
        }

        // No read-back verification here: setFrame is the hot path — a seam
        // drag calls it for every window on the monitor for every mouse
        // event, and an extra read per call stalls the main thread 0.1s per
        // busy app. place() already reads the result and re-asks on a miss.

        if positionSet || sizeSet {
            // setFrame runs on the main thread from the layout paths; only hop when
            // that is not the case, so a drag does not queue a block per window.
            if Thread.isMainThread {
                frame = newFrame
            } else {
                DispatchQueue.main.async { self.frame = newFrame }
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

    func raise() {
        AXUIElementSetAttributeValue(axElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }

    // MARK: - Size Constraints

    /// Read a size-valued AX attribute. Returns nil when the attribute is absent or
    /// is not actually an AXValue — most windows do not publish size constraints,
    /// and an unchecked cast on the reply is a crash waiting for the one that does
    /// something unusual.
    private func sizeAttribute(_ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    var minSize: CGSize {
        if let cachedMinSize { return cachedMinSize }
        let resolved = sizeAttribute("AXMinimumSize") ?? CGSize(width: 100, height: 100)
        cachedMinSize = resolved
        return resolved
    }

    var maxSize: CGSize {
        if let cachedMaxSize { return cachedMaxSize }
        let resolved = sizeAttribute("AXMaximumSize") ?? CGSize(width: 10000, height: 10000)
        cachedMaxSize = resolved
        return resolved
    }

    // NOTE: an "observed minimum" learned from refused shrinks was tried here
    // and reverted. Apps apply AX resizes asynchronously, so a read right
    // after a write races the app and sees the OLD size — which is
    // indistinguishable from a refusal, and the phantom floor it learns then
    // clamps the seam that would have disproven it. Seams clamp on REPORTED
    // minimums only.

    /// Forget the cached min/max so the next read asks the app again.
    ///
    /// The cache assumed a window's limits are fixed for life. Webex's are
    /// not — it reports different minimum widths in different states, and a
    /// stale large minimum silently vetoed every attempt to shrink it: drops
    /// left it "stuck" wide, and seam drags on its column felt dead.
    func refreshSizeLimits() {
        cachedMinSize = nil
        cachedMaxSize = nil
    }

    /// Live minimized state, read from the app every time — the cached
    /// `isMinimized` only refreshes on discovery passes, and the layout needs
    /// the truth at apply time to give a minimized window's space away.
    var isCurrentlyMinimized: Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXMinimizedAttribute as CFString, &value) == .success,
              let minimized = value as? Bool else { return false }
        return minimized
    }
}

/// Observes window changes using AX notifications (much faster than polling)
class WindowObserver {
    /// Everything registered per window. Minimize and restore are watched so
    /// a layout can give a minimized window's space away and hand it back.
    static let notificationNames: [CFString] = [
        kAXMovedNotification as CFString,
        kAXResizedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
        kAXWindowDeminiaturizedNotification as CFString,
    ]

    private var observers: [pid_t: AXObserver] = [:]
    private var observedElements: [(element: AXUIElement, pid: pid_t)] = []
    private let callback: (AXUIElement, String) -> Void

    init(callback: @escaping (AXUIElement, String) -> Void) {
        self.callback = callback
    }

    deinit {
        stopObserving()
    }

    /// Watch exactly `windows`, adding and removing only what actually changed.
    ///
    /// Callers run this on every layout apply, not just when a layout starts, so
    /// a window added to a live layout gets notifications too. That makes it a
    /// hot path: rebuilding wholesale would tear down and recreate every
    /// AXObserver on each divider drag, so this diffs against what is already
    /// registered and does nothing at all when the set is unchanged.
    func observeWindows(_ windows: [ExternalWindow]) {
        let isWanted: (AXUIElement) -> Bool = { element in
            windows.contains { CFEqual($0.axElement, element) }
        }

        // Drop the ones that have left the layout.
        for entry in observedElements where !isWanted(entry.element) {
            guard let observer = observers[entry.pid] else { continue }
            for name in Self.notificationNames {
                AXObserverRemoveNotification(observer, entry.element, name)
            }
        }
        observedElements.removeAll { !isWanted($0.element) }

        // Register the ones that are new.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in windows
        where !observedElements.contains(where: { CFEqual($0.element, window.axElement) }) {
            guard let observer = observer(for: window.ownerPID) else { continue }

            var anyAdded = false
            for name in Self.notificationNames {
                if AXObserverAddNotification(observer, window.axElement, name, refcon) == .success {
                    anyAdded = true
                }
            }
            if anyAdded {
                observedElements.append((window.axElement, window.ownerPID))
            }
        }

        // Retire the observers for processes with nothing left to watch — which
        // includes any created just above whose notifications all failed.
        for (pid, observer) in observers
        where !observedElements.contains(where: { $0.pid == pid }) {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
            observers.removeValue(forKey: pid)
        }
    }

    /// The observer for a process, created and hooked to the run loop on first
    /// use. Each process needs its own.
    private func observer(for pid: pid_t) -> AXObserver? {
        if let existing = observers[pid] { return existing }

        var obs: AXObserver?
        let result = AXObserverCreate(pid, { (observer, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let this = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
            this.handleNotification(element: element, notification: notification as String)
        }, &obs)

        guard result == .success, let observer = obs else {
            print("Failed to create observer for PID \(pid)")
            return nil
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        observers[pid] = observer
        return observer
    }

    private func handleNotification(element: AXUIElement, notification: String) {
        // Call immediately on main thread
        if Thread.isMainThread {
            self.callback(element, notification)
        } else {
            DispatchQueue.main.async {
                self.callback(element, notification)
            }
        }
    }

    func stopObserving() {
        for (pid, observer) in observers {
            // Remove notifications for elements belonging to this PID
            for (element, elementPid) in observedElements where elementPid == pid {
                for name in Self.notificationNames {
                    AXObserverRemoveNotification(observer, element, name)
                }
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

}

// MARK: - App Launcher Helper

/// Helper for launching apps and looking up bundle identifiers
struct AppLauncher {

    /// Get bundle identifier from app name
    static func getBundleIdentifier(for appName: String) -> String? {
        // Method 1: Check running apps first (fastest)
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == appName
        }) {
            return running.bundleIdentifier
        }

        // Method 2: Search Applications folders
        let appPaths = [
            "/Applications",
            "/System/Applications",
            "/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]

        for basePath in appPaths {
            let appPath = "\(basePath)/\(appName).app"
            if FileManager.default.fileExists(atPath: appPath),
               let bundle = Bundle(path: appPath) {
                return bundle.bundleIdentifier
            }
        }

        return nil
    }

    /// Launch an app by bundle identifier
    @discardableResult
    static func launchApp(bundleId: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleId
        ) else { return false }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false  // Don't bring to front immediately

        var success = false
        let semaphore = DispatchSemaphore(value: 0)

        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            success = (error == nil)
            semaphore.signal()
        }

        // Wait briefly for the launch to complete
        _ = semaphore.wait(timeout: .now() + 2.0)
        return success
    }

    /// Get all installed applications
    static func getInstalledApps() -> [(name: String, bundleId: String, path: String)] {
        var apps: [(name: String, bundleId: String, path: String)] = []

        let appPaths = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]

        for basePath in appPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
                continue
            }

            for name in contents where name.hasSuffix(".app") {
                let appPath = "\(basePath)/\(name)"
                let appName = String(name.dropLast(4))

                if let bundle = Bundle(path: appPath),
                   let bundleId = bundle.bundleIdentifier {
                    apps.append((appName, bundleId, appPath))
                }
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
