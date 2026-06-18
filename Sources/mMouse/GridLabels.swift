import Foundation

/// A grid cell address. Both indices are 0-based; row 0 is the TOP row, col 0
/// the LEFT column — matching GridOverlay's drawing and EventTapManager's
/// cell math.
struct GridCell: Hashable {
    let row: Int
    let col: Int
}

/// Shared labelling helpers — the single source of truth that keeps the
/// overlay's drawing and the event tap's key matching in agreement about what
/// each cell is called.
enum GridLabels {
    /// Uppercase A–Z used for default row/column codes (26 max per axis).
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// Letter (A–Z, any case) → 0-based index, or nil for non-letters.
    static func letterIndex(_ ch: Character) -> Int? {
        guard let upper = ch.uppercased().first else { return nil }
        return alphabet.firstIndex(of: upper)
    }

    /// Resolve a two-letter default cell code like "FA" (row F, col A) into
    /// indices. Returns nil unless it is exactly two letters.
    static func cell(forCode code: String) -> GridCell? {
        let chars = Array(code)
        guard chars.count == 2,
              let r = letterIndex(chars[0]),
              let c = letterIndex(chars[1]) else { return nil }
        return GridCell(row: r, col: c)
    }

    /// Build the custom-label map for a `rows`×`cols` grid. Entries whose code
    /// is malformed, out of range for this grid, or whose label is empty are
    /// skipped; later entries win on a duplicate cell. Labels are uppercased so
    /// display and typed-key matching use one canonical form.
    static func resolveCustom(_ labels: [GridCustomLabel], rows: Int, cols: Int) -> [GridCell: String] {
        var map = [GridCell: String]()
        for entry in labels {
            let label = entry.label.uppercased()
            guard !label.isEmpty,
                  let cell = cell(forCode: entry.cell),
                  cell.row < rows, cell.col < cols else { continue }
            map[cell] = label
        }
        return map
    }
}
