#!/usr/bin/env swift
import AppKit

// Candidate SF Symbols suitable for an aim/cursor overlay.
let candidates: [String] = [
    "scope",                            // current
    "target",
    "dot.scope",
    "plus.viewfinder",
    "viewfinder",
    "viewfinder.circle",
    "viewfinder.circle.fill",
    "circle.dotted",
    "smallcircle.filled.circle",
    "smallcircle.filled.circle.fill",
    "record.circle",
    "record.circle.fill",
    "circle.inset.filled",
    "circle.circle",
    "circle.circle.fill",
    "circle.and.line.horizontal",
    "circle.and.line.horizontal.fill",
    "camera.metering.center.weighted",
    "camera.metering.spot",
    "plus.circle",
    "plus.circle.fill",
    "cursorarrow",
    "cursorarrow.click",
    "cursorarrow.rays",
    "hand.point.up.left",
    "location.north.circle.fill",
    "mappin.circle.fill",
    "diamond",
    "diamond.fill",
    "rhombus",
    "rhombus.fill",
    "arrow.up.and.down.and.arrow.left.and.right",
    "arrowtriangle.up.fill",
]

let iconSize: CGFloat = 56
let cellSize: CGFloat = 110
let cols = 4
let rows = (candidates.count + cols - 1) / cols
let imgWidth  = CGFloat(cols) * cellSize
let imgHeight = CGFloat(rows) * cellSize

let img = NSImage(size: NSSize(width: imgWidth, height: imgHeight))
img.lockFocus()

// Dark background so blue/green icons pop
NSColor(white: 0.12, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: imgWidth, height: imgHeight).fill()

let nameAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
    .foregroundColor: NSColor.white,
]

for (i, name) in candidates.enumerated() {
    let col = i % cols
    let row = i / cols
    let cellX = CGFloat(col) * cellSize
    // Flip rows so [0] is top-left
    let cellY = imgHeight - CGFloat(row + 1) * cellSize

    let cellRect = NSRect(x: cellX, y: cellY, width: cellSize, height: cellSize)

    // Cell border
    NSColor(white: 0.25, alpha: 1).setStroke()
    let border = NSBezierPath(rect: cellRect.insetBy(dx: 1, dy: 1))
    border.lineWidth = 0.5
    border.stroke()

    // Render icon
    let iconRect = NSRect(
        x: cellX + (cellSize - iconSize) / 2,
        y: cellY + (cellSize - iconSize) / 2 + 10, // shift up a bit for label
        width: iconSize,
        height: iconSize
    )

    if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
        if let configured = symbol.withSymbolConfiguration(cfg) {
            // Tint blue (mMouse default color)
            let tinted = NSImage(size: configured.size, flipped: false) { rect in
                NSColor.systemBlue.set()
                rect.fill()
                configured.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
            tinted.draw(in: iconRect)
        }
    } else {
        // Missing symbol — red X
        NSColor.systemRed.setStroke()
        let x = NSBezierPath()
        x.lineWidth = 2
        x.move(to: NSPoint(x: iconRect.minX, y: iconRect.minY))
        x.line(to: NSPoint(x: iconRect.maxX, y: iconRect.maxY))
        x.move(to: NSPoint(x: iconRect.minX, y: iconRect.maxY))
        x.line(to: NSPoint(x: iconRect.maxX, y: iconRect.minY))
        x.stroke()
    }

    // Label
    let label = name as NSString
    let labelSize = label.size(withAttributes: nameAttrs)
    label.draw(
        at: NSPoint(x: cellX + (cellSize - labelSize.width) / 2, y: cellY + 6),
        withAttributes: nameAttrs
    )
}

img.unlockFocus()

// Save
let outPath = "/Users/alicuche/workspace/personal/mMouse/scripts/icon-preview.png"
if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: outPath))
    print("Wrote: \(outPath)")
} else {
    print("Failed to encode PNG")
}
