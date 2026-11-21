import Carbon
import AppKit
import Combine
import SwiftUI

@main
enum Main {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        if await SelfTest.runIfAsked() { return }
        if args.contains(where: { ["-qa", "-intro-preview", "-perf"].contains($0) }) {
            if args.contains("-qa") { guard NSApplication.shared.setActivationPolicy(.prohibited) else { exit(1) } }
            let index = args.firstIndex(of: "-qa") ?? args.firstIndex(of: "-intro-preview")
            let dir = index.flatMap { args.dropFirst($0 + 1).first }.flatMap { $0.hasPrefix("-") ? nil : $0 }
            if args.contains("-qa"), dir == nil { print("Usage: -qa OUTPUT_DIRECTORY"); exit(2) }
            do { try await QA.run(dir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? URL(fileURLWithPath: "qa", isDirectory: true), introOnly: args.contains("-intro-preview"), render: index != nil) }
            catch { print("QA failed: \(error)"); exit(1) }
            return
        }
        launch()
    }

    @MainActor private static func launch() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor enum LedgeMark {
    static let diamond: CGPath = {
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: 4, y: 7)); outline.addLine(to: CGPoint(x: 9, y: 3)); outline.addLine(to: CGPoint(x: 15, y: 7)); outline.addLine(to: CGPoint(x: 9, y: 11)); outline.closeSubpath()
        return outline
    }()
    static let path: CGPath = {
        let mark = CGMutablePath(); mark.addPath(diamond.copy(strokingWithWidth: 1.5, lineCap: .round, lineJoin: .round, miterLimit: 1))
        mark.addRoundedRect(in: CGRect(x: 1, y: 13, width: 17, height: 2), cornerWidth: 1, cornerHeight: 1); return mark
    }()
    static let image: NSImage = {
        let path = LedgeMark.path
        let image = NSImage(size: NSSize(width: 19, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.addPath(path); context.fillPath(); return true
        }
        image.isTemplate = true; image.accessibilityDescription = "Ledge"
        return image
    }()
}

struct StatusDropFill: View {
    let targeted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Path(LedgeMark.diamond).fill(ShelfMetrics.amber).frame(width: 19, height: 18)
            .scaleEffect(targeted || reduce ? 1 : 0.65, anchor: UnitPoint(x: 9 / 19, y: 7 / 18))
            .opacity(targeted ? 1 : 0)
            .animation(reduce ? nil : KitMotion.snap, value: targeted)
    }
}

@MainActor enum StatusDrop {
    static func shelf(from items: [NSPasteboardItem]) -> Shelf? {
        let files = items.compactMap { $0.string(forType: .fileURL).flatMap(URL.init(string:)) }.filter(\.isFileURL)
        let shelf = Shelf()
        return shelf.add(files) ? shelf : nil
    }

    static func frame(below icon: CGRect, within visible: CGRect) -> CGRect {
        CGRect(x: min(max(visible.minX + 8, icon.midX - ShelfMetrics.width / 2), visible.maxX - ShelfMetrics.width - 8),
               y: min(icon.minY, visible.maxY) - 8 - ShelfMetrics.height, width: ShelfMetrics.width, height: ShelfMetrics.height)
    }
}

