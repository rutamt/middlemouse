import AppKit
import CoreGraphics

// Usage: generate_icon [output directory]
// Writes AppIcon.icns and MenuBarIcon.pdf (the vector template the app loads for its status item).

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath,
    isDirectory: true
)
let canvas: CGFloat = 1024
let cyan = CGColor(srgbRed: 0.20, green: 0.86, blue: 0.98, alpha: 1)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func verticalGradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
}

/// A true superellipse, which is what gives macOS icons their squircle shape.
func squirclePath(center: CGPoint, radius: CGFloat, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for step in 0..<steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = center.x + radius * copysign(pow(abs(cosine), 2 / exponent), cosine)
        let y = center.y + radius * copysign(pow(abs(sine), 2 / exponent), sine)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

func pill(centerX: CGFloat, centerY: CGFloat, width: CGFloat, height: CGFloat) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height),
        cornerWidth: width / 2,
        cornerHeight: width / 2,
        transform: nil
    )
}

func drawAppIcon(in context: CGContext, pixels: Int) {
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    context.setShouldAntialias(true)

    // Apple's icon grid leaves a 100pt margin around an 824pt body.
    let center = CGPoint(x: 512, y: 512)
    let squircle = squirclePath(center: center, radius: 412)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
    context.addPath(squircle)
    context.setFillColor(color(0.09, 0.11, 0.14))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(squircle)
    context.clip()
    context.drawLinearGradient(
        verticalGradient(color(0.27, 0.32, 0.39), color(0.07, 0.09, 0.12)),
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )

    let wheelCenter = CGPoint(x: 512, y: 610)

    // Click ripple, spreading from the wheel out past the mouse body.
    for (radius, alpha, width) in [(CGFloat(330), CGFloat(0.10), CGFloat(10)), (250, 0.20, 12), (170, 0.36, 14)] {
        context.setStrokeColor(cyan.copy(alpha: alpha)!)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(
            x: wheelCenter.x - radius,
            y: wheelCenter.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    // Mouse silhouette with a soft outer glow.
    let body = pill(centerX: 512, centerY: 490, width: 350, height: 570)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 56, color: color(0.78, 0.90, 1, 0.55))
    context.addPath(body)
    context.setFillColor(color(0.13, 0.16, 0.20))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    context.drawLinearGradient(
        verticalGradient(color(0.24, 0.29, 0.35), color(0.11, 0.14, 0.18)),
        start: CGPoint(x: 512, y: 775),
        end: CGPoint(x: 512, y: 205),
        options: []
    )
    // Inner ring of the ripple reads through the shell.
    context.setStrokeColor(cyan.copy(alpha: 0.55)!)
    context.setLineWidth(12)
    context.strokeEllipse(in: CGRect(x: wheelCenter.x - 96, y: wheelCenter.y - 96, width: 192, height: 192))
    context.restoreGState()

    context.addPath(body)
    context.setStrokeColor(color(0.90, 0.94, 0.98))
    context.setLineWidth(22)
    context.strokePath()

    // Scroll wheel.
    let wheel = pill(centerX: wheelCenter.x, centerY: wheelCenter.y, width: 58, height: 136)
    context.saveGState()
    context.setShadow(offset: .zero, blur: 60, color: cyan)
    context.addPath(wheel)
    context.setFillColor(cyan)
    context.fillPath()
    context.restoreGState()

    context.restoreGState()
}

func renderPNG(pixels: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.featureUnsupported)
    }
    drawAppIcon(in: context, pixels: pixels)
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

func generateAppIcon() throws {
    let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    for points in [16, 32, 128, 256, 512] {
        try renderPNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try renderPNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = [
        "-c", "icns",
        iconset.path,
        "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path,
    ]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

/// Black on clear; AppKit recolors it for light and dark menu bars because the app marks it as a template.
func generateMenuBarIcon() throws {
    let url = outputDirectory.appendingPathComponent("MenuBarIcon.pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.beginPDFPage(nil)

    context.addPath(CGPath(
        roundedRect: CGRect(x: 4.25, y: 1.75, width: 9.5, height: 14.5),
        cornerWidth: 4.75,
        cornerHeight: 4.75,
        transform: nil
    ))
    context.setStrokeColor(color(0, 0, 0))
    context.setLineWidth(1.5)
    context.strokePath()

    context.addPath(pill(centerX: 9, centerY: 11.25, width: 2.5, height: 5))
    context.setFillColor(color(0, 0, 0))
    context.fillPath()

    context.endPDFPage()
    context.closePDF()
}

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try generateAppIcon()
    try generateMenuBarIcon()
} catch {
    FileHandle.standardError.write(Data("generate_icon: \(error)\n".utf8))
    exit(1)
}
