import AppKit

/// Shortcuts that switch layouts.
///
/// ⌃⌥⌘1–9 pick the layout in that place on the display you're using (each display has its own
/// list). A layout can instead have its own shortcut, typed in the panel, which picks it from
/// anywhere, or none at all. Those choices are saved per layout, so a layout keeps them when
/// layouts.json is reordered.
final class LayoutShortcuts {
    private enum Override: Equatable {
        case custom(HotKeys.Shortcut)
        case cleared
    }

    private let store: LayoutStore
    private let commands: Commands
    private var registered: [UInt32] = []
    private var registeredFor: [String] = []
    /// Places (1–9) and layouts whose shortcut another app already owns.
    private var takenSlots: Set<Int> = []
    private var takenLayouts: Set<String> = []

    private let defaultsKey = "layoutShortcuts"

    init(store: LayoutStore, commands: Commands) {
        self.store = store
        self.commands = commands
    }

    /// The layout's shortcut on this display: its own, or ⌃⌥⌘ and its place in the list.
    func shortcut(for layout: Layout, on screen: NSScreen) -> HotKeys.Shortcut? {
        switch override(for: layout.id) {
        case .custom(let shortcut): return shortcut
        case .cleared: return nil
        case nil:
            guard let slot = slot(of: layout, on: screen) else { return nil }
            let keys = HotKeys.Shortcut.layout(slot)
            return customShortcuts.values.contains(keys) ? nil : keys // another layout has these keys
        }
    }

    /// Whether another app owns the layout's shortcut, so it doesn't work.
    func isTaken(_ layout: Layout, on screen: NSScreen) -> Bool {
        switch override(for: layout.id) {
        case .custom: return takenLayouts.contains(layout.id)
        case .cleared: return false
        case nil: return slot(of: layout, on: screen).map(takenSlots.contains) ?? false
        }
    }

    /// `nil` clears it. Typing a layout's own ⌃⌥⌘ place gives it back its default; a shortcut
    /// another layout had is taken from it.
    func set(_ shortcut: HotKeys.Shortcut?, for layout: Layout, on screen: NSScreen) {
        var all = saved
        if let shortcut {
            for (id, keys) in customShortcuts where id != layout.id && keys == shortcut {
                all[id] = ["key": -1]
            }
            if let slot = slot(of: layout, on: screen), shortcut == .layout(slot) {
                all[layout.id] = nil
            } else {
                all[layout.id] = ["key": shortcut.keyCode, "mods": shortcut.modifiers.rawValue, "char": shortcut.keyEquivalent]
            }
        } else {
            all[layout.id] = ["key": -1]
        }
        UserDefaults.standard.set(all, forKey: defaultsKey)
        register()
    }

    /// Re-registers when layouts are added or removed.
    func layoutsChanged() {
        if store.layouts.map(\.id) != registeredFor { register() }
    }

    func register() {
        registered.forEach(HotKeys.shared.unregister)
        registered = []
        takenSlots = []
        takenLayouts = []
        registeredFor = store.layouts.map(\.id)

        let customs = customShortcuts
        for (id, shortcut) in customs {
            guard let layout = store.layouts.first(where: { $0.id == id }) else { continue }
            if let hotKey = HotKeys.shared.register(shortcut, reportFailure: false, action: { [weak self] in self?.pick(layout.id) }) {
                registered.append(hotKey)
            } else {
                takenLayouts.insert(id)
                Log.debug("layout shortcut \(shortcut.display) for \(layout.name) is taken")
            }
        }
        // One per place, up to the longest list any display could have.
        for slot in (1...9).prefix(store.layouts.count) where !customs.values.contains(.layout(slot)) {
            if let hotKey = HotKeys.shared.register(.layout(slot), reportFailure: false, action: { [weak self] in self?.pick(slot: slot) }) {
                registered.append(hotKey)
            } else {
                takenSlots.insert(slot)
                Log.debug("layout shortcut \(HotKeys.Shortcut.layout(slot).display) is taken")
            }
        }
    }

    // MARK: - Firing

    /// ⌃⌥⌘N: the Nth layout on the display you're using, unless that layout has its own shortcut.
    private func pick(slot: Int) {
        guard let screen = commands.currentScreen else { return }
        let available = store.layouts(for: screen)
        guard available.indices.contains(slot - 1) else { return NSSound.beep() }
        let layout = available[slot - 1]
        guard override(for: layout.id) == nil else { return NSSound.beep() }
        commands.select(layout, on: screen)
    }

    /// A layout's own shortcut: on its display, or the one you're using if it's on every display.
    private func pick(_ id: String) {
        guard let layout = store.layouts.first(where: { $0.id == id }) else { return }
        let screen = layout.display.flatMap { display in NSScreen.screens.first { $0.settingsKey == display } }
            ?? commands.currentScreen
        guard let screen, layout.belongs(on: screen) else { return NSSound.beep() }
        commands.select(layout, on: screen)
    }

    // MARK: - Saved choices

    private func slot(of layout: Layout, on screen: NSScreen) -> Int? {
        guard let index = store.layouts(for: screen).firstIndex(where: { $0.id == layout.id }), index < 9 else { return nil }
        return index + 1
    }

    private func override(for id: String) -> Override? {
        guard let entry = saved[id] else { return nil }
        guard let keyCode = entry["key"] as? Int, keyCode >= 0, let modifiers = entry["mods"] as? UInt else { return .cleared }
        return .custom(HotKeys.Shortcut(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers),
                                        keyEquivalent: entry["char"] as? String ?? ""))
    }

    /// Layouts' own shortcuts, by layout ID.
    private var customShortcuts: [String: HotKeys.Shortcut] {
        saved.keys.reduce(into: [:]) { result, id in
            if case .custom(let shortcut) = override(for: id) { result[id] = shortcut }
        }
    }

    private var saved: [String: [String: Any]] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:]
    }
}
