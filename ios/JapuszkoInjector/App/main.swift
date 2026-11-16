import Foundation

/// Entry point. If a "Run inside" guest was requested, it takes over the
/// process here, before any of the injector's UI exists. Otherwise (or if the
/// guest fails to load) the injector starts normally.
enum GuestBoot {
    static let pendingKey = "jinject.pendingGuest"
    static let errorKey = "jinject.guestError"

    static func runPending() {
        let d = UserDefaults.standard
        guard let g = d.dictionary(forKey: pendingKey) as? [String: String] else { return }
        // Clear first: if the guest crashes, the next launch is the injector.
        d.removeObject(forKey: pendingKey)
        d.synchronize()
        guard let bundle = g["bundle"], let exec = g["exec"], let data = g["data"], let id = g["id"] else { return }

        // JIT launch: StikDebug (or another enabler) starts us under a
        // debugger. Give it a moment; without JIT a JIT-only guest would
        // just crash, so fall back to the injector with an explanation.
        if g["jit"] == "1" {
            let wait = Double(g["jit_wait"] ?? "") ?? 12
            if jg_wait_for_jit(wait) == 0 {
                d.set("\(g["name"] ?? id): JIT wasn't enabled within \(Int(wait))s. Open StikDebug, check its pairing file and VPN, then try again.", forKey: errorKey)
                d.synchronize()
                return
            }
        }

        var buf = [CChar](repeating: 0, count: 1024)
        let rc = jg_run_guest(bundle, exec, data, id, &buf, Int32(buf.count))
        // Only reached on failure.
        let msg = String(cString: buf)
        d.set("\(g["name"] ?? id) didn't start: \(msg) (\(rc))", forKey: errorKey)
        d.synchronize()
    }
}

GuestBoot.runPending()
JapuszkoInjectorApp.main()
