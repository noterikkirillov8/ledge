import AppKit
import SwiftUI

extension EnvironmentValues { @Entry var ledgeProofFocus: String? = nil }

enum DemoFiles {
    static func items() throws -> [ShelfItem] {
        guard let folder = Bundle.main.url(forResource: "Survey sheets", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
        return try ([folder] + ["Transect.swift", "Field notes.pdf", "Contour study.png"].map { folder.appendingPathComponent($0) }).map { url in
            guard let item = ShelfItem(url: url) else { throw CocoaError(.fileReadUnknown) }; return item
        }
    }
}

@MainActor enum QA {
    static func run(_ dir: URL, introOnly: Bool, render: Bool) async throws {
        let pure = !CommandLine.arguments.contains("-qa")
        precondition(pure ? NSApp == nil : NSApp.activationPolicy() == .prohibited && NSApp.windows.allSatisfy { !$0.isVisible })
        if CommandLine.arguments.contains("-pinch-proofs") { try settingsProofs(dir); return }
        let items = try await Task.detached { try DemoFiles.items() }.value
        for item in items {
            guard await Thumbs.image(for: item.url) != nil else { throw CocoaError(.fileReadUnknown) }
        }
        _ = await Thumbs.image(for: items[3].url)
        let shelf = Shelf()
        if Perf.enabled {
            for count in [0, 4] {
                shelf.items = Array(items.prefix(count))
                func frame(_ shown: Bool) -> some View { ShelfView(shelf: shelf, ctl: nil).opacity(shown ? 1 : 0).environment(\.displayScale, 2) }
                let renderer = ImageRenderer(content: frame(false)); renderer.scale = 2
                let width = Int(ShelfMetrics.width * 2), height = Int(ShelfMetrics.height * 2)
                guard let buffer = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.coderInvalidValue) }
                buffer.setBlendMode(.copy)
                func centerAlpha() throws -> UInt8 {
                    guard let image = renderer.cgImage, let bytes = buffer.data else { throw CocoaError(.coderInvalidValue) }
                    buffer.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); buffer.flush()
                    return bytes.load(fromByteOffset: ((height / 2) * width + width / 2) * 4 + 3, as: UInt8.self)
                }
                for _ in 0..<5 {
                    // No check on the hidden frame: current macOS hands back the previous image for a retained renderer.
                    renderer.content = frame(false)
                    let start = CACurrentMediaTime()
                    renderer.content = frame(true)
                    guard try centerAlpha() > 0 else { throw CocoaError(.coderInvalidValue) }
                    Perf.log("headless show-to-first-frame (retained renderer, \(count) files, 2x bitmap)", since: start)
                }
            }
        }
        guard render else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !introOnly {
            let actions = Shelf(items: Array(items.suffix(2)))
            actions.expanded = true
            try snapshot(ShelfView(shelf: actions, ctl: nil), "06-quick-actions", dir, light: false)
            try snapshot(ShelfView(shelf: actions, ctl: nil, copied: true), "06-quick-actions-copied", dir, light: false)
            if CommandLine.arguments.contains("-quick-action-proofs") { return }
            if !CommandLine.arguments.contains("-restoration-proof") {
                try statusDropProofs(items, dir)
                if CommandLine.arguments.contains("-status-drop-proofs") { return }
            }
            let missing = (0..<2).map { _ in ItemRecord(id: UUID(), bookmark: Data(), saved: false) }
            let restored = Shelf(restoring: ShelfRecord(id: UUID(), items: [items[2].record] + missing, frame: nil, visible: true))
            try snapshot(ShelfView(shelf: restored, ctl: nil), "03-restoration-note", dir)
            if CommandLine.arguments.contains("-restoration-proof") { return }
            func scene(_ name: String, light: Bool? = nil) throws {
                try snapshot(ShelfView(shelf: shelf, ctl: nil), name, dir, light: light)
            }
            shelf.items = []; try scene("01-empty"); shelf.dropTargeted = true; try scene("02-drop-hover"); shelf.dropTargeted = false
            shelf.items = [items[3]]; try scene("03-one-item"); shelf.items = items; try scene("04-stack-of-4")
            shelf.expanded = true; shelf.hovered = items[2].id; try scene("05-fanned-out-hover")
            shelf.dropTargeted = true; try scene("05-loaded-drop"); shelf.dropTargeted = false
            let longURL = items[3].url.deletingLastPathComponent().appendingPathComponent("The Oriole Basin survey — western ridge elevation and rainfall comparison — final proofs.png")
            shelf.items = (0..<49).map { index in ShelfItem(url: items[index % 4].url, bookmark: items[index % 4].bookmark)! }
            shelf.items.append(ShelfItem(url: longURL, bookmark: Data())!)
            try scene("05-fifty-expanded"); shelf.expanded = false; try scene("05-fifty-stacked")
            shelf.expanded = true
            try snapshot(ShelfView(shelf: shelf, ctl: nil, page: 12), "05-last-page", dir)
            shelf.items = items
            try snapshot(ShelfView(shelf: shelf, ctl: nil, landing: true), "05-landing", dir)
            try snapshot(ShelfView(shelf: shelf, ctl: nil), "05-fan-1x", dir, scale: 1)
            try snapshot(EdgeStrip().frame(width: ShelfMetrics.width, height: ShelfMetrics.height, alignment: .trailing).background(KitColor.raised), "06-edge-right", dir, pad: 0)
            try snapshot(ZStack(alignment: .leading) {
                KitColor.raised
                VStack(alignment: .leading, spacing: 6) {
                    Text("Survey station").font(KitFont.key); Text("Field atlas").font(KitFont.title)
                }.foregroundStyle(KitColor.text2).padding(.leading, 40)
                EdgeStrip()
            }.frame(width: ShelfMetrics.width, height: ShelfMetrics.height), "06-edge-strip", dir, pad: 0)
            try settingsProofs(dir)
            try menuProof(LedgeCommand.status, "07-menu-bar", dir)
            try menuProof(LedgeCommand.file, "07-file-menu", dir)
            try snapshot(HStack(spacing: 16) {
                KitButtonBody(kind: .secondary, label: Text("Next"), pressed: false)
                KitButtonBody(kind: .secondary, label: Text("Next"), pressed: false, hover: true)
                KitButtonBody(kind: .secondary, label: Text("Next"), pressed: true, hover: true)
                KitButtonBody(kind: .secondary, label: Text("Next"), pressed: false).disabled(true)
            }.frame(width: 384).padding(16).background(KitColor.window), "09-button-states", dir, pad: 0)
            try snapshot(Path(LedgeMark.path).fill(KitColor.text).frame(width: 19, height: 18), "07-status-mark", dir, pad: 8)
            shelf.hovered = nil; shelf.expanded = false; try scene("08-stack-light", light: true)
        }
        let frames = dir.appendingPathComponent("intro", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for scene in TourScene.allCases {
            let demo = TourModel(items: items)
            demo.select(scene)
            for (beat, name) in ["start", "beat-1", "beat-2", "middle", "beat-4", "beat-5", "end"].enumerated() {
                demo.apply(beat)
                try snapshot(TourView(demo: demo, close: {}, advance: {}), "0\(scene.rawValue + 1)-\(scene)-\(name)", frames, pad: 0)
            }
            try snapshot(TourView(demo: demo, close: {}, advance: {}, previewReducedMotion: true), "0\(scene.rawValue + 1)-\(scene)-reduced", frames, pad: 0)
        }
        precondition(pure ? NSApp == nil : NSApp.windows.allSatisfy { !$0.isVisible })
        print("Rendered off-screen PNGs in \(dir.path)")
    }

    private static func statusDropProofs(_ items: [ShelfItem], _ dir: URL) throws {
        let pasteItems = items.suffix(2).map { item in
            let paste = NSPasteboardItem(); paste.setString(item.url.absoluteString, forType: .fileURL); return paste
        }
        guard let shelf = StatusDrop.shelf(from: pasteItems) else { throw CocoaError(.fileReadUnknown) }
        func icon(_ targeted: Bool) -> some View {
            Path(LedgeMark.path).fill(KitColor.text).frame(width: 19, height: 18)
                .overlay { StatusDropFill(targeted: targeted) }.frame(width: 24, height: 24)
        }
        for (targeted, name) in [(false, "idle"), (true, "over")] {
            try snapshot(icon(targeted), "07-status-drop-" + name, dir, light: false, pad: 8)
        }
        let visible = CGRect(x: 0, y: 0, width: ShelfMetrics.width + 32, height: ShelfMetrics.height + 24)
        let button = CGRect(x: visible.midX - 12, y: visible.maxY, width: 24, height: 24)
        let frame = StatusDrop.frame(below: button, within: visible)
        try snapshot(ZStack(alignment: .top) {
            icon(false).frame(maxWidth: .infinity).background(KitColor.window)
            ShelfView(shelf: shelf, ctl: nil).position(x: frame.midX, y: button.maxY - frame.midY)
        }.frame(width: visible.width, height: button.maxY), "07-status-drop-shelf", dir, light: false, pad: 0)
    }

    @MainActor static func settingsProofs(_ dir: URL) throws {
        let domain = "Ledge.Proofs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let prefs = Prefs(defaults: defaults), state = WindowState()
        func render(_ tab: SettingsTab, _ name: String, light: Bool? = nil, recording: Bool = false, focus: String? = nil) throws {
            let view = SettingsView(prefs: prefs, state: state, tab: .constant(tab), bitmapViewport: true, recordingShortcut: recording, setShortcut: { _ in }, showIntro: {})
            try snapshot(view.defaultAppStorage(defaults).environment(\.ledgeProofFocus, focus), name, dir, light: light, pad: 0)
        }
        try render(.pinch, "12-settings-optimiser")
        state.pinchInstalled = true
        try render(.pinch, "12-settings-optimiser-installed-off")
        prefs.pinchEnabled = true
        try render(.pinch, "12-settings-optimiser-installed-on")
        if CommandLine.arguments.contains("-pinch-proofs") { return }
        try render(.general, "10-settings-general")
        try render(.general, "10-settings-tab-focus", focus: "Shelf")
        try render(.shelf, "11-settings-shelf")
        try render(.about, "13-settings-about")
        try render(.general, "14-settings-light", light: true)
        defaults.set(0.05, forKey: KitSound.volumeKey)
        try render(.general, "10-settings-recording", recording: true)
        defaults.set(1.0, forKey: KitSound.volumeKey)
        try render(.general, "10-settings-full-volume")
        state.login = true; state.loginDetail = "Allow Ledge in System Settings → Login Items."
        state.shortcutDetail = "Shortcut unavailable. Record another combination."
        prefs.shortcut = nil; defaults.set(false, forKey: KitSound.enabledKey)
        try render(.general, "10-settings-attention")
        for (days, edge) in [(1, EdgeMode.left), (90, .right)] {
            prefs.retentionDays = days; prefs.edgeMode = edge; prefs.shake = false; prefs.closeEmpty = false
            try render(.shelf, "11-settings-\(days)-days")
        }
    }

    private static func menuProof(_ commands: [LedgeCommand?], _ name: String, _ dir: URL) throws {
        try snapshot(VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<commands.count, id: \.self) { index in
                if let command = commands[index] {
                    HStack { Text(command.rawValue); Spacer(); if !command.key.isEmpty { Text("⌘" + command.key.uppercased()).foregroundStyle(KitColor.text2) } }
                        .padding(.horizontal, 12).frame(height: 24)
                } else { KitDivider().padding(.vertical, 4) }
            }
        }.font(KitFont.body).foregroundStyle(KitColor.text).padding(4).frame(width: 192).background(KitColor.window, in: RoundedRectangle(cornerRadius: 8)), name, dir)
    }

    private static func snapshot<V: View>(_ view: V, _ name: String, _ dir: URL, light: Bool? = nil, pad: CGFloat = 24, scale: CGFloat = 2) throws {
        guard let light else {
            try snapshot(view, name, dir, light: false, pad: pad, scale: scale)
            try snapshot(view, name + "-light", dir, light: true, pad: pad, scale: scale)
            return
        }
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)!
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.padding(pad).background(light ? Color(hex: 0xD3D4D0) : Color(hex: 0x35373A))
                .environment(\.colorScheme, light ? .light : .dark).environment(\.displayScale, scale))
            renderer.scale = scale
            data = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        }
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: dir.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
