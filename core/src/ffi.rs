//! C ABI for the Swift app. Everything is JSON strings:
//!
//! * `jinject_init(root, cb, ctx)` once at launch.
//! * `jinject_call(json)` starts an async op and returns its op id; the result
//!   arrives as a `done` / `failed` event with that id.
//! * `jinject_call_sync(json)` for quick local ops (list, config…); returns a
//!   JSON string you free with `jinject_free`.
//! * `jinject_respond(prompt, json)` answers 2FA / cert / app ID prompts.

use std::{
    ffi::{CStr, CString, c_char, c_void},
    path::PathBuf,
    sync::Arc,
};

use once_cell::sync::OnceCell;
use serde_json::{Value as Json, json};

use crate::{engine::Engine, model::*, prep};

pub type EventCallback = extern "C" fn(ctx: *mut c_void, json: *const c_char);

struct Global {
    engine: Arc<Engine>,
    rt: tokio::runtime::Runtime,
}

static GLOBAL: OnceCell<Global> = OnceCell::new();

#[derive(Clone, Copy)]
struct Ctx(usize);
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn out(s: String) -> *mut c_char {
    CString::new(s.replace('\0', ""))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

struct LogWriter {
    emit: crate::engine::Emit,
}

impl std::io::Write for LogWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let line = String::from_utf8_lossy(buf).trim().to_string();
        if !line.is_empty() {
            let (level, message) = match line.split_once(' ') {
                Some((l, m)) if ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"].contains(&l) => {
                    (l.to_lowercase(), m.trim().to_string())
                }
                _ => ("info".to_string(), line),
            };
            (self.emit)(Event::Log { level, message });
        }
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Returns 0 on success, 1 if already initialised, -1 on failure.
#[unsafe(no_mangle)]
pub extern "C" fn jinject_init(root: *const c_char, cb: EventCallback, ctx: *mut c_void) -> i32 {
    if GLOBAL.get().is_some() {
        return 1;
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();

    let ctx = Ctx(ctx as usize);
    let emit: crate::engine::Emit = Arc::new(move |ev: Event| {
        let s = serde_json::to_string(&ev.to_json()).unwrap_or_default();
        if let Ok(c) = CString::new(s) {
            cb(ctx.0 as *mut c_void, c.as_ptr());
        }
    });

    let log_emit = emit.clone();
    let _ = tracing_subscriber::fmt()
        .with_ansi(false)
        .without_time()
        .with_target(false)
        .with_max_level(tracing::Level::INFO)
        .with_writer(move || LogWriter {
            emit: log_emit.clone(),
        })
        .try_init();

    let rt = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(_) => return -1,
    };
    let engine = Arc::new(Engine::new(PathBuf::from(cstr(root)), emit));
    if GLOBAL.set(Global { engine, rt }).is_err() {
        return 1;
    }
    0
}

/// Start an async op. Returns the op id (0 if not initialised / bad JSON).
#[unsafe(no_mangle)]
pub extern "C" fn jinject_call(request: *const c_char) -> u64 {
    let Some(g) = GLOBAL.get() else { return 0 };
    let Ok(req) = serde_json::from_str::<Json>(&cstr(request)) else {
        return 0;
    };
    let engine = g.engine.clone();
    let op = engine.next_op();
    g.rt.spawn(async move {
        let result = dispatch(&engine, op, &req).await;
        let ev = match result {
            Ok(result) => Event::Done { op, result },
            Err(error) => Event::Failed { op, error },
        };
        engine.emit_event(ev);
    });
    op
}

