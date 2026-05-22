#!/usr/bin/env swift
import AppKit
import CoreText

// Bold "M" centered on a transparent 2048×2048 canvas.
// Uses CTLineDraw with explicit baseline positioning derived from glyph-path
// bounds — `.draw(at:)` with typographic bounds left lots of whitespace below
// the cap-height-only glyph.

let canvas: CGFloat = 2048
let size = NSSize(width: canvas, height: canvas)

let img = NSImage(size: size, flipped: false) { rect in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // Transparent background.
    ctx.clear(rect)

    let pad: CGFloat = 80
    let targetSize = canvas - pad * 2
    let font = NSFont.systemFont(ofSize: targetSize, weight: .heavy)

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.black,
        // Slight negative kerning makes the M feel more logo-like at small sizes.
        .kern: -targetSize * 0.02,
    ]
    let str = NSAttributedString(string: "M", attributes: attrs)
    let line = CTLineCreateWithAttributedString(str)

    // Ink bounds of the glyph (no leading/descender padding).
    let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])

    // Center the ink rect on the canvas:
    //   ctx.textPosition sets the BASELINE origin.
    //   ink.minX = left edge of ink relative to baseline origin (often slightly negative)
    //   ink.minY = bottom of ink relative to baseline (negative for above-baseline glyphs)
    //
    // We want ink center to land at canvas center:
    //   inkCenterCG.x = textPos.x + ink.midX → textPos.x = canvasCenter.x - ink.midX
    //   inkCenterCG.y = textPos.y + ink.midY → textPos.y = canvasCenter.y - ink.midY
    let canvasCenter = CGPoint(x: canvas / 2, y: canvas / 2)
    let textPos = CGPoint(
        x: canvasCenter.x - ink.midX,
        y: canvasCenter.y - ink.midY
    )

    ctx.textPosition = textPos
    CTLineDraw(line, ctx)
    return true
}

if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    let outURL = URL(fileURLWithPath: "/Users/alicuche/workspace/personal/mMouse/logo.png")
    try? png.write(to: outURL)
    print("Wrote: \(outURL.path) (\(png.count / 1024) KB, \(Int(canvas))×\(Int(canvas)))")
} else {
    print("Failed to encode PNG")
}
