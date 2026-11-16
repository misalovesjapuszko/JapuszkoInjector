import SwiftUI

/// One "Run inside" app.
struct GuestSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var guest: GuestRecord
    @State private var confirmRemove = false
    @State private var needsJIT = false
    @State private var script = ""

    private var hostTeam: String? {
        let acct = store.apps.first(where: \.isSelf)?.account
        return store.accounts.first { $0.email.caseInsensitiveCompare(acct ?? "") == .orderedSame }?.teamId
    }

    var body: some View {
        SheetFrame(code: "CT", title: "Container", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    AppIconView(url: guest.iconRel.map { store.guestURL($0) }, name: guest.name, size: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(guest.name).font(.head(28)).foregroundStyle(Theme.text).textCase(.uppercase)
                            .lineLimit(2).minimumScaleFactor(0.6)
                        Text("v\(guest.version)").font(.label(11)).foregroundStyle(Theme.dim)
                        Tag(text: "runs inside", color: Theme.acid)
                    }
                }

                Panel(code: "01", title: "Spec") {
                    VStack(spacing: 8) {
                        row("Bundle", guest.bundleId)
                        row("Signed by", guest.teamId)
                        row("Size", guest.sizeBytes.megabytes)
                        row("Added", Date(timeIntervalSince1970: TimeInterval(guest.addedAt)).stamp)
                    }
                }

                if let t = hostTeam, t != guest.teamId {
                    HStack(alignment: .top, spacing: 10) {
                        HazardStripes().frame(width: 8)
                        Text("Signed by team \(guest.teamId) but JapuszkoInjector now runs as \(t). Re-sign it or iOS won't load it.")
                            .font(.body(12)).foregroundStyle(Theme.amber)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                Panel(code: "02", title: "JIT") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabToggle(title: "Needs JIT",
                                  detail: "Emulators and VMs. Launches through StikDebug so the guest gets JIT.",
                                  isOn: $needsJIT)
                            .onChange(of: needsJIT) { _, on in store.setGuestNeedsJIT(guest, on) }
                        if needsJIT {
                            LabField(caption: "StikDebug script (optional)", text: $script, placeholder: "e.g. the script for this emulator")
                                .onChange(of: script) { _, v in store.setGuestScript(guest, v) }
                            Text("Newer iOS on A15 and later chips only gives JIT to apps that have a StikDebug script. Put its name here if this app needs one.")
                                .font(.body(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Lamp(color: store.stikDebugInstalled ? Theme.acid : Theme.red)
                                Text(store.stikDebugInstalled ? "StikDebug found" : "StikDebug not installed").caps(9)
                            }
                        }
                    }
                }

                PlungerButton(label: needsJIT ? "Hold to launch with JIT" : "Hold to launch",
                              enabled: store.busy == nil && (!needsJIT || store.stikDebugInstalled)) {
                    store.launch(guest, jit: needsJIT ? .stikDebug : .off)
                }
                if needsJIT {
                    Button("I'll enable JIT myself") { store.launch(guest, jit: .manual) }
                        .buttonStyle(LabButtonStyle(compact: true))
                    Text("JapuszkoInjector opens StikDebug, which relaunches it with a debugger attached. The guest starts once JIT is on. If nothing happens within about 12 seconds, the injector opens again and says why.")
                        .font(.body(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("JapuszkoInjector closes and \(guest.name) starts in its place. Tap the notification (or reopen the app) if it doesn't come up by itself. To get back, swipe it away in the app switcher and open JapuszkoInjector again.")
                        .font(.body(11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Re-sign") { Task { await store.resignGuests(guest.id) } }
                        .buttonStyle(LabButtonStyle())
                    Button("Remove") { confirmRemove = true }
                        .buttonStyle(LabButtonStyle(kind: .danger))
                }
                .disabled(store.busy != nil)
            }
        }
        .onAppear {
            needsJIT = store.guestNeedsJIT(guest)
            script = store.guestScript(guest)
        }
        .confirmationDialog("Remove \(guest.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove, keep its data") { store.removeGuest(guest, wipeData: false); dismiss() }
            Button("Remove and wipe data", role: .destructive) { store.removeGuest(guest, wipeData: true); dismiss() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).caps(9).frame(width: 74, alignment: .leading)
            Text(v).font(.readout(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

/// Free account already has 3 apps.
struct SlotsFullSheet: View {
    @Environment(AppStore.self) private var store
    var prompt: SlotsPrompt

    var body: some View {
        SheetFrame(code: "3/3", title: "Account full", onClose: nil) {
            VStack(alignment: .leading, spacing: 16) {
                HazardStripes().frame(height: 10)
                Text("\(prompt.account) already has 3 apps, the most a free Apple ID can have at once. Pick how to fit \(prompt.appName):")
                    .font(.body(14)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)

                if !prompt.otherAccounts.isEmpty {
                    Panel(code: "A", title: "Use another account") {
                        VStack(spacing: 8) {
                            ForEach(prompt.otherAccounts) { a in
                                Button { store.answerSlots(account: a.email) } label: {
                                    HStack {
                                        Text(a.email).font(.body(14)).foregroundStyle(Theme.text).lineLimit(1)
                                        Spacer()
                                        Text("\(a.used)/3").font(.readout(12)).foregroundStyle(a.used >= 3 ? Theme.red : Theme.acid)
                                    }
                                    .padding(10)
                                    .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(a.used >= 3)
                            }
                        }
                    }
                }

                Panel(code: "B", title: "Replace an app") {
                    VStack(spacing: 8) {
                        ForEach(prompt.apps.filter { !$0.isSelf }) { a in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).font(.body(14)).foregroundStyle(Theme.text)
                                    Text((TimeInterval(a.expiresAt) - Date().timeIntervalSince1970).readout + " left")
                                        .font(.label(10)).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                Button("Uninstall") { store.answerSlots(replace: a.id) }
                                    .buttonStyle(LabButtonStyle(kind: .danger, compact: true))
                            }
                        }
                        if prompt.apps.contains(where: \.isSelf) {
                            Text("JapuszkoInjector itself takes one of the 3.").caps(8)
                        }
                    }
                }

                Panel(code: "C", title: "Run inside instead") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Load it into the container. It runs inside JapuszkoInjector and needs no slot or app ID.")
                            .font(.body(12)).foregroundStyle(Theme.dim)
                        Button("Switch to Run inside") { store.answerSlots(runInside: true) }
                            .buttonStyle(LabButtonStyle(kind: .primary))
                    }
                }

                Button("Cancel") { store.answerSlots() }.buttonStyle(LabButtonStyle())
            }
        }
    }
}
