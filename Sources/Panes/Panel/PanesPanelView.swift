import SwiftUI

/// Sizes shared across the panel. The panel's corner radius (GlassPanel) is the padding plus
/// the zone board's 16 pt radius, so the corners stay concentric.
private enum PanelLayout {
    static let width: CGFloat = 300
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 16
    static var contentWidth: CGFloat { width - padding * 2 }
    /// The icon's sky-to-indigo, washed faintly over the glass.
    static let sky = Color(red: 0.47, green: 0.71, blue: 1.0)
    static let indigo = Color(red: 0.15, green: 0.22, blue: 0.60)
}

/// The panel under the menu bar item: pick a layout from a grid, move the frontmost window
/// into a zone, and change settings with real controls.
struct PanesPanelView: View {
    let model: PanelModel
    /// Reports the content size so the panel stays pinned under the menu bar as it changes.
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.spacing) {
            if !model.warnings.isEmpty {
                WarningList(warnings: model.warnings)
            }
            LayoutGrid(model: model)
            MoveSection(model: model)
            WorkspacesSection(model: model)
            Divider().opacity(0.5)
            SettingsSection(model: model)
            Footer(model: model)
        }
        .padding(PanelLayout.padding)
        .frame(width: PanelLayout.width)
        .background {
            LinearGradient(colors: [PanelLayout.sky, PanelLayout.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.22) // a tint over the panel's glass, which blurs what's behind
        }
        .clipShape(RoundedRectangle(cornerRadius: GlassPanel.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSizeChange)
    }
}

// MARK: - Layouts

/// Every layout as a tile, three across. Click one to make it active (the zones flash up).
private struct LayoutGrid: View {
    let model: PanelModel

