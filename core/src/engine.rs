//! The engine: accounts, install, refresh, certs. One instance per app.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

use isideload::{
    anisette::remote_v3::RemoteV3AnisetteProvider,
    auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse},
    dev::{
        app_ids::AppIdsApi, certificates::CertificatesApi, certificates::DevelopmentCertificate,
        developer_session::DeveloperSession, devices::DevicesApi, teams::DeveloperTeam,
    },
    sideload::{
        SideloaderBuilder, TeamSelection,
        builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
        cert_identity::CertificateIdentity,
        sideloader::Sideloader,
    },
    util::{
        callbacks::{ExtensionsBehaviorCallbackBox, MaxCertsCallbackBox},
        fs_storage::FsStorage,
    },
};
use rootcause::prelude::*;
use serde::Deserialize;
use serde_json::{Value as Json, json};
use tokio::sync::{Mutex, oneshot};

use crate::{device, guest, model::*, prep};

pub type Emit = Arc<dyn Fn(Event) + Send + Sync>;
type Loader = Sideloader<MaxCertsCallbackBox, ExtensionsBehaviorCallbackBox>;

struct Session {
    loader: Loader,
    info: AccountInfo,
    team: DeveloperTeam,
}

#[derive(Default)]
pub struct Prompts {
    next: AtomicU64,
    open: std::sync::Mutex<HashMap<u64, oneshot::Sender<Json>>>,
}

impl Prompts {
    fn open(&self) -> (u64, oneshot::Receiver<Json>) {
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = oneshot::channel();
        self.open.lock().unwrap().insert(id, tx);
        (id, rx)
    }
    pub fn answer(&self, id: u64, value: Json) -> bool {
        match self.open.lock().unwrap().remove(&id) {
            Some(tx) => tx.send(value).is_ok(),
            None => false,
        }
    }
    /// Cancels every open prompt (e.g. the app went to the background).
    pub fn cancel_all(&self) {
        self.open.lock().unwrap().clear();
    }
}

pub struct Engine {
    root: PathBuf,
    emit: Emit,
    pub prompts: Arc<Prompts>,
    sessions: Mutex<HashMap<String, Session>>,
    /// Serialises device/portal work; Apple and installd hate parallel jobs.
    work: Mutex<()>,
    next_op: AtomicU64,
}

fn rep(r: Report) -> String {
    clean_report(&format!("{r}"))
}

/// rootcause prints a tree with source paths; keep just the messages.
/// "● Failed to log in ├ /path ● error sending request" → "Failed to log in: error sending request"
pub fn clean_report(raw: &str) -> String {
    let mut parts: Vec<String> = Vec::new();
    for line in raw.lines() {
        let t = line.trim().trim_start_matches(['│', '├', '╰', '|', ' ']).trim();
        if t.is_empty() || t.starts_with('/') || t.contains(".rs:") {
            continue;
        }
        let t = t.trim_start_matches('●').trim();
        if !t.is_empty() && !parts.iter().any(|p| p == t) {
            parts.push(t.to_string());
        }
    }
    if parts.is_empty() { raw.trim().to_string() } else { parts.join(": ") }
}

