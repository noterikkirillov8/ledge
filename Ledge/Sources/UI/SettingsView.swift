import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable { case general = "General", shelf = "Shelf", pinch = "Optimiser", about = "About" }

@MainActor final class WindowState: ObservableObject {
    @Published var shown = false
    @Published var pinchInstalled = false
    @Published var login = false
    @Published var loginDetail: String?
    @Published var shortcutDetail: String?

    func refresh() {
        pinchInstalled = PinchHandoff.applicationURL != nil
        if !pinchInstalled && Prefs.shared.pinchEnabled { Prefs.shared.pinchEnabled = false }
        let status = SMAppService.mainApp.status
        login = status == .enabled || status == .requiresApproval
        loginDetail = status == .requiresApproval ? "Allow Ledge in System Settings → Login Items." : nil
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch { refresh(); loginDetail = error.localizedDescription }
    }
}

struct SettingsShell: View {
    @ObservedObject var state: WindowState
    @AppStorage("settingsTab") private var tab: SettingsTab = .general
    let setShortcut: (KitHotKey?) -> Void
    let showIntro: () -> Void

    var body: some View {
        SettingsView(prefs: .shared, state: state, tab: $tab, setShortcut: setShortcut, showIntro: showIntro)
            .ledgeEntrance(state.shown, anchor: .center)
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var state: WindowState
    @Binding var tab: SettingsTab
    var bitmapViewport = false
    var recordingShortcut = false
    let setShortcut: (KitHotKey?) -> Void
    let showIntro: () -> Void

    var body: some View {
        KitSettings(title: "Ledge settings", tabs: SettingsTab.allCases.map { ($0, $0.rawValue) }, selection: $tab, bitmapViewport: bitmapViewport) { selected in
            switch selected {
            case .general:
                KitSection(title: "Startup and shortcut") {
                    KitToggleRow(title: "Launch at login", detail: state.loginDetail, isOn: Binding(get: { state.login }, set: { state.setLogin($0) }))
                    KitRow(title: "New shelf shortcut", detail: state.shortcutDetail) {
                        KitHotKeyField(hotKey: Binding(get: { prefs.shortcut }, set: { setShortcut($0) }), recording: recordingShortcut)
                    }
                }
                KitSoundSection()
                KitSection {
                    KitRow(title: "Field guide") { Button("Show intro", action: showIntro).buttonStyle(.kitSecondary) }
                }
            case .shelf:
                KitSection(title: "Open the shelf") {
                    KitToggleRow(title: "Shake to open", detail: "Move a file left and right as you drag.", isOn: $prefs.shake)
                    KitRow(title: "Screen edge", detail: "Hold a file at this edge for 0.4 seconds.") {
                        KitSegmented(selection: $prefs.edgeMode, options: [(.off, "Off"), (.left, "Left"), (.right, "Right")]).frame(width: 160)
                    }
                }
                KitSection(title: "After a drop") {
                    KitToggleRow(title: "Close empty shelves", detail: "When you drag the last item out.", isOn: $prefs.closeEmpty)
                    KitRow(title: "Keep saved drops", detail: "Applies only to unused copies Ledge makes.") {
                        KitStepper(value: $prefs.retentionDays, range: Prefs.retentionRange, format: { $0 == 1 ? "1 day" : "\($0) days" })
                    }
                }
            case .pinch:
                KitSection(footer: "Supports PNG, JPEG, HEIC, GIF and WebP. Ledge never edits your originals.") {
                    KitToggleRow(title: "Optimise dropped images", detail: state.pinchInstalled ? "Keep a Pinch copy beside each original." : "Pinch isn't installed",
                                 isOn: Binding(get: { state.pinchInstalled && prefs.pinchEnabled }, set: { prefs.pinchEnabled = $0 }))
                        .disabled(!state.pinchInstalled)
                }
            case .about:
                KitAboutView(name: "Ledge", tagline: "A shelf for files on their way somewhere.", repoURL: URL(string: "https://github.com/noterikkirillov8/ledge"))
            }
        }
        .kitAccent(ShelfMetrics.amber)
    }
}