    /// Where the dragged tile is drawn, relative to its place in the grid.
    @State private var dragOffset: CGSize = .zero
    /// Where in the tile the drag started, so the tile stays under the pointer.
    @State private var grab: CGSize = .zero

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private static let space = "layoutGrid"
    private static let tileWidth = (PanelLayout.contentWidth - 16) / 3
    private static let columnPitch = tileWidth + 8
    private static let rowPitch: CGFloat = 52 + 6 + 18 + 10 // tile, gap, caption, row spacing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Edit mode swaps contents in place (this row's text, each tile's caption, badges
            // drawn over the tiles) and never changes the panel's size: a resize while open
            // looked broken.
            HStack(spacing: 12) {
                if model.isEditing {
                    Text(editingHint)
                        .font(.caption)
                        .foregroundStyle(model.recordingNote == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    SectionTitle("Layout")
                }
                Spacer(minLength: 8)
                if !model.isEditing {
                    FooterButton(title: "New", symbol: "plus", font: .caption) { model.newLayout() }
                        .disabled(!model.canAddLayout)
                        .help(model.canAddLayout ? "Draw a new layout for this display"
                                                 : "This display has 9 layouts, the most it can have. Delete one to add another.")
                }
                FooterButton(title: model.isEditing ? "Done" : "Edit",
                             symbol: model.isEditing ? "checkmark" : "pencil", font: .caption) {
                    model.toggleEditing()
                }
            }
            .frame(height: 18)
            GlassEffectContainer(spacing: model.isEditing ? 0 : 8) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.layouts) { layout in
                        let isDragged = model.draggingID == layout.id
                        LayoutTile(layout: layout,
                                   isSelected: layout.id == model.active?.id,
                                   shortcut: model.shortcutText[layout.id],
                                   isTaken: model.takenShortcuts.contains(layout.id),
                                   isEditing: model.isEditing,
                                   isRecording: model.recordingID == layout.id,
                                   onTap: { model.tap(layout) },
                                   onShortcut: { model.recordShortcut(layout) })
                            .modifier(Wiggle(isOn: model.isEditing && !isDragged, seed: layout.id.hashValue))
                            .scaleEffect(isDragged ? 1.08 : 1)
                            .offset(isDragged ? dragOffset : .zero)
                            .zIndex(isDragged ? 1 : 0)
                            // The dragged tile jumps to its new place at once (its offset makes
                            // up the difference); the others slide.
                            .transaction { if isDragged { $0.animation = nil } }
                            .highPriorityGesture(reorderGesture(for: layout), including: model.isEditing ? .all : .subviews)
                    }
                }
                .coordinateSpace(.named(Self.space))
            }
            .animation(.smooth(duration: 0.25), value: model.activeID)
            // Delete badges in a layer of their own, laid out like the grid: inside it, each
            // tile's glass is drawn on top of anything attached to the tile.
            .overlay(alignment: .topLeading) {
                if model.isEditing && model.draggingID == nil {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.layouts) { layout in
                            VStack(spacing: 6) {
                                Color.clear
                                    .frame(height: 52)
                                    .overlay(alignment: .topLeading) {
                                        if model.deletable.contains(layout.id) {
                                            DeleteBadge(isArmed: model.pendingDeleteID == layout.id) { model.requestDelete(layout) }
                                                .offset(x: -5, y: -5)
                                        }
                                    }
                                Color.clear.frame(height: 18)
                            }
                            .modifier(Wiggle(isOn: true, seed: layout.id.hashValue))
                        }
                    }
                }
            }
        }
    }

    /// Drag a tile in Edit mode to give it another place; the others make room.
    private func reorderGesture(for layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { drag in
                if model.draggingID == nil {
                    guard let start = model.layouts.firstIndex(where: { $0.id == layout.id }) else { return }
                    let centre = Self.centre(of: start)
                    grab = CGSize(width: drag.startLocation.x - centre.x, height: drag.startLocation.y - centre.y)
                    model.beginReorder(layout)
                }
                // The tile's centre decides which place it's over.
                let tileCentre = CGPoint(x: drag.location.x - grab.width, y: drag.location.y - grab.height)
                withAnimation(.smooth(duration: 0.25)) { model.moveDragged(to: index(at: tileCentre)) }
                if let now = model.layouts.firstIndex(where: { $0.id == layout.id }) {
                    let centre = Self.centre(of: now)
                    dragOffset = CGSize(width: tileCentre.x - centre.x, height: tileCentre.y - centre.y)
                }
            }
            .onEnded { _ in
                withAnimation(.smooth(duration: 0.25)) { dragOffset = .zero }
                model.endReorder()
            }
    }

    private static func centre(of index: Int) -> CGPoint {
        CGPoint(x: CGFloat(index % 3) * columnPitch + tileWidth / 2, y: CGFloat(index / 3) * rowPitch + 38)
    }

    private func index(at point: CGPoint) -> Int {
        let column = min(max(Int((point.x / Self.columnPitch).rounded(.down)), 0), 2)
        let row = max(Int((point.y / Self.rowPitch).rounded(.down)), 0)
        return min(row * 3 + column, model.layouts.count - 1)
    }

    private var editingHint: String {
        if let note = model.recordingNote { return note }
        if model.recordingID != nil { return "Type keys · ⌫ clears · esc cancels" }
        if model.pendingDeleteID != nil { return "Click Delete again to remove it" }
        if model.isRestorePending { return "Click again to restore the defaults" }
        return "Drag to reorder · click to redraw"
    }
}

/// The iOS-style jiggle for tiles in Edit mode: a small, quick rock, out of step from tile to
/// tile. Driven by the clock, so it starts and stops cleanly.
private struct Wiggle: ViewModifier {
    let isOn: Bool
    let seed: Int

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !isOn)) { context in
            let phase = Double(abs(seed) % 1000) / 1000 * 2 * .pi
            let time = context.date.timeIntervalSinceReferenceDate
            content.rotationEffect(.degrees(isOn ? sin(time * 2 * .pi / 0.26 + phase) * 1.5 : 0))
        }
    }
}

