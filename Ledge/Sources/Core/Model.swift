import AppKit

enum ShelfEdge: String, Codable, CaseIterable { case left, right }

struct ItemRecord: Codable, Hashable {
    var id: UUID
    var bookmark: Data
    var saved: Bool          // a file Ledge made itself (dropped text, image or link)
}

struct ShelfRecord: Codable {
    var id: UUID
    var items: [ItemRecord]
    var frame: CGRect?
    var visible: Bool
    var edge: ShelfEdge?
}

enum Bookmark {
    static func make(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, stale)
    }
}

extension Bookmark {
    enum Status { case found(URL, stale: Bool), unmounted(URL), gone }

    /// `unmounted` is a file whose volume is simply not connected right now: it must be kept, not forgotten.
    static func status(_ data: Data, volumeMounted: (URL) -> Bool = defaultVolumeMounted) -> Status {
        if let found = resolve(data) { return .found(found.url, stale: found.stale) }
        guard let path = (try? URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data))?.path else { return .gone }
        let url = URL(fileURLWithPath: path)
        return volumeMounted(url) ? .gone : .unmounted(url)
    }

    /// Anything under /Volumes/NAME needs /Volumes/NAME to exist; everything else lives on the startup volume.
    static func defaultVolumeMounted(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }
}

struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var bookmark: Data
    let saved: Bool
    var detail: String
    var available = true             // false while the file's volume is not connected

    var name: String { url.lastPathComponent }

    init?(url: URL, saved: Bool = false, id: UUID = UUID(), bookmark: Data? = nil) {
        guard let data = bookmark ?? Bookmark.make(url) else { return nil }
        self.id = id; self.url = url; self.bookmark = data; self.saved = saved
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        var parts: [String] = []
        if values?.isDirectory == true { parts.append("Folder") }
        else if !url.pathExtension.isEmpty { parts.append(url.pathExtension.uppercased()) }
        if values?.isDirectory != true, let size = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        detail = parts.joined(separator: "  ")
    }

    init?(record: ItemRecord, trashDirectory: URL?, volumeMounted: (URL) -> Bool = Bookmark.defaultVolumeMounted) {
        let url: URL, stale: Bool
        switch Bookmark.status(record.bookmark, volumeMounted: volumeMounted) {
        case .found(let u, let s): url = u; stale = s
        case .unmounted(let u):
            self.init(url: u, saved: record.saved, id: record.id, bookmark: record.bookmark)
            detail = "Unavailable"; available = false
            return
        case .gone: return nil
        }
        var relationship = FileManager.URLRelationship.other
        let checked: Void?
        if let trashDirectory {
            checked = try? FileManager.default.getRelationship(&relationship, ofDirectoryAt: trashDirectory, toItemAt: url)
        } else {
            checked = try? FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: [], toItemAt: url)
        }
        guard checked == nil || relationship == .other else { return nil }
        self.init(url: url, saved: record.saved, id: record.id, bookmark: stale ? Bookmark.make(url) : record.bookmark)
    }

    var record: ItemRecord { ItemRecord(id: id, bookmark: bookmark, saved: saved) }
}

/// One shelf's content. References files, never copies them.
@MainActor
final class Shelf: ObservableObject, Identifiable {
    let id: UUID
    @Published var items: [ShelfItem]
    @Published var hovered: UUID?
    @Published var expanded = false
    @Published var presented = false
    @Published var restorationNote: String?
    @Published var edge: ShelfEdge?
    @Published var dropTargeted = false
    var onChange: (() -> Void)?
    var availableURLs: [URL] { items.filter(\.available).map(\.url) }

    /// Called when the shelf shows: items whose drive came back are live again, items truly gone are dropped.
    func refreshAvailability(volumeMounted: (URL) -> Bool = Bookmark.defaultVolumeMounted) {
        var changed = false
        for item in items where !item.available {
            guard let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
            switch Bookmark.status(item.bookmark, volumeMounted: volumeMounted) {
            case .unmounted: continue
            case .found: if let fresh = ShelfItem(record: item.record, trashDirectory: nil, volumeMounted: volumeMounted) { items[i] = fresh; changed = true }
            case .gone: items.remove(at: i); changed = true
            }
        }
        if changed { onChange?() }
    }

    init(id: UUID = UUID(), items: [ShelfItem] = [], edge: ShelfEdge? = nil) {
        self.id = id; self.items = items; self.edge = edge
    }

    convenience init(restoring record: ShelfRecord, trashDirectory: URL? = nil) {
        let items = record.items.compactMap { ShelfItem(record: $0, trashDirectory: trashDirectory) }
        self.init(id: record.id, items: items, edge: record.edge)
        let removed = record.items.count - items.count
        if removed > 0 {
            restorationNote = "\(removed) \(removed == 1 ? "item was" : "items were") removed (moved or deleted)"
        }
    }

    @discardableResult func add(_ urls: [URL], saved: Bool = false) -> Bool {
        let before = items.count
        for url in urls {
            let path = url.standardizedFileURL.path
            guard !items.contains(where: { $0.url.standardizedFileURL.path == path }),
                  let item = ShelfItem(url: url, saved: saved) else { continue }
            items.append(item)
        }
        onChange?()
        return items.count > before
    }

    /// Takes items off the shelf. Files are never deleted; only copies Ledge made itself go to the Trash.
    func remove(_ ids: Set<UUID>, trashSaved: Bool) {
        for item in items where ids.contains(item.id) && item.saved && trashSaved {
            Saver.trashIfOurs(item.url)
        }
        items.removeAll { ids.contains($0.id) }
        if let h = hovered, ids.contains(h) { hovered = nil }
        onChange?()
    }

    func clear() { remove(Set(items.map(\.id)), trashSaved: true) }
}

enum Persistence {
    static let file = Saver.supportDir.appendingPathComponent("shelves.json")

    static func load(_ file: URL = file) -> [ShelfRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([ShelfRecord].self, from: data)) ?? []
    }

    static func save(_ records: [ShelfRecord], to file: URL = file) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: file, options: .atomic) }
    }
}
