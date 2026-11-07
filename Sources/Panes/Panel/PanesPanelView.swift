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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Edit mode swaps contents in place (this row's text, each tile's caption) and never
            // changes the panel's size: a resize while open looked broken.
            HStack {
                if model.isEditingShortcuts {
                    Text(editingHint)
                        .font(.caption)
                        .foregroundStyle(model.recordingNote == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    SectionTitle("Layout")
                }
                Spacer(minLength: 8)
                FooterButton(title: model.isEditingShortcuts ? "Done" : "Shortcuts",
                             symbol: model.isEditingShortcuts ? "checkmark" : "keyboard", font: .caption) {
                    model.toggleEditingShortcuts()
                }
            }
            .frame(height: 18)
            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.layouts) { layout in
                        LayoutTile(layout: layout,
                                   isSelected: layout.id == model.active?.id,
                                   shortcut: model.shortcutText[layout.id],
                                   isTaken: model.takenShortcuts.contains(layout.id),
                                   isEditing: model.isEditingShortcuts,
                                   isRecording: model.recordingID == layout.id) {
                            model.tap(layout)
                        }
                    }
                }
            }
            .animation(.smooth(duration: 0.25), value: model.activeID)
        }
    }

    private var editingHint: String {
        model.recordingNote ?? (model.recordingID == nil ? "Click a layout, then type keys" : "Type keys · ⌫ removes · esc cancels")
    }
}

/// A layout's zones in a glass tile, with its name below; in edit mode, its shortcut.
private struct LayoutTile: View {
    let layout: Layout
    let isSelected: Bool
    let shortcut: String?
    let isTaken: Bool
    let isEditing: Bool
    let isRecording: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZoneShapes(zones: layout.zones, gap: 3, cornerRadius: 3) { _ in
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(0.75))
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(.rect(cornerRadius: 12))
                .glassEffect(isSelected ? .regular.interactive() : .clear.interactive(), in: .rect(cornerRadius: 12))

                Group {
                    if isEditing {
                        ShortcutCapsule(text: isRecording ? "Type keys…" : shortcut ?? "None",
                                        isEmpty: shortcut == nil && !isRecording, isTaken: isTaken, isRecording: isRecording)
                    } else {
                        Text(layout.name)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                }
                .frame(height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDipStyle())
        .opacity(isEditing || isSelected || isHovering ? 1 : 0.6)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel("\(layout.name) layout")
        .accessibilityValue(shortcut ?? "No shortcut")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var help: String {
        guard let shortcut else { return layout.name }
        return isTaken ? "\(layout.name)  \(shortcut): another app already uses this shortcut" : "\(layout.name)  \(shortcut)"
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
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .contentShape(.capsule)
        }
        .buttonStyle(PressDipStyle())
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("\(title)  \(shortcut.display)")
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
            FooterButton(title: "Edit Layouts…", symbol: "square.and.pencil") { model.editLayouts() }
            Spacer()
            FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
        }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    var font: Font = .callout
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(font)
                .foregroundStyle(isHovering ? .primary : .secondary)
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
