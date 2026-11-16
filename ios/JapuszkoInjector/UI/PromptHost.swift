import SwiftUI

/// Presents prompts from the core (2FA, app ID quota, account full, cert
/// limit) and error alerts. Every sheet in the app adds this at its level;
/// only the topmost level presents, because iOS won't show a sheet from a
/// view that is already covered by another sheet.
struct PromptHost: ViewModifier {
    @Environment(AppStore.self) private var store
    let depth: Int

    private var active: Bool { store.modalDepth == depth }

    private var twoFactor: Binding<TwoFactorPrompt?> {
        Binding(get: { active ? store.twoFactor : nil }, set: { _ in })
    }
    private var appIdLimit: Binding<AppIdLimitPrompt?> {
        Binding(get: { active ? store.appIdLimit : nil }, set: { _ in })
    }
    private var slotsFull: Binding<SlotsPrompt?> {
        Binding(get: { active ? store.slotsFull : nil }, set: { _ in })
    }
    private var maxCerts: Binding<MaxCertsPrompt?> {
        Binding(get: { active ? store.maxCerts : nil }, set: { _ in })
    }
    private var showError: Binding<Bool> {
        Binding(get: { active && store.errorAlert != nil },
                set: { if !$0 { store.errorAlert = nil } })
    }

    func body(content: Content) -> some View {
        content
            .modifier(SheetPrompts(twoFactor: twoFactor, appIdLimit: appIdLimit,
                                   slotsFull: slotsFull, maxCerts: maxCerts))
            .modifier(ErrorAlert(isPresented: showError, item: store.errorAlert))
    }
}

private struct SheetPrompts: ViewModifier {
    let twoFactor: Binding<TwoFactorPrompt?>
    let appIdLimit: Binding<AppIdLimitPrompt?>
    let slotsFull: Binding<SlotsPrompt?>
    let maxCerts: Binding<MaxCertsPrompt?>

    func body(content: Content) -> some View {
        let first = content
            .sheet(item: twoFactor) { (p: TwoFactorPrompt) in
                TwoFactorSheet(prompt: p).interactiveDismissDisabled()
            }
            .sheet(item: appIdLimit) { (p: AppIdLimitPrompt) in
                AppIdLimitSheet(prompt: p).interactiveDismissDisabled()
            }
        return first
            .sheet(item: slotsFull) { (p: SlotsPrompt) in
                SlotsFullSheet(prompt: p).interactiveDismissDisabled()
            }
            .sheet(item: maxCerts) { (p: MaxCertsPrompt) in
                MaxCertsSheet(prompt: p).interactiveDismissDisabled()
            }
    }
}

private struct ErrorAlert: ViewModifier {
    @Environment(AppStore.self) private var store
    let isPresented: Binding<Bool>
    let item: AlertItem?

    func body(content: Content) -> some View {
        content.alert(item?.title ?? "Error", isPresented: isPresented) {
            Button("OK", role: .cancel) { store.errorAlert = nil }
        } message: {
            Text(item?.message ?? "")
        }
    }
}

/// Marks the root of one of our sheets.
struct ModalLevel: ViewModifier {
    @Environment(AppStore.self) private var store
    let depth: Int

    func body(content: Content) -> some View {
        content
            .modifier(PromptHost(depth: depth))
            .onAppear { store.modalDepth = depth }
            .onDisappear { store.modalDepth = depth - 1 }
    }
}

extension View {
    func promptHost() -> some View { modifier(PromptHost(depth: 0)) }
    func modalLevel(_ depth: Int = 1) -> some View { modifier(ModalLevel(depth: depth)) }
}
