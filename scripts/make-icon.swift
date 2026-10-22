#!/usr/bin/env swift
// Draws Canopy's app icon (1024 × 1024, opaque) into App/Assets.xcassets/AppIcon.appiconset.
// Run from the repository root:  swift scripts/make-icon.swift
//
// A tree crown in the canopy lime over the brand green, with a trunk ringed in survey orange (the DBH
// measurement) and a faint grid for the S2 tiles.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("no context") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let s = CGFloat(size)

// Background: brand green, a little darker at the bottom.
let background = CGGradient(
    colorsSpace: space, colors: [color(0x2a7426), color(0x1e5d1b), color(0x123d12)] as CFArray,
    locations: [0, 0.55, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// S2 tile grid, very faint.
context.setStrokeColor(color(0xffffff, 0.06))
context.setLineWidth(4)
for i in 1..<6 {
    let p = s * CGFloat(i) / 6
    context.move(to: CGPoint(x: p, y: 0))
    context.addLine(to: CGPoint(x: p, y: s))
    context.move(to: CGPoint(x: 0, y: p))
    context.addLine(to: CGPoint(x: s, y: p))
}
context.strokePath()

// Ground shadow.
context.setFillColor(color(0x0f1512, 0.35))
context.fillEllipse(in: CGRect(x: 322, y: 118, width: 380, height: 64))

// Trunk.
context.setFillColor(color(0xf4f6f1))
let trunk = CGPath(roundedRect: CGRect(x: 462, y: 150, width: 100, height: 360), cornerWidth: 34, cornerHeight: 34, transform: nil)
context.addPath(trunk)
context.fillPath()

// Crown: overlapping discs, back to front.
let crown: [(CGFloat, CGFloat, CGFloat, UInt32)] = [
    (340, 580, 165, 0x7fb83c),
    (684, 580, 165, 0x7fb83c),
    (512, 545, 200, 0x8cc643),
    (405, 690, 180, 0x9bd14b),
    (619, 690, 180, 0x9bd14b),
    (512, 760, 185, 0xb6e36a),
]
for (x, y, r, hex) in crown {
    context.setFillColor(color(hex))
    context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// The trunk shows again below the crown, ringed at breast height by the survey orange.
context.setFillColor(color(0xf4f6f1))
context.addPath(CGPath(roundedRect: CGRect(x: 462, y: 150, width: 100, height: 210), cornerWidth: 34, cornerHeight: 34, transform: nil))
context.fillPath()
context.setStrokeColor(color(0xf08a24))
context.setLineWidth(22)
context.strokeEllipse(in: CGRect(x: 420, y: 226, width: 184, height: 64))

guard let image = context.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("cannot write \(url.path)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
print("wrote \(url.path)")
