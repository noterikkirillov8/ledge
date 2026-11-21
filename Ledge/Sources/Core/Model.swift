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

struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    var url: URL
    var bookmark: Data
    let saved: Bool
    let detail: String

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

    init?(record: ItemRecord, trashDirectory: URL?) {
        guard let (url, stale) = Bookmark.resolve(record.bookmark) else { return nil }
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
