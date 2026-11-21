import AppKit
import UniformTypeIdentifiers

/// Turns dropped text, images and links into real files under Application Support/Ledge/Items.
enum Saver {
    static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ledge", isDirectory: true)
    static var itemsDir: URL { supportDir.appendingPathComponent("Items", isDirectory: true) }

    /// Each saved file gets its own folder so names never collide.
    static func newFolder(in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func slot(_ dir: URL, _ name: String) throws -> URL { try newFolder(in: dir).appendingPathComponent(name) }

    static func sanitize(_ s: String, fallback: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let clean = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            .drop { $0 == "." }.description   // a leading dot would make the saved file hidden in Finder
        return clean.isEmpty ? fallback : String(clean.prefix(40))
    }

    static func saveText(_ text: String, in dir: URL = itemsDir) throws -> URL {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let url = try slot(dir, sanitize(first, fallback: "Text") + ".txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func saveImage(_ image: NSImage, in dir: URL = itemsDir) throws -> URL {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let url = try slot(dir, "Image.png")
        try png.write(to: url)
        return url
    }

    struct DroppedImage {
        static let formats = ["public.jpeg": ["jpg", "jpeg", "jpe", "jfif"], "public.png": ["png"],
                              "public.webp": ["webp"], UTType.webP.identifier: ["webp"], "public.heic": ["heic"]]
        let data: Data
        let filename: String?

        init?(_ item: NSPasteboardItem) {
            let source = item.string(forType: .URL).flatMap(URL.init(string:))?.lastPathComponent
            let names = [source, item.string(forType: NSPasteboard.PasteboardType("public.url-name"))]
                .compactMap { $0 }.map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty && $0 != "/" }
            let formats = Self.formats
            let originals = item.types.filter { formats[$0.rawValue] != nil }
            func matches(_ name: String, _ flavor: NSPasteboard.PasteboardType) -> Bool {
                formats[flavor.rawValue]?.contains((name as NSString).pathExtension.lowercased()) == true
            }
            let preferred = names.compactMap { name in originals.first { matches(name, $0) } }
            for flavor in preferred + originals.filter({ !preferred.contains($0) }) {
                guard let ext = formats[flavor.rawValue]?.first, let bytes = item.data(forType: flavor), !bytes.isEmpty else { continue }
                let stem = names.first.map { ($0 as NSString).deletingPathExtension } ?? "Image"
                filename = names.first { matches($0, flavor) } ?? ((stem.isEmpty ? "Image" : stem) + "." + ext)
                data = bytes
                return
            }
            for flavor in item.types where NSImage.imageTypes.contains(flavor.rawValue) {
                if let bytes = item.data(forType: flavor), !bytes.isEmpty {
                    data = bytes; filename = nil; return
                }
            }
            return nil
        }

        func save(in dir: URL = Saver.itemsDir) throws -> URL {
            if let filename {
                let url = try Saver.slot(dir, filename)
                try data.write(to: url)
                return url
            }
            guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            return try Saver.saveImage(image, in: dir)
        }
    }

    static func keepPromisedFile(_ url: URL, from folder: URL, in dir: URL = itemsDir) throws -> URL {
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { throw CocoaError(.fileReadInvalidFileName) }
        let destination = try slot(dir, url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func saveLink(_ link: URL, in dir: URL = itemsDir) throws -> URL {
        let url = try slot(dir, sanitize(link.host ?? link.absoluteString, fallback: "Link") + ".webloc")
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    static func systemTrash(_ url: URL) throws { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    /// Only ever trashes files inside Ledge's own Items folder.
    static func trashIfOurs(_ url: URL, itemsDir: URL = itemsDir, trash: (URL) throws -> Void = systemTrash) {
        guard url.standardizedFileURL.path.hasPrefix(itemsDir.standardizedFileURL.path + "/") else { return }
        let folder = url.deletingLastPathComponent()
        try? trash(folder)
    }

    /// Only unused, expired Ledge slots go to the Trash.
    static func prune(keeping urls: [URL], itemsDir: URL = itemsDir, olderThan age: TimeInterval = 7 * 86400, trash: (URL) throws -> Void = systemTrash) {
        let kept = urls.map { $0.standardizedFileURL.path }
        let folders = (try? FileManager.default.contentsOfDirectory(at: itemsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let path = folder.standardizedFileURL.path
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true,
                  !kept.contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }) else { continue }
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            if Date.now.timeIntervalSince(date) > age { try? trash(folder) }
        }
    }
}
