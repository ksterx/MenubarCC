import Cocoa

// A session row rendered as a custom view so its name / age / context columns
// line up vertically across rows and the context reaches the same right margin
// as the gauges above. NSMenuItem's plain title can't align proportional text,
// so the view also supplies its own hover highlight and click handling.
final class SessionRowView: NSView {
    var onClick: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }

    // Keep clicks (and hover) on the row itself — the label subviews must not
    // capture them, or the whole row would stop opening its session.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview?.convert(point, to: self) ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
