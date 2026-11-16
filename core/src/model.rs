//! Plain data types shared between the engine, the CLI and the Swift app (as JSON).

use serde::{Deserialize, Serialize};

pub const SELF_ID: &str = "__self__";
pub const DEFAULT_ANISETTE: &str = "https://ani.iloader.app";
/// Always tried after the user's own list.
pub const FALLBACK_ANISETTE: &[&str] = &[
    "https://ani.iloader.app",
    "https://ani.sidestore.io",
    "https://anisette.sideloadly.io",
];
/// LocalDevVPN / StosVPN loop the device back to itself on this address.
pub const DEFAULT_LOOPBACK_IP: &str = "10.7.0.1";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Anisette v3 servers, tried in order (put a self-hosted one first).
    pub anisette_servers: Vec<String>,
    /// Name shown on the development certificate in Apple's portal.
    pub machine_name: String,
    /// How to reach the device.
    pub target: Target,
    /// Revoke old certs automatically when the account hits the cert limit
    /// instead of asking.
    pub auto_revoke_certs: bool,
    /// Auto refresh refreshes anything expiring within this many hours.
    pub refresh_threshold_hours: u64,
    /// Stop at 3 apps per account (free Apple IDs). Off for paid accounts.
    pub enforce_free_limits: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            anisette_servers: vec![DEFAULT_ANISETTE.into()],
            machine_name: "JapuszkoInjector".into(),
            target: Target::Network {
                ip: DEFAULT_LOOPBACK_IP.into(),
            },
            auto_revoke_certs: false,
            refresh_threshold_hours: 48,
            enforce_free_limits: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Target {
    /// Over the network with a pairing file (on-device via the loopback VPN).
    Network { ip: String },
    /// Over USB through usbmuxd (Linux bootstrap). `udid: None` = first device.
    Usb { udid: Option<String> },
}

/// Tweaks applied to the bundle before signing.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct InstallOptions {
    pub custom_name: Option<String>,
    pub custom_bundle_id: Option<String>,
    /// Remove app extensions (saves app IDs: each extension costs one).
    pub strip_extensions: bool,
    /// Ask Apple for the increased-memory-limit entitlement.
    pub increased_memory_limit: bool,
    /// Expose the app's Documents in Files.
    pub file_sharing: bool,
    /// Drop UISupportedDevices / minimum-OS restrictions.
    pub strip_device_restrictions: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppRecord {
    /// Original bundle id (stable key).
    pub id: String,
    pub name: String,
    pub version: String,
    /// Bundle id as installed on the device (with the team suffix).
    pub installed_bundle_id: String,
    pub installed_at: i64,
    /// Unix seconds when the provisioning profile expires.
    pub expires_at: i64,
    pub options: InstallOptions,
    /// Number of app IDs this app uses (main + extensions).
    pub app_id_count: usize,
    pub has_icon: bool,
    pub size_bytes: u64,
    /// Apple ID that signed it (refreshes use the same account).
    #[serde(default)]
    pub account: String,
}

/// An app that runs inside the injector ("Run inside"). Paths are relative to
/// the engine root because iOS moves the app container between installs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GuestRecord {
    pub id: String,
    pub name: String,
    pub version: String,
    pub bundle_id: String,
    pub exec_name: String,
    pub app_rel: String,
    pub data_rel: String,
    pub icon_rel: Option<String>,
    /// Team whose cert signed it; must match the injector's own team.
    pub team_id: String,
    pub added_at: i64,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountInfo {
    pub email: String,
    pub first_name: String,
    pub last_name: String,
    pub team_id: String,
    pub team_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CertInfo {
    pub name: String,
    pub serial: String,
    pub machine_name: String,
    pub machine_id: String,
    pub expires_at: Option<i64>,
    /// True when this cert belongs to this install (we hold its key).
    pub is_ours: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppIdInfo {
    pub identifier: String,
    pub name: String,
    pub expires_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppIdsInfo {
    pub max: Option<u64>,
    pub available: Option<i64>,
    pub ids: Vec<AppIdInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceInfo {
    pub name: String,
    pub udid: String,
    pub ios_version: String,
    pub model: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RefreshReport {
    pub refreshed: Vec<AppRecord>,
    pub skipped: Vec<String>,
    pub failed: Vec<RefreshFailure>,
    /// The injector itself must be refreshed last; the app gets killed by the
    /// install, so this is reported separately.
    pub self_refreshed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RefreshFailure {
    pub id: String,
    pub error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportedCert {
    pub p12_path: String,
    pub password: String,
    pub profile_path: Option<String>,
}

/// Events streamed to the UI.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Log { level: String, message: String },
    Progress { op: u64, stage: String, value: f32 },
    /// The UI must answer with `respond(prompt, TwoFactorAnswer)`.
    TwoFactor {
        prompt: u64,
        params: serde_json::Value,
    },
    /// The UI must answer with `respond(prompt, {"revoke": [serials]})` or
    /// `{"revoke": null}` to cancel.
    MaxCerts { prompt: u64, certs: Vec<CertInfo> },
    Done { op: u64, result: serde_json::Value },
    Failed { op: u64, error: String },
    /// Pre-built JSON (already has its own "type"); sent as is.
    #[serde(skip_serializing)]
    Raw(serde_json::Value),
}

impl Event {
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Event::Raw(v) => v.clone(),
            other => serde_json::to_value(other).unwrap_or(serde_json::Value::Null),
        }
    }
}

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}
