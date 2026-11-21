import SwiftUI

private struct TourShell: View {
    @ObservedObject var demo: TourModel
    let close: () -> Void
    let advance: () -> Void
    var body: some View { TourView(demo: demo, close: close, advance: advance).ledgeEntrance(demo.shown, anchor: .center) }
}

/// The intro: an IntroFlow, one 30 Hz timer and an IntroPresenter window. Scene and beat both derive from the one clock.
@MainActor final class TourController {
    static let sceneSeconds = 4.0, beatSeconds = 0.48
    private let demo: TourModel
    private let presenter = IntroPresenter()
    private var flow = IntroFlow(durations: Array(repeating: TourController.sceneSeconds, count: TourScene.allCases.count))
    private var timer: Timer?
    private var seen: () -> Void
    var isShowing: Bool { presenter.isShowing }

    init(items: [ShelfItem], seen: @escaping () -> Void) {
        demo = TourModel(items: items); self.seen = seen
        presenter.onClose = { [weak self] in self?.closed() }
        presenter.onNext = { [weak self] in self?.step(1) }
        presenter.onBack = { [weak self] in self?.step(-1) }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        if presenter.isShowing { presenter.show(EmptyView(), size: .zero); return }
        seen()
        flow = IntroFlow(durations: flow.durations, now: now); flow.markSeen()
        demo.select(TourScene(rawValue: 0)!)
        presenter.show(TourShell(demo: demo, close: { [weak self] in self?.finish() }, advance: { [weak self] in self?.step(1) }), size: CGSize(width: 640, height: 440))
        KitSound.play(.powerOn)
        demo.shown = true
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    func finish() { presenter.close() }

    private func closed() {
        flow.close(); seen()
        timer?.invalidate(); timer = nil
        KitSound.play(.powerOff)
        demo.shown = false
    }

    private func step(_ delta: Int) {
        guard presenter.isShowing else { return }
        if delta > 0 { flow.next(now: now) } else { flow.back(now: now) }
        if flow.closed { finish() } else { sync() }
    }

    private func tick() {
        guard presenter.isShowing else { return }
        flow.tick(now: now); sync()
    }

    /// Bring the demo model in line with the flow: scene on change, beat from the scene clock.
    private func sync() {
        if let scene = TourScene(rawValue: flow.scene), scene != demo.scene {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? KitMotion.soft : KitMotion.list) { demo.select(scene) }
        }
        let beat = min(6, Int(flow.time(now: now) / Self.beatSeconds))
        if beat != demo.beat { demo.apply(beat) }
    }
}
