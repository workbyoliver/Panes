import SwiftUI

/// Which tutorial page is showing (the window's arrow keys change it too).
@Observable
final class TutorialModel {
    var page = 0
    static let pageCount = 6

    func next() { page = min(page + 1, Self.pageCount - 1) }
    func back() { page = max(page - 1, 0) }
}

/// "How Panes Works": a card per feature, each with a looping animation of it on a little
/// screen, keys lighting up as they're "pressed", and that feature's shortcuts.
struct TutorialView: View {
    let model: TutorialModel
    let close: () -> Void

    static let size = CGSize(width: 540, height: 548)
    private static let sky = Color(red: 0.47, green: 0.71, blue: 1.0)
    private static let indigo = Color(red: 0.15, green: 0.22, blue: 0.60)

    var body: some View {
        let page = Self.pages[model.page]
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("How Panes Works").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
                        .background(.white.opacity(0.12), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help("Close (esc)")
            }

            page.illustration
                .frame(width: Self.size.width - 48, height: 236)
                .id(model.page) // each page's animation starts from the beginning

            VStack(alignment: .leading, spacing: 6) {
                Text(page.title).font(.title3.weight(.semibold))
                Text(page.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            ShortcutList(hints: page.keys)

            Spacer(minLength: 0)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<TutorialModel.pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == model.page ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.25)))
                            .frame(width: 6, height: 6)
                            .onTapGesture { model.page = index }
                    }
                }
                Spacer()
                if model.page > 0 {
                    Button("Back") { model.back() }.buttonStyle(TutorialButtonStyle())
                }
                if model.page < TutorialModel.pageCount - 1 {
                    Button("Next") { model.next() }.buttonStyle(TutorialButtonStyle(prominent: true))
                } else {
                    Button("Done", action: close).buttonStyle(TutorialButtonStyle(prominent: true))
                }
            }
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background {
            LinearGradient(colors: [Self.sky, Self.indigo], startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.22)
        }
        .clipShape(RoundedRectangle(cornerRadius: GlassPanel.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.25), value: model.page)
    }

    // MARK: - Pages

    private struct Page {
        let title: String
        let text: String
        let keys: [KeyHint]
        let illustration: AnyView
    }

    private static let pages: [Page] = [
        Page(title: "Pick a layout",
             text: "A layout splits your screen into zones. Pick one in the panel, or with a shortcut. Each display keeps its own.",
             keys: [KeyHint("⌃⌥⌘ 1–9", "That layout"), KeyHint("⌃⌥ L", "Next layout")],
             illustration: AnyView(LayoutsScene())),
        Page(title: "Hold ⌥ while you drag",
             text: "Drag any window by its title bar and hold ⌥: the zones light up. Let go over one and the window fills it.",
             keys: [KeyHint("⌥ + drag", "Show zones"), KeyHint("⇧", "Span two zones"), KeyHint("Tab", "Switch layout mid-drag")],
             illustration: AnyView(DragScene())),
        Page(title: "Move with the keyboard",
             text: "The focused window hops between zones, grows across them, fills the screen or centres, and every move can be undone.",
             keys: [KeyHint("⌃⌥ ← →", "Next zone"), KeyHint("⌃⌥ 1–9", "Zone number"), KeyHint("⌃⌥⇧ arrow", "Grow"),
                    KeyHint("⌃⌥ ↩", "Fill"), KeyHint("⌃⌥ C", "Centre"), KeyHint("⌃⌥ ⌫", "Undo")],
             illustration: AnyView(KeyboardScene())),
        Page(title: "Swap and snap",
             text: "Drop a window on a zone that's taken and the two swap places. Drag to a screen edge to snap there, or to the top to fill.",
             keys: [KeyHint("Drag to an edge", "Snap"), KeyHint("Drag to the top", "Fill")],
             illustration: AnyView(SwapScene())),
        Page(title: "Draw your own layouts",
             text: "Click New in the panel and drag across the grid. Zones are numbered in the order you draw them. In Edit, drag layouts to reorder, redraw, delete or change shortcuts.",
             keys: [KeyHint("New", "Draw a layout"), KeyHint("Edit", "Reorder, delete, shortcuts"), KeyHint("Restore Defaults", "Bring back the built-ins")],
             illustration: AnyView(EditorScene())),
        Page(title: "Made for Stage Manager",
             text: "Zones leave room for the strip of recent apps, and each stage remembers its layout: switch stages and it comes back.",
             keys: [KeyHint("Remember layout per stage", "In the panel"), KeyHint("Leave room for Stage Manager", "In the panel")],
             illustration: AnyView(StageScene())),
    ]
}

