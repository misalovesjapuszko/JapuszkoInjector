import SwiftUI

struct TwoFactorSheet: View {
    @Environment(AppStore.self) private var store
    var prompt: TwoFactorPrompt
    @State private var code = ""
    @FocusState private var focused: Bool

    private var target: String {
        if prompt.params.sms,
           let n = prompt.params.numbers.first(where: { $0.id == prompt.params.selectedNumberId }) {
            return n.numberWithDialCode
        }
        return "your trusted devices"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit())
                        .focused($focused)
                        .onChange(of: code) { _, new in
                            code = String(new.filter(\.isNumber).prefix(6))
                            if code.count == 6 { submit() }
                        }
                } header: {
                    Text(prompt.params.unknown ? "Choose how to get a code" : "Code sent to \(target)")
                } footer: {
                    if let err = prompt.params.lastError, !err.isEmpty {
                        Text(err).foregroundStyle(.red)
                    }
                }

                Section("Didn't get a code?") {
                    Button("Send to Trusted Devices") { store.answerTwoFactor("SendToDevices") }
                    ForEach(prompt.params.numbers) { n in
                        Button("Text \(n.numberWithDialCode)") { store.answerTwoFactor(["SendSms": n.id]) }
                    }
                    if !prompt.params.unknown {
                        Button("Resend Code") { store.answerTwoFactor("ResendCode") }
                    }
                }
            }
            .navigationTitle("Verification Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.answerTwoFactor("Abort") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Verify") { submit() }.bold().disabled(code.count != 6)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    private func submit() {
        guard code.count == 6 else { return }
        store.answerTwoFactor(["SubmitCode": code])
    }
}

struct AppIdLimitSheet: View {
    @Environment(AppStore.self) private var store
    var prompt: AppIdLimitPrompt
    @State private var pick: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(prompt.account) can't register more app IDs this week. Choose one of your existing app IDs for \(prompt.appName) instead. If another app uses it, that app gets replaced.")
                        .font(.subheadline)
                }
                Section("Your App IDs") {
                    ForEach(prompt.choices) { c in
                        Button {
                            pick = c.identifier
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).foregroundStyle(.primary)
                                    Text(c.identifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if let u = c.usedBy {
                                        Text("Used by \(u)").font(.caption).foregroundStyle(.orange)
                                    } else {
                                        Text("Not in use").font(.caption).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                if pick == c.identifier {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).bold()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("No App IDs Left")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.answerAppIdLimit(reuse: nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { store.answerAppIdLimit(reuse: pick) }.bold().disabled(pick == nil)
                }
            }
        }
        .onAppear { pick = prompt.choices.first(where: { $0.usedBy == nil })?.identifier }
    }
}

struct SlotsFullSheet: View {
    @Environment(AppStore.self) private var store
    var prompt: SlotsPrompt

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(prompt.account) already has 3 apps, the most a free Apple ID can have at once.")
                        .font(.subheadline)
                }
                if !prompt.otherAccounts.isEmpty {
                    Section("Use Another Apple ID") {
                        ForEach(prompt.otherAccounts) { a in
                            Button {
                                store.answerSlots(account: a.email)
                            } label: {
                                LabeledContent(a.email, value: "\(a.used) of 3")
                            }
                            .disabled(a.used >= 3)
                        }
                    }
                }
                Section {
                    ForEach(prompt.apps.filter { !$0.isSelf }) { a in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name)
                                Text((TimeInterval(a.expiresAt) - Date().timeIntervalSince1970).expiryText)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Replace", role: .destructive) { store.answerSlots(replace: a.id) }.pill()
                        }
                    }
                } header: {
                    Text("Replace an App")
                } footer: {
                    Text("The app you replace is uninstalled from this device.")
                }
                Section {
                    Button("Install Inside This App Instead") { store.answerSlots(runInside: true) }
                } footer: {
                    Text("Runs inside JapuszkoInjector and doesn't need an app slot.")
                }
            }
            .navigationTitle("Apple ID Full")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.answerSlots() }
                }
            }
        }
    }
}

struct MaxCertsSheet: View {
    @Environment(AppStore.self) private var store
    var prompt: MaxCertsPrompt
    @State private var chosen: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("This Apple ID already has the maximum number of certificates. Choose which ones to revoke.")
                        .font(.subheadline)
                }
                Section {
                    ForEach(prompt.certs) { c in
                        Button {
                            if chosen.contains(c.serial) { chosen.remove(c.serial) } else { chosen.insert(c.serial) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.machineName.isEmpty ? c.name : c.machineName).foregroundStyle(.primary)
                                    Text(c.serial).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chosen.contains(c.serial) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).bold()
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Apps signed with a revoked certificate stop opening until they're refreshed.")
                }
            }
            .navigationTitle("Certificate Limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.answerMaxCerts(revoke: nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Revoke") { store.answerMaxCerts(revoke: Array(chosen)) }
                        .bold()
                        .disabled(chosen.isEmpty)
                }
            }
        }
    }
}
