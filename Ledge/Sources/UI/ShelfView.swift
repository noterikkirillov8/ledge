import SwiftUI
import UniformTypeIdentifiers

enum ShelfMetrics {
    static let width: CGFloat = 416
    static let height: CGFloat = 200
    static let amber = Color(hex: 0xE0A030)
    static let angles = [-6.0, 3, -2, 5]
}

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    weak var ctl: ShelfController?
    @Environment(\.displayScale) private var scale
    @State var page = 0
    @State private var displayedCount = 0
    @State var landing = false
    @State var copied = false
    @State private var zipping = false
    @State private var feedbackReset: Task<Void, Never>?
    @State private var actionError: String?
    @Environment(\.accessibilityReduceMotion) private var reduce
    private var count: Int { ctl == nil ? shelf.items.count : displayedCount }

    private var lastPage: Int { max(0, shelf.items.count - 1) / 4 }
    private var batch: [ShelfItem] {
        Array(shelf.items.reversed().dropFirst(min(page, lastPage) * 4).prefix(4).reversed())
    }
    private var active: ShelfItem? { batch.first { $0.id == shelf.hovered } ?? batch.last }
    private var spread: Bool { shelf.expanded && !shelf.dropTargeted && !landing }
    private var lit: Bool { shelf.dropTargeted || !shelf.items.isEmpty }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12) }

    var body: some View {
        if let ctl {
            ledge.onDrop(of: ShelfDrop.types, delegate: ShelfDrop(shelf: shelf, ctl: ctl))
                .ledgeEntrance(shelf.presented)
                .task(id: shelf.presented) {
                    guard shelf.presented, shelf.restorationNote != nil else { return }
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { shelf.restorationNote = nil }
                }
                .task(id: shelf.presented ? shelf.items.count : -1) {
                    guard shelf.presented else { displayedCount = 0; return }
                    let target = shelf.items.count
                    let stride = max(1, abs(target - displayedCount) / 5)
                    while !Task.isCancelled && displayedCount != target {
                        let delta = target - displayedCount
                        displayedCount += reduce ? delta : min(stride, abs(delta)) * delta.signum()
                        if displayedCount != target { try? await Task.sleep(for: .milliseconds(75)) }
                    }
                }
        } else { ledge }
    }

    private var ledge: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Ledge").font(KitFont.title)
                Text("\(count)").font(KitFont.number).foregroundStyle(KitColor.text2).kitRollingNumber(count)
                    .accessibilityLabel("\(count) items")
                Spacer()
                if !shelf.items.isEmpty { Button("Clear") { ctl?.clear() }.buttonStyle(.kitQuiet) }
                KitIconButton(symbol: "xmark", help: "Close shelf") { ctl?.close() }
            }.padding(.horizontal, 16).frame(height: 40)
            ZStack {
                if let newest = batch.last {
                    HStack {
                        Spacer().frame(width: 168)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(newest.name).font(KitFont.title).lineLimit(2).truncationMode(.middle).help(newest.name)
                            Text(newest.detail).font(KitFont.detail.monospacedDigit()).foregroundStyle(KitColor.text2)
                        }
                        Spacer(minLength: 16)
                    }.opacity(spread ? 0 : 1).allowsHitTesting(!spread)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: shelf.dropTargeted ? "arrow.down.to.line" : "square.2.layers.3d").font(.system(size: 24, weight: .medium))
                            .foregroundStyle(KitColor.text2)
                        Text(shelf.dropTargeted ? "Release to add" : "Drop files here").font(KitFont.bodyMedium).foregroundStyle(KitColor.text2)
                    }
                }
                ForEach(Array(batch.enumerated()), id: \.element.id) { index, item in
                    tile(item)
                        .rotationEffect(.degrees(spread || batch.count == 1 ? 0 : ShelfMetrics.angles[index]))
                        .offset(x: spread ? CGFloat(index * 98) - CGFloat(batch.count - 1) * 49 : -118 + (CGFloat(index) - CGFloat(batch.count - 1) / 2) * 14,
                                y: spread ? 0 : CGFloat(batch.count - index - 1) * -2)
                        .transition(reduce ? .opacity : .asymmetric(insertion: .offset(y: -24).combined(with: .opacity), removal: .kitRow))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let note = shelf.restorationNote {
                Text(note).font(KitFont.key).foregroundStyle(KitColor.text2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
            }
            if spread && !shelf.items.isEmpty {
                actionRow.transition(reduce ? .opacity : .opacity.combined(with: .offset(y: 3)))
            }
            HStack(spacing: 8) {
                if spread, let active {
                    Text(active.name).font(KitFont.bodyMedium).lineLimit(1).truncationMode(.middle).help(active.name)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        KitIconButton(symbol: "eye", help: "Quick Look") { ctl?.quickLook(active) }
                        KitIconButton(symbol: "folder", help: "Reveal in Finder") { ctl?.reveal(active) }
                        KitIconButton(symbol: "minus", help: "Remove from shelf") { ctl?.remove(active) }
                    }.transition(reduce ? .opacity : .opacity.combined(with: .offset(x: 4))).animation(KitMotion.soft, value: spread)
                } else {
                    if !shelf.items.isEmpty {
                        Text(shelf.dropTargeted ? "Release to add" : "Drag a file out").font(KitFont.key).foregroundStyle(KitColor.text2)
                    } else if shelf.dropTargeted {
                        Text("Original files stay in place").font(KitFont.key).foregroundStyle(KitColor.text2)
                    } else if ctl == nil || Prefs.shared.shortcut != nil {
                        Text("New shelf shortcut").font(KitFont.key).foregroundStyle(KitColor.text2)
                    }
                    Spacer()
                }
                if shelf.items.count > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.grid.2x2.fill"); Text("Drag all")
                    }.font(KitFont.key).padding(.horizontal, 8).frame(height: 26)
                        .background(KitColor.raised, in: RoundedRectangle(cornerRadius: 5))
                        .overlay { if ctl != nil { DragSource(urls: { shelf.items.map(\.url) }, onEnd: { ctl?.dragEnded(ids: Set(shelf.items.map(\.id)), $0, $1) }) } }
                }
                if spread && lastPage > 0 {
                    KitIconButton(symbol: "chevron.right", help: "Next four files") { page = (min(page, lastPage) + 1) % (lastPage + 1); shelf.hovered = nil }
                }
                if !lit, let shortcut = (ctl == nil ? Prefs.defaultShortcut : Prefs.shared.shortcut) {
                    Text(shortcut.display).font(KitFont.key).foregroundStyle(KitColor.text2)
                }
            }.padding(.horizontal, 16).frame(height: 40).background(KitColor.well)
        }
        .foregroundStyle(KitColor.text)
        .frame(width: ShelfMetrics.width, height: ShelfMetrics.height + (shelf.dropTargeted ? 8 : 0))
        .background(KitColor.window).overlay { shape.strokeBorder(KitColor.line, lineWidth: 1 / scale) }
        .overlay(alignment: .top) { Rectangle().fill(lit ? ShelfMetrics.amber : KitColor.unlit).frame(height: 2).padding(.horizontal, 8) }
        .clipShape(shape)
        .animation(reduce ? nil : KitMotion.snap, value: shelf.dropTargeted).animation(reduce ? nil : KitMotion.snap, value: spread)
        .animation(reduce ? KitMotion.soft : KitMotion.list, value: batch.map(\.id))
        .onChange(of: shelf.items.last?.id) { _, _ in page = 0 }
        .onChange(of: shelf.items.count) { old, new in if ctl != nil && new > old { landing = true } }
        .task(id: shelf.items.last?.id) {
            guard landing else { return }; try? await Task.sleep(for: .milliseconds(340))
            if !Task.isCancelled { landing = false }
        }
        .kitAccent(ShelfMetrics.amber)
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            Text(actionError ?? (shelf.items.count == 1 ? "1 item" : "All \(shelf.items.count) items"))
                .font(KitFont.key).foregroundStyle(KitColor.text2).lineLimit(1)
            Spacer(minLength: 4)
            Button { airDrop() } label: { Label("AirDrop", systemImage: "antenna.radiowaves.left.and.right") }
                .help("AirDrop the shelf contents")
            Button { zip() } label: { Label(zipping ? "Zipping" : "Zip", systemImage: "archivebox") }
                .disabled(zipping)
                .help("Create an archive beside the first item and add it to the shelf")
                .overlay(alignment: .bottom) {
                    if zipping { ArchiveActivity().padding(.horizontal, 12) }
                }
            Button { copyPaths() } label: {
                Label(copied ? "Copied" : "Copy path", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 92)
            }.help("Copy all paths, one per line")
        }.buttonStyle(.kitQuiet).padding(.leading, 16).padding(.trailing, 4)
            .animation(reduce ? nil : KitMotion.snap, value: copied)
    }

    private func feedback(_ error: String? = nil, copied confirmation: Bool = false) {
        feedbackReset?.cancel(); actionError = error; copied = confirmation
        feedbackReset = Task { @MainActor in
            try? await Task.sleep(for: .seconds(error == nil ? 1.4 : 3))
            guard !Task.isCancelled else { return }; actionError = nil; copied = false
        }
    }

    private func airDrop() {
        let urls = shelf.items.map(\.url)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            feedback("Unavailable"); return
        }
        service.perform(withItems: urls)
    }

    private func copyPaths() {
        let board = NSPasteboard.general
        board.clearContents()
        if board.setString(QuickActions.pathText(shelf.items.map(\.url)), forType: .string) { feedback(copied: true) }
        else { feedback("Copy failed") }
    }

    private func zip() {
        guard !zipping else { return }; zipping = true
        let urls = shelf.items.map(\.url)
        Task {
            defer { zipping = false }
            do {
                let archive = try await Task.detached(priority: .userInitiated) { try QuickActions.archive(urls) }.value
                if !shelf.add([archive]) { feedback("Not shelved") }
            } catch { feedback("Zip failed") }
        }
    }

    private func tile(_ item: ShelfItem) -> some View {
        ThumbnailCard(item: item, selected: spread && active?.id == item.id)
            .overlay {
                if ctl != nil {
                    DragSource(urls: { [item.url] }, onEnd: { ctl?.dragEnded(ids: [item.id], $0, $1) },
                               menu: { ctl?.menu(for: item) }, onHover: { inside in if inside { shelf.hovered = item.id } }, onOpen: { ctl?.open(item) })
                }
            }
            .accessibilityLabel(item.name).help(item.name)
    }
}

