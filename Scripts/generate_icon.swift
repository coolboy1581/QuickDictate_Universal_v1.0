import Cocoa

func renderQuickDictateIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let scale = size / 1024.0

    // 1. Shadow for squircle
    ctx.saveGState()
    let shadowOffset = CGSize(width: 0, height: -18 * scale)
    let shadowBlur = 32.0 * scale
    ctx.setShadow(offset: shadowOffset, blur: shadowBlur, color: NSColor.black.withAlphaComponent(0.35).cgColor)

    // 2. Base Squircle Path
    let margin: CGFloat = 80.0 * scale
    let iconRect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let cornerRadius: CGFloat = 200.0 * scale
    let squirclePath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Background Gradient (Dark Indigo to Vibrant Deep Purple/Blue)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.24, alpha: 1.0).cgColor, // Deep midnight
        NSColor(calibratedRed: 0.22, green: 0.18, blue: 0.44, alpha: 1.0).cgColor, // Rich violet
        NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.52, alpha: 1.0).cgColor  // Royal blue
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.55, 1.0]
    let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: bgLocations)!

    squirclePath.addClip()
    ctx.drawLinearGradient(gradient, start: CGPoint(x: iconRect.midX, y: iconRect.maxY), end: CGPoint(x: iconRect.midX, y: iconRect.minY), options: [])
    ctx.restoreGState()

    // 3. Subtle Inner Border / Bevel
    ctx.saveGState()
    let innerBorderPath = NSBezierPath(roundedRect: iconRect.insetBy(dx: 1.5 * scale, dy: 1.5 * scale), xRadius: cornerRadius - 1.5 * scale, yRadius: cornerRadius - 1.5 * scale)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.setLineWidth(2.5 * scale)
    innerBorderPath.stroke()
    ctx.restoreGState()

    // 4. Subtle Radial Glow behind microphone
    ctx.saveGState()
    let glowCenter = CGPoint(x: size * 0.5, y: size * 0.52)
    let glowColors = [
        NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 0.35).cgColor,
        NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 0.0).cgColor
    ] as CFArray
    let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(glowGradient, startCenter: glowCenter, startRadius: 0, endCenter: glowCenter, endRadius: 280 * scale, options: [])
    ctx.restoreGState()

    // 5. Waveform Bars (Symmetrical glowing sound bars on left and right)
    ctx.saveGState()
    let barHeights: [CGFloat] = [70, 140, 220, 130, 80]
    let barSpacing: CGFloat = 28 * scale
    let barWidth: CGFloat = 18 * scale
    let leftStartX = size * 0.5 - (110 * scale) - (5 * (barWidth + barSpacing))
    let rightStartX = size * 0.5 + (110 * scale)

    let waveColors = [
        NSColor(calibratedRed: 0.0, green: 0.88, blue: 0.95, alpha: 0.9).cgColor, // Cyan
        NSColor(calibratedRed: 0.35, green: 0.75, blue: 1.0, alpha: 0.95).cgColor // Sky Blue
    ] as CFArray
    let waveGradient = CGGradient(colorsSpace: colorSpace, colors: waveColors, locations: [0.0, 1.0])!

    // Draw Left Bars
    for (i, h) in barHeights.enumerated() {
        let x = leftStartX + CGFloat(i) * (barWidth + barSpacing)
        let scaledH = h * scale
        let y = size * 0.52 - scaledH * 0.5
        let barRect = CGRect(x: x, y: y, width: barWidth, height: scaledH)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth * 0.5, yRadius: barWidth * 0.5)
        ctx.saveGState()
        barPath.addClip()
        ctx.drawLinearGradient(waveGradient, start: CGPoint(x: x, y: y), end: CGPoint(x: x, y: y + scaledH), options: [])
        ctx.restoreGState()
    }

    // Draw Right Bars (Reversed for symmetry)
    for (i, h) in barHeights.reversed().enumerated() {
        let x = rightStartX + CGFloat(i) * (barWidth + barSpacing)
        let scaledH = h * scale
        let y = size * 0.52 - scaledH * 0.5
        let barRect = CGRect(x: x, y: y, width: barWidth, height: scaledH)
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth * 0.5, yRadius: barWidth * 0.5)
        ctx.saveGState()
        barPath.addClip()
        ctx.drawLinearGradient(waveGradient, start: CGPoint(x: x, y: y), end: CGPoint(x: x, y: y + scaledH), options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // 6. Central Modern Microphone Glyph (Crisp Vector)
    ctx.saveGState()
    let micCenterX = size * 0.5
    let micCenterY = size * 0.55
    let micWidth: CGFloat = 110 * scale
    let micHeight: CGFloat = 200 * scale

    // Microphone capsule
    let capsuleRect = CGRect(x: micCenterX - micWidth * 0.5, y: micCenterY - micHeight * 0.5 + 40 * scale, width: micWidth, height: micHeight)
    let capsulePath = NSBezierPath(roundedRect: capsuleRect, xRadius: micWidth * 0.5, yRadius: micWidth * 0.5)

    // Microphone metallic gradient (pure white to light cool silver)
    let micColors = [
        NSColor.white.cgColor,
        NSColor(calibratedRed: 0.88, green: 0.92, blue: 0.98, alpha: 1.0).cgColor
    ] as CFArray
    let micGrad = CGGradient(colorsSpace: colorSpace, colors: micColors, locations: [0.0, 1.0])!

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 16 * scale, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    capsulePath.addClip()
    ctx.drawLinearGradient(micGrad, start: CGPoint(x: capsuleRect.midX, y: capsuleRect.maxY), end: CGPoint(x: capsuleRect.midX, y: capsuleRect.minY), options: [])
    ctx.restoreGState()

    // Microphone Mesh / Band accent
    let bandY = capsuleRect.minY + capsuleRect.height * 0.42
    let bandHeight: CGFloat = 14 * scale
    let bandRect = CGRect(x: capsuleRect.minX + 4 * scale, y: bandY, width: capsuleRect.width - 8 * scale, height: bandHeight)
    ctx.setFillColor(NSColor(calibratedRed: 0.22, green: 0.20, blue: 0.38, alpha: 0.25).cgColor)
    ctx.fill(bandRect)

    // Microphone Outer U-Cradle / Stand
    let cradleWidth = micWidth + 56 * scale
    let cradleHeight = micHeight * 0.65
    let cradleRect = CGRect(x: micCenterX - cradleWidth * 0.5, y: capsuleRect.minY - 18 * scale, width: cradleWidth, height: cradleHeight)
    let cradlePath = CGMutablePath()
    cradlePath.addArc(center: CGPoint(x: micCenterX, y: cradleRect.maxY - cradleWidth * 0.5 + 20 * scale),
                      radius: cradleWidth * 0.5,
                      startAngle: .pi,
                      endAngle: 0,
                      clockwise: true)

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(20 * scale)
    ctx.setLineCap(.round)
    ctx.addPath(cradlePath)
    ctx.strokePath()

    // Microphone Stem & Base
    let stemY = cradleRect.maxY - cradleWidth * 0.5 + 20 * scale - (cradleWidth * 0.5)
    let stemHeight: CGFloat = 55 * scale
    let stemPath = NSBezierPath()
    stemPath.move(to: CGPoint(x: micCenterX, y: stemY))
    stemPath.line(to: CGPoint(x: micCenterX, y: stemY - stemHeight))
    stemPath.lineWidth = 20 * scale
    stemPath.lineCapStyle = .round
    NSColor.white.setStroke()
    stemPath.stroke()

    // Horizontal Base plate
    let baseWidth: CGFloat = 110 * scale
    let basePath = NSBezierPath()
    basePath.move(to: CGPoint(x: micCenterX - baseWidth * 0.5, y: stemY - stemHeight))
    basePath.line(to: CGPoint(x: micCenterX + baseWidth * 0.5, y: stemY - stemHeight))
    basePath.lineWidth = 20 * scale
    basePath.lineCapStyle = .round
    basePath.stroke()

    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func savePNG(image: NSImage, path: String, targetPixelSize: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: targetPixelSize,
        pixelsHigh: targetPixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: targetPixelSize, height: targetPixelSize),
               from: NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
               operation: .copy,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

let fm = FileManager.default
let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetDir = "\(root)/AppBundle/QuickDictate.iconset"
let icnsPath = "\(root)/AppBundle/AppIcon.icns"

try? fm.removeItem(atPath: iconsetDir)
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let baseImage = renderQuickDictateIcon(size: 1024)

let iconConfigs: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for cfg in iconConfigs {
    let outPath = "\(iconsetDir)/\(cfg.name)"
    savePNG(image: baseImage, path: outPath, targetPixelSize: cfg.px)
    print("Generated \(cfg.name) (\(cfg.px)x\(cfg.px))")
}

// Convert with iconutil
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
do {
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
        print("Successfully generated \(icnsPath)")
    } else {
        print("iconutil failed with code \(process.terminationStatus)")
    }
} catch {
    print("iconutil failed: \(error)")
}
