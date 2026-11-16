import SwiftUI

// MARK: 2FA

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
        SheetFrame(code: "2F", title: "Verify", onClose: nil) {
            VStack(alignment: .leading, spacing: 18) {
                if prompt.params.unknown {
                    Text("Apple didn't say where the code went. Pick a method below.")
                        .font(.body(13)).foregroundStyle(Theme.amber)
                } else {
                    Text("Code sent to \(target).").font(.body(14)).foregroundStyle(Theme.dim)
                }
                if let err = prompt.params.lastError, !err.isEmpty {
                    Text(err).font(.label(11)).foregroundStyle(Theme.red)
                }

                // six readout cells over a hidden field
                ZStack {
                    TextField("", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused)
                        .opacity(0.01)
                        .onChange(of: code) { _, new in
                            code = String(new.filter(\.isNumber).prefix(6))
                            if code.count == 6 { submit() }
                        }
                    HStack(spacing: 8) {
                        ForEach(0..<6, id: \.self) { i in
                            let ch = i < code.count ? String(code[code.index(code.startIndex, offsetBy: i)]) : ""
                            Text(ch)
                                .font(.readout(30)).foregroundStyle(Theme.acid)
                                .frame(maxWidth: .infinity).frame(height: 62)
                                .background(Theme.panel)
                                .overlay(Rectangle().stroke(i == code.count && focused ? Theme.acid : Theme.line, lineWidth: 1))
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { focused = true }

                Button("Submit") { submit() }
                    .buttonStyle(LabButtonStyle(kind: .primary))
                    .disabled(code.count != 6)

                Panel(code: "··", title: "Other ways") {
                    VStack(spacing: 8) {
                        Button("Send to trusted devices") { store.answerTwoFactor("SendToDevices") }
                            .buttonStyle(LabButtonStyle(compact: false))
                        ForEach(prompt.params.numbers.filter { $0.id != prompt.params.selectedNumberId || !prompt.params.sms }) { n in
                            Button("SMS to \(n.numberWithDialCode)") { store.answerTwoFactor(["SendSms": n.id]) }
                                .buttonStyle(LabButtonStyle())
                        }
                        if !prompt.params.unknown {
                            Button("Resend code") { store.answerTwoFactor("ResendCode") }
                                .buttonStyle(LabButtonStyle())
                        }
                    }
                }
                Button("Cancel sign-in") { store.answerTwoFactor("Abort") }
                    .buttonStyle(LabButtonStyle(kind: .danger))
            }
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard code.count == 6 else { return }
        store.answerTwoFactor(["SubmitCode": code])
    }
}

// MARK: app ID quota

struct AppIdLimitSheet: View {
    @Environment(AppStore.self) private var store
    var prompt: AppIdLimitPrompt
    @State private var pick: String?

    var body: some View {
        SheetFrame(code: "ID", title: "Quota hit", onClose: nil) {
            VStack(alignment: .leading, spacing: 16) {
                HazardStripes().frame(height: 10)
                Text("\(prompt.account) has \(max(prompt.available, 0)) app ID\(prompt.available == 1 ? "" : "s") left this week, and \(prompt.appName) needs \(prompt.needed).")
                    .font(.body(14)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Text("Overwrite an existing app ID instead. The new app takes its slot and whatever app uses that ID now gets replaced on the device. Extensions get stripped so no extra IDs are needed.")
                    .font(.body(12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(prompt.choices) { c in
                        Button { pick = c.identifier; UISelectionFeedbackGenerator().selectionChanged() } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: pick == c.identifier ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(pick == c.identifier ? Theme.acid : Theme.faint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.identifier).font(.label(11)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                    HStack(spacing: 6) {
                                        Text(c.name).font(.body(11)).foregroundStyle(Theme.dim).lineLimit(1)
                                        if let u = c.usedBy { Tag(text: "in use: \(u)", color: Theme.amber) } else { Tag(text: "free", color: Theme.acid) }
                                    }
                                    if let e = c.expiresAt {
                                        Text("frees up \(Date(timeIntervalSince1970: TimeInterval(e)).stamp)").caps(8)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(pick == c.identifier ? Theme.acid.opacity(0.06) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))

                PlungerButton(label: "Hold to overwrite", enabled: pick != nil) {
                    store.answerAppIdLimit(reuse: pick)
                }
                Button("Cancel") { store.answerAppIdLimit(reuse: nil) }
                    .buttonStyle(LabButtonStyle())
            }
        }
        .onAppear {
            // Preselect an ID nobody is using.
            pick = prompt.choices.first(where: { $0.usedBy == nil })?.identifier
        }
    }
}

// MARK: cert limit

struct MaxCertsSheet: View {
    @Environment(AppStore.self) private var store
    var prompt: MaxCertsPrompt
    @State private var chosen: Set<String> = []

    var body: some View {
        SheetFrame(code: "CT", title: "Cert limit", onClose: nil) {
            VStack(alignment: .leading, spacing: 16) {
                Text("This account already has the maximum number of development certificates. Revoke one to make room. Apps signed with a revoked cert may stop opening until they're re-injected.")
                    .font(.body(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    ForEach(prompt.certs) { c in
                        Button {
                            if chosen.contains(c.serial) { chosen.remove(c.serial) } else { chosen.insert(c.serial) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: chosen.contains(c.serial) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(chosen.contains(c.serial) ? Theme.red : Theme.faint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.machineName.isEmpty ? c.name : c.machineName).font(.body(14)).foregroundStyle(Theme.text)
                                    Text(c.serial).font(.label(10)).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                if c.isOurs { Tag(text: "ours", color: Theme.acid) }
                            }
                            .padding(10)
                            .overlay(Rectangle().stroke(chosen.contains(c.serial) ? Theme.red.opacity(0.6) : Theme.line, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Revoke \(chosen.count) & continue") { store.answerMaxCerts(revoke: Array(chosen)) }
                    .buttonStyle(LabButtonStyle(kind: .danger))
                    .disabled(chosen.isEmpty)
                Button("Cancel") { store.answerMaxCerts(revoke: nil) }
                    .buttonStyle(LabButtonStyle())
            }
        }
    }
}
