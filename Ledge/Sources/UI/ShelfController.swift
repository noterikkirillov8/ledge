import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The floating, non-activating panel that shows one shelf.
final class ShelfPanel: NSPanel {
    weak var ctl: ShelfController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            switch event.keyCode {
            case 49: ctl?.quickLookHovered()      // space
            case 53: ctl?.close()                 // esc
            case 51, 117: ctl?.removeHovered()    // delete
            case 36, 76: ctl?.openHovered()       // return
            default: super.keyDown(with: event)
            }
        }
    }
}

@MainActor
private final class ShelfHost: NSHostingView<AnyView> {
    weak var shelf: Shelf?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { shelf?.expanded = true }
    override func mouseExited(with event: NSEvent) { shelf?.expanded = false; shelf?.hovered = nil }
}

@MainActor
final class ShelfController: NSObject {
    let shelf: Shelf
    let panel: ShelfPanel
    private let host: ShelfHost
    private var closing: Task<Void, Never>?
    private var sizeObservation: AnyCancellable?
    var onClose: ((ShelfController) -> Void)?
    var onChange: (() -> Void)?
    var closeEmpty: () -> Bool = { Prefs.shared.closeEmpty }

    init(shelf: Shelf) {
        self.shelf = shelf
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: ShelfMetrics.width, height: ShelfMetrics.height),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        host = ShelfHost(rootView: AnyView(EmptyView()))
        super.init()
        panel.ctl = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        host.shelf = shelf
        host.sizingOptions = []
        host.rootView = AnyView(ShelfView(shelf: shelf, ctl: self).frame(maxHeight: .infinity, alignment: .top))
        panel.contentView = host
        shelf.onChange = { [weak self] in self?.onChange?() }
        sizeObservation = shelf.$dropTargeted.removeDuplicates().dropFirst().sink { [weak self] targeted in
            guard let self else { return }
            var rect = panel.frame
            let top = rect.maxY
            rect.size.height = ShelfMetrics.height + (targeted ? 8 : 0); rect.origin.y = top - rect.height
            if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.setFrame(rect, display: false); return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28; context.allowsImplicitAnimation = true; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(rect, display: true)
            }
        }
        host.layoutSubtreeIfNeeded()
    }

    private func present() {
        closing?.cancel()
        shelf.refreshAvailability()
        panel.orderFrontRegardless()
        shelf.presented = true
    }

    // MARK: Placing

    private func screen(at point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Centre the shelf on the pointer, kept on screen.
    func show(near point: NSPoint) {
        shelf.edge = nil
        let visible = screen(at: point).visibleFrame
        var origin = NSPoint(x: point.x - panel.frame.width / 2, y: point.y - panel.frame.height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
        present()
    }

    /// Slide in from a screen edge.
    func slideIn(from edge: ShelfEdge, screenAt point: NSPoint) {
        shelf.edge = edge
        let f = screen(at: point).frame
        let y = f.midY - panel.frame.height / 2
        let docked = NSPoint(x: edge == .left ? f.minX : f.maxX - panel.frame.width, y: y)
        let hidden = NSPoint(x: edge == .left ? f.minX - panel.frame.width : f.maxX, y: y)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrameOrigin(reduce ? docked : hidden)
        present()
        guard !reduce else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(docked)
        }
    }

    /// Where a saved frame goes now: moved fully inside the visible area of the screen it overlaps most, nil when no screen has it.
    static func restoredOrigin(_ frame: CGRect, visibleFrames: [CGRect]) -> CGPoint? {
        func overlap(_ r: CGRect) -> CGFloat { let i = r.intersection(frame); return i.isNull ? 0 : i.width * i.height }
        guard let area = visibleFrames.max(by: { overlap($0) < overlap($1) }), overlap(area) > 0 else { return nil }
        return CGPoint(x: min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width)),
                       y: min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height)))
    }

    func restore(frame: CGRect?) {
        if let frame, let origin = Self.restoredOrigin(frame, visibleFrames: NSScreen.screens.map(\.visibleFrame)) { panel.setFrameOrigin(origin) }
        else { show(near: NSEvent.mouseLocation); return }
        present()
    }

    var isShown: Bool { panel.isVisible }

    // MARK: Actions

    func close() {
        closing?.cancel()
        shelf.presented = false
        shelf.restorationNote = nil
        shelf.expanded = false; shelf.hovered = nil; shelf.dropTargeted = false
        closing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            panel.orderOut(nil)
            if shelf.items.isEmpty { onClose?(self) } else { onChange?() }
        }
    }

    func clear() { shelf.clear(); close() }
    func remove(_ item: ShelfItem) {
        shelf.remove([item.id], trashSaved: true)
        if shelf.items.isEmpty && closeEmpty() { close() }
    }
    func open(_ item: ShelfItem) { if item.available { NSWorkspace.shared.open(item.url) } }
    func reveal(_ item: ShelfItem) { if item.available { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
    func copy(_ item: ShelfItem) {
        guard item.available else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item.url as NSURL])
    }
    func quickLook(_ item: ShelfItem) { if item.available { QuickLook.shared.toggle(shelf.availableURLs, selected: item.url) } }
    private var hovered: ShelfItem? { shelf.items.first { $0.id == shelf.hovered } }
    func removeHovered() { if let item = hovered { remove(item) } }
    func openHovered() { if let item = hovered { open(item) } }
    func quickLookHovered() {
        if let id = shelf.hovered, let item = shelf.items.first(where: { $0.id == id }) { quickLook(item) }
    }
    func share(_ item: ShelfItem) {
        guard item.available, let view = panel.contentView else { return }
        let p = panel.mouseLocationOutsideOfEventStream
        NSSharingServicePicker(items: [item.url]).show(relativeTo: NSRect(x: p.x, y: p.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    func menu(for item: ShelfItem) -> NSMenu {
        let menu = NSMenu()
        for command in LedgeCommand.file {
            guard let command else { menu.addItem(.separator()); continue }
            menu.addItem(BlockItem(command.rawValue) { [weak self] in
                switch command {
                case .preview: self?.quickLook(item)
                case .copy: self?.copy(item)
                case .reveal: self?.reveal(item)
                case .share: self?.share(item)
                case .remove: self?.remove(item)
                default: break
                }
            })
        }
        return menu
    }

    /// A drag out of the shelf ended. A completed plain drag takes the items off the shelf; Option keeps them.
    /// Dropping back onto the shelf itself is not a drag out.
    static func removesAfterDrag(_ operation: NSDragOperation, optionHeld: Bool, endedAt point: NSPoint, panel: CGRect) -> Bool {
        operation != [] && !optionHeld && !panel.contains(point)
    }

    func dragEnded(ids: Set<UUID>, _ operation: NSDragOperation, _ optionHeld: Bool) {
        guard Self.removesAfterDrag(operation, optionHeld: optionHeld, endedAt: NSEvent.mouseLocation, panel: panel.frame) else { return }
        shelf.remove(ids, trashSaved: false)
        if shelf.items.isEmpty && closeEmpty() { close() }
    }

    // MARK: Drops

    func ingestOriginalImages(from pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return false }
        return Self.ingest(items, on: shelf, batch: DropBatch(count: items.count)) {
            pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        }
    }

    static func ingest(_ items: [NSPasteboardItem], on shelf: Shelf, batch: DropBatch, itemsDir: URL = Saver.itemsDir,
                       receivers: () -> [NSFilePromiseReceiver]) -> Bool {
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        guard items.contains(where: { item in
            !item.types.contains(.fileURL) && (item.types.contains { Saver.DroppedImage.formats[$0.rawValue] != nil } ||
                !promiseTypes.isDisjoint(with: item.types))
        }) else { return false }
        var promises = receivers().makeIterator()
        var destination: URL?
        for item in items {
            let receiver = promiseTypes.isDisjoint(with: item.types) ? nil : promises.next()
            if let file = item.string(forType: .fileURL).flatMap(URL.init(string:)), file.isFileURL {
                batch.finish(file, on: shelf); continue
            }
            let image = Saver.DroppedImage(item)
            if let receiver {
                if destination == nil { destination = try? Saver.newFolder(in: itemsDir) }
                if let destination {
                    receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { file, error in
                        let url = error == nil ? try? Saver.keepPromisedFile(file, from: destination, in: itemsDir) : nil
                        MainActor.assumeIsolated { batch.land(url ?? (try? image?.save(in: itemsDir)), on: shelf, saved: true) }
                    }
                    batch.finish(nil, on: shelf)
                    continue
                }
            }
            if let image {
                batch.finish(try? image.save(), on: shelf, saved: true)
            } else if let link = item.string(forType: .URL).flatMap(URL.init(string:)) {
                batch.finish(try? Saver.saveLink(link), on: shelf, saved: true)
            } else if let text = item.string(forType: .string), !text.isEmpty {
                batch.finish(try? Saver.saveText(text), on: shelf, saved: true)
            } else { batch.finish(nil, on: shelf) }
        }
        return true
    }

    func ingest(_ providers: [NSItemProvider]) {
        let shelf = self.shelf
        let batch = DropBatch(count: providers.count)
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    Task { @MainActor in batch.finish(url, on: shelf) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                    let data = (image as? NSImage)?.tiffRepresentation
                    Task { @MainActor in
                        let url = data.flatMap(NSImage.init(data:)).flatMap { try? Saver.saveImage($0) }
                        batch.finish(url, on: shelf, saved: true)
                    }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = p.loadObject(ofClass: URL.self) { link, _ in
                    Task { @MainActor in batch.finish(link.flatMap { try? Saver.saveLink($0) }, on: shelf, saved: true) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    Task { @MainActor in
                        let url = text.flatMap { $0.isEmpty ? nil : try? Saver.saveText($0) }
                        batch.finish(url, on: shelf, saved: true)
                    }
                }
            } else { batch.finish(nil, on: shelf) }
        }
    }
}
