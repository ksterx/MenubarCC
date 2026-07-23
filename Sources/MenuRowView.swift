import Cocoa

// A fixed-width, clickable menu row with its own hover highlight. Used for rows
// NSMenuItem's plain title can't render well — session rows (aligned columns)
// and the top notices — so they all share one width and never widen the menu.
final class MenuRowView: NSView {
    var onClick: (() -> Void)?
    // Some rows (e.g. sound preview) should act without dismissing the menu so
    // several can be triggered in a row.
    var closesMenuOnClick = true
    // An optional sub-region with its own action that keeps the menu open —
    // e.g. a play icon sharing a row with a "Choose…" click.
    var hotZone: NSRect = .zero
    var hotAction: (() -> Void)?

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
    // capture them, or the whole row would stop responding.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview?.convert(point, to: self) ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let hot = hotAction, hotZone.contains(local) {
            hot()   // acts in place, menu stays open
            return
        }
        if closesMenuOnClick { enclosingMenuItem?.menu?.cancelTracking() }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}