private final class StatusDropTarget: NSHostingView<StatusDropFill> {
    var enabled: () -> Bool = { false }
    var didDrop: (Shelf, CGRect, CGRect) -> Void = { _, _, _ in }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = enabled() && sender.draggingSourceOperationMask.contains(.copy) && sender.draggingPasteboard.types?.contains(.fileURL) == true
        if rootView.targeted != accepts { rootView = StatusDropFill(targeted: accepts) }
        return accepts ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { rootView = StatusDropFill(targeted: false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { rootView = StatusDropFill(targeted: false) }
        guard enabled(), let window, let screen = window.screen,
              let shelf = StatusDrop.shelf(from: sender.draggingPasteboard.pasteboardItems ?? []) else { return false }
        didDrop(shelf, window.convertToScreen(convert(bounds, to: nil)), screen.visibleFrame)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var tour: TourController?
    private var preparingTour = false
    private let settingsState = WindowState()
    private let watcher = DragWatcher()
    private let manager = ShelfManager.shared
    private var retentionObservation: AnyCancellable?

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        for command in LedgeCommand.status {
            guard let command else { menu.addItem(.separator()); continue }
            if command == .quit {
                menu.addItem(NSMenuItem(title: command.rawValue, action: #selector(NSApplication.terminate(_:)), keyEquivalent: command.key))
                continue
            }
            let item = BlockItem(command.rawValue) { [weak self] in
                switch command {
                case .newShelf: if self?.introBusy == false { _ = self?.manager.shelfNearPointer() }
                case .showShelves: if self?.introBusy == false { self?.manager.showAll() }
                case .settings: self?.showSettings()
                case .intro: self?.showIntro()
                default: break
                }
            }
            item.keyEquivalent = command.key; menu.addItem(item)
        }
        return menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = LedgeMark.image
            let target = StatusDropTarget(rootView: StatusDropFill(targeted: false))
            target.frame = button.bounds; target.autoresizingMask = [.width, .height]
            target.sizingOptions = []; target.setAccessibilityElement(false)
            button.addSubview(target); target.registerForDraggedTypes([.fileURL])
            target.enabled = { [weak self] in self?.introBusy == false }
            target.didDrop = { [weak self] shelf, icon, visible in
                guard let self else { return }
                manager.makeController(shelf).restore(frame: StatusDrop.frame(below: icon, within: visible))
                manager.persist()
            }
        }
        item.menu = statusMenu()
        statusItem = item

        if !registerShortcut(Prefs.shared.shortcut) { settingsState.shortcutDetail = "Shortcut unavailable. Record another combination." }
        watcher.onShake = { [weak self] _ in if self?.introBusy == false { _ = self?.manager.shelfNearPointer() } }
        watcher.onEdge = { [weak self] edge, point in if self?.introBusy == false { self?.manager.slideIn(edge, at: point) } }
        watcher.start()
        manager.restore()
        retentionObservation = Prefs.shared.$retentionDays.dropFirst().removeDuplicates().sink { [weak self] days in
            self?.manager.pruneSavedDrops(days: days)
        }
        manager.prepare()
        if !UserDefaults.standard.bool(forKey: "sawLedgeIntro") { showIntro() }
    }

    private func showIntro() {
        if let tour { tour.start(); return }
        guard !preparingTour else { return }; preparingTour = true
        Task {
            defer { preparingTour = false }
            guard let items = try? await Task.detached(operation: { try DemoFiles.items() }).value else { return }
            for item in items { _ = await Thumbs.image(for: item.url) }
            let controller = TourController(items: items) { UserDefaults.standard.set(true, forKey: "sawLedgeIntro") }
            tour = controller; controller.start()
        }
    }

    /// No shelf opens while the intro is showing or still loading.
    private var introBusy: Bool { preparingTour || tour?.isShowing == true }

    func applicationWillTerminate(_ notification: Notification) {
        if statusItem != nil { manager.persist() }
    }

    private func registerShortcut(_ shortcut: KitHotKey?) -> Bool {
        guard let shortcut else { HotKeys.shared.unregister(1); return true }
        return HotKeys.shared.register(1, .init(shortcut)) { [weak self] in if self?.introBusy == false { _ = self?.manager.shelfNearPointer() } }
    }

    private func setShortcut(_ shortcut: KitHotKey?) {
        if registerShortcut(shortcut) {
            Prefs.shared.shortcut = shortcut; settingsState.shortcutDetail = nil
        } else {
            _ = registerShortcut(Prefs.shared.shortcut)
            settingsState.shortcutDetail = "Shortcut unavailable. Try another combination."
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { settingsState.refresh() }

    private func showSettings() {
        settingsState.refresh()
        if settingsWindow == nil {
            let host = NSHostingView(rootView: SettingsShell(state: settingsState, setShortcut: { [weak self] in self?.setShortcut($0) }, showIntro: { [weak self] in self?.showIntro() }))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Ledge"
            w.titlebarAppearsTransparent = true
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsState.shown = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        settingsState.shown = false
        Task {
            try? await Task.sleep(for: .milliseconds(140))
            if !settingsState.shown { sender.orderOut(nil) }
        }
        return false
    }
}
