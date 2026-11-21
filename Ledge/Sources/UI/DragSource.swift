import AppKit
import SwiftUI

/// Transparent AppKit layer over a row: starts file drags (several files at once), double-click open,
/// right-click menu and hover. Hover is done here because SwiftUI's onHover is unreliable in a
/// non-activating panel.
struct DragSource: NSViewRepresentable {
    var urls: () -> [URL]
    var onEnd: (_ operation: NSDragOperation, _ optionHeld: Bool) -> Void
    var menu: (() -> NSMenu?)? = nil
    var onHover: ((Bool) -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    func makeNSView(context: Context) -> DragNSView { DragNSView() }
    func updateNSView(_ view: DragNSView, context: Context) { view.config = self }
}

final class DragNSView: NSView, NSDraggingSource {
    var config: DragSource?
    private var downPoint: NSPoint?
    private var dragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { config?.onHover?(true) }
    override func mouseExited(with event: NSEvent) { config?.onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragging = false
        if event.clickCount == 2 { config?.onOpen?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = downPoint, let urls = config?.urls(), !urls.isEmpty else { return }
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        dragging = true
        let origin = convert(event.locationInWindow, from: nil)
        let items = urls.prefix(6).enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = Thumbs.cached(url).map { NSImage(cgImage: $0, size: NSSize(width: 40, height: 40)) }
                ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
            let offset = CGFloat(index) * 4
            item.setDraggingFrame(NSRect(x: origin.x - 20 + offset, y: origin.y - 20 + offset, width: 40, height: 40), contents: icon)
            return item
        }
        // Items beyond the sixth still travel with the drag; they just get no extra picture.
        let rest = urls.dropFirst(6).map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: origin.x, y: origin.y, width: 1, height: 1), contents: nil)
            return item
        }
        beginDraggingSession(with: items + rest, event: event, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { config?.menu?() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        config?.onEnd(operation, NSEvent.modifierFlags.contains(.option))
    }
}