private struct ArchiveActivity: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var trailing = false

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(KitColor.line).overlay(alignment: .leading) {
                Capsule().fill(ShelfMetrics.amber).frame(width: geometry.size.width * 0.4)
                    .offset(x: trailing ? geometry.size.width * 0.6 : 0)
            }
        }.frame(height: 2).onAppear {
            if !reduce { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { trailing = true } }
        }.accessibilityHidden(true)
    }
}

struct ThumbnailCard: View {
    let item: ShelfItem
    let selected: Bool
    @Environment(\.displayScale) private var scale
    @Environment(\.colorScheme) private var scheme
    @State private var image: CGImage?
    private var kind: String { item.detail == "Folder" ? "DIR" : String(item.url.pathExtension.uppercased().prefix(8)) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                KitColor.raised
                if let preview = image ?? Thumbs.cached(item.url) {
                    Image(decorative: preview, scale: 2).resizable().scaledToFit()
                } else {
                    Image(systemName: item.detail == "Folder" ? "folder.fill" : "doc.text").foregroundStyle(KitColor.text2)
                }
            }.frame(height: 64)
            HStack {
                Text(kind.isEmpty ? "FILE" : kind).font(KitFont.header).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0); if selected { Capsule().fill(ShelfMetrics.amber).frame(width: 12, height: 2) }
            }.padding(.horizontal, 8).frame(height: 20).background(KitColor.well)
        }.frame(width: 84).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder((scheme == .dark ? Color.white : .black).opacity(0.12), lineWidth: 1 / scale) }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            .task(id: item.url) { image = await Thumbs.image(for: item.url) }
    }
}

/// Asks for file URLs first. With onDrop(of:) a Finder drag of an image or text file arrived as public.png or plain
/// text only, so the shelf saved a copy ("Image.png") instead of pointing at the original file.
struct ShelfDrop: DropDelegate {
    static let types = [UTType.fileURL, .image, .url, .plainText, UTType(importedAs: "public.webp")].map(\.identifier) +
        NSFilePromiseReceiver.readableDraggedTypes
    let shelf: Shelf
    let ctl: ShelfController

    func dropEntered(info: DropInfo) { shelf.dropTargeted = true }
    func dropExited(info: DropInfo) { shelf.dropTargeted = false }
    func performDrop(info: DropInfo) -> Bool {
        shelf.dropTargeted = false
        if ctl.ingestOriginalImages(from: NSPasteboard(name: .drag)) { return true }
        let files = info.itemProviders(for: [.fileURL])
        ctl.ingest(files.isEmpty ? info.itemProviders(for: Array(Self.types.dropFirst())) : files)
        return true
    }
}
