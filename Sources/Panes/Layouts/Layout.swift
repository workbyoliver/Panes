import AppKit

/// A zone as fractions of the display's usable area, from its top-left corner.
struct Zone: Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var unit: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// A plain-language name from the zone's position, e.g. "Top Left" or "Centre".
    var name: String {
        let column = x + w / 2 < 0.4 ? "Left" : x + w / 2 > 0.6 ? "Right" : nil
        let row = h > 0.75 ? nil : y + h / 2 < 0.4 ? "Top" : y + h / 2 > 0.6 ? "Bottom" : nil
        switch (row, column) {
        case let (row?, column?): return "\(row) \(column)"
        case let (row?, nil): return row
        case let (nil, column?): return column
        case (nil, nil): return "Centre"
        }
    }
}

/// Zones in layouts.json read as numbers or as fractions written like "1/3".
extension Zone: Decodable {
    private enum CodingKeys: String, CodingKey { case x, y, w, h }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try Self.fraction(c, .x)
        y = try Self.fraction(c, .y)
        w = try Self.fraction(c, .w)
        h = try Self.fraction(c, .h)
    }

    private static func fraction(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Double {
        if let number = try? c.decode(Double.self, forKey: key) { return number }
        let text = try c.decode(String.self, forKey: key)
        let parts = text.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, parts[1] != 0 { return parts[0] / parts[1] }
        if parts.count == 1 { return parts[0] }
        throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Expected a number or a fraction like \"1/3\", got \"\(text)\"")
    }

    /// For the hand-editable layouts file: "1/3" rather than 0.33333333333333331.
    static func jsonValue(_ value: Double) -> String {
        if value == 0 || value == 1 { return value == 0 ? "0" : "1" }
        for denominator in 2...48 { // the editor's finer grid has 24ths and 16ths
            let numerator = (value * Double(denominator)).rounded()
            if abs(numerator / Double(denominator) - value) < 1e-9 { return "\"\(Int(numerator))/\(denominator)\"" }
        }
        return "\(value)"
    }
}

struct Layout: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    /// In reading order: their position here is the zone's number (⌃⌥1, ⌃⌥2…).
    var zones: [Zone]
    /// The display it was drawn for (`NSScreen.settingsKey`); nil means every display.
    var display: String? = nil
    /// That display's name, so layouts.json reads well. Not used to match.
    var displayName: String? = nil

    func belongs(on screen: NSScreen) -> Bool {
        display == nil || display == screen.settingsKey
    }
}

/// Turns zones into window frames on one display, with even gaps: `gap` between
/// neighbouring windows and between windows and the screen's edges.
struct ZoneGeometry {
    let area: CGRect
    let gap: CGFloat

    init(screen: NSScreen, gap: CGFloat) {
        var area = screen.visibleRect
        let inset = StageManager.leftInset
        area.origin.x += inset
        area.size.width -= inset
        self.area = area
        self.gap = gap
    }

    func frame(for unit: CGRect) -> CGRect {
        let edge = 0.001
        // Round each edge (not the size), so neighbouring zones share exact boundaries.
        var minX = (area.minX + unit.minX * area.width).rounded()
        var maxX = (area.minX + unit.maxX * area.width).rounded()
        var minY = (area.minY + unit.minY * area.height).rounded()
        var maxY = (area.minY + unit.maxY * area.height).rounded()
        let half = (gap / 2).rounded(.down)
        minX += unit.minX < edge ? gap : half
        maxX -= unit.maxX > 1 - edge ? gap : gap - half
        minY += unit.minY < edge ? gap : half
        maxY -= unit.maxY > 1 - edge ? gap : gap - half
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    var fill: CGRect { frame(for: CGRect(x: 0, y: 0, width: 1, height: 1)) }

    func frames(_ layout: Layout) -> [CGRect] { layout.zones.map { frame(for: $0.unit) } }

    /// The zone (or the whole screen) a window with this frame is sitting in, if any.
    func placement(of frame: CGRect, in layout: Layout) -> CGRect? {
        (frames(layout) + [fill]).first { $0.isClose(to: frame, tolerance: 3) }
    }

    /// The frame covering a run of zones (a span), e.g. two neighbouring thirds.
    func frame(spanning indices: some Sequence<Int>, in layout: Layout) -> CGRect {
        let unit = indices.map { layout.zones[$0].unit }.reduce(CGRect.null) { $0.union($1) }
        return frame(for: unit)
    }

    /// The zone under a point; in a gap, the nearest one. Overlapping zones prefer the smallest.
    func zoneIndex(at point: CGPoint, in layout: Layout) -> Int? {
        let frames = frames(layout)
        let hits = frames.indices.filter { frames[$0].insetBy(dx: -gap / 2 - 0.5, dy: -gap / 2 - 0.5).contains(point) }
        if let smallest = hits.min(by: { frames[$0].area < frames[$1].area }) { return smallest }
        return frames.indices.min { frames[$0].distance(to: point) < frames[$1].distance(to: point) }
    }

    /// The zones a span's unit rect covers (for highlighting and for "grow").
    static func indices(of layout: Layout, within unit: CGRect) -> [Int] {
        let slack = unit.insetBy(dx: -0.001, dy: -0.001)
        return layout.zones.indices.filter { slack.contains(layout.zones[$0].unit) }
    }
}

extension Layout {
    /// The default order (Restore Defaults puts them back like this).
    static let builtIn: [Layout] = [
        Layout(id: "halves", name: "Halves", zones: columns([1, 1])),
        Layout(id: "thirds", name: "Thirds", zones: columns([1, 1, 1])),
        Layout(id: "four-columns", name: "Four Columns", zones: columns([1, 1, 1, 1])),
        Layout(id: "quarters", name: "Quarters", zones: grid(columns: 2, rows: 2)),
        Layout(id: "focus", name: "Focus", zones: columns([1, 2, 1])),
        Layout(id: "main-side", name: "Main + Side", zones: [
            Zone(x: 0, y: 0, w: 2.0 / 3, h: 1),
            Zone(x: 2.0 / 3, y: 0, w: 1.0 / 3, h: 0.5),
            Zone(x: 2.0 / 3, y: 0.5, w: 1.0 / 3, h: 0.5),
        ]),
        // Numbered by column: 1–2 left, 3 the main panel, 4–5 right.
        Layout(id: "main-sides", name: "Main + Sides", zones: [
            Zone(x: 0, y: 0, w: 0.25, h: 0.5),
            Zone(x: 0, y: 0.5, w: 0.25, h: 0.5),
            Zone(x: 0.25, y: 0, w: 0.5, h: 1),
            Zone(x: 0.75, y: 0, w: 0.25, h: 0.5),
            Zone(x: 0.75, y: 0.5, w: 0.25, h: 0.5),
        ]),
    ]

    /// Full-height columns with relative widths, e.g. [1, 2, 1] = ¼ · ½ · ¼.
    static func columns(_ weights: [Double]) -> [Zone] {
        let total = weights.reduce(0, +)
        var x = 0.0
        return weights.map { weight in
            defer { x += weight / total }
            return Zone(x: x, y: 0, w: weight / total, h: 1)
        }
    }

    static func grid(columns: Int, rows: Int) -> [Zone] {
        (0..<rows).flatMap { row in
            (0..<columns).map { column in
                Zone(x: Double(column) / Double(columns), y: Double(row) / Double(rows),
                     w: 1 / Double(columns), h: 1 / Double(rows))
            }
        }
    }
}
