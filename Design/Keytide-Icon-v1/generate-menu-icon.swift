import AppKit

// Vector template master, 18pt canvas. No bitmap or glass effects.
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
    NSColor.black.set()
    let outline = NSBezierPath()
    outline.move(to: NSPoint(x: 5, y: 15.5))
    outline.line(to: NSPoint(x: 13, y: 15.5))
    outline.curve(to: NSPoint(x: 15, y: 13.5), controlPoint1: NSPoint(x: 14.2, y: 15.5), controlPoint2: NSPoint(x: 14.8, y: 14.8))
    outline.line(to: NSPoint(x: 16.5, y: 4.5))
    outline.curve(to: NSPoint(x: 14.5, y: 2.5), controlPoint1: NSPoint(x: 16.7, y: 3.2), controlPoint2: NSPoint(x: 15.8, y: 2.5))
    outline.line(to: NSPoint(x: 3.5, y: 2.5))
    outline.curve(to: NSPoint(x: 1.5, y: 4.5), controlPoint1: NSPoint(x: 2.2, y: 2.5), controlPoint2: NSPoint(x: 1.3, y: 3.2))
    outline.line(to: NSPoint(x: 3, y: 13.5))
    outline.curve(to: NSPoint(x: 5, y: 15.5), controlPoint1: NSPoint(x: 3.2, y: 14.8), controlPoint2: NSPoint(x: 3.8, y: 15.5))
    outline.close()
    outline.lineWidth = 1.3
    outline.lineJoinStyle = .round
    outline.stroke()
    for (x, height) in [(5.0, 3.0), (8.0, 5.0), (11.0, 7.0)] {
        NSBezierPath(roundedRect: NSRect(x: x, y: 5, width: 2, height: height), xRadius: 0.65, yRadius: 0.65).fill()
    }
    return true
}
let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
view.image = image
try view.dataWithPDF(inside: view.bounds).write(to: URL(fileURLWithPath: output))
