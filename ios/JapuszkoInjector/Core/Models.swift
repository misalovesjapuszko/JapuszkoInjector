import Foundation

// Mirrors core/src/model.rs. JSON is snake_case on the Rust side.

struct InstallOptions: Codable, Hashable {
    var customName: String? = nil
    var customBundleId: String? = nil
    var stripExtensions = false
    var increasedMemoryLimit = false
    var fileSharing = false
    var stripDeviceRestrictions = false
}

struct AppRecord: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var version: String
    var installedBundleId: String
    var installedAt: Int64
    var expiresAt: Int64
    var options: InstallOptions
    var appIdCount: Int
    var hasIcon: Bool
    var sizeBytes: UInt64
    var account: String

    var isSelf: Bool { id == "__self__" }
    var secondsLeft: TimeInterval { TimeInterval(expiresAt) - Date().timeIntervalSince1970 }
    /// 0…1 of the 7-day lifetime left.
    var fill: Double { max(0, min(1, secondsLeft / (7 * 86400))) }
}

/// A "Run inside" app living in the injector's container.
struct GuestRecord: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var version: String
    var bundleId: String
    var execName: String
    var appRel: String
    var dataRel: String
    var iconRel: String?
    var teamId: String
    var addedAt: Int64
    var sizeBytes: UInt64
}

struct AccountInfo: Codable, Identifiable, Hashable {
    var email: String
    var firstName: String
    var lastName: String
    var teamId: String
    var teamName: String
    var id: String { email.lowercased() }
}

struct CertInfo: Codable, Identifiable, Equatable {
    var name: String
    var serial: String
    var machineName: String
    var machineId: String
    var expiresAt: Int64?
    var isOurs: Bool
    var id: String { serial }
}

struct AppIdInfo: Codable, Identifiable, Equatable {
    var identifier: String
    var name: String
    var expiresAt: Int64?
    var id: String { identifier }
}

struct AppIdsInfo: Codable, Equatable {
    var max: UInt64?
    var available: Int64?
    var ids: [AppIdInfo]
}

struct DeviceInfo: Codable, Equatable {
    var name: String
    var udid: String
    var iosVersion: String
    var model: String
}

struct RefreshFailure: Codable, Equatable {
    var id: String
    var error: String
}

struct RefreshReport: Codable, Equatable {
    var refreshed: [AppRecord]
    var skipped: [String]
    var failed: [RefreshFailure]
    var selfRefreshed: Bool
}

struct ExportedCert: Codable, Equatable {
    var p12Path: String
    var password: String
    var profilePath: String?
}

struct DeviceApp: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var version: String
}

struct Inspected: Codable, Equatable {
    var name: String
    var bundleId: String
    var version: String
    var extensions: Int
    var icon: String?
}

struct NetStep: Codable, Identifiable, Equatable {
    var step: String
    var ok: Bool
    var detail: String
    var id: String { step }
}

struct NetTestResult: Codable, Equatable {
    var server: String
    var steps: [NetStep]
}

struct CoreConfig: Codable, Equatable {
    struct Target: Codable, Equatable {
        var kind: String = "network"
        var ip: String? = "10.7.0.1"
        var udid: String? = nil
    }
    var anisetteServers: [String] = [
        "https://ani.iloader.app",
        "https://ani.sidestore.io",
        "https://ani.sidestore.app",
        "https://ani.sidestore.zip",
        "https://anisette.sideloadly.io",
    ]
    var machineName: String = "JapuszkoInjector"
    var target = Target()
    var autoRevokeCerts = false
    var refreshThresholdHours: Int = 48
    var enforceFreeLimits = true
}

// MARK: prompts coming from the core

struct TrustedNumber: Codable, Identifiable, Equatable {
    var numberWithDialCode: String
    var lastTwoDigits: String
    var pushMode: String
    var id: UInt32
}

/// isideload's TwoFactorCallbackParams (camelCase JSON).
struct TwoFactorParams: Codable, Equatable {
    var lastError: String?
    var unknown: Bool
    var sms: Bool
    var numbers: [TrustedNumber]
    var selectedNumberId: UInt32?
}

struct TwoFactorPrompt: Identifiable, Equatable {
    var id: UInt64
    var params: TwoFactorParams
}

struct AppIdChoice: Codable, Identifiable, Equatable {
    var identifier: String
    var name: String
    var expiresAt: Int64?
    var usedBy: String?
    var id: String { identifier }
}

struct AppIdLimitPrompt: Codable, Identifiable, Equatable {
    var prompt: UInt64
    var account: String
    var needed: Int
    var available: Int64
    var appName: String
    var choices: [AppIdChoice]
    var id: UInt64 { prompt }
}

struct MaxCertsPrompt: Codable, Identifiable, Equatable {
    var prompt: UInt64
    var certs: [CertInfo]
    var id: UInt64 { prompt }
}

struct SlotApp: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var expiresAt: Int64
    var isSelf: Bool
}

struct SlotAccount: Codable, Identifiable, Equatable {
    var email: String
    var used: Int
    var id: String { email }
}

/// Account already has 3 apps (free limit).
struct SlotsPrompt: Codable, Identifiable, Equatable {
    var prompt: UInt64
    var account: String
    var appName: String
    var apps: [SlotApp]
    var otherAccounts: [SlotAccount]
    var id: UInt64 { prompt }
}

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    var date = Date()
    var level: String
    var message: String
}

// MARK: helpers

extension TimeInterval {
    /// "Expires in 4 days", "Expires in 5 hours", "Expired"
    var expiryText: String {
        if self <= 0 { return "Expired" }
        let days = Int(self) / 86400, hours = Int(self) / 3600, minutes = Int(self) / 60
        if days >= 1 { return "Expires in \(days) day\(days == 1 ? "" : "s")" }
        if hours >= 1 { return "Expires in \(hours) hour\(hours == 1 ? "" : "s")" }
        return "Expires in \(max(minutes, 1)) minute\(minutes == 1 ? "" : "s")"
    }

    /// "4D 13H", "5H 20M", "EXPIRED"
    var readout: String {
        if self <= 0 { return "EXPIRED" }
        let d = Int(self) / 86400, h = (Int(self) % 86400) / 3600, m = (Int(self) % 3600) / 60
        if d > 0 { return "\(d)D \(h)H" }
        if h > 0 { return "\(h)H \(m)M" }
        return "\(m)M"
    }
}

extension UInt64 {
    var megabytes: String { String(format: "%.1f MB", Double(self) / 1_048_576) }
}
