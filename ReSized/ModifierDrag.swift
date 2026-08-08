import AppKit

/// Watches global mouse drags and modifier flags for the placement gesture.
///
/// Listen-only: nothing is intercepted or altered, the tap is a wiretap. It
/// exists only while a layout is live, and it deliberately knows nothing about
/// windows or layouts — it reports "a drag began / moved / ended, and whether
/// the modifier was down", in CG top-left coordinates, and WindowManager does
/// the thinking.
final class ModifierDragMonitor {
    var onBegin: ((CGPoint) -> Void)?
    /// Cursor and armed state, on every drag movement and on modifier changes
    /// mid-drag — pressing the modifier late or releasing it early must both
    /// register without the mouse moving.
    var onUpdate: ((CGPoint, Bool) -> Void)?
    var onEnd: ((CGPoint, Bool) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dragging = false

    /// fn, or command+shift. fn is the wanted gesture; ⌘⇧ is the fallback for
    /// keyboards that never report fn. If fn proves flaky, delete its line.
    ///
    /// The fallback must not contain ⌥: macOS's own window tiling claims
    /// option-drag (Sequoia's "hold ⌥ while dragging to tile"), painting a
    /// half-screen preview over our band and tiling the window on release.
    /// ⌘-drag on a title bar is a plain drag that doesn't even raise the
    /// window, which suits a placement gesture.
    static func isArmed(_ flags: CGEventFlags) -> Bool {
        if flags.contains(.maskSecondaryFn) { return true }
        return flags.contains(.maskCommand) && flags.contains(.maskShift)
    }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<ModifierDragMonitor>.fromOpaque(refcon)
                        .takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            // Accessibility covers listen-only taps, so this failing means
            // something odd; the feature just stays off.
            AccessibilityHelper.logDebug("modifier-drag: event tap creation failed")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
        dragging = false
    }

    deinit { stop() }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        // The system disables taps it thinks are slow, even listen-only ones.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let cursor = event.location
        let armed = Self.isArmed(event.flags)

        switch type {
        case .leftMouseDown:
            dragging = true
            onBegin?(cursor)
        case .leftMouseDragged:
            if dragging { onUpdate?(cursor, armed) }
        case .flagsChanged:
            // Only meaningful mid-drag, and only while the button is down —
            // a flagsChanged after mouse-up belongs to no gesture.
            if dragging, NSEvent.pressedMouseButtons & 1 == 1 { onUpdate?(cursor, armed) }
        case .leftMouseUp:
            if dragging {
                dragging = false
                onEnd?(cursor, armed)
            }
        default:
            break
        }
    }
}
