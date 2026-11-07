import AppKit
import UniformTypeIdentifiers

/// The layouts (from ~/Library/Application Support/Panes/layouts.json, written with the
/// built-ins on first launch) and which one is active on each display.
final class LayoutStore {
    private(set) var layouts: [Layout] = Layout.builtIn
    private(set) var loadError: String?
    /// Called when the active layout or the list of layouts changes.
    var onChange: (() -> Void)?
    /// Called when you pick a layout (not when Panes brings back a stage's layout).
    var onPick: ((Layout, NSScreen) -> Void)?

    let fileURL: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Panes", isDirectory: true)
        return folder.appendingPathComponent("layouts.json")
    }()

    private var loadedModificationDate: Date?
    private let activeKey = "activeLayouts"

    init() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { writeBuiltIns() }
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

    /// Opens layouts.json in a code editor. Not with the default app for .json files (After
    /// Effects on some Macs), and TextEdit only as a last resort: its smart quotes break JSON.
    func openInEditor() {
        let editors = [
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92" /* Cursor */, "dev.zed.Zed",
            "com.sublimetext.4", "com.barebones.bbedit", "com.panic.Nova", "com.coteditor.CotEditor",
            "com.apple.dt.Xcode",
        ]
        let workspace = NSWorkspace.shared
        guard let editor = editors.lazy.compactMap({ workspace.urlForApplication(withBundleIdentifier: $0) }).first
                ?? workspace.urlForApplication(toOpen: .plainText) else {
            workspace.open(fileURL)
            return
        }
        workspace.open([fileURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    func activeLayout(for screen: NSScreen) -> Layout {
        reloadIfChanged()
        let id = (UserDefaults.standard.dictionary(forKey: activeKey) as? [String: String])?[screen.settingsKey]
        return layouts.first { $0.id == id } ?? layouts[0]
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
        let current = activeLayout(for: screen)
        let index = layouts.firstIndex(of: current) ?? 0
        let next = layouts[(index + 1) % layouts.count]
        setActive(next, for: screen)
        return next
    }

    /// Written by hand rather than with JSONEncoder: one zone per line, fractions as "1/3".
    private func writeBuiltIns() {
        let help = """
            Each layout is a list of zones. A zone's x, y, w (width) and h (height) are fractions of \
            the screen's usable area, measured from its top-left corner: numbers like 0.25 or text \
            like "1/3". Zones are numbered in the order listed (⌃⌥1, ⌃⌥2…). Save the file and \
            Panes picks up the change.
            """
        let helpJSON = (try? JSONSerialization.data(withJSONObject: help, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let layouts = Layout.builtIn.map { layout in
            let zones = layout.zones.map { z in
                "        { \"x\": \(Zone.jsonValue(z.x)), \"y\": \(Zone.jsonValue(z.y)), \"w\": \(Zone.jsonValue(z.w)), \"h\": \(Zone.jsonValue(z.h)) }"
            }.joined(separator: ",\n")
            return """
                    {
                      "id": "\(layout.id)",
                      "name": "\(layout.name)",
                      "zones": [
                \(zones)
                      ]
                    }
                """
        }.joined(separator: ",\n")
        let text = "{\n  \"help\": \(helpJSON),\n  \"layouts\": [\n\(layouts)\n  ]\n}\n"
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            loadError = error.localizedDescription
        }
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
