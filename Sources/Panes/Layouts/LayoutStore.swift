import AppKit

/// The layouts (from ~/Library/Application Support/Panes/layouts.json, written with the
/// built-ins on first launch) and which one is active on each display. A layout drawn in the
/// editor belongs to one display; the rest are on every display.
final class LayoutStore {
    private(set) var layouts: [Layout] = Layout.builtIn
    private(set) var loadError: String?
    /// Called when the active layout or the list of layouts changes.
    var onChange: (() -> Void)?
    /// Called when you pick a layout (not when Panes brings back a stage's layout).
    var onPick: ((Layout, NSScreen) -> Void)?

    static let defaultURL: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Panes", isDirectory: true)
        return folder.appendingPathComponent("layouts.json")
    }()

    let fileURL: URL
    private var loadedModificationDate: Date?
    private let activeKey = "activeLayouts"

    init(fileURL: URL = LayoutStore.defaultURL) {
        self.fileURL = fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) { write(Layout.builtIn) }
        reloadIfChanged()
    }

    /// Cheap enough to call before every use (one stat), so edits to the file apply at once.
    func reloadIfChanged() {
        let date = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard date != loadedModificationDate else { return }
        loadedModificationDate = date
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(LayoutFile.self, from: data)
            let valid = file.layouts.filter { !$0.zones.isEmpty }
            guard !valid.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            layouts = valid
            loadError = nil
        } catch {
            // Keep the last good layouts, and say what's wrong in the menu.
            loadError = (error as? DecodingError).map(Self.describe) ?? error.localizedDescription
        }
        onChange?()
    }

    /// The layouts offered on a display: those on every display, plus its own, in file order.
    func layouts(for screen: NSScreen) -> [Layout] {
        reloadIfChanged()
        let mine = layouts.filter { $0.belongs(on: screen) }
        return mine.isEmpty ? [Layout.builtIn[0]] : mine
    }

    /// Adds a layout, or replaces the one with the same ID, and writes layouts.json.
    func save(_ layout: Layout) {
        reloadIfChanged()
        var all = layouts
        if let index = all.firstIndex(where: { $0.id == layout.id }) {
            all[index] = layout
        } else {
            all.append(layout)
        }
        write(all)
        reloadIfChanged()
    }

    /// Puts these layouts in this order (a display's list, reordered in the panel). Layouts not
    /// listed keep their places in the file.
    func reorder(_ ids: [String]) {
        reloadIfChanged()
        let moving = Set(ids)
        var queue = ids.compactMap { id in layouts.first { $0.id == id } }[...]
        let reordered = layouts.map { layout in moving.contains(layout.id) && !queue.isEmpty ? queue.removeFirst() : layout }
        guard reordered != layouts else { return }
        write(reordered)
        reloadIfChanged()
    }

    /// Whether the built-in layouts differ from how they ship: one deleted, redrawn, renamed
    /// or moved, or one added in an update.
    var defaultsDiffer: Bool {
        let builtInIDs = Set(Layout.builtIn.map(\.id))
        return layouts.filter { builtInIDs.contains($0.id) } != Layout.builtIn
    }

    /// The built-in layouts as they ship, first and in their usual order: deleted ones come
    /// back, redrawn ones are reset. Layouts you drew stay, after them, except exact copies of
    /// a built-in one (such as a hand-drawn four columns), which merge into it.
    func restoreDefaults() {
        reloadIfChanged()
        let builtInIDs = Set(Layout.builtIn.map(\.id))
        let builtInZones = Set(Layout.builtIn.map(\.zones))
        write(Layout.builtIn + layouts.filter { !builtInIDs.contains($0.id) && !builtInZones.contains($0.zones) })
        reloadIfChanged()
    }

    /// Whether deleting would leave a connected display with no layouts of its own choosing.
    func canDelete(_ layout: Layout) -> Bool {
        let rest = layouts.filter { $0.id != layout.id }
        return NSScreen.screens.allSatisfy { screen in rest.contains { $0.belongs(on: screen) } }
    }

    func delete(_ layout: Layout) {
        reloadIfChanged()
        guard canDelete(layout) else { return NSSound.beep() }
        write(layouts.filter { $0.id != layout.id })
        reloadIfChanged()
    }

    /// Rewrites layouts.json from the layouts in use: the last version that read correctly.
    /// (For a file broken by hand; Panes itself always writes it whole.)
    func repairFile() {
        write(layouts)
        reloadIfChanged()
    }

    func activeLayout(for screen: NSScreen) -> Layout {
        let available = layouts(for: screen)
        let id = (UserDefaults.standard.dictionary(forKey: activeKey) as? [String: String])?[screen.settingsKey]
        return available.first { $0.id == id } ?? available[0]
    }

    /// `picked` is false when Panes chose it (a stage's remembered layout coming back).
    func setActive(_ layout: Layout, for screen: NSScreen, picked: Bool = true) {
        var map = UserDefaults.standard.dictionary(forKey: activeKey) as? [String: String] ?? [:]
        map[screen.settingsKey] = layout.id
        UserDefaults.standard.set(map, forKey: activeKey)
        onChange?()
        if picked { onPick?(layout, screen) }
    }

    func cycleLayout(on screen: NSScreen) -> Layout {
        let available = layouts(for: screen)
        let current = activeLayout(for: screen)
        let index = available.firstIndex(of: current) ?? 0
        let next = available[(index + 1) % available.count]
        setActive(next, for: screen)
        return next
    }

    /// Written by hand rather than with JSONEncoder: one zone per line, fractions as "1/3".
    private func write(_ layouts: [Layout]) {
        let help = """
            Each layout is a list of zones. A zone's x, y, w (width) and h (height) are fractions of \
            the screen's usable area, measured from its top-left corner: numbers like 0.25 or text \
            like "1/3". Zones are numbered in the order listed (⌃⌥1, ⌃⌥2…). A layout with a \
            "display" (added by the layout editor) is only offered on that display. Save the file \
            and Panes picks up the change.
            """
        let entries = layouts.map { layout in
            let zones = layout.zones.map { z in
                "        { \"x\": \(Zone.jsonValue(z.x)), \"y\": \(Zone.jsonValue(z.y)), \"w\": \(Zone.jsonValue(z.w)), \"h\": \(Zone.jsonValue(z.h)) }"
            }.joined(separator: ",\n")
            var fields = ["      \"id\": \(Self.json(layout.id))", "      \"name\": \(Self.json(layout.name))"]
            if let display = layout.display { fields.append("      \"display\": \(Self.json(display))") }
            if let name = layout.displayName { fields.append("      \"displayName\": \(Self.json(name))") }
            fields.append("      \"zones\": [\n\(zones)\n      ]")
            return "    {\n" + fields.joined(separator: ",\n") + "\n    }"
        }.joined(separator: ",\n")
        let text = "{\n  \"help\": \(Self.json(help)),\n  \"layouts\": [\n\(entries)\n  ]\n}\n"
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// A JSON string literal, escaped.
    private static func json(_ string: String) -> String {
        (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context),
             .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return "layouts.json\(path): \(context.debugDescription)"
        @unknown default:
            return "layouts.json can't be read"
        }
    }
}

private struct LayoutFile: Decodable {
    var layouts: [Layout]
}

/// Small preferences, kept in UserDefaults.
enum Settings {
    static var gap: CGFloat {
        get { UserDefaults.standard.object(forKey: "gap") as? CGFloat ?? 8 }
        set { UserDefaults.standard.set(newValue, forKey: "gap") }
    }

    static var leaveRoomForStageManager: Bool {
        get { UserDefaults.standard.object(forKey: "leaveRoomForStageManager") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "leaveRoomForStageManager") }
    }

    static var rememberLayoutPerStage: Bool {
        get { UserDefaults.standard.object(forKey: "rememberLayoutPerStage") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rememberLayoutPerStage") }
    }

    static var snapAtEdges: Bool {
        get { UserDefaults.standard.object(forKey: "snapAtEdges") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "snapAtEdges") }
    }
}
