import SwiftUI
import AppKit
import OrbCore

@main
struct ORBApp: App {
    @StateObject private var model = AppModel()
    init() {
        if let p = UserDefaults.standard.string(forKey: "modelsDir"), !p.isEmpty {
            Paths.override = URL(fileURLWithPath: p, isDirectory: true)
        }
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .frame(minWidth: 820, minHeight: 760)
                .background(T.bg)
                .preferredColorScheme(.dark)
                .task { await model.boot() }
        }
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsView().environmentObject(model).preferredColorScheme(.dark)
        }
    }
}
