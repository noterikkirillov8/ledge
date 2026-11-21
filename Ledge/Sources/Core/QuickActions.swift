import Foundation

enum QuickActions {
    static func pathText(_ urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }

    static func zipCommand(source: URL, output: URL) -> (executable: URL, arguments: [String]) {
        (URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, output.path])
    }

    static func numbered(_ url: URL, _ number: Int) -> URL {
        guard number > 1 else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(stem) \(number)\(suffix)")
    }

    /// Beside the originals, except when the first item is one of Ledge's own saved copies: its folder is trashed with it,
    /// so the zip gets a folder of its own and counts as a saved copy itself.
    static func archiveDestination(for first: URL, itemsDir: URL = Saver.itemsDir) throws -> (parent: URL, saved: Bool) {
        guard first.standardizedFileURL.path.hasPrefix(itemsDir.standardizedFileURL.path + "/") else { return (first.deletingLastPathComponent(), false) }
        return (try Saver.newFolder(in: itemsDir), true)
    }

    static func archive(_ urls: [URL], into folder: URL? = nil) throws -> URL {
        guard let first = urls.first else { throw CocoaError(.fileNoSuchFile) }
        let files = FileManager.default
        let parent = folder ?? first.deletingLastPathComponent()
        let scratch = parent.appendingPathComponent(".ledge-\(UUID().uuidString)", isDirectory: true)
        let scratchPath = scratch.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard !urls.contains(where: { scratchPath.starts(with: $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents) }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: scratch) }
        var source = first
        if urls.count > 1 {
            source = scratch.appendingPathComponent("Archive", isDirectory: true)
            try files.createDirectory(at: source, withIntermediateDirectories: false)
            for url in urls {
                let base = source.appendingPathComponent(url.lastPathComponent)
                var number = 1
                while true {
                    do { try files.copyItem(at: url, to: numbered(base, number)); break }
                    catch CocoaError.fileWriteFileExists { number += 1 }
                }
            }
        }
        let output = scratch.appendingPathComponent("Archive.zip")
        let command = zipCommand(source: source, output: output)
        let process = Process()
        process.executableURL = command.executable; process.arguments = command.arguments
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        var number = 1
        while true {
            let destination = numbered(parent.appendingPathComponent("Archive.zip"), number)
            if renamex_np(output.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return destination }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            number += 1
        }
    }
}
