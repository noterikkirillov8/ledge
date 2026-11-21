import AppKit
import Carbon

/// `Ledge -selftest`: logic checks on scratch data under $TMPDIR. Exit code 0 when all pass.
@MainActor
enum SelfTest {
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        if !ok { failed += 1 }
    }

    static func runIfAsked() async -> Bool {
        guard CommandLine.arguments.contains("-selftest") else { return false }
        if let index = CommandLine.arguments.firstIndex(of: "-settings-proofs") {
            guard CommandLine.arguments.indices.contains(index + 1), NSApp == nil else { exit(2) }
            do {
                try QA.settingsProofs(URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
                check("settings proofs: no application or windows", NSApp == nil)
            } catch { check("settings proofs: \(error)", false) }
        } else if let index = CommandLine.arguments.firstIndex(of: "-render-proofs") {
            guard CommandLine.arguments.indices.contains(index + 1), NSApp == nil else { exit(2) }
            do {
                try await QA.run(URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true), introOnly: false, render: true)
                check("render: no application object, windows, or status item", NSApp == nil)
            } catch { check("render: \(error)", false) }
        } else { await run() }
        print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
        exit(failed == 0 ? 0 : 1)
    }

    private static func shakes(_ xs: [CGFloat], step: Double) -> Bool {
        var d = ShakeDetector()
        for (i, x) in xs.enumerated() where d.feed(x: x, t: Double(i) * step) { return true }
        return false
    }

    private static func testQuickActions() {
        let first = URL(fileURLWithPath: "/Survey/Field notes.pdf"), second = URL(fileURLWithPath: "/Survey/Ridge & valley.png")
        let archive = URL(fileURLWithPath: "/Survey/Archive.zip")
        let zip = QuickActions.zipCommand(source: first, output: archive)
        check("quick actions: ditto executable and literal zip arguments", zip.executable.path == "/usr/bin/ditto" && zip.arguments == ["-c", "-k", "--sequesterRsrc", "--keepParent", "/Survey/Field notes.pdf", "/Survey/Archive.zip"])
        check("quick actions: copy POSIX paths in order, one per line", QuickActions.pathText([first, second]) == "/Survey/Field notes.pdf\n/Survey/Ridge & valley.png" && QuickActions.pathText([]).isEmpty)
        check("quick actions: number archive collisions before extension", QuickActions.numbered(archive, 1) == archive && QuickActions.numbered(archive, 2).lastPathComponent == "Archive 2.zip")
    }

    static func run() async {
        testQuickActions()
        // Shake detector on fixture sequences.
        let zigzag: [CGFloat] = [0, 20, 45, 20, 0, 25, 50, 25, 0, 25, 50]
        check("shake: quick zigzag fires", shakes(zigzag, step: 0.04))
        check("shake: same zigzag slowly does not", !shakes(zigzag, step: 0.3))
        check("shake: straight drag does not", !shakes(Array(stride(from: 0, to: 800, by: 12)).map { CGFloat($0) }, step: 0.016))
        check("shake: one turn (drag and back) does not", !shakes(Array(stride(from: 0, to: 300, by: 15)).map { CGFloat($0) }
            + Array(stride(from: 300, to: 0, by: -15)).map { CGFloat($0) }, step: 0.016))
        check("shake: small jitter does not", !shakes((0..<60).map { CGFloat($0 % 2 == 0 ? 100 : 108) }, step: 0.016))
        check("shake: wide vigorous shake fires", shakes([0, 80, -10, 90, -20, 100], step: 0.06))

        // Edge hold.
        var e = EdgeHoldDetector()
        func feed(_ x: CGFloat, _ t: Double, _ allowed: ShelfEdge? = .left) -> ShelfEdge? {
            e.feed(x: x, minX: 0, maxX: 1000, t: t, allowed: allowed)
        }
        check("edge: not yet at 0.3 s", feed(1, 0) == nil && feed(1, 0.3) == nil)
        check("edge: fires at 0.4 s", feed(1, 0.41) == .left)
        check("edge: fires only once", feed(1, 0.6) == nil)
        e.reset()
        check("edge: leaving resets the clock", feed(1, 0) == nil && feed(300, 0.3) == nil && feed(1, 0.5) == nil && feed(1, 0.8) == nil)
        e.reset()
        check("edge: other edge ignored", feed(999, 0) == nil && feed(999, 1) == nil)
        e.reset()
        check("edge: right edge when allowed", feed(999, 0, .right) == nil && feed(999, 0.5, .right) == .right)
        e.reset()
        check("edge: off never fires", feed(1, 0, nil) == nil && feed(1, 2, nil) == nil)

        // Files, bookmarks, persistence.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledge-test-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let isolated = CommandLine.arguments.contains("-isolated-trash")
        let bin = root.appendingPathComponent("Test Trash", isDirectory: true)
        let trash: (URL) throws -> Void = { url in
            if isolated {
                try fm.createDirectory(at: bin, withIntermediateDirectories: true)
                try fm.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
            } else { try Saver.systemTrash(url) }
        }
        print(isolated ? "Trash backend: isolated recoverable directory (not native macOS Trash)" : "Trash backend: native macOS Trash")
        defer { if !isolated { try? fm.trashItem(at: root, resultingItemURL: nil) } }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt"), gone = root.appendingPathComponent("gone.txt")
        for u in [a, b, gone] { try? "x".write(to: u, atomically: true, encoding: .utf8) }

        let dropped = [a, b, a].map { url in
            let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item
        }
        let first = StatusDrop.shelf(from: dropped), second = StatusDrop.shelf(from: dropped)
        check("status drop: creates a new shelf with both file references in order", first?.items.map(\.url) == [a, b] && second?.items.map(\.url) == [a, b] && first?.id != second?.id)
        let plain = NSPasteboardItem(); plain.setString("Field notes", forType: .string)
        check("status drop: plain text does not create a shelf", StatusDrop.shelf(from: [plain]) == nil)
        let below = StatusDrop.frame(below: CGRect(x: -24, y: 880, width: 24, height: 24), within: CGRect(x: -1440, y: 0, width: 1440, height: 880))
        check("status drop: stays under the icon and inside its screen", below.maxX == -8 && below.maxY == 872)

        let shelf = Shelf()
        await testSettingsAndDrops(in: root)
        shelf.add([a, b, gone, a])
        check("shelf: adds files, ignores duplicates", shelf.items.count == 3)
        let record = ShelfRecord(id: shelf.id, items: shelf.items.map(\.record), frame: CGRect(x: 10, y: 20, width: 260, height: 140), visible: true, edge: .left)
        let file = root.appendingPathComponent("shelves.json")
        Persistence.save([record], to: file)
        let b2 = root.appendingPathComponent("renamed.txt")
        try? fm.moveItem(at: b, to: b2)
        try? fm.removeItem(at: gone)
        let loaded = Persistence.load(file)
        let restored = loaded.first.map { Shelf(restoring: $0) }
        let items = restored?.items ?? []
        check("persist: round trip keeps shelf id, edge, frame", loaded.first?.id == shelf.id && loaded.first?.edge == .left && loaded.first?.frame == record.frame)
        check("persist: bookmark follows a renamed file", items.contains { $0.url.lastPathComponent == "renamed.txt" })
        check("persist: vanished file is dropped", items.count == 2 && !items.contains { $0.name == "gone.txt" })
        check("restore: one missing file gives a singular note", restored?.restorationNote == "1 item was removed (moved or deleted)")
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let trashed = bin.appendingPathComponent(b2.lastPathComponent)
            try fm.moveItem(at: b2, to: trashed)
            let filtered = Shelf(restoring: record, trashDirectory: bin)
            check("restore: bookmark resolves inside fake Trash", Bookmark.resolve(record.items[1].bookmark)?.url.standardizedFileURL == trashed.standardizedFileURL)
            check("restore: trashed and deleted references removed with one note", filtered.items.map(\.id) == [record.items[0].id] && filtered.restorationNote == "2 items were removed (moved or deleted)" && fm.fileExists(atPath: trashed.path))
        } catch { check("restore: fake Trash fixture", false) }
        shelf.remove([shelf.items[0].id], trashSaved: true)
        check("shelf: removing from shelf keeps the file", fm.fileExists(atPath: a.path) && shelf.items.count == 2)

        // Saving dropped content.
        let dir = root.appendingPathComponent("Items", isDirectory: true)
        testPromisedDrop(in: dir)
        let text = try? Saver.saveText("Hello there\nsecond line", in: dir)
        check("save text: file named from first line with the text inside",
              text?.lastPathComponent == "Hello there.txt" && (try? String(contentsOf: text!, encoding: .utf8)) == "Hello there\nsecond line")
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor.orange.setFill(); r.fill(); return true }
        let png = try? Saver.saveImage(img, in: dir)
        check("save image: writes a PNG", png != nil && (try? Data(contentsOf: png!))?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        if let tiff = img.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg, properties: [:]) {
            let item = NSPasteboardItem()
            item.setData(tiff, forType: .tiff)
            if let preview = bitmap.representation(using: .png, properties: [:]) { item.setData(preview, forType: .png) }
            item.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
            item.setString("https://example.invalid/Dune%20study.jpeg?width=8", forType: .URL)
            let file = try? Saver.DroppedImage(item)?.save(in: dir)
            let saved = file.flatMap { try? Data(contentsOf: $0) }
            check("web image: original JPEG name, byte count and contents preserved",
                  file?.lastPathComponent == "Dune study.jpeg" && saved?.starts(with: [0xff, 0xd8]) == true && saved?.count == jpeg.count && saved == jpeg)
        } else { check("web image: create JPEG fixture", false) }
        let link = try? Saver.saveLink(URL(string: "https://example.com/page")!, in: dir)
        let plist = link.flatMap { try? Data(contentsOf: $0) }.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] }
        check("save link: .webloc holds the URL", link?.pathExtension == "webloc" && plist?["URL"] == "https://example.com/page")
        check("save text: slashes and empty names are cleaned", Saver.sanitize("a/b:c", fallback: "Text") == "a b c" && Saver.sanitize("  ", fallback: "Text") == "Text")

        let keepTrash = text!
        Saver.trashIfOurs(a, itemsDir: dir, trash: trash)
        check("trash: refuses files outside the Items folder", fm.fileExists(atPath: a.path))
        Saver.trashIfOurs(keepTrash, itemsDir: dir, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        check("trash: denied operation leaves saved bytes in place", (try? String(contentsOf: keepTrash, encoding: .utf8)) == "Hello there\nsecond line")
        Saver.trashIfOurs(keepTrash, itemsDir: dir, trash: trash)
        check("trash: moves Ledge's own copy to the Trash", !fm.fileExists(atPath: keepTrash.path))
        if isolated {
            let recovered = bin.appendingPathComponent(keepTrash.deletingLastPathComponent().lastPathComponent).appendingPathComponent(keepTrash.lastPathComponent)
            check("trash: original bytes recoverable in isolated bin", (try? String(contentsOf: recovered, encoding: .utf8)) == "Hello there\nsecond line")
        }

        // Pruning.
        let old = dir.appendingPathComponent(UUID().uuidString, isDirectory: true), used = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = dir.appendingPathComponent("Personal files", isDirectory: true)
        try? fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-30 * 86400)], ofItemAtPath: unrelated.path)
        for f in [old, used] { try? fm.createDirectory(at: f, withIntermediateDirectories: true); try? "x".write(to: f.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8) }
        try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-30 * 86400)], ofItemAtPath: old.path)
        try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(-30 * 86400)], ofItemAtPath: used.path)
        Saver.prune(keeping: [], itemsDir: dir, olderThan: 60 * 86400, trash: trash)
        check("retention: 60 days keeps month-old copies", fm.fileExists(atPath: old.path))
        Saver.prune(keeping: [used.appendingPathComponent("f.txt")], itemsDir: dir, trash: trash)
        check("prune: unused old folder trashed, referenced one kept", !fm.fileExists(atPath: old.path) && fm.fileExists(atPath: used.path))
        check("retention: unrelated folder left untouched", fm.fileExists(atPath: unrelated.path))
        introFlowChecks { check($1, $0) }
        if let samples = try? DemoFiles.items() {
            let tour = TourModel(items: samples); tour.select(.land)
            for beat in 0...6 { tour.apply(beat); check("intro: landing beat \(beat)", tour.shelf.items.count == min(4, max(0, beat - 1))) }
            tour.select(.fan); tour.apply(6); check("intro: fan selects PDF", tour.shelf.hovered == samples[2].id && tour.shelf.expanded)
            tour.select(.transfer); tour.apply(6); check("intro: drag-out only changes demo references", tour.shelf.items.count == 3 && samples.allSatisfy { fm.fileExists(atPath: $0.url.path) })
        } else { check("intro: bundled sample files", false) }
    }

    private static func testPromisedDrop(in dir: URL) {
        final class FakeReceiver: NSFilePromiseReceiver {
            override func receivePromisedFiles(atDestination destination: URL, options: [AnyHashable: Any] = [:],
                                               operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
                for name in ["Map.pdf", "Dune.heic"] {
                    let file = destination.appendingPathComponent(name)
                    do { try Data(name.utf8).write(to: file); reader(file, nil) }
                    catch { reader(file, error) }
                }
                reader(destination.appendingPathComponent("Cancelled.txt"), CocoaError(.userCancelled))
            }
        }
        let item = NSPasteboardItem(), shelf = Shelf()
        let type = NSFilePromiseReceiver.readableDraggedTypes[0]
        item.setData(Data(), forType: NSPasteboard.PasteboardType(type))
        var cues = 0
        let batch = DropBatch(count: 1, sound: { cues += 1 }, handoff: { _, _ in check("promise: no hand-off of saved copies", false) })
        let accepted = ShelfController.ingest([item], on: shelf, batch: batch, itemsDir: dir) { [FakeReceiver()] }
        check("promise: promise-only drop shelves original attachment and photo; skips cancelled file",
              ShelfDrop.types.contains(type) && accepted && cues == 1 && shelf.items.map(\.name) == ["Map.pdf", "Dune.heic"] &&
              shelf.items.allSatisfy { $0.saved && $0.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL &&
                  (try? Data(contentsOf: $0.url)) == Data($0.name.utf8) })
    }

    private static func testSettingsAndDrops(in root: URL) async {
        let domain = "Ledge.Test.\(UUID().uuidString)", fm = FileManager.default
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let prefs = Prefs(defaults: defaults)
        check("settings: default shortcut, seven days, optimiser off", prefs.shortcut == Prefs.defaultShortcut && prefs.retentionDays == 7 && !prefs.pinchEnabled)
        let shortcut = KitHotKey(keyCode: 12, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, display: "⇧⌘Q")
        prefs.shortcut = shortcut; prefs.pinchEnabled = true; prefs.retentionDays = 42
        let reload = Prefs(defaults: defaults)
        check("settings: recorded shortcut and shelf options survive reload", reload.shortcut == shortcut && reload.pinchEnabled && reload.retentionDays == 42)
        let combo = HotKeys.Combo(shortcut)
        check("shortcut: converts device-independent modifiers to Carbon", combo.keyCode == 12 && combo.modifiers == UInt32(cmdKey | shiftKey) && HotKeys.Combo(Prefs.defaultShortcut).modifiers == UInt32(controlKey | optionKey))
        prefs.shortcut = nil
        check("shortcut: cleared stays cleared", Prefs(defaults: defaults).shortcut == nil)
        check("sounds: all bundled CAF cues are readable", KitSound.allCases.allSatisfy { cue in
            Bundle.main.url(forResource: cue.rawValue, withExtension: "caf", subdirectory: "Sounds").flatMap { try? Data(contentsOf: $0) }?.starts(with: Data("caff".utf8)) == true
        })
        let images = ["PNG", "jpg", "JPEG", "heic", "gif", "webp"].map { root.appendingPathComponent("fixture." + $0) }
        let other = root.appendingPathComponent("notes.pdf"), folder = root.appendingPathComponent("folder.jpg", isDirectory: true)
        do {
            for file in images + [other] { try Data("fixture".utf8).write(to: file) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch { check("optimiser: create fixtures", false); return }
        let rejected = [other, folder, root.appendingPathComponent("missing.png"), URL(string: "https://example.invalid/photo.jpg")!]
        check("optimiser: six image types only; ignores folders, missing files and web URLs", PinchHandoff.images(in: rejected + images) == images)
        var sounds = 0, batches = [[URL]]()
        let shelf = Shelf()
        let batch = DropBatch(count: 6, sound: { sounds += 1 }, handoff: { urls, _ in batches.append(urls) })
        batch.finish(images[0], on: shelf); batch.finish(nil, on: shelf); batch.finish(images[0], on: shelf)
        batch.finish(images[1], on: shelf, saved: true); batch.finish(other, on: shelf); batch.finish(images[2], on: shelf)
        check("drop: one cue, one hand-off batch, no duplicates or generated copies", sounds == 1 && batches == [[images[0], other, images[2]]])
        let duplicate = DropBatch(count: 1, sound: { sounds += 1 }, handoff: { urls, _ in batches.append(urls) })
        duplicate.finish(images[0], on: shelf)
        check("drop: no sound or hand-off when nothing lands", sounds == 1 && batches.count == 1)
        let cache = root.appendingPathComponent("Pinch cache", isDirectory: true)
        var received = [URL]()
        await PinchHandoff.sendCopies(of: batches[0], to: shelf, cache: cache) { urls in
            received = urls
            for copy in urls {
                guard copy.path.hasPrefix(cache.path + "/"), try Data(contentsOf: copy) == Data("fixture".utf8) else { throw CocoaError(.fileReadCorruptFile) }
                try Data("optimised".utf8).write(to: copy)
            }
        }
        check("optimiser: receives cache copies, originals unchanged, results beside originals", received.count == 2 &&
              shelf.items.map(\.url) == [images[0], received[0], images[1], other, images[2], received[1]] &&
              received.allSatisfy { (try? Data(contentsOf: $0)) == Data("optimised".utf8) } &&
              images.allSatisfy { (try? Data(contentsOf: $0)) == Data("fixture".utf8) })
    }
}
