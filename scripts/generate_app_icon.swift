// generate_app_icon.swift
//
// Renders the PolyJuiceVoice app icon at 1024×1024 PNG using CoreGraphics.
// Run from a Mac:
//   swift scripts/generate_app_icon.swift
//
// Output: PolyJuiceVoice/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// Design notes:
//   * Polyjuice Potion is bubbling, viscous, and magical.
//   * Background: deep emerald → midnight gradient (Slytherin-ish, magical).
//   * Centerpiece: stylized potion flask with rounded shoulders.
//   * Inside the flask: three concentric arcs (sound waves) glowing gold.
//   * Above the flask: one rising bubble.
//   * Subtle inner highlight on the flask glass.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size: CGFloat = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Could not create bitmap context")
}

// Flip the coordinate system so Y=0 is the TOP of the canvas (matching the
// design comments above). CoreGraphics defaults to Y=0 at the bottom.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// MARK: - 1. Background gradient (deep emerald → midnight)

let bgColors = [
    CGColor(srgbRed: 0.08, green: 0.20, blue: 0.16, alpha: 1.0),   // deep emerald
    CGColor(srgbRed: 0.02, green: 0.06, blue: 0.10, alpha: 1.0),   // near-black blue
] as CFArray
let bgGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: bgColors,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// MARK: - 2. Soft radial glow behind flask

let glowCenter = CGPoint(x: size / 2, y: size * 0.55)
let glowColors = [
    CGColor(srgbRed: 0.25, green: 0.85, blue: 0.55, alpha: 0.55),  // bright green glow
    CGColor(srgbRed: 0.05, green: 0.30, blue: 0.20, alpha: 0.0),
] as CFArray
let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: glowColors,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    glow,
    startCenter: glowCenter, startRadius: 0,
    endCenter: glowCenter, endRadius: size * 0.42,
    options: []
)

// MARK: - 3. Flask outline + fill

// Flask geometry: long neck, rounded shoulders, wide body.
let cx: CGFloat = size / 2
let neckTop: CGFloat = size * 0.20
let neckBottom: CGFloat = size * 0.36
let neckHalfWidth: CGFloat = size * 0.07
let shoulderTop: CGFloat = neckBottom
let shoulderBottom: CGFloat = size * 0.45
let bodyHalfWidth: CGFloat = size * 0.26
let bodyBottom: CGFloat = size * 0.84
let cornerRadius: CGFloat = size * 0.08

let flask = CGMutablePath()
// Start at top-left of neck rim
flask.move(to: CGPoint(x: cx - neckHalfWidth, y: neckTop))
// Down the left side of neck
flask.addLine(to: CGPoint(x: cx - neckHalfWidth, y: shoulderTop))
// Curve outwards to the body
flask.addQuadCurve(
    to: CGPoint(x: cx - bodyHalfWidth, y: shoulderBottom),
    control: CGPoint(x: cx - bodyHalfWidth * 0.85, y: shoulderTop + (shoulderBottom - shoulderTop) * 0.1)
)
// Down the left body
flask.addLine(to: CGPoint(x: cx - bodyHalfWidth, y: bodyBottom - cornerRadius))
// Bottom-left corner
flask.addArc(
    tangent1End: CGPoint(x: cx - bodyHalfWidth, y: bodyBottom),
    tangent2End: CGPoint(x: cx - bodyHalfWidth + cornerRadius, y: bodyBottom),
    radius: cornerRadius
)
// Across bottom
flask.addLine(to: CGPoint(x: cx + bodyHalfWidth - cornerRadius, y: bodyBottom))
// Bottom-right corner
flask.addArc(
    tangent1End: CGPoint(x: cx + bodyHalfWidth, y: bodyBottom),
    tangent2End: CGPoint(x: cx + bodyHalfWidth, y: bodyBottom - cornerRadius),
    radius: cornerRadius
)
// Up the right body
flask.addLine(to: CGPoint(x: cx + bodyHalfWidth, y: shoulderBottom))
// Curve back to neck
flask.addQuadCurve(
    to: CGPoint(x: cx + neckHalfWidth, y: shoulderTop),
    control: CGPoint(x: cx + bodyHalfWidth * 0.85, y: shoulderTop + (shoulderBottom - shoulderTop) * 0.1)
)
// Up the right neck
flask.addLine(to: CGPoint(x: cx + neckHalfWidth, y: neckTop))
flask.closeSubpath()

// Glass fill — translucent green gradient
ctx.saveGState()
ctx.addPath(flask)
ctx.clip()

