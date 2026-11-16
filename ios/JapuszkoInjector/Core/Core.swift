import Foundation

enum CoreError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// Thin async wrapper over the Rust C API. One instance per process.
final class Core: @unchecked Sendable {
    static let shared = Core()

    /// Non-result events (log, progress, prompts). Always called on main.
    var onEvent: (([String: Any]) -> Void)?

    private let lock = NSLock()
    private var waiting: [UInt64: CheckedContinuation<Any?, Error>] = [:]
    private var early: [UInt64: Result<Any?, Error>] = [:]
    private(set) var started = false

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    func start(root: URL) {
        guard !started else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cb: jinject_event_cb = { _, json in
            guard let json else { return }
            Core.shared.handle(String(cString: json))
        }
        let rc = root.path.withCString { jinject_init($0, cb, nil) }
        started = rc == 0 || rc == 1
    }

    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "done":
            resolve(op: Self.u64(obj["op"]), .success(obj["result"] is NSNull ? nil : obj["result"]))
        case "failed":
            resolve(op: Self.u64(obj["op"]), .failure(CoreError.message(obj["error"] as? String ?? "Unknown error")))
        default:
            DispatchQueue.main.async { self.onEvent?(obj) }
        }
    }

    private func resolve(op: UInt64, _ r: Result<Any?, Error>) {
        lock.lock()
        if let cont = waiting.removeValue(forKey: op) {
            lock.unlock()
            cont.resume(with: r)
        } else {
            early[op] = r
            lock.unlock()
        }
    }

    static func u64(_ v: Any?) -> UInt64 {
        if let n = v as? NSNumber { return n.uint64Value }
        return 0
    }

    static func jsonString(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: calls

    func call(_ req: [String: Any]) async throws -> Any? {
        let str = try Self.jsonString(req)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            let op = str.withCString { jinject_call($0) }
            if op == 0 {
                cont.resume(throwing: CoreError.message("Core isn't running"))
                return
            }
            lock.lock()
            if let r = early.removeValue(forKey: op) {
                lock.unlock()
                cont.resume(with: r)
            } else {
                waiting[op] = cont
                lock.unlock()
            }
        }
    }

    func call<T: Decodable>(_ req: [String: Any], as type: T.Type) async throws -> T {
        let v = try await call(req)
        let data = try JSONSerialization.data(withJSONObject: v ?? NSNull(), options: [.fragmentsAllowed])
        return try Core.decoder.decode(T.self, from: data)
    }

    @discardableResult
    func sync(_ req: [String: Any]) throws -> Any? {
        let str = try Self.jsonString(req)
        guard let raw = str.withCString({ jinject_call_sync($0) }) else {
            throw CoreError.message("Core returned nothing")
        }
        defer { jinject_free(raw) }
        let data = Data(String(cString: raw).utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let err = obj["error"] as? String { throw CoreError.message(err) }
        let ok = obj["ok"]
        return ok is NSNull ? nil : ok
    }

    func sync<T: Decodable>(_ req: [String: Any], as type: T.Type) throws -> T {
        let v = try sync(req)
        let data = try JSONSerialization.data(withJSONObject: v ?? NSNull(), options: [.fragmentsAllowed])
        return try Core.decoder.decode(T.self, from: data)
    }

    func respond(_ prompt: UInt64, _ answer: Any) {
        guard let s = try? Self.jsonString(answer) else { return }
        _ = s.withCString { jinject_respond(prompt, $0) }
    }

    func cancelPrompts() { jinject_cancel_prompts() }

    /// Encodable → JSON object for embedding in requests.
    static func object<T: Encodable>(_ v: T) -> Any {
        guard let d = try? encoder.encode(v),
              let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return NSNull() }
        return o
    }
}