private struct KeyHint: Hashable {
    let keys: String
    let label: String
    init(_ keys: String, _ label: String) {
        self.keys = keys
        self.label = label
    }
}

private struct ShortcutList: View {
    let hints: [KeyHint]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            ForEach(hints, id: \.self) { hint in
                HStack(spacing: 8) {
                    Text(hint.keys)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(.white.opacity(0.12), in: .rect(cornerRadius: 5, style: .continuous))
                    Text(hint.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TutorialButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(0.12))))
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - The little screen

/// Seconds into a loop of `period`.
private func loopTime(_ date: Date, _ period: Double) -> Double {
    date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
}

/// 0 before `start`, 1 after `end`, eased in between.
private func progress(_ t: Double, _ start: Double, _ end: Double) -> Double {
    let x = min(max((t - start) / (end - start), 0), 1)
    return x * x * (3 - 2 * x)
}

private func mix(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
    CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
           width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
}

private func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
}

/// The area zones cover on the little screen, and zone frames in it (with small gaps).
private struct Area {
    let rect: CGRect

    func frame(_ zone: Zone) -> CGRect {
        CGRect(x: rect.minX + zone.x * rect.width, y: rect.minY + zone.y * rect.height,
               width: zone.w * rect.width, height: zone.h * rect.height).insetBy(dx: 2.5, dy: 2.5)
    }

    func frames(_ layout: String) -> [CGRect] {
        (Layout.builtIn.first { $0.id == layout }?.zones ?? []).map(frame)
    }

    /// Several zones of a layout joined (a span).
    func span(_ layout: String, _ indices: [Int]) -> CGRect {
        let all = frames(layout)
        return indices.map { all[$0] }.reduce(CGRect.null) { $0.union($1) }
    }

    var fill: CGRect { rect.insetBy(dx: 2.5, dy: 2.5) }

    var centred: CGRect {
        CGRect(x: rect.midX - rect.width * 0.4, y: rect.midY - rect.height * 0.4, width: rect.width * 0.8, height: rect.height * 0.8)
    }
}

/// A screen with a wallpaper and a menu bar, `strip` points of Stage Manager on the left.
private struct MiniScreen<Content: View>: View {
    var strip: CGFloat = 0
    @ViewBuilder let content: (Area) -> Content

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let area = Area(rect: CGRect(x: 6 + strip, y: 16, width: size.width - 12 - strip, height: size.height - 22))
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.95), Color(red: 0.2, green: 0.18, blue: 0.5),
                                        Color(red: 0.55, green: 0.3, blue: 0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.black.opacity(0.25)).frame(height: 10) // menu bar
                content(area)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
        }
    }
}

/// Places a view at a frame inside the screen (top-left coordinates).
private extension View {
    func placed(_ frame: CGRect) -> some View {
        self.frame(width: max(frame.width, 0), height: max(frame.height, 0))
            .padding(.leading, frame.minX)
            .padding(.top, frame.minY)
    }
}

private struct MiniWindow: View {
    var tint: Color = Color(red: 0.25, green: 0.5, blue: 0.95)

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.white.opacity(0.92))
            .overlay(alignment: .top) {
                ZStack(alignment: .leading) {
                    UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous).fill(tint)
                    HStack(spacing: 3) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.9)).frame(width: 4, height: 4) }
                    }
                    .padding(.leading, 5)
                }
                .frame(height: 10)
            }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

private struct ZoneShade: View {
    var number: Int?
    var isTarget = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isTarget ? AnyShapeStyle(Color.accentColor.opacity(0.55)) : AnyShapeStyle(.white.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(isTarget ? 0.7 : 0.35), lineWidth: 1))
            .overlay {
                if let number {
                    Text("\(number)").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                }
            }
    }
}

private struct Pointer: View {
    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 1.5)
    }
}

/// Keys being "pressed", shown on the screen like an on-screen keyboard display.
private struct KeysPressed: View {
    let keys: String?

