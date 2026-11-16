import AppIntents
import Foundation

/// "Refresh apps" for Shortcuts. Put it in a personal automation
/// (e.g. daily at 4:00, or "when charger connected") for hands-off refresh.
struct RefreshAllIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Apps"
    static var description = IntentDescription("Re-signs every app that expires soon. Turn the loopback VPN on first.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Refresh everything (not just expiring)", default: false)
    var force: Bool

    @Parameter(title: "Include JapuszkoInjector itself", default: true)
    var includeSelf: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let summary = await AppStore.shared.unattendedRefresh(force: force, includeSelf: includeSelf)
        return .result(dialog: "\(summary)")
    }
}

struct AppStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Days Left"
    static var description = IntentDescription("Says how long each sideloaded app has left.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppStore.shared
        store.bootIfNeeded()
        let lines = store.apps.sorted { $0.expiresAt < $1.expiresAt }.map { "\($0.name): \($0.secondsLeft.readout)" }
        let text = lines.isEmpty ? "Nothing injected yet." : lines.joined(separator: "\n")
        return .result(dialog: "\(text)")
    }
}

struct InjectorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAllIntent(),
            phrases: ["Refresh apps in \(.applicationName)", "\(.applicationName) refresh"],
            shortTitle: "Refresh Apps",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: AppStatusIntent(),
            phrases: ["How long do my apps have in \(.applicationName)"],
            shortTitle: "Days Left",
            systemImageName: "hourglass"
        )
    }
}
