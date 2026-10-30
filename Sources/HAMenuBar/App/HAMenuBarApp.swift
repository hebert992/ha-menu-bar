import AppKit
import SwiftUI

@main
struct HAMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: HomeStore

    init() {
        let store = HomeStore(settings: SettingsStore())
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelRoot()
                .environment(store)
        } label: {
            Image(systemName: "house.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already hides the Dock icon in the bundle; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }
}
