import AppKit
import SwiftUI

/// Owns every shelf: creates, restores and saves them.
@MainActor
final class ShelfManager {
    static let shared = ShelfManager(persistent: true)
    private(set) var controllers: [ShelfController] = []
    private let persistent: Bool
    private var standby: ShelfController?

    func prepare() {
        if standby == nil { standby = ShelfController(shelf: Shelf()) }
    }

    init(persistent: Bool) { self.persistent = persistent }

    @discardableResult
    func makeController(_ shelf: Shelf? = nil) -> ShelfController {
        let ctl: ShelfController
        if let shelf { ctl = ShelfController(shelf: shelf) }
        else if let ready = standby { ctl = ready; standby = nil }
        else { ctl = ShelfController(shelf: Shelf()) }
        ctl.onChange = { [weak self] in
            self?.persist()
            DispatchQueue.main.async { self?.prepare() }
        }
        ctl.onClose = { [weak self, weak ctl] _ in
            guard let self, let ctl else { return }
            self.controllers.removeAll { $0 === ctl }
            self.standby = ctl
            self.persist()
        }
        controllers.append(ctl)
        return ctl
    }

    /// An empty shelf that is already showing is reused instead of piling up new ones.
    func shelfNearPointer() -> ShelfController {
        let ctl = controllers.first { $0.isShown && $0.shelf.items.isEmpty } ?? makeController()
        ctl.show(near: NSEvent.mouseLocation)
        return ctl
    }

    func slideIn(_ edge: ShelfEdge, at point: NSPoint) {
        let ctl = controllers.first { $0.isShown && $0.shelf.items.isEmpty } ?? makeController()
        ctl.slideIn(from: edge, screenAt: point)
    }

    func showAll() {
        for ctl in controllers where !ctl.isShown { ctl.restore(frame: nil); }
        if controllers.isEmpty { _ = shelfNearPointer() }
    }

    func restore() {
        guard persistent else { return }
        let records = Persistence.load()
        var cleaned: [ShelfRecord] = []
        var removedItems = false
        for r in records {
            guard !r.items.isEmpty else { continue }
            let shelf = Shelf(restoring: r)
            if shelf.items.count != r.items.count { removedItems = true }
            if !shelf.items.isEmpty {
                var record = r
                record.items = shelf.items.map(\.record)
                cleaned.append(record)
            }
            let ctl = makeController(shelf)
            if r.visible { ctl.restore(frame: r.frame) }
        }
        if removedItems { Persistence.save(cleaned) }
        pruneSavedDrops(days: Prefs.shared.retentionDays)
    }

    func pruneSavedDrops(days: Int) {
        guard persistent else { return }
        Saver.prune(keeping: controllers.flatMap { $0.shelf.items.map(\.url) }, olderThan: Double(days) * 86400)
    }

    func persist() {
        guard persistent else { return }
        let records = controllers.filter { !$0.shelf.items.isEmpty }.map {
            ShelfRecord(id: $0.shelf.id, items: $0.shelf.items.map(\.record),
                        frame: $0.panel.frame, visible: $0.isShown, edge: $0.shelf.edge)
        }
        Persistence.save(records)
    }
}

struct EdgeStrip: View {
    var body: some View { Rectangle().fill(ShelfMetrics.amber).frame(width: 4, height: 128) }
}

/// Watches other apps' drags (no permission needed) and opens a shelf on a shake or an edge hold.
@MainActor
final class DragWatcher {
    var onShake: (NSPoint) -> Void = { _ in }
    var onEdge: (ShelfEdge, NSPoint) -> Void = { _, _ in }
    private var monitors: [Any] = []
    private var baseline = 0
    private var dragging = false
    private var fired = false
    private var shake = ShakeDetector()
    private var edge = EdgeHoldDetector()
    private var timer: Timer?
    private let prefs = Prefs.shared
    private var indicator: NSPanel?

    private func indicate(_ edge: ShelfEdge?, screen: NSScreen?) {
        guard let edge, let screen else { if indicator?.isVisible == true { indicator?.orderOut(nil) }; return }
        let frame = screen.frame
        let rect = NSRect(x: edge == .left ? frame.minX : frame.maxX - 4, y: frame.midY - 64, width: 4, height: 128)
        if indicator == nil {
            let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = NSHostingView(rootView: EdgeStrip()); panel.hasShadow = false
            panel.level = .floating; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; indicator = panel
        }
        if indicator?.frame != rect { indicator?.setFrame(rect, display: true) }
        if indicator?.isVisible != true { indicator?.orderFrontRegardless() }
    }

    func start() {
        let drag = NSPasteboard(name: .drag)
        func add(_ mask: NSEvent.EventTypeMask, _ body: @escaping @MainActor (DragWatcher) -> Void) {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            }) { monitors.append(m) }
        }
        add(.leftMouseDown) { w in w.baseline = drag.changeCount; w.end() }
        add(.leftMouseDragged) { w in w.dragged(drag) }
        add(.leftMouseUp) { w in w.end() }
    }

    private func dragged(_ drag: NSPasteboard) {
        if !dragging {
            // The drag pasteboard is rewritten when a drag starts, so a changed count means real content.
            guard drag.changeCount != baseline else { return }
            dragging = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        guard !fired, prefs.shake else { return }
        let p = NSEvent.mouseLocation
        if shake.feed(x: p.x, t: ProcessInfo.processInfo.systemUptime) { fired = true; indicate(nil, screen: nil); onShake(p) }
    }

    private func tick() {
        guard !fired, let allowed = prefs.edgeMode.edge else { indicate(nil, screen: nil); return }
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        let near = allowed == .left ? p.x <= screen.frame.minX + edge.zone : p.x >= screen.frame.maxX - edge.zone
        indicate(near ? allowed : nil, screen: screen)
        if let e = edge.feed(x: p.x, minX: screen.frame.minX, maxX: screen.frame.maxX,
                             t: ProcessInfo.processInfo.systemUptime, allowed: allowed) {
            fired = true; indicate(nil, screen: nil); onEdge(e, p)
        }
    }

    private func end() {
        indicate(nil, screen: nil)
        timer?.invalidate(); timer = nil
        dragging = false; fired = false
        shake.reset(); edge.reset()
    }
}
