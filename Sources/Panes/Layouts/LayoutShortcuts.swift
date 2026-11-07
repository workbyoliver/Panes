import AppKit

/// Shortcuts that switch layouts. Each layout gets ⌃⌥⌘ and its place in the panel's grid
/// (⌃⌥⌘1 for the first) unless you've typed another in the panel; you can also clear one.
/// Saved per layout, so a layout keeps its shortcut when layouts.json is reordered.
final class LayoutShortcuts {
    private let store: LayoutStore
    private let commands: Commands
    private var registered: [UInt32] = []
    private var registeredFor: [String] = []
    /// Layouts whose shortcut another app already owns.
    private(set) var taken: Set<String> = []

    private let defaultsKey = "layoutShortcuts"

    init(store: LayoutStore, commands: Commands) {
        self.store = store
        self.commands = commands
    }

    func shortcut(for layout: Layout) -> HotKeys.Shortcut? {
        if let saved = saved[layout.id] {
            guard let keyCode = saved["key"] as? Int, keyCode >= 0,
                  let modifiers = saved["mods"] as? UInt else { return nil } // cleared
            return HotKeys.Shortcut(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers),
                                    keyEquivalent: saved["char"] as? String ?? "")
        }
        guard let index = store.layouts.firstIndex(of: layout), index < 9 else { return nil }
        return .layout(index + 1)
    }

    /// `nil` clears it. A shortcut belongs to one layout, so any other layout using it loses it.
    func set(_ shortcut: HotKeys.Shortcut?, for layout: Layout) {
        var all = saved
        if let shortcut {
            for other in store.layouts where other.id != layout.id && self.shortcut(for: other) == shortcut {
                all[other.id] = ["key": -1]
            }
            all[layout.id] = ["key": shortcut.keyCode, "mods": shortcut.modifiers.rawValue, "char": shortcut.keyEquivalent]
        } else {
            all[layout.id] = ["key": -1]
        }
        UserDefaults.standard.set(all, forKey: defaultsKey)
        register()
    }

    /// Re-registers when the list of layouts changes (positions decide the defaults).
    func layoutsChanged() {
        if store.layouts.map(\.id) != registeredFor { register() }
    }

    func register() {
        registered.forEach(HotKeys.shared.unregister)
        registered = []
        taken = []
        registeredFor = store.layouts.map(\.id)
        for layout in store.layouts {
            guard let shortcut = shortcut(for: layout) else { continue }
            let id = layout.id
            if let hotKey = HotKeys.shared.register(shortcut, reportFailure: false, action: { [commands] in commands.selectLayout(id: id) }) {
                registered.append(hotKey)
            } else {
                taken.insert(id)
                Log.debug("layout shortcut \(shortcut.display) for \(layout.name) is taken")
            }
        }
    }

    private var saved: [String: [String: Any]] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
    }
}
