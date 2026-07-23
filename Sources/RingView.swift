import Cocoa

// A circular progress ring: a faint full-circle track plus a colored arc that
// sweeps clockwise from 12 o'clock in proportion to `pct` (0–100). Drawn with
// NSColor in draw(), so it tracks the menu's light/dark appearance.
final class RingView: NSView {
    var pct: Double = 0
    var color: NSColor = .systemGreen
    var lineWidth: CGFloat = 4

    override func draw(_ dirtyRect: NSRect) {
        let inset = lineWidth / 2 + 1
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setStroke()
        track.stroke()

        let frac = min(max(pct, 0), 100) / 100
        guard frac > 0 else { return }
        let start: CGFloat = 90                       // 12 o'clock
        let end = start - CGFloat(frac) * 360         // clockwise
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: start, endAngle: end, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
}
