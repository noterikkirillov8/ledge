import AppKit
import QuickLookThumbnailing
import QuickLookUI
import ImageIO
import CoreText

enum Perf {
    static let enabled = CommandLine.arguments.contains("-perf")
    static func log(_ operation: String, since start: CFTimeInterval) {
        if enabled { print(String(format: "[perf] %@ %.2f ms", operation, (CACurrentMediaTime() - start) * 1000)) }
    }
}

@MainActor enum Thumbs {
    private static let cache: NSCache<NSURL, CGImage> = {
        let result = NSCache<NSURL, CGImage>(); result.totalCostLimit = 24 * 1024 * 1024; return result
    }()
    private static var pending: [URL: Task<CGImage?, Never>] = [:]
    static func cached(_ url: URL) -> CGImage? { cache.object(forKey: url as NSURL) }
    static func image(for url: URL) async -> CGImage? {
        let start = CACurrentMediaTime()
        if let image = cached(url) { Perf.log("thumbnail cached", since: start); return image }
        if let existing = pending[url] { return await existing.value }
        let task = Task.detached(priority: .userInitiated) { await generate(url) }
        pending[url] = task
        let result = await task.value
        if let result { cache.setObject(result, forKey: url as NSURL, cost: result.bytesPerRow * result.height) }
        pending[url] = nil
        Perf.log("thumbnail " + (url.pathExtension.isEmpty ? "directory" : url.pathExtension), since: start)
        return result
    }

    nonisolated private static func generate(_ url: URL) async -> CGImage? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return folderCard() }
        let suffix = url.pathExtension.lowercased()
        let known = ["pdf", "png", "jpg", "jpeg", "heic", "webp", "tiff", "gif", "swift"].contains(suffix)
        let type = known ? nil : (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf",
           let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) {
            let box = page.getBoxRect(.cropBox)
            let scale = 224 / max(1, box.width, box.height)
            let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
            if let context = bitmap(width, height) {
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
                context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(page); return context.makeImage()
            }
        }
        if type?.conforms(to: .image) == true || ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"].contains(url.pathExtension.lowercased()),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 224] as CFDictionary) { return image }
        if type?.conforms(to: .sourceCode) == true || url.pathExtension == "swift",
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let bytes = try? handle.read(upToCount: 2048), let image = sourceCard(String(decoding: bytes, as: UTF8.self)) { return image }
        }
        if type?.conforms(to: .directory) != true {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 112, height: 112), scale: 2, representationTypes: .all)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { return rep.cgImage }
        }
        return NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    nonisolated private static func bitmap(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    nonisolated private static func folderCard() -> CGImage? {
        guard let context = bitmap(224, 168) else { return nil }
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ radius: CGFloat, _ color: CGColor) {
            context.setFillColor(color); context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil)); context.fillPath()
        }
        let blue = CGColor(red: 0.22, green: 0.42, blue: 0.55, alpha: 1)
        rect(30, 29, 164, 98, 9, blue); rect(30, 108, 72, 29, 8, blue)
        rect(40, 42, 144, 75, 4, CGColor(gray: 0.85, alpha: 1))
        rect(27, 26, 170, 83, 9, CGColor(red: 0.46, green: 0.66, blue: 0.75, alpha: 1))
        rect(43, 81, 45, 7, 2, blue); return context.makeImage()
    }

    nonisolated private static func sourceCard(_ text: String) -> CGImage? {
        guard let context = CGContext(data: nil, width: 224, height: 168, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: 0.12, green: 0.16, blue: 0.2, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 224, height: 168))
        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        for (index, line) in text.components(separatedBy: .newlines).prefix(9).enumerated() {
            let color = index == 0 ? CGColor(red: 0.98, green: 0.72, blue: 0.48, alpha: 1) : CGColor(red: 0.62, green: 0.8, blue: 0.82, alpha: 1)
            let string = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
            context.textPosition = CGPoint(x: 10, y: 145 - index * 19); CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        return context.makeImage()
    }
}

@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func toggle(_ urls: [URL], selected: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = urls.firstIndex(of: selected) ?? 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}

enum LedgeCommand: String {
    case newShelf = "New shelf", showShelves = "Show shelves", settings = "Settings…", intro = "Show intro", quit = "Quit Ledge"
    case preview = "Quick Look", copy = "Copy", reveal = "Reveal in Finder", share = "Share…", remove = "Remove from shelf"
    static let status: [Self?] = [.newShelf, .showShelves, nil, .settings, .intro, nil, .quit]
    static let file: [Self?] = [.preview, .copy, .reveal, .share, nil, .remove]
    var key: String { self == .settings ? "," : self == .quit ? "q" : "" }
}

final class BlockItem: NSMenuItem {
    private let block: () -> Void
    init(_ title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { block() }
}
