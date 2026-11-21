import AppKit

@MainActor enum PinchHandoff {
    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.erikkirillov.Pinch")
    }

    nonisolated static func images(in urls: [URL]) -> [URL] {
        let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp"]
        return urls.filter { url in
            url.isFileURL && extensions.contains(url.pathExtension.lowercased()) &&
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func send(_ urls: [URL], to shelf: Shelf) {
        guard Prefs.shared.pinchEnabled else { return }
        guard let applicationURL else { Prefs.shared.pinchEnabled = false; return }
        let cache = URL.cachesDirectory.appending(path: "Ledge/Pinch", directoryHint: .isDirectory)
        Task {
            await sendCopies(of: urls, to: shelf, cache: cache) { files in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try await NSWorkspace.shared.open(files, withApplicationAt: applicationURL, configuration: configuration)
            }
        }
    }

    static func sendCopies(of urls: [URL], to shelf: Shelf, cache: URL, open: ([URL]) async throws -> Void) async {
        let copies = await Task.detached {
            images(in: urls).compactMap { source -> (URL, URL)? in
                guard let folder = try? Saver.newFolder(in: cache) else { return nil }
                let copy = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (optimised)." + source.pathExtension)
                guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil,
                      let values = try? copy.resourceValues(forKeys: [.isRegularFileKey, .isAliasFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isAliasFile == false, values.isSymbolicLink == false else { return nil }
                return (source, copy)
            }
        }.value
        guard !copies.isEmpty else { return }
        do { try await open(copies.map(\.1)) } catch { return }
        for (source, copy) in copies {
            guard let index = shelf.items.firstIndex(where: { $0.url == source }), let item = ShelfItem(url: copy, saved: true) else { continue }
            shelf.items.insert(item, at: index + 1)
        }
        shelf.onChange?()
    }
}

@MainActor final class DropBatch {
    private var remaining: Int
    private var didLand = false
    private var files: [URL] = []
    private let sound: @MainActor () -> Void
    private let handoff: @MainActor ([URL], Shelf) -> Void

    init(count: Int, sound: @escaping @MainActor () -> Void = { KitSound.play(.drop) }, handoff: @escaping @MainActor ([URL], Shelf) -> Void = PinchHandoff.send) {
        remaining = count; self.sound = sound; self.handoff = handoff
    }

    func land(_ url: URL?, on shelf: Shelf, saved: Bool) {
        if let url, shelf.add([url], saved: saved) {
            if !didLand { didLand = true; sound() }
            if !saved { files.append(url) }
        }
    }

    func finish(_ url: URL?, on shelf: Shelf, saved: Bool = false) {
        land(url, on: shelf, saved: saved)
        remaining -= 1
        if remaining == 0, !files.isEmpty { handoff(files, shelf) }
    }
}
