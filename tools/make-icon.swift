#!/usr/bin/env swift
// Draws the Tandem app icon with Core Graphics and writes every size macOS asks for.
//
//     swift tools/make-icon.swift TandemApp/Sources/Tandem/Assets.xcassets/AppIcon.appiconset
//
// The mark: the same dark rounded plate as the user's other apps (Selects), and on it the two
// nested battery rings from the small widget — Mac outside, iPhone inside — drawn in the family's
// amber, with a small bolt in the centre. Everything is drawn here; no third-party artwork.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let plateTop = rgb(0.157, 0.157, 0.168)
let plateBottom = rgb(0.086, 0.086, 0.094)
let track = rgb(0.255, 0.255, 0.271)
let amber = rgb(0.925, 0.760, 0.435)
let amberDeep = rgb(0.835, 0.620, 0.290)

func boltPath(in rect: CGRect) -> CGPath {
    // SF-style bolt on a 24-unit grid, y down.
    let pts: [(Double, Double)] = [(13, 2), (5, 13), (11, 13), (10, 22), (18, 11), (12, 11)]
    let t = CGAffineTransform(translationX: rect.minX, y: rect.maxY)
        .scaledBy(x: rect.width / 24, y: -rect.height / 24)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: pts[0].0, y: pts[0].1), transform: t)
    for (x, y) in pts.dropFirst() { p.addLine(to: CGPoint(x: x, y: y), transform: t) }
    p.closeSubpath()
    return p
}

func ring(_ ctx: CGContext, center: CGPoint, radius: Double, width: Double, fraction: Double, color: CGColor) {
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(track)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    let start = Double.pi / 2                       // 12 o'clock, then clockwise
    let end = start - 2 * .pi * fraction
    ctx.setStrokeColor(color)
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
}

func drawIcon(size: Int) -> CGImage {
    let s = Double(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = s * 0.094
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = plate.width * 0.223
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [plateTop, plateBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()

    // Rings: outer = Mac, inner = iPhone. Amber with a slight depth gradient via two tones.
    let c = CGPoint(x: plate.midX, y: plate.midY)
    let w = plate.width
    let outerR = w * 0.30, innerR = w * 0.195, stroke = w * 0.085
    ring(ctx, center: c, radius: outerR, width: stroke, fraction: 0.72, color: amber)
    ring(ctx, center: c, radius: innerR, width: stroke, fraction: 0.58, color: amberDeep)

    // Bolt in the centre.
    let boltSize = w * 0.20
    let boltRect = CGRect(x: c.x - boltSize / 2, y: c.y - boltSize / 2, width: boltSize, height: boltSize)
    ctx.saveGState()
    ctx.addPath(boltPath(in: boltRect))
    ctx.clip()
    let warm = CGGradient(colorsSpace: space, colors: [amber, amberDeep] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: 0, y: boltRect.maxY), end: CGPoint(x: 0, y: boltRect.minY), options: [])
    ctx.restoreGState()

    // Hairline highlight on the plate edge, as in the sibling icons.
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: s * 0.004, dy: s * 0.004), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.07))
    ctx.setLineWidth(s * 0.006)
    ctx.strokePath()

    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    write(drawIcon(size: px), to: outDir.appendingPathComponent("\(name).png"))
}
let contents: [String: Any] = [
    "images": [
        ["idiom": "mac", "scale": "1x", "size": "16x16", "filename": "icon_16x16.png"],
        ["idiom": "mac", "scale": "2x", "size": "16x16", "filename": "icon_16x16@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "32x32", "filename": "icon_32x32.png"],
        ["idiom": "mac", "scale": "2x", "size": "32x32", "filename": "icon_32x32@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"],
        ["idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"],
        ["idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"],
        ["idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"],
    ],
    "info": ["author": "xcode", "version": 1],
]
let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(sizes.count) icons to \(outDir.path)")
