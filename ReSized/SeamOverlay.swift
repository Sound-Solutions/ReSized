import AppKit

/// Draggable seams drawn over the real desktop.
///
/// The config window's dividers work because the app owns a view sitting between
/// the tiles and gets the mouse directly. On the desktop there is nothing of
/// ReSized between the windows, which is why dragging a window's own edge has to
/// be inferred after the fact from accessibility notifications. This puts a real
/// view back between them, so a seam on screen is dragged by exactly the code
/// path the preview uses.
final class SeamOverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            // Non-activating, so grabbing a seam doesn't pull focus away from
            // whatever you were working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isMovableByWindowBackground = false
        // Needed for the hover highlight: a panel that never becomes key is not
        // sent mouse-moved events otherwise.
        acceptsMouseMovedEvents = true
        // Stationary and on every space: the seams belong to the monitor, not
        // to a particular desktop.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let view = SeamOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.screenOrigin = screen.frame.origin
        contentView = view
    }

    /// Never key and never main. A panel that took focus would deactivate the
    /// app being tiled every time a seam was touched.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var seamView: SeamOverlayView? { contentView as? SeamOverlayView }
}

/// The seams themselves, and the only part of the overlay that is not
/// transparent to the mouse.
final class SeamOverlayView: NSView {
    /// Screen coordinates of this view's origin, for converting seam rects that
    /// arrive in global space.
    var screenOrigin: CGPoint = .zero

    var seams: [DesktopSeam] = [] {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Called continuously while a seam is dragged, with the drag so far as a
    /// fraction of the seam's track.
    var onDrag: ((DesktopSeam, CGFloat) -> Void)?

    private var activeSeam: DesktopSeam?
    private var dragOrigin: CGPoint = .zero
    private var hoveredIndex: Int?

    override var isFlipped: Bool { false }

    // MARK: Hit testing

    /// Only the seams are grabbable. Everywhere else returns nil so the click
    /// goes to whatever is underneath — without this the overlay would swallow
    /// every click on the desktop it covers.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return seamRect(at: local) == nil ? nil : self
    }

    private func seamRect(at point: CGPoint) -> Int? {
        localSeamRects().firstIndex { $0.contains(point) }
    }

    private func localSeamRects() -> [CGRect] {
        seams.map { $0.rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y) }
    }

    // MARK: Cursors

    override func resetCursorRects() {
        super.resetCursorRects()
        for (index, rect) in localSeamRects().enumerated() {
            addCursorRect(rect, cursor: seams[index].isVertical ? .resizeLeftRight : .resizeUpDown)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Invisible until pointed at. A permanent grid of lines over every
        // window would be noise; the cursor already says the seam is there.
        guard let hoveredIndex, hoveredIndex < seams.count else { return }

        let rect = localSeamRects()[hoveredIndex]
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        let inset = seams[hoveredIndex].isVertical
            ? rect.insetBy(dx: rect.width / 2 - 1.5, dy: 0)
            : rect.insetBy(dx: 0, dy: rect.height / 2 - 1.5)
        NSBezierPath(roundedRect: inset, xRadius: 1.5, yRadius: 1.5).fill()
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = seamRect(at: point)
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = seamRect(at: point) else { return }
        activeSeam = seams[index]
        hoveredIndex = index
        dragOrigin = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeSeam, activeSeam.trackSize > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Measured from where the gesture began, never accumulated. A delta
        // added on every event is applied 1+2+3+…+n times over a drag.
        let travelled = activeSeam.isVertical
            ? point.x - dragOrigin.x
            // Screen coordinates grow upward while proportions are ordered
            // top-down, so dragging down has to read as a positive shift for
            // the first of the pair.
            : dragOrigin.y - point.y

        onDrag?(activeSeam, travelled / activeSeam.trackSize)
    }

    override func mouseUp(with event: NSEvent) {
        activeSeam = nil
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
}