/// A layout's zones in a glass tile, with its name below. In Edit mode: its shortcut below
/// (click to change), and a click on the tile opens it in the editor. (The delete badges are
/// drawn over the grid by LayoutGrid.)
private struct LayoutTile: View {
    let layout: Layout
    let isSelected: Bool
    let shortcut: String?
    let isTaken: Bool
    let isEditing: Bool
    let isRecording: Bool
    let onTap: () -> Void
    let onShortcut: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onTap) {
                ZoneShapes(zones: layout.zones, gap: 3, cornerRadius: 3) { _ in
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(0.75))
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(.rect(cornerRadius: 12))
                .glassEffect(isSelected ? .regular.interactive() : .clear.interactive(), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(PressDipStyle())
            .help(isEditing ? "Redraw \(layout.name)" : help)

            Group {
                if isEditing {
                    Button(action: onShortcut) {
                        ShortcutCapsule(text: isRecording ? "Type keys…" : shortcut ?? "None",
                                        isEmpty: shortcut == nil && !isRecording, isTaken: isTaken, isRecording: isRecording)
                    }
                    .buttonStyle(PressDipStyle())
                    .help(isTaken ? "Another app already uses this shortcut. Click to change it." : "Click to change \(layout.name)'s shortcut")
                } else {
                    Button(action: onTap) {
                        Text(layout.name)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 18)
        }
        .opacity(isEditing || isSelected || isHovering ? 1 : 0.6)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(layout.name) layout")
        .accessibilityValue(shortcut ?? "No shortcut")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var help: String {
        guard let shortcut else { return layout.name }
        return isTaken ? "\(layout.name)  \(shortcut): another app already uses this shortcut" : "\(layout.name)  \(shortcut)"
    }
}

/// ⊖ over a tile in Edit mode; once clicked it reads Delete and the next click deletes.
private struct DeleteBadge: View {
    let isArmed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isArmed {
                    Text("Delete")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                } else {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .heavy))
                        .frame(width: 18)
                }
            }
            .frame(height: 18)
            .foregroundStyle(.white)
            .background(Capsule().fill(isArmed ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color(white: 0.45))))
            .contentShape(.capsule)
        }
        .buttonStyle(PressDipStyle())
        .help(isArmed ? "Click again to delete this layout" : "Delete this layout")
        .accessibilityLabel(isArmed ? "Confirm delete" : "Delete")
    }
}

private struct ShortcutCapsule: View {
    let text: String
    let isEmpty: Bool
    let isTaken: Bool
    let isRecording: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(isTaken ? AnyShapeStyle(.orange) : isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(.white.opacity(isRecording ? 0.04 : 0.12)))
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: isRecording ? 1.5 : 0))
    }
}

// MARK: - Moving the window

/// The active layout at the screen's shape: click a zone to move the frontmost window there.
private struct MoveSection: View {
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionTitle("Move Window")
                Spacer(minLength: 8)
                if model.canMoveWindow, let app = model.frontApp {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    let name = model.windowTitle.isEmpty ? app.localizedName ?? "" : model.windowTitle
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(name)
                } else {
                    Text("No window to move").font(.caption).foregroundStyle(.tertiary)
                }
            }

            Group {
                if let layout = model.active {
                    ZoneBoard(layout: layout) { model.moveToZone($0) }
                        .frame(height: (PanelLayout.contentWidth / min(max(model.aspect, 1.6), 2.6)).rounded())
                }
                HStack(spacing: 8) {
                    ActionButton(title: "Fill", symbol: "rectangle.inset.filled", shortcut: .fill) { model.fill() }
                    ActionButton(title: "Centre", symbol: "rectangle.center.inset.filled", shortcut: .centre) { model.centre() }
                    ActionButton(title: "Undo", symbol: "arrow.uturn.backward", shortcut: .undo) { model.undo() }
                    ActionButton(title: model.isTargetPinned ? "Unpin" : "Pin", symbol: model.isTargetPinned ? "pin.slash" : "pin",
                                 shortcut: .pin) { model.togglePin() }
                }
            }
            .disabled(!model.canMoveWindow)
            .opacity(model.canMoveWindow ? 1 : 0.4)
        }
    }
}

