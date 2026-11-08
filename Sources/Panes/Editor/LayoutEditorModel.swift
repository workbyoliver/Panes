import AppKit
import ImageIO
import Observation

/// One display as the layout editor shows it.
struct EditorDisplay: Identifiable {
    /// `NSScreen.settingsKey`.
    let id: String
    let name: String
    /// The whole display, and the part windows can use (no menu bar or Dock), in top-left
    /// coordinates across all displays.
    let frame: CGRect
    let usable: CGRect
    /// How much the Stage Manager strip takes off the left when zones leave room for it.
    let stripInset: CGFloat
    /// The desktop picture, shrunk for drawing, when macOS gives a real one Panes can read.
    let wallpaper: CGImage?

    init(id: String, name: String, frame: CGRect, usable: CGRect, stripInset: CGFloat = 0, wallpaper: CGImage? = nil) {
        self.id = id
        self.name = name
        self.frame = frame
        self.usable = usable
        self.stripInset = stripInset
        self.wallpaper = wallpaper
    }

    init(screen: NSScreen) {
        self.init(id: screen.settingsKey, name: screen.localizedName, frame: screen.rect, usable: screen.visibleRect,
                  stripInset: StageManager.stripShowing ? StageManager.stripWidth : 0,
                  wallpaper: Self.wallpaper(for: screen))
    }

    /// macOS reports its stock picture (DefaultDesktop.heic) for wallpapers that aren't a single
    /// image: solid colours, Aerials, dynamic ones. Only a real picture that can be read is
    /// used (a sandboxed build can't read most); otherwise the editor draws its own backdrop.
    private static func wallpaper(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              !url.path.hasPrefix("/System/Library/CoreServices/DefaultDesktop"),
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return thumbnail(of: url)
    }

    /// The part zones cover.
    func area(leavingRoom: Bool) -> CGRect {
        guard leavingRoom, stripInset > 0 else { return usable }
        return CGRect(x: usable.minX + stripInset, y: usable.minY, width: usable.width - stripInset, height: usable.height)
    }

    private static func thumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The layout editor: drag across a display's grid to draw zones, numbered in the order you
/// draw them. Zones can't overlap.
@Observable
final class LayoutEditorModel {
    let displays: [EditorDisplay]
    /// The layout being changed, or nil for a new one.
    let editing: Layout?
    private(set) var displayID: String
    var name: String
    private(set) var zones: [Zone]
    var finerGrid = false
    /// The zone being dragged out, and whether it fits (it mustn't overlap another).
    private(set) var drawing: Zone?
    private(set) var drawingFits = true
    /// The same setting as the panel's: zones start right of the Stage Manager strip.
    var leaveRoomForStageManager = Settings.leaveRoomForStageManager {
        didSet { Settings.leaveRoomForStageManager = leaveRoomForStageManager }
    }
    /// Displays that already have the most layouts a display can have.
    let fullDisplays: Set<String>
    static let maxLayoutsPerDisplay = 9

    struct Cell: Equatable {
        var column: Int
        var row: Int
    }

    init(displays: [EditorDisplay], startOn displayID: String, editing: Layout?, name: String, fullDisplays: Set<String> = []) {
        self.displays = displays
        self.editing = editing
        self.fullDisplays = fullDisplays
        self.displayID = displays.contains { $0.id == displayID } ? displayID : displays.first?.id ?? displayID
        self.name = editing?.name ?? name
        zones = editing?.zones ?? []
    }

    var display: EditorDisplay? { displays.first { $0.id == displayID } ?? displays.first }

    /// A new layout can go on any display; an edited one stays where it's offered.
    var canChangeDisplay: Bool { editing == nil }

    var canSave: Bool { !trimmedName.isEmpty && !zones.isEmpty && !isDisplayFull }

    /// A new layout can't go on a display that already has nine.
    var isDisplayFull: Bool { editing == nil && display.map { fullDisplays.contains($0.id) } ?? false }

