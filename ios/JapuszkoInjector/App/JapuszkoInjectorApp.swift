import SwiftUI

// Started from main.swift (which may hand the process to a guest first).
struct JapuszkoInjectorApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(AppStore.shared)
                .preferredColorScheme(.dark)
                .task { await AppStore.shared.launch() }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            // Self-refresh is left to the foreground/Shortcuts paths: installing
            // ourselves kills the process mid-task.
            _ = await AppStore.shared.unattendedRefresh(force: false, includeSelf: false)
        }
    }
}
