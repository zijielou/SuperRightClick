import AppKit
import Foundation

private let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate_icon.swift <output.png>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let pixelSize = 1024
let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bitmapFormat: [],
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Unable to create bitmap drawing context")
}

bitmap.size = NSSize(width: pixelSize, height: pixelSize)

func drawGradient(_ colors: [NSColor], in path: NSBezierPath, angle: CGFloat) {
    guard let gradient = NSGradient(colors: colors) else {
        return
    }
    gradient.draw(in: path, angle: angle)
}

func drawLine(from start: NSPoint, to end: NSPoint, color: NSColor, width: CGFloat) {
    let line = NSBezierPath()
    line.move(to: start)
    line.line(to: end)
    line.lineWidth = width
    line.lineCapStyle = .round
    color.setStroke()
    line.stroke()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true
context.imageInterpolation = .high

NSColor.clear.setFill()
NSBezierPath(rect: canvas).fill()

let backgroundRect = canvas.insetBy(dx: 34, dy: 34)
let background = NSBezierPath(
    roundedRect: backgroundRect,
    xRadius: 220,
    yRadius: 220
)

drawGradient(
    [
        NSColor(calibratedRed: 0.14, green: 0.34, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.38, green: 0.18, blue: 0.90, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.65, blue: 0.92, alpha: 1)
    ],
    in: background,
    angle: -42
)

NSGraphicsContext.saveGraphicsState()
background.addClip()
NSColor.white.withAlphaComponent(0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: -90, y: 650, width: 560, height: 560)).fill()
NSColor(calibratedRed: 0.40, green: 0.90, blue: 1.0, alpha: 0.16).setFill()
NSBezierPath(ovalIn: NSRect(x: 610, y: -120, width: 560, height: 560)).fill()
NSColor.white.withAlphaComponent(0.08).setFill()
NSBezierPath(ovalIn: NSRect(x: 610, y: 660, width: 300, height: 300)).fill()
NSGraphicsContext.restoreGraphicsState()

let mouseRect = NSRect(x: 145, y: 165, width: 430, height: 690)
let mouse = NSBezierPath(
    roundedRect: mouseRect,
    xRadius: 205,
    yRadius: 205
)

NSGraphicsContext.saveGraphicsState()
let mouseShadow = NSShadow()
mouseShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
mouseShadow.shadowOffset = NSSize(width: 0, height: -20)
mouseShadow.shadowBlurRadius = 32
mouseShadow.set()
NSColor.white.setFill()
mouse.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
mouse.addClip()
drawGradient(
    [
        NSColor(calibratedWhite: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.86, green: 0.94, blue: 1.0, alpha: 1)
    ],
    in: mouse,
    angle: -90
)

let rightButtonArea = NSBezierPath(
    roundedRect: NSRect(x: 360, y: 610, width: 225, height: 270),
    xRadius: 95,
    yRadius: 95
)
drawGradient(
    [
        NSColor(calibratedRed: 1.0, green: 0.54, blue: 0.27, alpha: 1),
        NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.34, alpha: 1)
    ],
    in: rightButtonArea,
    angle: -45
)
NSGraphicsContext.restoreGraphicsState()

mouse.lineWidth = 22
NSColor.white.withAlphaComponent(0.96).setStroke()
mouse.stroke()

drawLine(
    from: NSPoint(x: 166, y: 610),
    to: NSPoint(x: 554, y: 610),
    color: NSColor(calibratedRed: 0.28, green: 0.35, blue: 0.72, alpha: 0.30),
    width: 12
)
drawLine(
    from: NSPoint(x: 360, y: 614),
    to: NSPoint(x: 360, y: 832),
    color: NSColor.white.withAlphaComponent(0.72),
    width: 12
)

let clickRing = NSBezierPath(ovalIn: NSRect(x: 405, y: 690, width: 96, height: 96))
clickRing.lineWidth = 13
NSColor.white.withAlphaComponent(0.92).setStroke()
clickRing.stroke()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 437, y: 722, width: 32, height: 32)).fill()

let menuRect = NSRect(x: 500, y: 205, width: 390, height: 390)
let menuCard = NSBezierPath(
    roundedRect: menuRect,
    xRadius: 66,
    yRadius: 66
)

NSGraphicsContext.saveGraphicsState()
let menuShadow = NSShadow()
menuShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
menuShadow.shadowOffset = NSSize(width: 0, height: -18)
menuShadow.shadowBlurRadius = 34
menuShadow.set()
NSColor.white.withAlphaComponent(0.98).setFill()
menuCard.fill()
NSGraphicsContext.restoreGraphicsState()

let titlePill = NSBezierPath(
    roundedRect: NSRect(x: 555, y: 518, width: 172, height: 22),
    xRadius: 11,
    yRadius: 11
)
NSColor(calibratedRed: 0.18, green: 0.36, blue: 0.92, alpha: 0.95).setFill()
titlePill.fill()

let rowCenters: [CGFloat] = [450, 365, 280]
let rowColors: [NSColor] = [
    NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.30, alpha: 1),
    NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.88, alpha: 1),
    NSColor(calibratedRed: 0.42, green: 0.32, blue: 0.90, alpha: 1)
]

for (index, centerY) in rowCenters.enumerated() {
    rowColors[index].setFill()
    NSBezierPath(ovalIn: NSRect(x: 555, y: centerY - 15, width: 30, height: 30)).fill()

    drawLine(
        from: NSPoint(x: 620, y: centerY + 7),
        to: NSPoint(x: 825, y: centerY + 7),
        color: NSColor(calibratedRed: 0.18, green: 0.25, blue: 0.48, alpha: 0.82),
        width: 15
    )
    drawLine(
        from: NSPoint(x: 620, y: centerY - 18),
        to: NSPoint(x: index == 1 ? 760 : 790, y: centerY - 18),
        color: NSColor(calibratedRed: 0.38, green: 0.45, blue: 0.64, alpha: 0.30),
        width: 10
    )
}

NSGraphicsContext.restoreGraphicsState()

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode PNG")
}

try pngData.write(to: outputURL, options: .atomic)
print("Generated icon artwork: \(outputURL.path)")
