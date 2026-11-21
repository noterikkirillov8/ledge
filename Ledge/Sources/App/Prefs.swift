import AppKit

enum EdgeMode: String, CaseIterable { case off, left, right
    var edge: ShelfEdge? { self == .left ? .left : (self == .right ? .right : nil) }
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d: UserDefaults
    static let defaultShortcut = KitHotKey(keyCode: 37, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, display: "⌃⌥L")
    static let retentionRange = 1...90
    @Published var shortcut: KitHotKey? { didSet { d.set(try? JSONEncoder().encode(shortcut), forKey: "shelfShortcut") } }
    @Published var pinchEnabled: Bool { didSet { d.set(pinchEnabled, forKey: "pinchEnabled") } }
    @Published var retentionDays: Int { didSet { d.set(retentionDays, forKey: "retentionDays") } }

    @Published var shake: Bool { didSet { d.set(shake, forKey: "shake") } }
    @Published var edgeMode: EdgeMode { didSet { d.set(edgeMode.rawValue, forKey: "edge") } }
    @Published var closeEmpty: Bool { didSet { d.set(closeEmpty, forKey: "closeEmpty") } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: ["shake": true, "edge": "off", "closeEmpty": true, "retentionDays": 7])
        if let data = d.data(forKey: "shelfShortcut") {
            do { shortcut = try JSONDecoder().decode(KitHotKey?.self, from: data) } catch { shortcut = Self.defaultShortcut }
        } else { shortcut = Self.defaultShortcut }
        pinchEnabled = d.bool(forKey: "pinchEnabled")
        retentionDays = min(Self.retentionRange.upperBound, max(Self.retentionRange.lowerBound, d.integer(forKey: "retentionDays")))
        shake = d.bool(forKey: "shake")
        edgeMode = EdgeMode(rawValue: d.string(forKey: "edge") ?? "") ?? .off
        closeEmpty = d.bool(forKey: "closeEmpty")
    }
}
