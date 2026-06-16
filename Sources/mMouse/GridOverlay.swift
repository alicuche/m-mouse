import AppKit
import CoreGraphics
import Foundation

/// Full-screen translucent overlay that paints a labelled matrix over the
/// display the cursor sits on. Each cell carries a two-letter code (row letter
/// + column letter, e.g. "BC"); typing the pair warps the cursor to that cell's
/// centre. The overlay is a passive, click-through display layer — all key
/// capture happens in EventTapManager via the CGEventTap, never here.
///
/// Coordinate spaces (the single most bug-prone part of this file):
///   - `displayBounds` is in CG coords (origin top-left, Y down) — same space
///     MouseController / CGWarpMouseCursorPosition use.
///   - `cellCentre(row:col:)` returns a CG point (handed straight to warp()).
///   - The NSPanel frame and all NSView drawing are in NS coords (origin
///     bottom-left, Y up). The panel is positioned so its content view maps
///     1:1 onto the target display; drawing flips Y internally.
@MainActor
final class GridOverlay {

    private let panel: NSPanel
    private let gridView: GridView

    /// Letters used for row/column labels (uppercase, in order). 26 max per axis.
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    private(set) var rows: Int = 0
    private(set) var cols: Int = 0
    /// CG bounds of the display currently being painted.
    private var displayBounds: CGRect = .zero

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Sit just below the cursor badge (popUpMenu+1) but above app content,
        // so the small badge stays visible if both are shown. The grid hides
        // the badge anyway while open; this only matters during transitions.
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        panel.level = NSWindow.Level(rawValue: popUpLevel)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let view = GridView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        panel.contentView = view

        self.panel = panel
        self.gridView = view
    }

    /// Show the grid over `bounds` (CG coords) with the given matrix size.
    /// `currentRow`/`currentCol` mark the cell the cursor currently occupies
    /// (outlined distinctly to orient the user).
    func show(on bounds: CGRect, rows: Int, cols: Int, currentRow: Int, currentCol: Int) {
        self.displayBounds = bounds
        self.rows = rows
        self.cols = cols

        panel.setFrame(Self.nsFrame(for: bounds), display: false)
        // Content view must fill the panel; reset its frame to the panel's size.
        gridView.frame = NSRect(origin: .zero, size: bounds.size)
        gridView.configure(rows: rows, cols: cols, currentRow: currentRow, currentCol: currentCol)
        gridView.highlightedRow = nil
        gridView.needsDisplay = true

        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Dim every row except `row` (the row picked by the first keypress). Pass
    /// `nil` to clear the dim (e.g. after Backspace / timeout).
    func highlight(row: Int?) {
        gridView.highlightedRow = row
        gridView.needsDisplay = true
    }

    /// Move the "you are here" outline to the cell the cursor now occupies.
    /// Cheap: only triggers a redraw when the cell actually changes.
    func updateCurrent(row: Int, col: Int) {
        guard row != gridView.currentRow || col != gridView.currentCol else { return }
        gridView.currentRow = row
        gridView.currentCol = col
        gridView.needsDisplay = true
    }

    /// Centre of cell (row, col) in CG coords — fed directly to warp().
    func cellCentre(row: Int, col: Int) -> CGPoint {
        let cellW = displayBounds.width / CGFloat(max(1, cols))
        let cellH = displayBounds.height / CGFloat(max(1, rows))
        return CGPoint(
            x: displayBounds.minX + (CGFloat(col) + 0.5) * cellW,
            y: displayBounds.minY + (CGFloat(row) + 0.5) * cellH
        )
    }

    /// Convert a CG display rect (top-left origin) → NS panel frame
    /// (bottom-left origin). NS global coords share the X axis with CG; only Y
    /// is flipped, using the primary display height as the baseline — the same
    /// convention CursorBadge.panelOriginForCursor relies on.
    private static func nsFrame(for cg: CGRect) -> NSRect {
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(
            x: cg.minX,
            y: primaryHeight - cg.maxY,
            width: cg.width,
            height: cg.height
        )
    }
}