struct ZoneBoard: View {
    let layout: Layout
    let onPick: (Int) -> Void

    @State private var hovered: Int?
    @State private var pressed: Int?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let frames = ZoneShapes.frames(for: layout.zones, in: geometry.size, gap: 6)
            let zoneAt = { (point: CGPoint) in frames.firstIndex { $0.contains(point) } }
            ZStack(alignment: .topLeading) {
                ForEach(frames.indices, id: \.self) { index in
                    zoneTile(index)
                        .frame(width: frames[index].width, height: frames[index].height)
                        .padding(.leading, frames[index].minX)
                        .padding(.top, frames[index].minY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            // One hover and click handler for the whole board, picking the zone under the
            // pointer. (Per-zone hover areas overlapped, so the last zone took every hover.)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = isEnabled ? zoneAt(point) : nil
                case .ended: hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in pressed = isEnabled ? zoneAt(drag.startLocation) : nil }
                    .onEnded { drag in
                        // A click: released on the zone it started on.
                        if let index = pressed, zoneAt(drag.location) == index { onPick(index + 1) }
                        pressed = nil
                    }
            )
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .padding(5)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func zoneTile(_ index: Int) -> some View {
        let zone = layout.zones[index]
        let isHovered = hovered == index
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isHovered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(0.1)))
            .overlay {
                Text("\(index + 1)")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(isHovered ? .primary : .secondary)
            }
            .scaleEffect(pressed == index ? 0.95 : 1)
            .help(index < 9 ? "\(zone.name)  \(HotKeys.Shortcut.zone(index + 1).display)" : zone.name)
            .accessibilityElement()
            .accessibilityLabel("Move to \(zone.name)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPick(index + 1) }
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let shortcut: HotKeys.Shortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .contentShape(.capsule)
        }
        .buttonStyle(PressDipStyle())
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("\(title)  \(shortcut.display)")
    }
}

// MARK: - Workspaces

/// Saved stages: Save Stage names the current one; click a name to bring it back. The names
/// scroll sideways, so saving or deleting never changes the panel's size.
private struct WorkspacesSection: View {
    @Bindable var model: PanelModel
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Workspaces")
                Spacer()
                if !model.isNamingWorkspace && !model.isEditing {
                    FooterButton(title: "Save Stage", symbol: "plus", font: .caption) { model.startSavingWorkspace() }
                        .help("Save the windows on this stage, their zones and the layout, under a name")
                }
            }
            .frame(height: 18)
            Group {
                if model.isNamingWorkspace {
                    HStack(spacing: 8) {
                        TextField("Name", text: $model.workspaceName)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)
                            .onSubmit { model.confirmWorkspaceName() }
                        Chip(title: "Save", prominent: true) { model.confirmWorkspaceName() }
                        Chip(title: "Cancel") { model.cancelWorkspaceName() }
                    }
                    .onAppear { isNameFocused = true }
                } else if model.workspaces.isEmpty {
                    Text("Save a stage, then bring it back with a click.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.workspaces) { workspace in
                                workspaceChip(workspace)
                            }
                        }
                    }
                }
            }
            .frame(height: 28)
        }
    }

    @ViewBuilder
    private func workspaceChip(_ workspace: Workspace) -> some View {
        let apps = Array(NSOrderedSet(array: workspace.entries.map(\.appName))).compactMap { $0 as? String }.joined(separator: ", ")
        if model.isEditing {
            let armed = model.pendingDeleteWorkspaceID == workspace.id
            Chip(title: armed ? "Delete \(workspace.name)?" : workspace.name, symbol: "minus.circle.fill", warning: armed) {
                model.requestDeleteWorkspace(workspace)
            }
            .help(armed ? "Click again to delete this workspace" : "Delete this workspace")
        } else {
            Chip(title: workspace.name, symbol: "square.stack.3d.up") { model.restoreWorkspace(workspace) }
                .help("Bring back \(workspace.name): \(apps)")
        }
    }
}