/// Run a quick local op and return `{"ok": ...}` or `{"error": "..."}`.
#[unsafe(no_mangle)]
pub extern "C" fn jinject_call_sync(request: *const c_char) -> *mut c_char {
    let Some(g) = GLOBAL.get() else {
        return out(r#"{"error":"not initialised"}"#.into());
    };
    let res = serde_json::from_str::<Json>(&cstr(request))
        .map_err(|e| e.to_string())
        .and_then(|req| dispatch_sync(&g.engine, &req));
    out(match res {
        Ok(v) => json!({ "ok": v }).to_string(),
        Err(e) => json!({ "error": e }).to_string(),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn jinject_respond(prompt: u64, answer: *const c_char) -> bool {
    let Some(g) = GLOBAL.get() else { return false };
    let v = serde_json::from_str(&cstr(answer)).unwrap_or(Json::Null);
    g.engine.prompts.answer(prompt, v)
}

#[unsafe(no_mangle)]
pub extern "C" fn jinject_cancel_prompts() {
    if let Some(g) = GLOBAL.get() {
        g.engine.prompts.cancel_all();
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn jinject_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

fn s<'a>(req: &'a Json, k: &str) -> Option<&'a str> {
    req.get(k).and_then(Json::as_str)
}
fn need<'a>(req: &'a Json, k: &str) -> Result<&'a str, String> {
    s(req, k).ok_or_else(|| format!("missing '{k}'"))
}
fn to<T: serde::Serialize>(v: T) -> Result<Json, String> {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

pub async fn dispatch(e: &Engine, op: u64, req: &Json) -> Result<Json, String> {
    let account = s(req, "account");
    match need(req, "op")? {
        "login" => to(e.login(need(req, "email")?, need(req, "password")?).await?),
        "logout" => {
            e.logout(need(req, "email")?).await;
            Ok(Json::Null)
        }
        "accounts" => to(e.accounts().await),
        "install" => {
            let opts: InstallOptions = req
                .get("options")
                .cloned()
                .map(serde_json::from_value)
                .transpose()
                .map_err(|e| e.to_string())?
                .unwrap_or_default();
            to(e
                .install(op, &PathBuf::from(need(req, "path")?), opts, account, None)
                .await?)
        }
        "refresh" => to(e.refresh(op, need(req, "id")?).await?),
        "refresh_self" => to(e
            .refresh_self(op, &PathBuf::from(need(req, "bundle")?), account)
            .await?),
        "refresh_all" => {
            let force = req.get("force").and_then(Json::as_bool).unwrap_or(false);
            let bundle = s(req, "self_bundle").map(PathBuf::from);
            to(e.refresh_all(op, force, bundle.as_deref()).await)
        }
        "remove" => {
            let un = req.get("uninstall").and_then(Json::as_bool).unwrap_or(false);
            e.remove(need(req, "id")?, un).await?;
            Ok(Json::Null)
        }
        "certs" => to(e.certs(account).await?),
        "revoke_cert" => {
            e.revoke_cert(account, need(req, "serial")?).await?;
            Ok(Json::Null)
        }
        "app_ids" => to(e.app_ids(account).await?),
        "export_cert" => to(e
            .export_cert(
                account,
                s(req, "password").map(String::from),
                &PathBuf::from(need(req, "out_dir")?),
                s(req, "app"),
            )
            .await?),
        "check_device" => to(e.check_device().await?),
        "guest_add" => to(e
            .guest_add(
                op,
                &PathBuf::from(need(req, "path")?),
                s(req, "name").filter(|n| !n.is_empty()).map(String::from),
                account,
            )
            .await?),
        "guest_resign" => to(e.guest_resign(op, s(req, "id")).await?),
        "device_apps" => {
            let apps = e.device_apps().await?;
            to(apps
                .into_iter()
                .map(|(id, name, version)| json!({"id": id, "name": name, "version": version}))
                .collect::<Vec<_>>())
        }
        other => dispatch_sync(e, req).map_err(|err| {
            if err.starts_with("unknown op") {
                format!("unknown op '{other}'")
            } else {
                err
            }
        }),
    }
}

pub fn dispatch_sync(e: &Engine, req: &Json) -> Result<Json, String> {
    match need(req, "op")? {
        "list" => to(e.registry()),
        "guests" => to(e.guests()),
        "guest_remove" => {
            let wipe = req.get("wipe_data").and_then(Json::as_bool).unwrap_or(false);
            e.guest_remove(need(req, "id")?, wipe)?;
            Ok(Json::Null)
        }
        "root" => Ok(Json::String(e.root().to_string_lossy().into_owned())),
        "get_config" => to(e.config()),
        "set_config" => {
            let c: Config = serde_json::from_value(req.get("config").cloned().unwrap_or_default())
                .map_err(|e| e.to_string())?;
            e.set_config(&c)?;
            Ok(Json::Null)
        }
        "import_bootstrap" => to(e.import_bootstrap(&PathBuf::from(need(req, "dir")?))?),
        "import_pairing" => {
            e.import_pairing(&PathBuf::from(need(req, "path")?))?;
            Ok(Json::Null)
        }
        "has_pairing" => Ok(Json::Bool(e.pairing_path().exists())),
        "icon_path" => Ok(Json::String(
            e.icon_path(need(req, "id")?).to_string_lossy().into_owned(),
        )),
        "self_status" => {
            let b = PathBuf::from(need(req, "bundle")?);
            let exp = std::fs::read(b.join("embedded.mobileprovision"))
                .ok()
                .and_then(|x| prep::profile_expiry(&x));
            Ok(json!({ "expires_at": exp }))
        }
        "inspect" => {
            // Peek at an IPA before injecting: name, id, version, extensions.
            let src = PathBuf::from(need(req, "path")?);
            let work = e.root().join("work").join("inspect");
            let p = prep::prepare(&src, &work, &InstallOptions::default(), None);
            let r = p.map(|p| {
                let icon = p.icon.as_ref().and_then(|i| {
                    let dst = e.root().join("work").join("inspect-icon.png");
                    std::fs::copy(i, &dst).ok().map(|_| dst)
                });
                json!({
                    "name": p.name,
                    "bundle_id": p.original_bundle_id,
                    "version": p.version,
                    "extensions": p.extension_count,
                    "icon": icon.map(|i| i.to_string_lossy().into_owned()),
                })
            });
            let _ = std::fs::remove_dir_all(&work);
            r
        }
        other => Err(format!("unknown op '{other}'")),
    }
}