    var body: some View {
        if let keys {
            Text(keys)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.black.opacity(0.55), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

// MARK: - Scenes

/// Layouts take turns, each with its shortcut.
private struct LayoutsScene: View {
    private let steps: [(id: String, keys: String)] = [("halves", "⌃⌥⌘ 1"), ("thirds", "⌃⌥⌘ 2"), ("four-columns", "⌃⌥⌘ 3"),
                                                       ("main-sides", "⌃⌥⌘ 7"), ("focus", "⌃⌥ L")]

    var body: some View {
        TimelineView(.animation) { context in
            let t = loopTime(context.date, Double(steps.count) * 1.6)
            let index = Int(t / 1.6) % steps.count
            let local = t - Double(index) * 1.6
            MiniScreen { area in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(area.frames(steps[index].id).enumerated()), id: \.offset) { number, frame in
                        ZoneShade(number: number + 1).placed(frame)
                    }
                    .opacity(progress(local, 0, 0.25) * (1 - progress(local, 1.4, 1.6)))
                    KeysPressed(keys: steps[index].keys)
                        .opacity(local < 1.2 ? 1 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}

/// A window dragged with ⌥: the zones appear, the target lights, it drops in.
private struct DragScene: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = loopTime(context.date, 5)
            MiniScreen { area in
                let zones = area.frames("thirds")
                let floating = CGRect(x: area.rect.midX - 70, y: area.rect.midY - 40, width: 140, height: 92)
                let dragged = floating.offsetBy(dx: zones[0].midX - floating.midX + 20, dy: -6)
                let moving = mix(floating, dragged, progress(t, 0.4, 2.0))
                let window = mix(moving, zones[0], progress(t, 2.3, 2.6))
                let zonesShown = progress(t, 0.7, 0.9) * (1 - progress(t, 2.4, 2.7))
                ZStack(alignment: .topLeading) {
                    ForEach(zones.indices, id: \.self) { index in
                        ZoneShade(number: index + 1, isTarget: index == 0 && t > 1.5).placed(zones[index])
                    }
                    .opacity(zonesShown)
                    MiniWindow().placed(window).opacity(1 - progress(t, 4.4, 4.9))
                    Pointer().offset(x: window.minX + 40, y: window.minY + 2).opacity(t < 2.4 ? 1 : 1 - progress(t, 2.4, 2.8))
                    KeysPressed(keys: t > 0.7 && t < 2.4 ? "⌥" : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}

/// Keyboard moves, one after another.
private struct KeyboardScene: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = loopTime(context.date, 8.4)
            MiniScreen { area in
                let zones = area.frames("thirds")
                let frames = [zones[0], zones[1], zones[2], area.span("thirds", [1, 2]), area.fill, area.centred, area.fill, zones[0]]
                let keys = ["⌃⌥ →", "⌃⌥ →", "⌃⌥⇧ ←", "⌃⌥ ↩", "⌃⌥ C", "⌃⌥ ⌫", "⌃⌥ 1"]
                let step = min(Int(t / 1.1), keys.count) // which move has happened
                let local = t - Double(step) * 1.1
                let from = frames[max(step - 1, 0)], to = frames[step]
                let window = step == 0 ? frames[0] : mix(from, to, progress(local, 0, 0.35))
                ZStack(alignment: .topLeading) {
                    ForEach(zones.indices, id: \.self) { index in ZoneShade().placed(zones[index]) }
                        .opacity(0.5)
                    MiniWindow().placed(window)
                    KeysPressed(keys: step >= 1 && step <= keys.count && local < 0.8 ? keys[step - 1] : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}

/// Dropping on a taken zone swaps; dragging to the top fills.
private struct SwapScene: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = loopTime(context.date, 6)
            MiniScreen { area in
                let zones = area.frames("thirds")
                let lift = zones[0].insetBy(dx: 12, dy: 12)
                let overB = lift.offsetBy(dx: zones[2].midX - lift.midX, dy: 0)
                let aMoving = mix(mix(zones[0], lift, progress(t, 0.3, 0.6)), overB, progress(t, 0.6, 1.8))
                let a1 = mix(aMoving, zones[2], progress(t, 1.9, 2.2))
                let topEdge = CGRect(x: area.rect.midX - 60, y: area.rect.minY - 4, width: 120, height: 80)
                let a2 = mix(mix(a1, zones[2].insetBy(dx: 12, dy: 12), progress(t, 3.0, 3.2)), topEdge, progress(t, 3.2, 4.2))
                let a = mix(a2, area.fill, progress(t, 4.3, 4.6))
                let b = mix(zones[2], zones[0], progress(t, 1.9, 2.3))
                ZStack(alignment: .topLeading) {
                    ForEach(zones.indices, id: \.self) { index in
                        ZoneShade(isTarget: index == 2 && t > 1.2 && t < 2.0).placed(zones[index])
                    }
                    .opacity(t > 0.6 && t < 2.1 ? 1 : 0.35)
                    MiniWindow(tint: Color(red: 0.95, green: 0.55, blue: 0.2)).placed(b)
                    MiniWindow().placed(a)
                    Pointer().offset(x: a.minX + 40, y: a.minY + 2).opacity(t < 4.4 ? 1 : 0)
                    KeysPressed(keys: t > 0.6 && t < 1.9 ? "⌥" : t > 3.6 && t < 4.6 ? "Top edge" : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                }
                .opacity(1 - progress(t, 5.5, 5.9))
            }
        }
    }
}

/// Zones drawn on the editor's grid, in order.
private struct EditorScene: View {
    private struct Cells {
        let c0, r0, c1, r1: Int
    }

    private static let cells = [Cells(c0: 0, r0: 0, c1: 2, r1: 5), Cells(c0: 3, r0: 0, c1: 8, r1: 5),
                                Cells(c0: 9, r0: 0, c1: 11, r1: 2), Cells(c0: 9, r0: 3, c1: 11, r1: 5)]

    /// The grid's cells on the little screen: 12 × 6, like the editor's on a wide display.
    private struct Grid {
        let area: CGRect
        var cw: CGFloat { area.width / 12 }
        var ch: CGFloat { area.height / 6 }

        func rect(_ c0: Int, _ r0: Int, _ c1: Int, _ r1: Int) -> CGRect {
            CGRect(x: area.minX + CGFloat(c0) * cw, y: area.minY + CGFloat(r0) * ch,
                   width: CGFloat(c1 - c0 + 1) * cw, height: CGFloat(r1 - r0 + 1) * ch).insetBy(dx: 2, dy: 2)
        }

        var lines: Path {
            var path = Path()
            for c in 1..<12 {
                let x = area.minX + CGFloat(c) * cw
                path.move(to: CGPoint(x: x, y: area.minY))
                path.addLine(to: CGPoint(x: x, y: area.maxY))
            }
            for r in 1..<6 {
                let y = area.minY + CGFloat(r) * ch
                path.move(to: CGPoint(x: area.minX, y: y))
                path.addLine(to: CGPoint(x: area.maxX, y: y))
            }
            return path
        }
    }

    private static func start(_ index: Int) -> Double { 0.3 + Double(index) * 1.15 }

    var body: some View {
        TimelineView(.animation) { context in
            let t = loopTime(context.date, 6)
            MiniScreen { area in
                scene(grid: Grid(area: area.rect), t: t)
            }
        }
    }

    private func scene(grid: Grid, t: Double) -> some View {
        let current = Self.cells.indices.last { t > Self.start($0) } ?? 0
        let cell = Self.cells[current]
        let from = grid.rect(cell.c0, cell.r0, cell.c0, cell.r0), to = grid.rect(cell.c1, cell.r1, cell.c1, cell.r1)
        let pointer = mix(CGPoint(x: from.midX, y: from.midY), CGPoint(x: to.midX, y: to.midY),
                          progress(t, Self.start(current), Self.start(current) + 0.8))
        return ZStack(alignment: .topLeading) {
            grid.lines.stroke(.white.opacity(0.3), lineWidth: 0.5)
            ForEach(Self.cells.indices, id: \.self) { index in
                zone(index, grid: grid, t: t)
            }
            Pointer().offset(x: pointer.x, y: pointer.y).opacity(t < 5 ? 1 : 0)
        }
        .opacity(1 - progress(t, 5.4, 5.9))
    }

    private func zone(_ index: Int, grid: Grid, t: Double) -> some View {
        let cell = Self.cells[index]
        let start = Self.start(index), end = start + 0.8
        let full = grid.rect(cell.c0, cell.r0, cell.c1, cell.r1)
        let first = grid.rect(cell.c0, cell.r0, cell.c0, cell.r0)
        return ZoneShade(number: t > end ? index + 1 : nil, isTarget: t <= end)
            .placed(mix(first, full, progress(t, start, end)))
            .opacity(t > start ? 1 : 0)
    }
}

/// The strip of stages on the left; switching stage brings back that stage's layout.
private struct StageScene: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = loopTime(context.date, 6)
            let switched = progress(t, 2.6, 3.1) // first stage → second
            let back = progress(t, 5.4, 5.9)
            let s = switched * (1 - back)
            MiniScreen(strip: 46) { area in
                let thirds = area.frames("thirds"), halves = area.frames("halves")
                ZStack(alignment: .topLeading) {
                    // The strip: two other stages as small thumbnails.
                    ForEach(0..<2, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.75))
                            .placed(CGRect(x: 8, y: 30 + CGFloat(index) * 52, width: 36, height: 28))
                            .overlay(alignment: .topLeading) {
                                if index == 0 && t > 2.2 && t < 2.7 {
                                    Pointer().offset(x: 30, y: 44)
                                }
                            }
                    }
                    ForEach(0..<3, id: \.self) { index in
                        MiniWindow().placed(thirds[index]).opacity(1 - s)
                    }
                    ForEach(0..<2, id: \.self) { index in
                        MiniWindow(tint: Color(red: 0.95, green: 0.55, blue: 0.2)).placed(halves[index]).opacity(s)
                    }
                    KeysPressed(keys: s > 0.5 ? "Stage 2 · Halves" : "Stage 1 · Thirds")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}