/// The drawing surface. Lives in NS coords (Y up). Row 0 is the TOP of the
/// screen, so when drawing we flip the row index against the view height.
private final class GridView: NSView {

    private var rows: Int = 0
    private var cols: Int = 0
    fileprivate var currentRow: Int = -1
    fileprivate var currentCol: Int = -1

    /// When set, all rows except this one are dimmed (post first keypress).
    var highlightedRow: Int? = nil

    override var isFlipped: Bool { false } // explicit NS (bottom-left) coords

    func configure(rows: Int, cols: Int, currentRow: Int, currentCol: Int) {
        self.rows = rows
        self.cols = cols
        self.currentRow = currentRow
        self.currentCol = currentCol
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rows > 0, cols > 0 else { return }
        let w = bounds.width
        let h = bounds.height
        let cellW = w / CGFloat(cols)
        let cellH = h / CGFloat(rows)

        // Light scrim so labels pop while content stays visible underneath.
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        // Hover cell: fill the WHOLE cell the cursor sits in with a pale neon
        // yellow so it reads as "you are here", drawn under the grid lines.
        if currentRow >= 0, currentCol >= 0, currentRow < rows, currentCol < cols {
            let hoverRect = NSRect(
                x: CGFloat(currentCol) * cellW,
                y: h - CGFloat(currentRow + 1) * cellH,
                width: cellW,
                height: cellH
            )
            Self.hoverFill.setFill()
            NSBezierPath(rect: hoverRect).fill()
        }

        // Grid lines (subtle).
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let linePath = NSBezierPath()
        linePath.lineWidth = 1
        for c in 0...cols {
            let x = CGFloat(c) * cellW
            linePath.move(to: NSPoint(x: x, y: 0))
            linePath.line(to: NSPoint(x: x, y: h))
        }
        for r in 0...rows {
            let y = CGFloat(r) * cellH
            linePath.move(to: NSPoint(x: 0, y: y))
            linePath.line(to: NSPoint(x: w, y: y))
        }
        linePath.stroke()

        let alphabet = GridOverlay.alphabet
        let font = NSFont.monospacedSystemFont(ofSize: min(16, cellH * 0.32), weight: .bold)

        for r in 0..<rows {
            guard r < alphabet.count else { break }
            let dimmed = (highlightedRow != nil && highlightedRow != r)
            for c in 0..<cols {
                guard c < alphabet.count else { break }
                let label = "\(alphabet[r])\(alphabet[c])"

                // Cell centre in NS coords: row 0 is the TOP, so flip via height.
                let cx = (CGFloat(c) + 0.5) * cellW
                let cy = h - (CGFloat(r) + 0.5) * cellH

                drawLabel(label, centre: NSPoint(x: cx, y: cy), font: font, dimmed: dimmed)
            }
        }
    }

    /// Pale neon (fluorescent) yellow used to flood-fill the hover cell.
    private static let hoverFill = NSColor(srgbRed: 0.85, green: 1.0, blue: 0.0, alpha: 0.28)
    /// Orange label pill.
    private static let pillFill = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)

    private func drawLabel(_ text: String, centre: NSPoint, font: NSFont, dimmed: Bool) {
        // Black text on an orange pill.
        let textColor = NSColor.black.withAlphaComponent(dimmed ? 0.30 : 1.0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attr.size()

        let padX: CGFloat = 5
        let padY: CGFloat = 2
        let pill = NSRect(
            x: centre.x - textSize.width / 2 - padX,
            y: centre.y - textSize.height / 2 - padY,
            width: textSize.width + padX * 2,
            height: textSize.height + padY * 2
        )
        let pillPath = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
        Self.pillFill.withAlphaComponent(dimmed ? 0.22 : 0.92).setFill()
        pillPath.fill()
        // Darker border to define the pill on bright backgrounds.
        NSColor(srgbRed: 0.45, green: 0.20, blue: 0.0, alpha: dimmed ? 0.25 : 0.85).setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()

        attr.draw(at: NSPoint(x: centre.x - textSize.width / 2,
                              y: centre.y - textSize.height / 2))
    }
}