    /// Whether the Stage Manager switch means anything here.
    var showsStageManagerSwitch: Bool { displays.contains { $0.stripInset > 0 } }

    func area(of display: EditorDisplay) -> CGRect {
        display.area(leavingRoom: leaveRoomForStageManager)
    }

    var grid: (columns: Int, rows: Int) {
        Self.grid(for: display.map { area(of: $0).size } ?? CGSize(width: 16, height: 9), finer: finerGrid)
    }

    /// Cells about square, and the counts divide into halves, thirds and quarters: 12 along
    /// the long side (24 past 32:9-ish), 6 along the short side (8 for squarer screens).
    static func grid(for size: CGSize, finer: Bool) -> (columns: Int, rows: Int) {
        let long = max(size.width, size.height), short = max(min(size.width, size.height), 1)
        let ratio = long / short
        let longCells = ratio > 2.7 ? 24 : 12
        let shortCells = ratio < 1.5 ? 8 : 6
        var cells = size.width >= size.height ? (columns: longCells, rows: shortCells) : (columns: shortCells, rows: longCells)
        if finer { cells = (cells.columns * 2, cells.rows * 2) }
        return cells
    }

    func selectDisplay(_ id: String) {
        guard canChangeDisplay, displays.contains(where: { $0.id == id }) else { return }
        displayID = id
    }

    // MARK: - Drawing (points are in the drawing area's own coordinates, top-left origin)

    /// A drag in progress, from where it started to where the pointer is now.
    func drag(from start: CGPoint, to point: CGPoint, in size: CGSize) {
        let zone = zone(from: cell(at: start, in: size), to: cell(at: point, in: size))
        guard zone != drawing else { return }
        drawing = zone
        drawingFits = !overlaps(zone)
    }

    /// Adds the zone if it fits. Returns whether it was added.
    @discardableResult
    func endDrag() -> Bool {
        defer {
            drawing = nil
            drawingFits = true
        }
        guard let zone = drawing, drawingFits else { return false }
        zones.append(zone)
        return true
    }

    func undo() {
        guard !zones.isEmpty else { return NSSound.beep() }
        zones.removeLast()
    }

    func reset() {
        zones = []
    }

    func overlaps(_ zone: Zone) -> Bool {
        zones.contains { $0.unit.intersection(zone.unit).area > 1e-9 }
    }

    private func cell(at point: CGPoint, in size: CGSize) -> Cell {
        let (columns, rows) = grid
        let column = Int((point.x / max(size.width, 1) * CGFloat(columns)).rounded(.down))
        let row = Int((point.y / max(size.height, 1) * CGFloat(rows)).rounded(.down))
        return Cell(column: min(max(column, 0), columns - 1), row: min(max(row, 0), rows - 1))
    }

    /// The whole cells from one corner cell to the other.
    private func zone(from a: Cell, to b: Cell) -> Zone {
        let (columns, rows) = grid
        let left = min(a.column, b.column), right = max(a.column, b.column)
        let top = min(a.row, b.row), bottom = max(a.row, b.row)
        return Zone(x: Double(left) / Double(columns), y: Double(top) / Double(rows),
                    w: Double(right - left + 1) / Double(columns), h: Double(bottom - top + 1) / Double(rows))
    }

    // MARK: - Saving

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The layout to save. An edited layout keeps its ID and the displays it's offered on;
    /// a new one belongs to the display it was drawn on.
    func layout() -> Layout {
        if var layout = editing {
            layout.name = trimmedName
            layout.zones = zones
            return layout
        }
        return Layout(id: "layout-" + UUID().uuidString.prefix(8).lowercased(), name: trimmedName, zones: zones,
                      display: display?.id, displayName: display?.name)
    }

    /// "Custom", or "Custom 2"… if that's taken.
    static func suggestedName(avoiding names: [String]) -> String {
        var number = 1
        while names.contains(number == 1 ? "Custom" : "Custom \(number)") { number += 1 }
        return number == 1 ? "Custom" : "Custom \(number)"
    }
}
