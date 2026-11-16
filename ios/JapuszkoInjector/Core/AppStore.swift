import Foundation
import Observation
import UIKit

enum LinkState: Equatable {
    case unknown, checking, ok(DeviceInfo), failed(String)
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, good, bad }
    let id = UUID()
    var kind: Kind
    var text: String
}

struct BusyState: Equatable {
    var title: String
    var stage: String = "Starting"
    var value: Double = 0
}

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    // data
    var apps: [AppRecord] = []
    var guests: [GuestRecord] = []
    var accounts: [AccountInfo] = []
    var savedEmails: [String] = UserDefaults.standard.stringArray(forKey: "accounts") ?? []
    var appIds: [String: AppIdsInfo] = [:]
    var config = CoreConfig()
    var selfExpiry: Date?
    var hasPairing = false
    var link: LinkState = .unknown
    var logs: [LogLine] = []

    // activity
    var busy: BusyState?
    var banner: Banner?

    // prompts from the core
    var twoFactor: TwoFactorPrompt?
    var appIdLimit: AppIdLimitPrompt?
    var maxCerts: MaxCertsPrompt?
    var slotsFull: SlotsPrompt?
    /// Set when the user picks "Run inside instead" from the slots prompt.
    var suggestRunInside = false

    private var booted = false
    private let core = Core.shared

    let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("JapuszkoInjector", isDirectory: true)
    let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var selfBundle: String { Bundle.main.bundlePath }

    // MARK: boot

    func bootIfNeeded() {
        guard !booted else { return }
        booted = true
        // Core.onEvent is always delivered on the main queue.
        core.onEvent = { ev in
            MainActor.assumeIsolated { AppStore.shared.handle(ev) }
        }
        core.start(root: root)

        // Linux bootstrap drops pairing + signing state here.
        let boot = documents.appendingPathComponent("bootstrap")
        if FileManager.default.fileExists(atPath: boot.path),
           let got = try? core.sync(["op": "import_bootstrap", "dir": boot.path]) as? [String], !got.isEmpty {
            show(.good, "Imported from Linux: \(got.joined(separator: ", "))")
        }
        reloadLocal()
        if let e = UserDefaults.standard.string(forKey: GuestBoot.errorKey) {
            UserDefaults.standard.removeObject(forKey: GuestBoot.errorKey)
            show(.bad, e)
        }
    }

    /// Foreground launch: sign in saved accounts, check the link, refresh what's due.
    func launch() async {
        bootIfNeeded()
        Notifier.requestAuthorization()
        await signInSaved()
        await checkLink()
        if case .ok = link { await refreshDue(includeSelf: true) }
        BackgroundRefresh.schedule()
    }

    func reloadLocal() {
        apps = (try? core.sync(["op": "list"], as: [AppRecord].self)) ?? []
        apps.sort { $0.expiresAt < $1.expiresAt }
        guests = ((try? core.sync(["op": "guests"], as: [GuestRecord].self)) ?? []).sorted { $0.name < $1.name }
        config = (try? core.sync(["op": "get_config"], as: CoreConfig.self)) ?? CoreConfig()
        hasPairing = (try? core.sync(["op": "has_pairing"]) as? Bool) ?? false
        if let s = try? core.sync(["op": "self_status", "bundle": selfBundle]) as? [String: Any],
           let exp = s["expires_at"] as? NSNumber {
            selfExpiry = Date(timeIntervalSince1970: exp.doubleValue)
        }
        Notifier.schedule(apps: apps, selfExpiry: selfExpiry)
    }

    // MARK: events

    private func handle(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "log":
            logs.append(LogLine(level: ev["level"] as? String ?? "info", message: ev["message"] as? String ?? ""))
            if logs.count > 3000 { logs.removeFirst(logs.count - 3000) }
        case "progress":
            busy?.stage = ev["stage"] as? String ?? ""
            busy?.value = (ev["value"] as? NSNumber)?.doubleValue ?? 0
        case "two_factor":
            if let p = ev["params"], let params = decode(TwoFactorParams.self, p, snake: false) {
                let prompt = TwoFactorPrompt(id: Core.u64(ev["prompt"]), params: params)
                if isForeground { twoFactor = prompt } else { abandon(prompt.id, answer: "Abort") }
            }
        case "max_certs":
            if let p = decode(MaxCertsPrompt.self, ev) {
                if isForeground { maxCerts = p } else { abandon(p.prompt, answer: ["revoke": NSNull()]) }
            }
        case "app_id_limit":
            if let p = decode(AppIdLimitPrompt.self, ev) {
                if isForeground { appIdLimit = p } else { abandon(p.prompt, answer: ["reuse": NSNull()]) }
            }
        case "app_slots_full":
            if let p = decode(SlotsPrompt.self, ev) {
                if isForeground { slotsFull = p } else { abandon(p.prompt, answer: ["cancel": true]) }
            }
        case "self_refresh_starting":
            show(.info, "Re-injecting JapuszkoInjector. It will close; open it again in a few seconds.")
        default: break
        }
    }

    private var isForeground: Bool { UIApplication.shared.applicationState == .active }

    private func abandon(_ prompt: UInt64, answer: Any) {
        core.respond(prompt, answer)
        Notifier.post("JapuszkoInjector needs you", "A refresh needs your input. Open the app and refresh again.")
    }

    private func decode<T: Decodable>(_ t: T.Type, _ any: Any, snake: Bool = true) -> T? {
        guard let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        if snake { return try? Core.decoder.decode(T.self, from: d) }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    func show(_ kind: Banner.Kind, _ text: String) {
        banner = Banner(kind: kind, text: text)
        let id = banner?.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(kind == .bad ? 7 : 4))
            if self.banner?.id == id { self.banner = nil }
        }
    }

    // MARK: prompt answers

    func answerTwoFactor(_ answer: Any) {
        guard let p = twoFactor else { return }
        twoFactor = nil
        core.respond(p.id, answer)
    }

    func answerAppIdLimit(reuse: String?) {
        guard let p = appIdLimit else { return }
        appIdLimit = nil
        core.respond(p.prompt, ["reuse": reuse ?? NSNull()])
    }

    func answerMaxCerts(revoke: [String]?) {
        guard let p = maxCerts else { return }
        maxCerts = nil
        core.respond(p.prompt, ["revoke": revoke ?? NSNull()])
    }

    func answerSlots(replace: String? = nil, account: String? = nil, runInside: Bool = false) {
        guard let p = slotsFull else { return }
        slotsFull = nil
        var a: [String: Any] = [:]
        if let replace { a["replace"] = replace }
        if let account { a["account"] = account }
        if a.isEmpty { a["cancel"] = true }
        core.respond(p.prompt, a)
        if runInside { suggestRunInside = true }
    }

    // MARK: run inside

    func guestURL(_ rel: String) -> URL { root.appendingPathComponent(rel) }

    func addGuest(_ path: URL, name: String?) async -> GuestRecord? {
        var req: [String: Any] = ["op": "guest_add", "path": path.path]
        if let name, !name.isEmpty { req["name"] = name }
        let g: GuestRecord? = await run("Loading into container") {
            try await core.call(req, as: GuestRecord.self)
        }
        if let g {
            try? FileManager.default.removeItem(at: path)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show(.good, "\(g.name) is in the container. No app slot or app ID used.")
        }
        reloadLocal()
        return g
    }

    func resignGuests(_ id: String? = nil) async {
        var req: [String: Any] = ["op": "guest_resign"]
        if let id { req["id"] = id }
        _ = await run("Re-signing guests") { try await core.call(req) }
        reloadLocal()
    }

    func removeGuest(_ g: GuestRecord, wipeData: Bool) {
        do {
            try core.sync(["op": "guest_remove", "id": g.id, "wipe_data": wipeData])
        } catch {
            show(.bad, error.localizedDescription)
        }
        reloadLocal()
    }

    // Per-guest JIT preferences (UI-only, so they live in UserDefaults).
    func guestNeedsJIT(_ g: GuestRecord) -> Bool {
        UserDefaults.standard.bool(forKey: "jinject.guest.\(g.id).jit")
    }
    func setGuestNeedsJIT(_ g: GuestRecord, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "jinject.guest.\(g.id).jit")
    }
    func guestScript(_ g: GuestRecord) -> String {
        UserDefaults.standard.string(forKey: "jinject.guest.\(g.id).script") ?? ""
    }
    func setGuestScript(_ g: GuestRecord, _ s: String) {
        UserDefaults.standard.set(s, forKey: "jinject.guest.\(g.id).script")
    }

    var stikDebugInstalled: Bool {
        guard let u = URL(string: "stikjit://") else { return false }
        return UIApplication.shared.canOpenURL(u)
    }
    /// JIT state of the injector process right now.
    var jitActive: Bool { jg_jit_enabled() == 1 }

    enum JITMode { case off, stikDebug, manual }

    /// Restart into the guest: remember it, then close. An app can't relaunch
    /// itself, so either a notification, StikDebug, or the user brings it back.
    func launch(_ g: GuestRecord, jit: JITMode = .off) {
        var info: [String: String] = [
            "bundle": guestURL(g.appRel).path,
            "exec": g.execName,
            "data": guestURL(g.dataRel).path,
            "id": g.bundleId,
            "name": g.name,
        ]
        if jit != .off { info["jit"] = "1" }

        // StikDebug: stikjit://enable-jit?bundle-id=<us>[&script-name=…]
        var stikURL: URL?
        if jit == .stikDebug {
            var c = URLComponents()
            c.scheme = "stikjit"
            c.host = "enable-jit"
            var q = [URLQueryItem(name: "bundle-id", value: Bundle.main.bundleIdentifier ?? "")]
            let script = guestScript(g).trimmingCharacters(in: .whitespaces)
            if !script.isEmpty { q.append(URLQueryItem(name: "script-name", value: script)) }
            c.queryItems = q
            stikURL = c.url
            guard let u = stikURL, UIApplication.shared.canOpenURL(u) else {
                show(.bad, "StikDebug isn't installed (or doesn't handle stikjit:// links).")
                return
            }
        }

        UserDefaults.standard.set(info, forKey: GuestBoot.pendingKey)
        UserDefaults.standard.synchronize()

        switch jit {
        case .off:
            Notifier.relaunch(g.name)
            UIApplication.shared.perform(Selector(("suspend")))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
        case .stikDebug:
            // StikDebug relaunches us under its debugger; we must be gone by then.
            UIApplication.shared.open(stikURL!) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
            }
        case .manual:
            show(.info, "Now open StikDebug (or your JIT tool) and launch JapuszkoInjector from its app list.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                UIApplication.shared.perform(Selector(("suspend")))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exit(0) }
            }
        }
    }

    // MARK: work wrapper

    @discardableResult
    private func run<T>(_ title: String, quiet: Bool = false, _ body: () async throws -> T) async -> T? {
        let wasBusy = busy != nil
        if !quiet && !wasBusy { busy = BusyState(title: title) }
        defer { if !quiet && !wasBusy { busy = nil } }
        do {
            return try await body()
        } catch {
            show(.bad, error.localizedDescription)
            logs.append(LogLine(level: "error", message: "\(title): \(error.localizedDescription)"))
            return nil
        }
    }

    // MARK: accounts

    func signIn(email: String, password: String) async -> Bool {
        let email = email.trimmingCharacters(in: .whitespaces)
        let info: AccountInfo? = await run("Signing in") {
            try await core.call(["op": "login", "email": email, "password": password], as: AccountInfo.self)
        }
        guard let info else { return false }
        Keychain.set(password, for: email)
        if !savedEmails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
            savedEmails.append(email)
            UserDefaults.standard.set(savedEmails, forKey: "accounts")
        }
        accounts.removeAll { $0.id == info.id }
        accounts.append(info)
        show(.good, "Signed in as \(info.firstName) (\(info.teamId))")
        await loadAppIds(info.email)
        return true
    }

    func signInSaved() async {
        for email in savedEmails where !accounts.contains(where: { $0.id == email.lowercased() }) {
            guard let pw = Keychain.get(email) else { continue }
            let info: AccountInfo? = await run("Signing in \(email)", quiet: true) {
                try await core.call(["op": "login", "email": email, "password": pw], as: AccountInfo.self)
            }
            if let info { accounts.append(info) }
        }
        for a in accounts { await loadAppIds(a.email) }
    }

    func signOut(_ email: String) async {
        _ = try? await core.call(["op": "logout", "email": email])
        Keychain.remove(email)
        savedEmails.removeAll { $0.caseInsensitiveCompare(email) == .orderedSame }
        UserDefaults.standard.set(savedEmails, forKey: "accounts")
        accounts.removeAll { $0.id == email.lowercased() }
        appIds[email.lowercased()] = nil
    }

    func loadAppIds(_ email: String) async {
        if let r = await run("App IDs", quiet: true, {
            try await core.call(["op": "app_ids", "account": email], as: AppIdsInfo.self)
        }) {
            appIds[email.lowercased()] = r
        }
    }

    func appsOn(_ email: String) -> Int {
        apps.filter { $0.account.caseInsensitiveCompare(email) == .orderedSame }.count
    }

    // MARK: install / refresh

    /// Copies a picked file into our sandbox (the picker URL is temporary).
    func stage(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let dst = inbox.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: url, to: dst)
            return dst
        } catch {
            show(.bad, "Couldn't read that file: \(error.localizedDescription)")
            return nil
        }
    }

    func download(_ remote: URL) async -> URL? {
        await run("Downloading") {
            busy?.stage = "Downloading"
            let (tmp, resp) = try await URLSession.shared.download(from: remote)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                throw CoreError.message("Download failed (HTTP \(http.statusCode))")
            }
            let inbox = root.appendingPathComponent("inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            var name = remote.lastPathComponent
            if !name.lowercased().hasSuffix(".ipa") { name += ".ipa" }
            let dst = inbox.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            return dst
        }
    }

    func inspect(_ path: URL) -> Inspected? {
        do {
            return try core.sync(["op": "inspect", "path": path.path], as: Inspected.self)
        } catch {
            show(.bad, error.localizedDescription)
            return nil
        }
    }

    func inject(_ path: URL, options: InstallOptions, account: String?) async -> AppRecord? {
        var req: [String: Any] = ["op": "install", "path": path.path, "options": Core.object(options)]
        if let account { req["account"] = account }
        let rec: AppRecord? = await run("Injecting") {
            try await core.call(req, as: AppRecord.self)
        }
        if let rec {
            try? FileManager.default.removeItem(at: path)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show(.good, "\(rec.name) injected · \(rec.secondsLeft.readout) left")
            reloadLocal()
            await loadAppIds(rec.account)
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        return rec
    }

    func refresh(_ app: AppRecord) async {
        if app.isSelf { await refreshSelf(); return }
        let rec: AppRecord? = await run("Refreshing \(app.name)") {
            try await core.call(["op": "refresh", "id": app.id], as: AppRecord.self)
        }
        if let rec { show(.good, "\(rec.name) good for \(rec.secondsLeft.readout)") }
        reloadLocal()
    }

    func refreshSelf() async {
        var req: [String: Any] = ["op": "refresh_self", "bundle": selfBundle]
        if let a = apps.first(where: \.isSelf)?.account ?? accounts.first?.email { req["account"] = a }
        show(.info, "Re-injecting JapuszkoInjector. It will close; open it again in a few seconds.")
        _ = await run("Re-injecting myself") { try await core.call(req, as: AppRecord.self) }
        reloadLocal()
    }

    func refreshAll(force: Bool, includeSelf: Bool) async -> RefreshReport? {
        var req: [String: Any] = ["op": "refresh_all", "force": force]
        if includeSelf { req["self_bundle"] = selfBundle }
        let r: RefreshReport? = await run("Refreshing") {
            try await core.call(req, as: RefreshReport.self)
        }
        reloadLocal()
        if let r {
            if !r.failed.isEmpty {
                show(.bad, "\(r.failed.count) failed: \(r.failed.first?.error ?? "")")
            } else if r.refreshed.isEmpty && !r.selfRefreshed {
                show(.info, "Nothing needed a refresh.")
            } else {
                show(.good, "Refreshed \(r.refreshed.count) app\(r.refreshed.count == 1 ? "" : "s").")
            }
        }
        return r
    }

    func refreshDue(includeSelf: Bool) async {
        let threshold = TimeInterval(config.refreshThresholdHours * 3600)
        let appsDue = apps.contains { !$0.isSelf && $0.secondsLeft < threshold }
        let selfDue = includeSelf && (selfExpiry.map { $0.timeIntervalSinceNow < threshold } ?? false)
        guard appsDue || selfDue else { return }
        _ = await refreshAll(force: false, includeSelf: selfDue)
    }

    /// Background task + Shortcuts: no UI, no prompts, short summary.
    func unattendedRefresh(force: Bool, includeSelf: Bool) async -> String {
        bootIfNeeded()
        await signInSaved()
        if accounts.isEmpty { return "No Apple account signed in. Open JapuszkoInjector." }
        var req: [String: Any] = ["op": "refresh_all", "force": force]
        if includeSelf { req["self_bundle"] = selfBundle }
        do {
            let r = try await core.call(req, as: RefreshReport.self)
            reloadLocal()
            BackgroundRefresh.schedule()
            if !r.failed.isEmpty {
                let msg = "\(r.failed.count) failed: \(r.failed[0].error)"
                Notifier.post("Refresh failed", msg)
                return msg
            }
            return r.refreshed.isEmpty ? "All apps are fresh." : "Refreshed \(r.refreshed.count) app(s)."
        } catch {
            Notifier.post("Refresh failed", error.localizedDescription)
            return error.localizedDescription
        }
    }

    func remove(_ app: AppRecord, uninstall: Bool) async {
        _ = await run("Removing \(app.name)") {
            try await core.call(["op": "remove", "id": app.id, "uninstall": uninstall])
        }
        reloadLocal()
    }

    // MARK: device + lab

    func checkLink() async {
        guard hasPairing else { link = .failed("No pairing file yet"); return }
        link = .checking
        do {
            link = .ok(try await core.call(["op": "check_device"], as: DeviceInfo.self))
        } catch {
            link = .failed(error.localizedDescription)
        }
    }

    func importPairing(_ url: URL) {
        guard let staged = stage(url) else { return }
        do {
            try core.sync(["op": "import_pairing", "path": staged.path])
            try? FileManager.default.removeItem(at: staged)
            hasPairing = true
            show(.good, "Pairing file imported")
            Task { await checkLink() }
        } catch {
            show(.bad, error.localizedDescription)
        }
    }

    func certs(_ email: String) async -> [CertInfo] {
        await run("Certificates", quiet: true) {
            try await core.call(["op": "certs", "account": email], as: [CertInfo].self)
        } ?? []
    }

    func revoke(_ cert: CertInfo, on email: String) async {
        _ = await run("Revoking") {
            try await core.call(["op": "revoke_cert", "account": email, "serial": cert.serial])
        }
    }

    /// Returns file URLs ready for the share sheet.
    func exportCert(_ email: String, password: String?, appId: String?) async -> (files: [URL], password: String)? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString.prefix(6))")
        var req: [String: Any] = ["op": "export_cert", "account": email, "out_dir": out.path]
        if let password, !password.isEmpty { req["password"] = password }
        if let appId { req["app"] = appId }
        guard let r: ExportedCert = await run("Exporting certificate", {
            try await core.call(req, as: ExportedCert.self)
        }) else { return nil }
        var files = [URL(fileURLWithPath: r.p12Path)]
        if let p = r.profilePath { files.append(URL(fileURLWithPath: p)) }
        return (files, r.password)
    }

    func deviceApps() async -> [DeviceApp] {
        await run("Reading device", quiet: true) {
            try await core.call(["op": "device_apps"], as: [DeviceApp].self)
        } ?? []
    }

    func saveConfig() {
        do {
            try core.sync(["op": "set_config", "config": Core.object(config)])
        } catch {
            show(.bad, error.localizedDescription)
        }
    }

    func iconURL(_ app: AppRecord) -> URL? {
        guard app.hasIcon, let p = try? core.sync(["op": "icon_path", "id": app.id]) as? String else { return nil }
        return URL(fileURLWithPath: p)
    }
}
