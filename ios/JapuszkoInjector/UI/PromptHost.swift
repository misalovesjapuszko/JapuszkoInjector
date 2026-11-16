import SwiftUI

/// Presents prompts from the core (2FA, app ID quota, account full, cert
/// limit) and error alerts. Every sheet in the app adds this at its level;
/// only the topmost level presents, because iOS won't show a sheet from a
/// view that is already covered by another sheet.
struct PromptHost: ViewModifier {
    @Environment(AppStore.self) private var store
    let depth: Int

    private func gate<T>(_ value: T?) -> T? {
        store.modalDepth == depth ? value : nil
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { gate(store.twoFactor) }, set: { _ in })) { p in
                TwoFactorSheet(prompt: p).interactiveDismissDisabled()
            }
            .sheet(item: Binding(get: { gate(store.appIdLimit) }, set: { _ in })) { p in
                AppIdLimitSheet(prompt: p).interactiveDismissDisabled()
            }
            .sheet(item: Binding(get: { gate(store.slotsFull) }, set: { _ in })) { p in
                SlotsFullSheet(prompt: p).interactiveDismissDisabled()
            }
            .sheet(item: Binding(get: { gate(store.maxCerts) }, set: { _ in })) { p in
                MaxCertsSheet(prompt: p).interactiveDismissDisabled()
            }
            .alert(gate(store.errorAlert)?.title ?? "",
                   isPresented: Binding(get: { gate(store.errorAlert) != nil },
                                        set: { if !$0 { store.errorAlert = nil } }),
                   presenting: gate(store.errorAlert)) { _ in
                Button("OK", role: .cancel) { store.errorAlert = nil }
            } message: { item in
                Text(item.message)
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