/// A small capsule button (tap, so the first click counts).
private struct Chip: View {
    let title: String
    var symbol: String?
    var prominent = false
    var warning = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.caption2) }
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(warning ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(warning ? AnyShapeStyle(Color.red) : prominent ? AnyShapeStyle(Color.accentColor)
                                   : AnyShapeStyle(.white.opacity(isHovering ? 0.2 : 0.12))))
        .contentShape(.capsule)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    let model: PanelModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("Gaps").fixedSize()
                Picker("Gaps", selection: Binding(get: { model.gap }, set: { model.setGap($0) })) {
                    Text("None").tag(CGFloat(0))
                    Text("Small").tag(CGFloat(8))
                    Text("Large").tag(CGFloat(16))
                    Text("Huge").tag(CGFloat(32))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            SwitchRow(title: "Snap at screen edges",
                      isOn: Binding(get: { model.snapAtEdges }, set: { model.setSnapAtEdges($0) }))
            if model.stageManagerOn {
                SwitchRow(title: "Leave room for Stage Manager",
                          isOn: Binding(get: { model.leaveRoomForStageManager }, set: { model.setLeaveRoomForStageManager($0) }))
                SwitchRow(title: "Remember layout per stage",
                          isOn: Binding(get: { model.rememberLayoutPerStage }, set: { model.setRememberLayoutPerStage($0) }))
                    .help("Switching stages brings back the layout you last used there.")
            }
            SwitchRow(title: "Open at login",
                      isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
        }
        .font(.callout)
    }
}

private struct SwitchRow: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

private struct Footer: View {
    let model: PanelModel

    var body: some View {
        HStack {
            if !model.isEditing {
                FooterButton(title: "How Panes Works", symbol: "questionmark.circle") { model.showTutorial() }
                    .help("A quick animated tour of every feature and its shortcuts")
            }
            if model.isEditing {
                FooterButton(title: model.isRestorePending ? "Restore Defaults?" : "Restore Defaults",
                             symbol: "arrow.counterclockwise", isWarning: model.isRestorePending) {
                    model.restoreDefaults()
                }
                .disabled(!model.canRestoreDefaults)
                .help(model.canRestoreDefaults
                      ? "Brings back the built-in layouts as they ship, in their usual order. Layouts you drew stay."
                      : "The built-in layouts are as they ship")
            }
            Spacer()
            FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
        }
        .frame(height: 20) // its buttons' symbols differ in height between modes
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    var font: Font = .callout
    var isWarning = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(font)
                .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDipStyle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Warnings

private struct WarningList: View {
    let warnings: [PanelModel.Warning]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(warnings) { warning in
                Button { warning.action?() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.title).font(.callout.weight(.semibold))
                            Text(warning.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.orange.opacity(0.15), in: .rect(cornerRadius: 12, style: .continuous))
                    .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(PressDipStyle())
                .disabled(warning.action == nil)
            }
        }
    }
}

// MARK: - Shared

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// A layout's zones drawn as rounded rectangles with even gaps between them.
private struct ZoneShapes: View {
    let zones: [Zone]
    let gap: CGFloat
    let cornerRadius: CGFloat
    let style: (Int) -> AnyShapeStyle

    var body: some View {
        GeometryReader { geometry in
            let frames = Self.frames(for: zones, in: geometry.size, gap: gap)
            ForEach(frames.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(style(index))
                    .frame(width: frames[index].width, height: frames[index].height)
                    .position(x: frames[index].midX, y: frames[index].midY)
            }
        }
    }

    /// Each zone inset by half a gap, so neighbours sit a full gap apart.
    static func frames(for zones: [Zone], in size: CGSize, gap: CGFloat) -> [CGRect] {
        zones.map { zone in
            CGRect(x: zone.x * size.width, y: zone.y * size.height, width: zone.w * size.width, height: zone.h * size.height)
                .insetBy(dx: gap / 2, dy: gap / 2)
        }
    }
}

/// No chrome: a dip when pressed.
private struct PressDipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
