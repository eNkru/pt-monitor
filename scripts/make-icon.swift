// Generates Resources/AppIcon.icns — no Xcode / asset catalog needed (R10:
// CLT-only build). Run:  swift scripts/make-icon.swift
//
// The icon matches the app's identity: the CodexBar-style panel's dark card
// (near-opaque charcoal gradient + hairline border), the teal accent #4fb6c3
// of the pill progress meters, and the ↓/↑ arrows of the menu bar speed text.
// Down is solid teal, up is dimmed — a read-only monitor leans on the
// download direction.
//
// Output: build/AppIcon.iconset with every size iconutil requires, then
// `iconutil -c icns` produces Resources/AppIcon.icns. Pure CoreGraphics, so
// every icns size is rendered crisp from the vector shape, never downscaled.

import AppKit
import CoreGraphics
import ImageIO

// MARK: - Palette (single source: design §6.2 / PanelView)

private let tealTop = CGColor(red: 0x6F / 255.0, green: 0xD3 / 255.0, blue: 0xDE / 255.0, alpha: 1)
private let tealBottom = CGColor(red: 0x3A / 255.0, green: 0xA7 / 255.0, blue: 0xB5 / 255.0, alpha: 1)
private let cardTop = CGColor(red: 0x2E / 255.0, green: 0x2E / 255.0, blue: 0x33 / 255.0, alpha: 1)
private let cardBottom = CGColor(red: 0x13 / 255.0, green: 0x13 / 255.0, blue: 0x16 / 255.0, alpha: 1)

private func rgba(_ hex: UInt32, _ alpha: CGFloat) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

// MARK: - Geometry (all in a unit side of `s`; CG origin is bottom-left)

/// The rounded-square card path. macOS template corner ≈ 22.5% of the side.
private func cardPath(_ s: CGFloat) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: s * 0.225,
        cornerHeight: s * 0.225,
        transform: nil
    )
}

/// An arrow path pointing `down` or `up`, centred on `cx`, spanning the
/// vertical band [yLow, yHigh]. One continuous shape: shaft + triangular head.
private func arrowPath(s: CGFloat, cx: CGFloat, yLow: CGFloat, yHigh: CGFloat, down: Bool) -> CGPath {
    let shaftHalf = s * 0.043 // shaft half-width
    let headHalf = s * 0.105 // head half-width
    let headDepth = s * 0.105 // head height
    let (tipY, baseY) = down ? (yLow, yHigh) : (yHigh, yLow)
    let shaftEnd = down ? yLow + headDepth : yHigh - headDepth

    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - shaftHalf, y: baseY))
    p.addLine(to: CGPoint(x: cx + shaftHalf, y: baseY))
    p.addLine(to: CGPoint(x: cx + shaftHalf, y: shaftEnd))
    p.addLine(to: CGPoint(x: cx + headHalf, y: shaftEnd))
    p.addLine(to: CGPoint(x: cx, y: tipY))
    p.addLine(to: CGPoint(x: cx - headHalf, y: shaftEnd))
    p.addLine(to: CGPoint(x: cx - shaftHalf, y: shaftEnd))
    p.closeSubpath()
    return p
}

/// A capsule (pill) path — the shape of the torrent progress meters.
private func capsulePath(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
        cornerWidth: h / 2,
        cornerHeight: h / 2,
        transform: nil
    )
}

// MARK: - Icon

/// Draws the icon into a bitmap context of `pixels` × `pixels`. All layout is
/// proportional, so any size renders identically (just crisper or coarser).
private func renderIcon(pixels: Int) -> CGImage? {
    let s = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
    ) else { return nil }

    // --- Card background: dark gradient, top-lit, hairline border. ---
    let card = cardPath(s)
    ctx.addPath(card)
    ctx.clip()

    let bg = CGGradient(colorsSpace: space, colors: [cardTop, cardBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    let sheen = CGGradient(
        colorsSpace: space,
        colors: [rgba(0xFFFFFF, 0.07), rgba(0xFFFFFF, 0.0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.42), options: [])

    ctx.addPath(card)
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.10))
    ctx.setLineWidth(s * 0.004)
    ctx.strokePath()

    // --- Arrows: ↓ solid teal (left), ↑ dimmed (right), side by side in the
    // upper-middle band. Echos the menu bar's "↓ … ↑ …" speed text. ---
    let yLow = s * 0.34
    let yHigh = s * 0.68
    let teal = CGGradient(colorsSpace: space, colors: [tealTop, tealBottom] as CFArray, locations: [0, 1])!

    // Down arrow — solid teal, vertical gradient.
    let down = arrowPath(s: s, cx: s * 0.37, yLow: yLow, yHigh: yHigh, down: true)
    ctx.addPath(down)
    ctx.saveGState()
    ctx.clip()
    ctx.drawLinearGradient(teal, start: CGPoint(x: 0, y: yHigh), end: CGPoint(x: 0, y: yLow), options: [])
    ctx.restoreGState()

    // Up arrow — same shape mirrored, dimmed to sit behind the down arrow
    // in the hierarchy.
    let up = arrowPath(s: s, cx: s * 0.63, yLow: yLow, yHigh: yHigh, down: false)
    ctx.addPath(up)
    ctx.saveGState()
    ctx.clip()
    ctx.setAlpha(0.38)
    ctx.drawLinearGradient(teal, start: CGPoint(x: 0, y: yHigh), end: CGPoint(x: 0, y: yLow), options: [])
    ctx.restoreGState()

    // --- Pill progress meter: track at ~12% teal, fill 62% — same shape as
    // the torrent rows' PillMeter. ---
    let meterW = s * 0.52
    let meterH = s * 0.032
    let meterY = s * 0.21
    let meterCX = s * 0.5

    ctx.addPath(capsulePath(cx: meterCX, cy: meterY, w: meterW, h: meterH))
    ctx.setFillColor(CGColor(red: 0x4F / 255.0, green: 0xB6 / 255.0, blue: 0xC3 / 255.0, alpha: 0.12))
    ctx.fillPath()

    // Fill: left-anchored 62% of the track, solid teal.
    let fillW = meterW * 0.62
    ctx.addPath(capsulePath(cx: meterCX - meterW / 2 + fillW / 2, cy: meterY, w: fillW, h: meterH))
    ctx.saveGState()
    ctx.clip()
    ctx.drawLinearGradient(teal, start: CGPoint(x: 0, y: meterY + meterH), end: CGPoint(x: 0, y: meterY - meterH), options: [])
    ctx.restoreGState()

    return ctx.makeImage()
}

// MARK: - PNG output

private func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// MARK: - Main

let fm = FileManager.default
let root = URL(fileURLWithPath: #filePath) // .../pt-monitor/scripts/make-icon.swift
let repo = root.deletingLastPathComponent().deletingLastPathComponent()
let iconset = repo.appendingPathComponent("build/AppIcon.iconset")

try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (file name, pixel size) — exactly the set iconutil requires.
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    guard let image = renderIcon(pixels: px) else {
        FileHandle.standardError.write(Data("error: render failed at \(px)px\n".utf8))
        exit(1)
    }
    guard writePNG(image, to: iconset.appendingPathComponent(name)) else {
        FileHandle.standardError.write(Data("error: PNG write failed: \(name)\n".utf8))
        exit(1)
    }
}

// Preview copy for review (read tool can display it).
if let image = renderIcon(pixels: 512) {
    _ = writePNG(image, to: repo.appendingPathComponent("build/icon-preview.png"))
}

print("iconset: \(iconset.path)")
