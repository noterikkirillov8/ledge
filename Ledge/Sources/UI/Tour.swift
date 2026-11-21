import SwiftUI

private struct Entrance: ViewModifier {
    var shown: Bool
    var anchor: UnitPoint
    @Environment(\.accessibilityReduceMotion) private var reduce
    @ViewBuilder func body(content: Content) -> some View {
        if reduce { content.opacity(shown ? 1 : 0).animation(KitMotion.soft, value: shown) }
        else { content.kitPanelEntrance(shown, anchor: anchor) }
    }
}

extension View {
    func ledgeEntrance(_ shown: Bool, anchor: UnitPoint = .top) -> some View { modifier(Entrance(shown: shown, anchor: anchor)) }
}

enum TourScene: Int, CaseIterable {
    case shake, land, fan, transfer, edge
    var title: String { ["Shake to open a shelf", "Drop files together", "Look through the stack", "Drag a file out", "Open another shelf"][rawValue] }
    var detail: String { ["Move a file left and right as you drag. A shelf appears under your pointer.", "The originals stay where they are. You can pick them up from the shelf later.", "Hover to spread the files. Pick one to preview or reveal in Finder.", "Drop it into another window. Hold Option to keep it on the shelf as well.", "Use the menu bar or your shortcut. To open a shelf mid-drag, choose a screen edge in Settings."][rawValue] }
}

@MainActor final class TourModel: ObservableObject {
    let items: [ShelfItem]
    @Published private(set) var scene: TourScene = .shake
    @Published private(set) var beat = 0
    @Published private(set) var shelf = Shelf()
    @Published var shown = false

    init(items: [ShelfItem]) { self.items = items }
    func select(_ scene: TourScene) { shelf = Shelf(); self.scene = scene; apply(0) }
    func apply(_ beat: Int) {
        self.beat = beat
        let count = switch scene {
        case .shake, .edge: 0
        case .land: min(4, max(0, beat - 1))
        case .fan: 4
        case .transfer: beat >= 5 ? 3 : 4
        }
        shelf.items = Array(items.prefix(count))
        shelf.dropTargeted = (scene == .land && beat == 1) || (scene == .shake && beat >= 5)
        shelf.expanded = (scene == .fan && beat >= 3) || scene == .transfer
        shelf.hovered = scene == .fan && beat >= 5 ? items[2].id : nil
    }
}

struct TourView: View {
    @ObservedObject var demo: TourModel
    var close: () -> Void
    var advance: () -> Void
    var previewReducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduce
    private var reduce: Bool { systemReduce || previewReducedMotion }
    private let shell = RoundedRectangle(cornerRadius: 14)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                TourStage(scene: demo.scene, beat: demo.beat, shelf: demo.shelf, items: demo.items, reduce: reduce)
                    .transaction { if reduce { $0.animation = nil } }
                    .id(reduce ? demo.beat : 0).transition(.opacity)
                    .animation(reduce ? KitMotion.soft : nil, value: reduce ? demo.beat : 0)
                    .id(demo.scene).transition(reduce ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24))))
            }.frame(height: 280).clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(demo.scene.title).font(KitFont.title)
                Text(demo.scene.detail).font(KitFont.body).foregroundStyle(KitColor.text2)
            }.padding(.horizontal, 16).padding(.top, 20)
            Spacer()
            HStack {
                Button("Skip", action: close).buttonStyle(.kitQuiet).focusable(false)
                Spacer()
                if demo.scene == .edge { Button("Get started", action: close).buttonStyle(.kitPrimary).focusable(false) }
                else { Button("Next", action: advance).buttonStyle(.kitSecondary).focusable(false) }
            }.overlay { HStack(spacing: 8) { ForEach(TourScene.allCases, id: \.self) { KitLed(on: demo.scene == $0) } }.accessibilityLabel("Step \(demo.scene.rawValue + 1) of 5") }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }.frame(width: 640, height: 440).background(KitColor.window).foregroundStyle(KitColor.text)
        .clipShape(shell).kitAccent(ShelfMetrics.amber)
    }
}

private struct TourStage: View {
    let scene: TourScene
    let beat: Int
    let shelf: Shelf
    let items: [ShelfItem]
    let reduce: Bool
    @Environment(\.displayScale) private var scale
    private var carried: ShelfItem { items[3] }
    private var point: CGPoint {
        switch scene {
        case .shake: CGPoint(x: [-170,-112,-174,-106,-152,-96,-54][beat], y: [-2,4,-5,2,-4,6,12][beat])
        case .land: CGPoint(x: [-134,-105,-99,-91,-84,-75,-68][beat], y: [-55,-38,-15,-10,0,8,20][beat])
        case .fan: CGPoint(x: [-208,-170,-120,-78,-20,38,42][beat], y: [58,50,28,21,15,12,12][beat])
        case .transfer: CGPoint(x: [-130,-90,-43,25,90,154,176][beat], y: [44,32,8,-11,-5,13,42][beat])
        case .edge: CGPoint(x: [-148,-202,-251,-281,-286,-278,-250][beat], y: [35,28,22,18,11,9,6][beat])
        }
    }
    private var readout: String {
        switch scene {
        case .shake: beat < 4 ? "Tracking drag" : "Shelf open"
        case .land: "\(shelf.items.count) held"
        case .fan: beat < 3 ? "Stacked" : (beat < 5 ? "Spread" : "PDF selected")
        case .transfer: beat < 2 ? "On shelf" : (beat < 5 ? "In transit" : "Delivered")
        case .edge: beat < 3 ? "Approaching" : (beat < 5 ? "Edge lit" : "Shelf open")
        }
    }

