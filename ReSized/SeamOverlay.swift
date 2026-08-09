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
        }
    }

    /// Where a modifier-dragged window would land, in screen coordinates.
    /// Drawn stronger than the hover band: this one announces an action that
    /// will happen on release, not a handle that could be grabbed.
    var dropIndicator: (rect: CGRect, isVertical: Bool)? {
        didSet {
            guard dropIndicator?.rect != oldValue?.rect else { return }
            needsDisplay = true
        }
    }

    /// Whether a screen point on a seam is actually showing this layout, and
    /// not some unmanaged window sitting on top of it. The panel floats above
    /// every ordinary window, so without this check the seams draw, grab and
    /// swallow clicks straight through whatever is covering the tiled windows.
    var isPointExposed: ((CGPoint) -> Bool)?

    /// Called continuously while a seam is dragged, with the clamped drag so
    /// far as a fraction of the seam's track. Live on purpose — deferring
    /// the whole gesture to mouse-up was tried (2026-08-08) and rejected by
    /// Kennith against the shipped build: out here the desktop's own windows
    /// ARE the preview, and a band sliding over frozen windows reads as the
    /// app fighting the drag. The clamp is only the generic one; windows
    /// that cannot keep up simply stop, and the settle pass reconciles
    /// whatever the drag couldn't get once the mouse is up.
    var onDrag: ((DesktopSeam, CGFloat) -> Void)?

    /// How much of a requested shift the split can absorb — the generic
    /// bound, so the band and the model always agree on where "as far as it
    /// goes" is.
    var clampShift: ((DesktopSeam, CGFloat) -> CGFloat)?

    private var activeSeam: DesktopSeam?
    private var dragOrigin: CGPoint = .zero
    /// The drag so far, clamped, as a fraction of the seam's track. The band
    /// is drawn from this rather than the raw cursor so it never travels
    /// somewhere the layout won't follow on release.
    private var activeShift: CGFloat = 0
    private var hoveredIndex: Int?

    override var isFlipped: Bool { false }

    // MARK: Hit testing

    /// Only the seams are grabbable. Everywhere else returns nil so the click
    /// goes to whatever is underneath — without this the overlay would swallow
    /// every click on the desktop it covers.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Routed through window coordinates so this lands in exactly the same
        // space as the mouse handlers. hitTest is handed a point in the
        // superview's system and the handlers convert from the window's, and
        // any difference between the two shows up as the seam being grabbable
        // slightly off from where it is drawn.
        let windowPoint = superview?.convert(point, to: nil) ?? point
        return seamRect(at: convert(windowPoint, from: nil)) == nil ? nil : self
    }

    private func seamRect(at point: CGPoint) -> Int? {
        guard let index = localSeamRects().firstIndex(where: { $0.contains(point) }) else { return nil }
        // The occlusion query is only paid for points already on a seam strip.
        if let isPointExposed,
           !isPointExposed(CGPoint(x: point.x + screenOrigin.x, y: point.y + screenOrigin.y)) {
            return nil
        }
        return index
    }

    private func localSeamRects() -> [CGRect] {
        seams.map { $0.rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let (rect, isVertical) = dropIndicator {
            let band = rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: band, xRadius: 2, yRadius: 2).fill()
            let centre: CGRect = isVertical
                ? band.insetBy(dx: band.width / 2 - 1.5, dy: 0)
                : band.insetBy(dx: 0, dy: band.height / 2 - 1.5)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: centre, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Invisible until pointed at. A permanent grid of lines over every
        // window would be noise; the cursor already says the seam is there.
        guard let (band, isVertical) = indicator() else { return }

        // The band is the grabbable strip itself, drawn faintly, with a crisp
        // line down its middle. Showing only the thin line meant what you could
        // see and what you could grab were different shapes, so being on the
        // line was no guarantee of being on the seam.
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: band, xRadius: 2, yRadius: 2).fill()

        let centre: CGRect = isVertical
            ? band.insetBy(dx: band.width / 2 - 1.5, dy: 0)
            : band.insetBy(dx: 0, dy: band.height / 2 - 1.5)
        NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: centre, xRadius: 1.5, yRadius: 1.5).fill()
    }

    /// What to draw: the grabbed seam's strip displaced by the clamped shift
    /// while dragging, otherwise the hovered seam's own strip.
    private func indicator() -> (band: CGRect, isVertical: Bool)? {
        if let activeSeam {
            let extent = activeSeam.rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            // A positive shift grows the first of the pair: rightward for a
            // vertical seam, downward (negative y on screen) for a horizontal
            // one — the same sign convention the commit uses.
            let band = activeSeam.isVertical
                ? extent.offsetBy(dx: activeShift * activeSeam.trackSize, dy: 0)
                : extent.offsetBy(dx: 0, dy: -activeShift * activeSeam.trackSize)
            return (band, activeSeam.isVertical)
        }

        guard let hoveredIndex, hoveredIndex < seams.count else { return nil }
        return (localSeamRects()[hoveredIndex], seams[hoveredIndex].isVertical)
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHover(seamRect(at: point))
    }

    /// Hover state and the cursor move together, both gated by the same
    /// exposure check. This used to be cursor rects covering every seam, which
    /// AppKit applies with no idea that another app's window is in the way —
    /// so the resize cursor showed through anything floating over the layout.
    private func setHover(_ index: Int?) {
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        needsDisplay = true
        if let index, index < seams.count {
            (seams[index].isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
        } else if activeSeam == nil {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = seamRect(at: point) else { return }
        activeSeam = seams[index]
        hoveredIndex = index
        dragOrigin = point
        activeShift = 0
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

        let requested = travelled / activeSeam.trackSize
        let clamped = clampShift?(activeSeam, requested) ?? requested
        // Skip the apply when the clamp pinned us to where we already are —
        // no reason to re-place every window for a drag past the stop.
        if abs(clamped - activeShift) > 0.0005 {
            activeShift = clamped
            onDrag?(activeSeam, clamped)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        activeSeam = nil
        activeShift = 0
        needsDisplay = true
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
