import Foundation

/// What a sealed table needs for drawing: styled cell text, borders, margins and widths.
public struct Table {
    /// A width of 0 means the border is switched off.
    public struct Border { public let width: Double; public let color: String? }

    public struct Cell {
        public let text: NSAttributedString
        public let span: Int
        public let borders: [Border?]   // top, left, bottom, right
        public let margins: [Double]    // top, left, bottom, right, in points
    }

    public let rows: [[Cell]]
    public let minHeights: [Double]
    public let columns: [Double]        // points; empty when the table has no grid
    public let percent: Double?         // share of the text width, when the table is sized that way
    public let align: String?

    public var plainRows: [[String]] { rows.map { $0.map(\.text.string) } }
}

let tableSides = ["top", "left", "bottom", "right"]

/// Children named by side, with start and end read as left and right.
func sides<T>(_ x: XDoc, _ n: Int32, _ value: (Int32) -> T) -> [String: T] {
    var out: [String: T] = [:]
    for c in x.children(n) {
        let side = String(x.name(c).dropFirst(2))
        out[side == "start" ? "left" : side == "end" ? "right" : side] = value(c)
    }
    return out
}

func parseBorders(_ x: XDoc, _ n: Int32) -> [String: Table.Border] {
    sides(x, n) { c in
        let off = ["nil", "none"].contains(x.attr(c, "w:val") ?? "none")
        // w:sz is in eighths of a point.
        return Table.Border(width: off ? 0 : max(0.25, (x.attr(c, "w:sz").flatMap(Double.init) ?? 4) / 8), color: x.attr(c, "w:color"))
    }
}

func parseMargins(_ x: XDoc, _ n: Int32) -> [String: Double] {
    sides(x, n) { twipsToPt(x.attr($0, "w:w")) ?? 0 }
}
