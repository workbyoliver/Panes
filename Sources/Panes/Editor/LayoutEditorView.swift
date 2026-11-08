import SwiftUI

/// The layout editor window's content: a toolbar, then every display as a picture (arranged
/// as in System Settings) with a grid on the one you're drawing on.
struct LayoutEditorView: View {
    @Bindable var model: LayoutEditorModel
    let onCancel: () -> Void
    let onSave: () -> Void

    static let width: CGFloat = 960
    private static let padding: CGFloat = 20

    var body: some View {
        // The controls sit below the displays: in the band just under the title bar (macOS 26),
        // clicks never reached the toolbar's buttons, though Accessibility presses did.
        VStack(alignment: .leading, spacing: 14) {
            DisplayArrangement(model: model)
                .frame(height: Self.canvasHeight(for: model.displays))
            footer
            Divider()
            toolbar
        }
        .padding(Self.padding)
        .frame(width: Self.width)
    }

    /// Tall enough for the displays' combined shape at the window's width, within limits.
    static func canvasHeight(for displays: [EditorDisplay]) -> CGFloat {
        let union = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0 else { return 400 }
        return min(560, max(260, (width - padding * 2) * union.height / union.width)).rounded()
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Layout name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { if model.canSave { onSave() } }
            Spacer()
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .buttonStyle(EditorButtonStyle())
                .keyboardShortcut("z")
                .disabled(model.zones.isEmpty)
                .help("Remove the last zone (⌘Z)")
            Button { model.reset() } label: { Label("Reset", systemImage: "trash") }
                .buttonStyle(EditorButtonStyle())
                .disabled(model.zones.isEmpty)
                .help("Remove every zone")
            Divider().frame(height: 18)
            Button("Cancel", action: onCancel)
                .buttonStyle(EditorButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Save", action: onSave)
                .buttonStyle(EditorButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Toggle("Finer grid", isOn: $model.finerGrid)
            if model.showsStageManagerSwitch {
                Toggle("Leave room for Stage Manager", isOn: $model.leaveRoomForStageManager)
                    .help("The same setting as in the panel: zones start right of the Stage Manager strip")
            }
            Spacer(minLength: 12)
            if model.isDisplayFull {
                Text("\(model.display?.name ?? "This display") already has \(LayoutEditorModel.maxLayoutsPerDisplay) layouts. Delete one first.")
                    .foregroundStyle(.orange)
            } else {
                Text(placement).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.callout)
    }

    private var placement: String {
        if let editing = model.editing, editing.display == nil { return "Offered on every display" }
        return "For \(model.display?.name ?? "this display")"
    }
}

/// Every display at its real position and size, scaled to fit.
private struct DisplayArrangement: View {
    let model: LayoutEditorModel

    var body: some View {
        GeometryReader { geometry in
            let union = model.displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let scale = union.isNull ? 1 : min(geometry.size.width / union.width, geometry.size.height / union.height)
            let left = (geometry.size.width - union.width * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(model.displays) { display in
                    DisplayPicture(display: display, scale: scale, model: model)
                        .padding(.leading, left + (display.frame.minX - union.minX) * scale)
                        .padding(.top, (display.frame.minY - union.minY) * scale)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}

/// One display: its wallpaper, the parts zones never cover shaded, and on the display you're
/// drawing on, the grid and zones. Click another display to draw on it instead.
private struct DisplayPicture: View {
    let display: EditorDisplay
    let scale: CGFloat
    let model: LayoutEditorModel

    var body: some View {
        let size = CGSize(width: (display.frame.width * scale).rounded(), height: (display.frame.height * scale).rounded())
        let zoneArea = model.area(of: display)
        let area = CGRect(x: (zoneArea.minX - display.frame.minX) * scale, y: (zoneArea.minY - display.frame.minY) * scale,
                          width: zoneArea.width * scale, height: zoneArea.height * scale)
        let isSelected = model.display?.id == display.id
        ZStack(alignment: .topLeading) {
            wallpaper(size: size)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(area)
            }
            .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
            if isSelected {
                DrawingArea(model: model)
                    .frame(width: area.width, height: area.height)
                    .padding(.leading, area.minX)
                    .padding(.top, area.minY)
            } else {
                Color.black.opacity(0.45)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.2), lineWidth: isSelected ? 2 : 1)
        }
        .overlay(alignment: .bottomLeading) {
            Text(display.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45), in: .capsule)
                .padding(8)
                .allowsHitTesting(false)
        }
        .overlay {
            if !isSelected {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectDisplay(display.id) }
                    .help(model.canChangeDisplay ? "Draw on \(display.name)" : "This layout stays on \(model.display?.name ?? "its display")")
            }
        }
    }

    @ViewBuilder
    private func wallpaper(size: CGSize) -> some View {
        if let image = display.wallpaper {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            // Panes's own backdrop: the icon's sky-to-indigo with a soft light from the top left.
            ZStack {
                LinearGradient(colors: [Color(red: 0.40, green: 0.60, blue: 0.95), Color(red: 0.13, green: 0.18, blue: 0.48)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topLeading,
                               startRadius: 0, endRadius: max(size.width, size.height) * 0.8)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// The grid over a display's usable area, its zones, and the one being dragged out.
private struct DrawingArea: View {
    let model: LayoutEditorModel

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let grid = model.grid
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.15)
                GridLines(columns: grid.columns, rows: grid.rows)
                    .stroke(.white.opacity(0.35), lineWidth: 0.5)
                ForEach(model.zones.indices, id: \.self) { index in
                    zoneTile(model.zones[index], number: index + 1, style: .placed, in: size)
                }
                if let drawing = model.drawing {
                    zoneTile(drawing, number: model.zones.count + 1, style: model.drawingFits ? .drawing : .blocked, in: size)
                }
                if model.zones.isEmpty && model.drawing == nil {
                    Text("Drag across the grid to draw a zone.\nZones are numbered in the order you draw them.")
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 10, style: .continuous))
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in model.drag(from: drag.startLocation, to: drag.location, in: size) }
                    .onEnded { _ in
                        if !model.endDrag() { NSSound.beep() }
                    }
            )
        }
    }

    private func zoneTile(_ zone: Zone, number: Int, style: ZoneTile.Style, in size: CGSize) -> some View {
        let frame = CGRect(x: zone.x * size.width, y: zone.y * size.height, width: zone.w * size.width, height: zone.h * size.height)
            .insetBy(dx: 2, dy: 2)
        return ZoneTile(number: number, style: style)
            .frame(width: max(frame.width, 1), height: max(frame.height, 1))
            .padding(.leading, frame.minX)
            .padding(.top, frame.minY)
            .allowsHitTesting(false)
    }
}

private struct ZoneTile: View {
    enum Style { case placed, drawing, blocked }

    let number: Int
    let style: Style

    var body: some View {
        GeometryReader { geometry in
            let tint: Color = style == .blocked ? .red : .accentColor
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(style == .placed ? 0.55 : 0.3))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tint, style: StrokeStyle(lineWidth: style == .placed ? 1.5 : 2, dash: style == .placed ? [] : [5, 3]))
                }
                .overlay {
                    Text("\(number)")
                        .font(.system(size: min(30, max(10, min(geometry.size.width, geometry.size.height) * 0.4)), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
        }
    }
}

private struct GridLines: Shape {
    let columns: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for column in 1..<max(columns, 1) {
            let x = (rect.width * CGFloat(column) / CGFloat(columns)).rounded()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: rect.height))
        }
        for row in 1..<max(rows, 1) {
            let y = (rect.height * CGFloat(row) / CGFloat(rows)).rounded()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return path
    }
}

/// A capsule button; `prominent` for Save.
private struct EditorButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            .contentShape(.capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