    var body: some View {
        ZStack {
            KitColor.well
            VStack {
                HStack(alignment: .firstTextBaseline) {
                    Text("Field guide").font(KitFont.header)
                    Spacer()
                    Text(readout).font(KitFont.key.monospacedDigit())
                }
                Spacer()
            }.padding(16).foregroundStyle(KitColor.text2)
            if scene == .shake {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pointer movement").font(KitFont.key).foregroundStyle(KitColor.text2)
                    Canvas { context, size in
                        var trace = Path(); trace.move(to: CGPoint(x: 0, y: size.height / 2))
                        for sample in 0...64 {
                            let time = Double(sample) / 64
                            trace.addLine(to: CGPoint(x: time * size.width, y: size.height * (0.5 + 0.38 * sin(time * .pi * 6) * sin(time * .pi))))
                        }
                        context.stroke(trace, with: .color(KitColor.line), lineWidth: 2)
                        context.stroke(trace.trimmedPath(from: 0, to: CGFloat(beat + 1) / 7), with: .color(ShelfMetrics.amber), lineWidth: 2)
                    }.frame(width: 120, height: 30)
                }.offset(x: 88).opacity(beat < 4 ? 1 : 0)
            }
            if scene == .edge {
                HStack(spacing: 12) {
                    Path(LedgeMark.path).fill(KitColor.text).frame(width: 19, height: 18).scaleEffect(!reduce && beat >= 4 ? 1.12 : 1)
                    Text("Menu bar").font(KitFont.key); KitKeycaps(keys: "⌃⌥L")
                }.padding(12).background(KitColor.window, in: RoundedRectangle(cornerRadius: 8)).offset(x: 147, y: -46)
                EdgeStrip().opacity(beat >= 3 ? 1 : 0).offset(x: -310)
                if beat < 5 { ThumbnailCard(item: carried, selected: false).scaleEffect(0.58).offset(x: reduce ? -162 : point.x + 16, y: reduce ? 0 : point.y - 22) }
            }
            if scene == .transfer {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Field report", systemImage: "macwindow").font(KitFont.header).padding(12)
                    Rectangle().fill(KitColor.line).frame(height: 1 / scale)
                    ZStack { if beat >= 5 { ThumbnailCard(item: carried, selected: false).scaleEffect(0.76) }
                        else { Text("Drop here").font(KitFont.detail).foregroundStyle(KitColor.text2) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(width: 160, height: 120).background(KitColor.window, in: RoundedRectangle(cornerRadius: 8))
                    .offset(x: 167)
            }
            ShelfView(shelf: shelf, ctl: nil).allowsHitTesting(false)
                .scaleEffect(scene == .transfer || scene == .edge ? 0.62 : 0.82)
                .offset(x: scene == .transfer ? -133 : scene == .edge ? -165 : scene == .shake ? 76 : 0)
                .opacity((scene == .shake && beat < 4) || (scene == .edge && beat < 5) ? 0 : 1)
            if scene == .shake || (scene == .transfer && (2...4).contains(beat)) {
                ThumbnailCard(item: carried, selected: false).scaleEffect(0.68)
                    .rotationEffect(.degrees(reduce ? 0 : (beat.isMultiple(of: 2) ? -5 : 4)))
                    .offset(x: reduce ? -120 : point.x - 20, y: reduce ? -32 : point.y - 22)
            }
            GhostPointer().frame(width: 20, height: 27).offset(x: reduce ? 0 : point.x, y: reduce ? 38 : point.y)
        }.animation(reduce ? KitMotion.soft : KitMotion.snap, value: beat)
    }
}

private struct GhostPointer: View {
    var body: some View {
        Canvas { context, _ in
            var arrow = Path(); arrow.move(to: CGPoint(x: 2, y: 1))
            for point in [CGPoint(x: 18,y: 14), CGPoint(x: 11,y: 15), CGPoint(x: 15,y: 23), CGPoint(x: 11,y: 25), CGPoint(x: 7,y: 17), CGPoint(x: 2,y: 22)] { arrow.addLine(to: point) }
            arrow.closeSubpath(); context.fill(arrow, with: .color(KitColor.text)); context.stroke(arrow, with: .color(.black), lineWidth: 1)
        }.accessibilityHidden(true)
    }
}