let glassColors = [
    CGColor(srgbRed: 0.18, green: 0.70, blue: 0.45, alpha: 0.95),  // top: bright green liquid
    CGColor(srgbRed: 0.05, green: 0.40, blue: 0.30, alpha: 0.95),  // bottom: deep teal
] as CFArray
let glassGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: glassColors,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    glassGradient,
    start: CGPoint(x: cx, y: shoulderTop),
    end: CGPoint(x: cx, y: bodyBottom),
    options: []
)

// MARK: - 4. Sound waves inside the flask body

let waveCenter = CGPoint(x: cx, y: (shoulderBottom + bodyBottom) / 2 + size * 0.02)
ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.90, blue: 0.55, alpha: 0.95))   // warm gold
ctx.setLineCap(.round)
let waveRadii: [CGFloat] = [size * 0.07, size * 0.12, size * 0.17]
let waveLineWidths: [CGFloat] = [size * 0.018, size * 0.014, size * 0.011]
for (radius, lineWidth) in zip(waveRadii, waveLineWidths) {
    ctx.setLineWidth(lineWidth)
    let arc = CGMutablePath()
    arc.addArc(
        center: waveCenter,
        radius: radius,
        startAngle: .pi * 1.20,
        endAngle: .pi * 1.80,
        clockwise: false
    )
    ctx.addPath(arc)
    ctx.strokePath()
}
// Small filled dot at the wave center (the speaker)
ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.90, blue: 0.55, alpha: 1.0))
ctx.fillEllipse(in: CGRect(
    x: waveCenter.x - size * 0.018,
    y: waveCenter.y - size * 0.018,
    width: size * 0.036,
    height: size * 0.036
))

ctx.restoreGState()

// MARK: - 5. Inner highlight on the glass (subtle white sheen left side)

ctx.saveGState()
ctx.addPath(flask)
ctx.clip()
let sheenColors = [
    CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.18),
    CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0),
] as CFArray
let sheenGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: sheenColors,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    sheenGradient,
    start: CGPoint(x: cx - bodyHalfWidth * 0.7, y: shoulderTop),
    end: CGPoint(x: cx - bodyHalfWidth * 0.2, y: bodyBottom),
    options: []
)
ctx.restoreGState()

// MARK: - 6. Flask outline stroke

ctx.addPath(flask)
ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 1.0, blue: 0.85, alpha: 0.85))
ctx.setLineWidth(size * 0.012)
ctx.strokePath()

// MARK: - 7. Cork/stopper at neck top

let corkRect = CGRect(
    x: cx - neckHalfWidth - size * 0.012,
    y: neckTop - size * 0.05,
    width: (neckHalfWidth + size * 0.012) * 2,
    height: size * 0.06
)
let corkPath = CGPath(roundedRect: corkRect, cornerWidth: size * 0.02, cornerHeight: size * 0.02, transform: nil)
ctx.addPath(corkPath)
ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.40, blue: 0.20, alpha: 1.0))   // cork brown
ctx.fillPath()
ctx.addPath(corkPath)
ctx.setStrokeColor(CGColor(srgbRed: 0.30, green: 0.20, blue: 0.10, alpha: 1.0))
ctx.setLineWidth(size * 0.006)
ctx.strokePath()

// MARK: - 8. Rising bubbles above the flask

let bubbleColor = CGColor(srgbRed: 0.7, green: 1.0, blue: 0.85, alpha: 0.9)
let bubbles: [(x: CGFloat, y: CGFloat, r: CGFloat, alpha: CGFloat)] = [
    (cx - size * 0.08, neckTop - size * 0.10, size * 0.025, 0.85),
    (cx + size * 0.06, neckTop - size * 0.16, size * 0.018, 0.70),
    (cx - size * 0.02, neckTop - size * 0.22, size * 0.012, 0.50),
]
for b in bubbles {
    ctx.setFillColor(CGColor(
        srgbRed: 0.7, green: 1.0, blue: 0.85, alpha: b.alpha
    ))
    ctx.fillEllipse(in: CGRect(x: b.x - b.r, y: b.y - b.r, width: b.r * 2, height: b.r * 2))
    // tiny highlight
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: b.alpha * 0.6))
    ctx.fillEllipse(in: CGRect(
        x: b.x - b.r * 0.45,
        y: b.y - b.r * 0.45,
        width: b.r * 0.5,
        height: b.r * 0.5
    ))
    _ = bubbleColor
}

// MARK: - Save PNG

guard let cgImage = ctx.makeImage() else {
    fatalError("Could not finalize image")
}

let outURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "PolyJuiceVoice/Assets.xcassets/AppIcon.appiconset/icon-1024.png")

try? FileManager.default.createDirectory(
    at: outURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fatalError("Could not create image destination at \(outURL.path)")
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else {
    fatalError("Could not write PNG to \(outURL.path)")
}

print("Wrote 1024×1024 icon to \(outURL.path)")