/// Walk an error's source chain into one line.
fn chain(e: &(dyn std::error::Error + 'static)) -> String {
    let mut out = e.to_string();
    let mut cur = e.source();
    while let Some(s) = cur {
        let m = s.to_string();
        if !out.contains(&m) {
            out.push_str(": ");
            out.push_str(&m);
        }
        cur = s.source();
    }
    out
}

fn unix(d: &plist::Date) -> i64 {
    let st: std::time::SystemTime = (*d).into();
    st.duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// What the UI sends back for an app-ID-limit prompt.
#[derive(Deserialize)]
struct ReuseAnswer {
    reuse: Option<String>,
}

#[derive(Deserialize)]
struct RevokeAnswer {
    revoke: Option<Vec<String>>,
}

impl Engine {
    pub fn new(root: PathBuf, emit: Emit) -> Self {
        let _ = std::fs::create_dir_all(root.join("apps"));
        Self {
            root,
            emit,
            prompts: Arc::new(Prompts::default()),
            sessions: Mutex::new(HashMap::new()),
            work: Mutex::new(()),
            next_op: AtomicU64::new(0),
        }
    }

    pub fn next_op(&self) -> u64 {
        self.next_op.fetch_add(1, Ordering::Relaxed) + 1
    }

    pub fn emit_event(&self, ev: Event) {
        (self.emit)(ev);
    }

    fn progress(&self, op: u64, stage: &str, value: f32) {
        (self.emit)(Event::Progress {
            op,
            stage: stage.into(),
            value,
        });
    }

    // ---------- paths, config, registry ----------

    fn storage_dir(&self) -> PathBuf {
        self.root.join("isideload")
    }
    pub fn pairing_path(&self) -> PathBuf {
        self.root.join("pairing.plist")
    }
    fn app_dir(&self, id: &str) -> PathBuf {
        self.root.join("apps").join(sanitize(id))
    }

    // ---------- session persistence ----------

    fn session_path(&self, email: &str) -> PathBuf {
        self.root
            .join("sessions")
            .join(format!("{}.plist", sanitize(&email.to_lowercase())))
    }

    /// Save the authenticated session to disk so the next launch can skip a
    /// full login (no password, no 2FA).
    fn save_session(
        &self,
        email: &str,
        first_name: &str,
        last_name: &str,
        spd: &plist::Dictionary,
    ) {
        let dir = self.root.join("sessions");
        if std::fs::create_dir_all(&dir).is_err() {
            return;
        }
        let mut wrapper = plist::Dictionary::new();
        wrapper.insert(
            "first_name".into(),
            plist::Value::String(first_name.to_string()),
        );
        wrapper.insert(
            "last_name".into(),
            plist::Value::String(last_name.to_string()),
        );
        wrapper.insert("spd".into(), plist::Value::Dictionary(spd.clone()));
        let _ = plist::to_file_xml(self.session_path(email), &wrapper);
    }

    /// Load a previously saved session (SPD + name).
    fn load_saved_session(
        &self,
        email: &str,
    ) -> Option<(String, String, plist::Dictionary)> {
        let path = self.session_path(email);
        let wrapper: plist::Dictionary = plist::from_file(path).ok()?;
        let first = wrapper
            .get("first_name")?
            .as_string()?
            .to_string();
        let last = wrapper
            .get("last_name")?
            .as_string()?
            .to_string();
        let spd = wrapper.get("spd")?.as_dictionary()?.clone();
        Some((first, last, spd))
    }

    fn delete_saved_session(&self, email: &str) {
        let _ = std::fs::remove_file(self.session_path(email));
    }

    pub fn config(&self) -> Config {
        std::fs::read(self.root.join("config.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }
    pub fn set_config(&self, c: &Config) -> Result<(), String> {
        let b = serde_json::to_vec_pretty(c).map_err(|e| e.to_string())?;
        std::fs::write(self.root.join("config.json"), b).map_err(|e| e.to_string())
    }

    pub fn registry(&self) -> Vec<AppRecord> {
        std::fs::read(self.root.join("apps/registry.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }
    fn save_registry(&self, r: &[AppRecord]) -> Result<(), String> {
        let b = serde_json::to_vec_pretty(r).map_err(|e| e.to_string())?;
        std::fs::write(self.root.join("apps/registry.json"), b).map_err(|e| e.to_string())
    }
    fn upsert(&self, rec: AppRecord) -> Result<(), String> {
        let mut r = self.registry();
        r.retain(|x| x.id != rec.id);
        r.push(rec);
        self.save_registry(&r)
    }

    // ---------- accounts ----------

    pub async fn accounts(&self) -> Vec<AccountInfo> {
        self.sessions
            .lock()
            .await
            .values()
            .map(|s| s.info.clone())
            .collect()
    }

    pub async fn logout(&self, email: &str) {
        self.sessions.lock().await.remove(&email.to_lowercase());
        self.delete_saved_session(email);
    }

    fn two_factor_cb(
        &self,
    ) -> impl Fn(
        TwoFactorCallbackParams,
    ) -> std::pin::Pin<
        Box<dyn Future<Output = Result<TwoFactorCallbackResponse, Report>> + Send>,
    > + Send
    + Sync
    + 'static {
        let prompts = self.prompts.clone();
        let emit = self.emit.clone();
        move |params: TwoFactorCallbackParams| {
            let prompts = prompts.clone();
            let emit = emit.clone();
            Box::pin(async move {
                let (id, rx) = prompts.open();
                emit(Event::TwoFactor {
                    prompt: id,
                    params: serde_json::to_value(&params).unwrap_or(Json::Null),
                });
                let v = rx.await.map_err(|_| report!("Sign-in was cancelled"))?;
                let ans: TwoFactorCallbackResponse = serde_json::from_value(v)
                    .map_err(|e| report!("Bad 2FA answer from UI: {e}"))?;
                Ok(ans)
            })
        }
    }

    fn max_certs_cb(&self) -> MaxCertsCallbackBox {
        let prompts = self.prompts.clone();
        let emit = self.emit.clone();
        let machine = self.config().machine_name;
        Box::new(move |certs: Vec<DevelopmentCertificate>| {
            let prompts = prompts.clone();
            let emit = emit.clone();
            let machine = machine.clone();
            Box::pin(async move {
                let (id, rx) = prompts.open();
                emit(Event::MaxCerts {
                    prompt: id,
                    certs: certs.iter().map(|c| cert_info(c, &machine)).collect(),
                });
                let v = rx.await.map_err(|_| report!("Cancelled"))?;
                let ans: RevokeAnswer =
                    serde_json::from_value(v).map_err(|e| report!("Bad answer: {e}"))?;
                Ok(ans.revoke)
            })
        })
    }

    fn max_certs_behavior(&self) -> MaxCertsBehavior<MaxCertsCallbackBox> {
        if self.config().auto_revoke_certs {
            MaxCertsBehavior::Revoke
        } else {
            MaxCertsBehavior::Prompt(self.max_certs_cb())
        }
    }

    pub async fn login(&self, email: &str, password: &str) -> Result<AccountInfo, String> {
        let cfg = self.config();
        let mut last_err = String::from("No anisette servers configured");
        // The user's list first, then the built-in fallbacks.
        let mut servers = cfg.anisette_servers.clone();
        for f in FALLBACK_ANISETTE {
            if !servers.iter().any(|s| s.trim_end_matches('/') == *f) {
                servers.push(f.to_string());
            }
        }

        // Try restoring a saved session first (skips the password and 2FA).
        if let Some(info) = self.try_restore(email, &servers).await {
            return Ok(info);
        }

        // Fall back to a fresh login.
        for (i, url) in servers.iter().enumerate() {
            tracing::info!("Signing in as {email} (anisette: {url})");
            let provider = RemoteV3AnisetteProvider::new(
                url,
                Box::new(FsStorage::new(self.storage_dir())),
                "0".into(),
            )
            .map_err(rep)?;
            let attempt = AppleAccount::builder(email)
                .anisette_provider(provider)
                .login(password, self.two_factor_cb())
                .await;
            match attempt {
                Ok(account) => return self.finish_login(email, account).await,
                Err(e) => {
                    last_err = rep(e);
                    if is_anisette_error(&last_err) && i + 1 < servers.len() {
                        tracing::warn!("Anisette server {url} failed, trying the next one");
                        continue;
                    }
                    break;
                }
            }
        }
        Err(explain_auth(&last_err))
    }

    /// Try to restore a previously saved Apple ID session without sending the
    /// password or requiring 2FA.  Returns `None` when there is no saved
    /// session or when the saved session has expired.
    async fn try_restore(
        &self,
        email: &str,
        servers: &[String],
    ) -> Option<AccountInfo> {
        let (_, _, spd) = self.load_saved_session(email)?;
        tracing::info!("Attempting session restore for {email}");

        for url in servers {
            let provider = match RemoteV3AnisetteProvider::new(
                url,
                Box::new(FsStorage::new(self.storage_dir())),
                "0".into(),
            ) {
                Ok(p) => p,
                Err(_) => continue,
            };
            let mut account = match AppleAccount::builder(email)
                .anisette_provider(provider)
                .build()
                .await
            {
                Ok(a) => a,
                Err(e) => {
                    let msg = rep(e);
                    if is_anisette_error(&msg) {
                        tracing::warn!(
                            "Session restore: anisette {url} failed, trying the next one"
                        );
                        continue;
                    }
                    break;
                }
            };
            account.spd = Some(spd.clone());

            match self.finish_login(email, account).await {
                Ok(info) => {
                    tracing::info!("Restored session for {email}");
                    return Some(info);
                }
                Err(e) => {
                    if is_anisette_error(&e) {
                        tracing::warn!(
                            "Session restore: anisette {url} failed, trying the next one"
                        );
                        continue;
                    }
                    // Auth/token error — the session has expired.
                    tracing::info!("Saved session for {email} expired: {e}");
                    break;
                }
            }
        }

        // Restore failed; delete the stale session file.
        self.delete_saved_session(email);
        None
    }

    async fn finish_login(
        &self,
        email: &str,
        mut account: AppleAccount,
    ) -> Result<AccountInfo, String> {
        let (first, last) = account.get_name().unwrap_or_default();
        let dev = DeveloperSession::from_account(&mut account)
            .await
            .map_err(rep)?;
        // Persist the session so the next app launch can skip the password/2FA.
        if let Some(spd) = &account.spd {
            self.save_session(email, &first, &last, spd);
        }
        let cfg = self.config();
        let mut loader: Loader = SideloaderBuilder::new(dev, email.to_string())
            .team_selection(TeamSelection::First)
            .max_certs_behavior(self.max_certs_behavior())
            .storage(Box::new(FsStorage::new(self.storage_dir())))
            .machine_name(cfg.machine_name.clone())
            .extensions_behavior(ExtensionsBehaviorSelection::Fixed(
                ExtensionsBehavior::RegisterAll,
            ))
            .delete_app_after_install(false)
            .build();
        let team = loader.get_team().await.map_err(rep)?;
        let info = AccountInfo {
            email: email.to_string(),
            first_name: first,
            last_name: last,
            team_id: team.team_id.clone(),
            team_name: team.name.clone().unwrap_or_default(),
        };
        self.sessions.lock().await.insert(
            email.to_lowercase(),
            Session {
                loader,
                info: info.clone(),
                team,
            },
        );
        tracing::info!("Signed in: {} ({})", info.email, info.team_id);
        Ok(info)
    }

    /// Picks the signed-in account with the most room for one more app.
    async fn pick_account(&self, wanted: Option<&str>) -> Result<String, String> {
        let sessions = self.sessions.lock().await;
        if sessions.is_empty() {
            return Err("No Apple account signed in. Add one in Lab → Accounts.".into());
        }
        if let Some(w) = wanted {
            let k = w.to_lowercase();
            return if sessions.contains_key(&k) {
                Ok(k)
            } else {
                Err(format!("{w} is not signed in"))
            };
        }
        let reg = self.registry();
        let mut best: Option<(usize, String)> = None;
        for (k, _) in sessions.iter() {
            let used = reg.iter().filter(|r| r.account.to_lowercase() == *k).count();
            if best.as_ref().is_none_or(|(u, _)| used < *u) {
                best = Some((used, k.clone()));
            }
        }
        Ok(best.unwrap().1)
    }

    // ---------- install / refresh ----------

    /// Sign and install. `source` is an .ipa or a .app dir.
    /// `record_id` = Some when refreshing an existing record.
    pub async fn install(
        &self,
        op: u64,
        source: &Path,
        mut opts: InstallOptions,
        account: Option<&str>,
        record_id: Option<&str>,
    ) -> Result<AppRecord, String> {
        let _guard = self.work.lock().await;
        let mut key = self.pick_account(account).await?;
        let is_self = record_id == Some(SELF_ID);
        let cfg = self.config();

        // 3-apps-per-account rule (free accounts), checked before any work so
        // the user can switch account or replace an app.
        if record_id.is_none() && cfg.enforce_free_limits {
            let (bundle_id, name) = prep::peek_info(source)?;
            key = self.check_slots(&key, &bundle_id, &name).await?;
        }

        // Everything that needs the session happens under this lock.
        let mut sessions = self.sessions.lock().await;
        let sess = sessions
            .get_mut(&key)
            .ok_or_else(|| format!("{key} is not signed in"))?;
        let team = sess.team.clone();
        let email = sess.info.email.clone();

        self.progress(op, "Unpacking", 0.02);
        let work = self.root.join("work").join(op.to_string());
        let mut prepared = prep::prepare(source, &work, &opts, Some(&team.team_id))?;
        let reg = self.registry();

        // App ID budget: offer to reuse an existing ID when there's no room.
        self.progress(op, "Checking app IDs", 0.06);
        let ids = sess
            .loader
            .get_dev_session()
            .list_app_ids(&team, None)
            .await
            .map_err(rep)?;
        let main_id = format!("{}.{}", prepared.original_bundle_id, team.team_id);
        let mut needed = usize::from(!ids.app_ids.iter().any(|a| a.identifier == main_id));
        if !opts.strip_extensions {
            needed += prepared.extension_count; // rough: assumes new
        }
        // Apple sometimes reports a negative count when the quota is used up.
        let available = ids.available_quantity.unwrap_or(i64::MAX).max(0);
        if needed > 0 && needed as i64 > available {
            let (pid, rx) = self.prompts.open();
            let choices: Vec<Json> = ids
                .app_ids
                .iter()
                .map(|a| {
                    let used_by = reg
                        .iter()
                        .find(|r| r.installed_bundle_id == a.identifier)
                        .map(|r| r.name.clone());
                    json!({
                        "identifier": a.identifier,
                        "name": a.name,
                        "expires_at": a.expiration_date.as_ref().map(unix),
                        "used_by": used_by,
                    })
                })
                .collect();
            (self.emit)(Event::Raw(json!({
                "type": "app_id_limit",
                "prompt": pid,
                "account": email,
                "needed": needed,
                "available": available,
                "app_name": prepared.name,
                "choices": choices,
            })));
            let ans: ReuseAnswer = serde_json::from_value(rx.await.map_err(|_| "Cancelled")?)
                .map_err(|e| e.to_string())?;
            let Some(reuse) = ans.reuse else {
                return Err(format!(
                    "{email} has no free app IDs this week ({needed} needed, {available} left)."
                ));
            };
            let suffix = format!(".{}", team.team_id);
            let base = reuse.strip_suffix(&suffix).unwrap_or(&reuse).to_string();
            tracing::info!("Reusing app ID {reuse} for {}", prepared.name);
            opts.custom_bundle_id = Some(base);
            opts.strip_extensions = true;
            prepared = prep::prepare(source, &work, &opts, Some(&team.team_id))?;
        }

        let id = record_id
            .map(String::from)
            .unwrap_or_else(|| prepared.original_bundle_id.clone());
        let store = self.app_dir(&id);
        std::fs::create_dir_all(&store).map_err(|e| e.to_string())?;

        // Keep the untouched original for refreshes (not for the injector
        // itself: it re-signs its own running bundle).
        if !is_self {
            let orig = store.join("original.ipa");
            if source != orig {
                if source.is_dir() {
                    prep::pack_ipa(source, &orig)?;
                } else {
                    std::fs::copy(source, &orig).map_err(|e| format!("saving ipa: {e}"))?;
                }
            }
        }
        let has_icon = match &prepared.icon {
            Some(p) => std::fs::copy(p, store.join("icon.png")).is_ok(),
            None => store.join("icon.png").exists(),
        };

        self.progress(op, "Connecting to device", 0.1);
        let provider = device::connect(&cfg.target, &self.pairing_path()).await?;
        let dinfo = device::info(&provider).await?;
        sess.loader
            .get_dev_session()
            .ensure_device_registered(&team, &dinfo.name, &dinfo.udid, None)
            .await
            .map_err(rep)?;

        self.progress(op, "Signing", 0.15);
        let emit = self.emit.clone();
        let (signed, _special) = sess
            .loader
            .sign_app(
                prepared.app_dir.clone(),
                Some(team.clone()),
                opts.increased_memory_limit,
                Some(move |p: f32| {
                    emit(Event::Progress {
                        op,
                        stage: "Signing".into(),
                        value: 0.15 + p * 0.35,
                    });
                    std::future::ready(())
                }),
                None,
                Some(&dinfo.udid),
            )
            .await
            .map_err(|e| explain_portal(&rep(e)))?;
        drop(sessions);

        let profile = std::fs::read(signed.join("embedded.mobileprovision")).unwrap_or_default();
        let expires_at = prep::profile_expiry(&profile).unwrap_or(now() + 7 * 86400);
        let _ = std::fs::write(store.join("profile.mobileprovision"), &profile);
        let installed_bundle_id = prep::read_dict(&signed.join("Info.plist"))?
            .get("CFBundleIdentifier")
            .and_then(|v| v.as_string())
            .unwrap_or_default()
            .to_string();

        let rec = AppRecord {
            id: id.clone(),
            name: prepared.name.clone(),
            version: prepared.version.clone(),
            installed_bundle_id: installed_bundle_id.clone(),
            installed_at: now(),
            expires_at,
            options: opts,
            app_id_count: 1 + prepared.extension_count,
            has_icon,
            size_bytes: prep::dir_size(&signed),
            account: email,
        };

        // Anything else living on this bundle id just got overwritten.
        let mut reg = self.registry();
        reg.retain(|r| r.id == id || r.installed_bundle_id != installed_bundle_id);
        self.save_registry(&reg)?;
        // The injector dies mid-install when it replaces itself, so save first.
        if is_self {
            self.upsert(rec.clone())?;
        }

        self.progress(op, "Installing", 0.5);
        let emit = self.emit.clone();
        isideload::sideload::install::install_app(&provider, &signed, move |pct| {
            emit(Event::Progress {
                op,
                stage: "Installing".into(),
                value: 0.5 + pct as f32 / 200.0,
            });
        })
        .await
        .map_err(|e| device::explain(&rep(e)))?;

        let _ = std::fs::remove_dir_all(&work);
        self.upsert(rec.clone())?;
        self.progress(op, "Done", 1.0);
        tracing::info!("Installed {} ({installed_bundle_id})", rec.name);
        Ok(rec)
    }

    pub async fn refresh(&self, op: u64, id: &str) -> Result<AppRecord, String> {
        let rec = self
            .registry()
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| format!("No app with id {id}"))?;
        let src = self.app_dir(id).join("original.ipa");
        if !src.exists() {
            return Err(format!("The original IPA for {} is missing; re-inject it.", rec.name));
        }
        self.install(op, &src, rec.options.clone(), Some(&rec.account), Some(id))
            .await
    }

    /// Re-sign the running injector from its own bundle.
    pub async fn refresh_self(
        &self,
        op: u64,
        bundle: &Path,
        account: Option<&str>,
    ) -> Result<AppRecord, String> {
        let account = account
            .map(String::from)
            .or_else(|| {
                self.registry()
                    .into_iter()
                    .find(|r| r.id == SELF_ID)
                    .map(|r| r.account)
            });
        let opts = InstallOptions {
            file_sharing: true,
            ..Default::default()
        };
        self.install(op, bundle, opts, account.as_deref(), Some(SELF_ID))
            .await
    }

    /// Refresh everything expiring within the threshold (or everything when
    /// `force`). The injector itself goes last because installing it kills us.
    pub async fn refresh_all(
        &self,
        op: u64,
        force: bool,
        self_bundle: Option<&Path>,
    ) -> RefreshReport {
        let threshold = self.config().refresh_threshold_hours as i64 * 3600;
        let mut report = RefreshReport {
            refreshed: vec![],
            skipped: vec![],
            failed: vec![],
            self_refreshed: false,
        };
        let signed_in: Vec<String> = self.sessions.lock().await.keys().cloned().collect();
        for rec in self.registry().into_iter().filter(|r| r.id != SELF_ID) {
            let due = force || rec.expires_at - now() < threshold;
            if !due {
                report.skipped.push(rec.id);
                continue;
            }
            if !signed_in.contains(&rec.account.to_lowercase()) {
                report.failed.push(RefreshFailure {
                    id: rec.id,
                    error: format!("{} is not signed in", rec.account),
                });
                continue;
            }
            match self.refresh(op, &rec.id).await {
                Ok(r) => report.refreshed.push(r),
                Err(error) => report.failed.push(RefreshFailure { id: rec.id, error }),
            }
        }
        if let Some(bundle) = self_bundle {
            let self_exp = std::fs::read(bundle.join("embedded.mobileprovision"))
                .ok()
                .and_then(|b| prep::profile_expiry(&b));
            let due = force || self_exp.is_none_or(|e| e - now() < threshold);
            if due {
                (self.emit)(Event::Raw(json!({
                    "type": "self_refresh_starting",
                    "report": serde_json::to_value(&report).unwrap_or(Json::Null),
                })));
                match self.refresh_self(op, bundle, None).await {
                    Ok(_) => report.self_refreshed = true,
                    Err(error) => report.failed.push(RefreshFailure {
                        id: SELF_ID.into(),
                        error,
                    }),
                }
            }
        }
        report
    }

    pub async fn remove(&self, id: &str, uninstall: bool) -> Result<(), String> {
        let _guard = self.work.lock().await;
        let mut reg = self.registry();
        let Some(rec) = reg.iter().find(|r| r.id == id).cloned() else {
            return Err(format!("No app with id {id}"));
        };
        if uninstall {
            let p = device::connect(&self.config().target, &self.pairing_path()).await?;
            device::uninstall(&p, &rec.installed_bundle_id).await?;
        }
        reg.retain(|r| r.id != id);
        self.save_registry(&reg)?;
        let _ = std::fs::remove_dir_all(self.app_dir(id));
        Ok(())
    }

    /// Returns the account to install with. Prompts when `key` already has 3
    /// apps: replace one (uninstalls it), switch account, or cancel.
    async fn check_slots(&self, key: &str, bundle_id: &str, name: &str) -> Result<String, String> {
        let reg = self.registry();
        let on = |acct: &str| {
            reg.iter()
                .filter(|r| r.account.eq_ignore_ascii_case(acct) && r.id != bundle_id)
                .collect::<Vec<_>>()
        };
        let used = on(key);
        if used.len() < 3 {
            return Ok(key.to_string());
        }
        let others: Vec<Json> = self
            .sessions
            .lock()
            .await
            .keys()
            .filter(|k| k.as_str() != key)
            .map(|k| json!({ "email": k, "used": on(k).len() }))
            .collect();
        let (pid, rx) = self.prompts.open();
        (self.emit)(Event::Raw(json!({
            "type": "app_slots_full",
            "prompt": pid,
            "account": key,
            "app_name": name,
            "apps": used.iter().map(|r| json!({
                "id": r.id, "name": r.name, "expires_at": r.expires_at, "is_self": r.id == SELF_ID,
            })).collect::<Vec<_>>(),
            "other_accounts": others,
        })));
        let ans = rx.await.map_err(|_| "Cancelled")?;
        if let Some(acct) = ans.get("account").and_then(Json::as_str) {
            tracing::info!("Switching to {acct} (3/3 on {key})");
            return Ok(acct.to_lowercase());
        }
        if let Some(id) = ans.get("replace").and_then(Json::as_str) {
            let rec = reg.iter().find(|r| r.id == id).cloned().ok_or("Unknown app")?;
            tracing::info!("Uninstalling {} to free a slot", rec.name);
            let p = device::connect(&self.config().target, &self.pairing_path()).await?;
            device::uninstall(&p, &rec.installed_bundle_id).await?;
            let mut r = self.registry();
            r.retain(|x| x.id != id);
            self.save_registry(&r)?;
            let _ = std::fs::remove_dir_all(self.app_dir(id));
            return Ok(key.to_string());
        }
        Err(format!("{key} already has 3 apps. Free accounts can't have more at once."))
    }

    // ---------- run inside (guests) ----------

    pub fn guests(&self) -> Vec<GuestRecord> {
        std::fs::read(self.root.join("guests/registry.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }
    fn save_guests(&self, g: &[GuestRecord]) -> Result<(), String> {
        std::fs::create_dir_all(self.root.join("guests")).map_err(|e| e.to_string())?;
        let b = serde_json::to_vec_pretty(g).map_err(|e| e.to_string())?;
        std::fs::write(self.root.join("guests/registry.json"), b).map_err(|e| e.to_string())
    }

    /// The account that signed the injector itself; guests must use the same
    /// team or iOS refuses to load them into our process.
    async fn host_account(&self, wanted: Option<&str>) -> Result<String, String> {
        if let Some(rec) = self.registry().into_iter().find(|r| r.id == SELF_ID) {
            return self.pick_account(Some(&rec.account)).await.map_err(|_| {
                format!(
                    "JapuszkoInjector was signed by {}. Sign that account in to load guests.",
                    rec.account
                )
            });
        }
        self.pick_account(wanted).await
    }

    async fn identity(&self, key: &str) -> Result<(CertificateIdentity, String), String> {
        let cfg = self.config();
        let storage = FsStorage::new(self.storage_dir());
        let behavior = self.max_certs_behavior();
        self.with_session(Some(key), async |s| {
            let team = s.team.clone();
            let email = s.info.email.clone();
            let ident = CertificateIdentity::retrieve(
                &cfg.machine_name,
                &email,
                s.loader.get_dev_session(),
                &team,
                &storage,
                &behavior,
            )
            .await
            .map_err(rep)?;
            Ok((ident, team.team_id))
        })
        .await
    }

    /// Patch + sign an IPA into the container.
    pub async fn guest_add(
        &self,
        op: u64,
        source: &Path,
        custom_name: Option<String>,
        account: Option<&str>,
    ) -> Result<GuestRecord, String> {
        let _guard = self.work.lock().await;
        let key = self.host_account(account).await?;
        self.progress(op, "Unpacking", 0.05);
        let work = self.root.join("work").join(op.to_string());
        let opts = InstallOptions {
            custom_name,
            strip_extensions: true,
            ..Default::default()
        };
        let p = prep::prepare(source, &work, &opts, None)?;
        let info = prep::read_dict(&p.app_dir.join("Info.plist"))?;
        let exec = info
            .get("CFBundleExecutable")
            .and_then(|v| v.as_string())
            .ok_or("no CFBundleExecutable")?
            .to_string();

        self.progress(op, "Patching", 0.2);
        let report = guest::patch_executable(&p.app_dir.join(&exec))?;
        tracing::info!(
            "Patched {exec}: thinned={} id={} paths={}",
            report.thinned,
            report.inserted_id,
            report.paths_rewritten
        );

        self.progress(op, "Fetching certificate", 0.3);
        let (ident, team_id) = self.identity(&key).await?;
        self.progress(op, "Signing", 0.45);
        let app_dir = p.app_dir.clone();
        tokio::task::block_in_place(|| guest::sign_bundle(&app_dir, &ident, &team_id))?;

        self.progress(op, "Storing", 0.9);
        let id = p.original_bundle_id.clone();
        let base = self.root.join("guests").join(sanitize(&id));
        let app_name = p.app_dir.file_name().ok_or("bad app dir")?.to_owned();
        let dest = base.join(&app_name);
        std::fs::create_dir_all(&base).map_err(|e| e.to_string())?;
        if dest.exists() {
            std::fs::remove_dir_all(&dest).map_err(|e| e.to_string())?;
        }
        std::fs::rename(&p.app_dir, &dest).map_err(|e| format!("storing guest: {e}"))?;
        std::fs::create_dir_all(base.join("Data")).map_err(|e| e.to_string())?;
        let has_icon = p
            .icon
            .as_ref()
            .map(|i| i.strip_prefix(&p.app_dir).ok().map(|rel| dest.join(rel)))
            .flatten()
            .and_then(|i| std::fs::copy(i, base.join("icon.png")).ok())
            .is_some();
        let _ = std::fs::remove_dir_all(&work);

        let rel = |path: &Path| path.strip_prefix(&self.root).unwrap_or(path).to_string_lossy().into_owned();
        let rec = GuestRecord {
            id: id.clone(),
            name: p.name,
            version: p.version,
            bundle_id: id.clone(),
            exec_name: exec,
            app_rel: rel(&dest),
            data_rel: rel(&base.join("Data")),
            icon_rel: has_icon.then(|| rel(&base.join("icon.png"))),
            team_id,
            added_at: now(),
            size_bytes: prep::dir_size(&dest),
        };
        let mut g = self.guests();
        g.retain(|x| x.id != id);
        g.push(rec.clone());
        self.save_guests(&g)?;
        self.progress(op, "Done", 1.0);
        tracing::info!("{} is ready to run inside", rec.name);
        Ok(rec)
    }

    /// Re-sign guests (after a certificate change). `id: None` = all.
    pub async fn guest_resign(&self, op: u64, id: Option<&str>) -> Result<Vec<GuestRecord>, String> {
        let _guard = self.work.lock().await;
        let key = self.host_account(None).await?;
        let (ident, team_id) = self.identity(&key).await?;
        let mut all = self.guests();
        let total = all.len().max(1) as f32;
        for (i, g) in all.iter_mut().enumerate() {
            if id.is_some_and(|x| x != g.id) {
                continue;
            }
            self.progress(op, &format!("Signing {}", g.name), i as f32 / total);
            let dir = self.root.join(&g.app_rel);
            guest::patch_executable(&dir.join(&g.exec_name))?;
            tokio::task::block_in_place(|| guest::sign_bundle(&dir, &ident, &team_id))?;
            g.team_id = team_id.clone();
        }
        self.save_guests(&all)?;
        self.progress(op, "Done", 1.0);
        Ok(all)
    }

    pub fn guest_remove(&self, id: &str, wipe_data: bool) -> Result<(), String> {
        let mut g = self.guests();
        let rec = g.iter().find(|x| x.id == id).cloned().ok_or("No such guest")?;
        let base = self.root.join("guests").join(sanitize(id));
        let _ = std::fs::remove_dir_all(self.root.join(&rec.app_rel));
        if wipe_data {
            let _ = std::fs::remove_dir_all(&base);
        }
        g.retain(|x| x.id != id);
        self.save_guests(&g)
    }

    // ---------- portal stuff ----------

    async fn with_session<T>(
        &self,
        account: Option<&str>,
        f: impl AsyncFnOnce(&mut Session) -> Result<T, String>,
    ) -> Result<T, String> {
        let key = self.pick_account(account).await?;
        let mut sessions = self.sessions.lock().await;
        let s = sessions
            .get_mut(&key)
            .ok_or_else(|| format!("{key} is not signed in"))?;
        f(s).await
    }

    pub async fn certs(&self, account: Option<&str>) -> Result<Vec<CertInfo>, String> {
        let machine = self.config().machine_name;
        self.with_session(account, async |s| {
            let team = s.team.clone();
            let certs = s
                .loader
                .get_dev_session()
                .list_ios_certs(&team)
                .await
                .map_err(rep)?;
            Ok(certs.iter().map(|c| cert_info(c, &machine)).collect())
        })
        .await
    }

    pub async fn revoke_cert(&self, account: Option<&str>, serial: &str) -> Result<(), String> {
        self.with_session(account, async |s| {
            let team = s.team.clone();
            s.loader
                .get_dev_session()
                .revoke_development_cert(&team, serial, None)
                .await
                .map_err(rep)
        })
        .await
    }

    pub async fn app_ids(&self, account: Option<&str>) -> Result<AppIdsInfo, String> {
        self.with_session(account, async |s| {
            let team = s.team.clone();
            let r = s
                .loader
                .get_dev_session()
                .list_app_ids(&team, None)
                .await
                .map_err(rep)?;
            Ok(AppIdsInfo {
                max: r.max_quantity,
                available: r.available_quantity,
                ids: r
                    .app_ids
                    .iter()
                    .map(|a| AppIdInfo {
                        identifier: a.identifier.clone(),
                        name: a.name.clone(),
                        expires_at: a.expiration_date.as_ref().map(unix),
                    })
                    .collect(),
            })
        })
        .await
    }

    /// Export the signing cert as .p12 (+ an app's profile if `app` is given).
    pub async fn export_cert(
        &self,
        account: Option<&str>,
        password: Option<String>,
        out_dir: &Path,
        app: Option<&str>,
    ) -> Result<ExportedCert, String> {
        let key = self.pick_account(account).await?;
        let (ident, _) = self.identity(&key).await?;
        // SideStore/AltStore expect the machine id as the password.
        let password = password
            .filter(|p| !p.is_empty())
            .unwrap_or_else(|| ident.machine_id.clone());
        let p12 = ident.as_p12(&password).await.map_err(rep)?;
        std::fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;
        let p12_path = out_dir.join("JapuszkoInjector.p12");
        std::fs::write(&p12_path, p12).map_err(|e| e.to_string())?;

        let profile_path = match app {
            Some(id) => {
                let src = self.app_dir(id).join("profile.mobileprovision");
                let dst = out_dir.join(format!("{}.mobileprovision", sanitize(id)));
                std::fs::copy(&src, &dst)
                    .map_err(|e| format!("No saved profile for {id}: {e}"))?;
                Some(dst.to_string_lossy().into_owned())
            }
            None => None,
        };
        Ok(ExportedCert {
            p12_path: p12_path.to_string_lossy().into_owned(),
            password,
            profile_path,
        })
    }

    // ---------- diagnostics ----------

    /// Checks DNS, TCP and HTTPS to the first anisette server separately, so
    /// a failed sign-in can be pinned to one layer.
    pub async fn net_test(&self) -> Json {
        let cfg = self.config();
        let url = cfg
            .anisette_servers
            .first()
            .cloned()
            .unwrap_or_else(|| DEFAULT_ANISETTE.to_string());
        let host = url
            .trim_start_matches("https://")
            .trim_start_matches("http://")
            .split('/')
            .next()
            .unwrap_or("")
            .to_string();
        let mut steps: Vec<Json> = Vec::new();
        let timeout = std::time::Duration::from_secs(8);

        let addrs: Vec<std::net::SocketAddr> =
            match tokio::time::timeout(timeout, tokio::net::lookup_host((host.as_str(), 443))).await {
                Ok(Ok(a)) => a.collect(),
                Ok(Err(e)) => {
                    steps.push(json!({"step": "DNS", "ok": false, "detail": e.to_string()}));
                    vec![]
                }
                Err(_) => {
                    steps.push(json!({"step": "DNS", "ok": false, "detail": "timed out"}));
                    vec![]
                }
            };
        if !addrs.is_empty() {
            let list: Vec<String> = addrs.iter().map(|a| a.ip().to_string()).collect();
            steps.push(json!({"step": "DNS", "ok": true, "detail": list.join(", ")}));
            let tcp = match tokio::time::timeout(timeout, tokio::net::TcpStream::connect(addrs[0])).await {
                Ok(Ok(_)) => json!({"step": "TCP", "ok": true, "detail": format!("connected to {}", addrs[0])}),
                Ok(Err(e)) => json!({"step": "TCP", "ok": false, "detail": e.to_string()}),
                Err(_) => json!({"step": "TCP", "ok": false, "detail": "timed out"}),
            };
            steps.push(tcp);
        }

        let target = format!("{}/v3/client_info", url.trim_end_matches('/'));
        let https = match reqwest::Client::builder().timeout(timeout).build() {
            Err(e) => json!({"step": "HTTPS", "ok": false, "detail": format!("client: {}", chain(&e))}),
            Ok(c) => match c.get(&target).send().await {
                Ok(r) => json!({"step": "HTTPS", "ok": r.status().is_success(), "detail": format!("HTTP {}", r.status())}),
                Err(e) => json!({"step": "HTTPS", "ok": false, "detail": chain(&e)}),
            },
        };
        steps.push(https);
        tracing::info!("Network test for {url}: {}", Json::Array(steps.clone()));
        json!({ "server": url, "steps": steps })
    }

    // ---------- device ----------

    pub async fn check_device(&self) -> Result<DeviceInfo, String> {
        let p = device::connect(&self.config().target, &self.pairing_path()).await?;
        device::info(&p).await
    }

    pub async fn device_apps(&self) -> Result<Vec<(String, String, String)>, String> {
        let p = device::connect(&self.config().target, &self.pairing_path()).await?;
        device::installed_apps(&p).await
    }

    /// Move files the Linux bootstrap dropped into Documents/bootstrap into
    /// private storage.
    pub fn import_bootstrap(&self, dir: &Path) -> Result<Vec<String>, String> {
        let mut imported = vec![];
        if !dir.exists() {
            return Ok(imported);
        }
        let pairing = dir.join("pairing.plist");
        if pairing.exists() {
            std::fs::copy(&pairing, self.pairing_path()).map_err(|e| e.to_string())?;
            imported.push("pairing file".into());
        }
        let state = dir.join("isideload");
        if state.exists() {
            prep::copy_dir(&state, &self.storage_dir())?;
            imported.push("signing state".into());
        }
        let cfg = dir.join("config.json");
        if cfg.exists() && !self.root.join("config.json").exists() {
            std::fs::copy(&cfg, self.root.join("config.json")).map_err(|e| e.to_string())?;
            imported.push("config".into());
        }
        let _ = std::fs::remove_dir_all(dir);
        Ok(imported)
    }

    pub fn import_pairing(&self, path: &Path) -> Result<(), String> {
        idevice::pairing_file::PairingFile::read_from_file(path)
            .map_err(|e| format!("That doesn't look like a pairing file: {e}"))?;
        std::fs::copy(path, self.pairing_path())
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    pub fn icon_path(&self, id: &str) -> PathBuf {
        self.app_dir(id).join("icon.png")
    }

    pub fn root(&self) -> &Path {
        &self.root
    }
}

fn cert_info(c: &DevelopmentCertificate, our_machine: &str) -> CertInfo {
    let machine_name = c.machine_name.clone().unwrap_or_default();
    CertInfo {
        name: c.name.clone().unwrap_or_default(),
        serial: c.serial_number.clone().unwrap_or_default(),
        is_ours: machine_name == our_machine,
        machine_name,
        machine_id: c.machine_id.clone().unwrap_or_default(),
        expires_at: c.expiration_date.as_ref().map(unix),
    }
}

fn sanitize(id: &str) -> String {
    id.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_' { c } else { '_' })
        .collect()
}

fn is_anisette_error(msg: &str) -> bool {
    let l = msg.to_lowercase();
    l.contains("anisette")
        || l.contains("websocket")
        || l.contains("error sending request")
        || l.contains("dns")
}

fn explain_auth(err: &str) -> String {
    let l = err.to_lowercase();
    if l.contains("-22406") || l.contains("incorrect") {
        "Wrong Apple ID or password.".into()
    } else if l.contains("anisette") || l.contains("websocket") {
        format!(
            "Couldn't reach an anisette server. Check the internet connection, run Settings → Advanced → Network Test, or add another server under Anisette Servers. Details: {err}"
        )
    } else {
        err.into()
    }
}

fn explain_portal(err: &str) -> String {
    let l = err.to_lowercase();
    if l.contains("not enough available app ids") {
        format!("{err} Free accounts get 10 new app IDs per week; reuse one or wait.")
    } else if l.contains("maximum number") && l.contains("certificate") {
        format!("{err} Revoke an old certificate in Lab → Certificates.")
    } else {
        err.into()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn cleans_rootcause_tree() {
        let raw = "Failed to get anisette client info\n├ /Users/runner/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/isideload-0.5.2/src/auth/apple_account.rs:164\n│\n● Failed to request /v3/client_info from anisette server\n├ /Users/runner/x/isideload-0.5.2/src/anisette/remote_v3/mod.rs:141\n│\n● error sending request for url (https://ani.iloader.app/v3/client_info)\n╰ /Users/runner/x/remote_v3/mod.rs:141";
        assert_eq!(
            super::clean_report(raw),
            "Failed to get anisette client info: Failed to request /v3/client_info from anisette server: error sending request for url (https://ani.iloader.app/v3/client_info)"
        );
    }
}
