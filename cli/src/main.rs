//! `jinject`: the Linux side of JapuszkoInjector.
//!
//! Mainly used once: `jinject bootstrap JapuszkoInjector.ipa -e you@icloud.com`
//! installs the app over USB and drops the pairing file + signing state into
//! it, so the phone can take over from there.

use std::{
    io::Write,
    path::PathBuf,
    sync::{Arc, OnceLock},
};

use clap::{Parser, Subcommand};
use jinject_core::{
    Engine, device,
    model::{Config, Event, InstallOptions, SELF_ID, Target},
};
use serde_json::{Value, json};

#[derive(Parser)]
#[command(name = "jinject", about = "JapuszkoInjector Linux helper", version)]
struct Cli {
    /// Device UDID (default: first USB device)
    #[arg(long, global = true)]
    udid: Option<String>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// List USB devices
    Devices,
    /// Save the device's pairing file (for importing in the app manually)
    Pair {
        #[arg(short, long, default_value = "pairing.plist")]
        out: PathBuf,
    },
    /// One-time setup: install JapuszkoInjector and hand it the pairing file
    Bootstrap {
        ipa: PathBuf,
        #[arg(short, long)]
        email: String,
        /// Anisette server (default: public one)
        #[arg(long)]
        anisette: Option<String>,
    },
    /// Sign and install any IPA over USB
    Install {
        ipa: PathBuf,
        #[arg(short, long)]
        email: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long)]
        bundle_id: Option<String>,
        #[arg(long)]
        strip_extensions: bool,
        #[arg(long)]
        anisette: Option<String>,
    },
    /// List development certificates
    Certs {
        #[arg(short, long)]
        email: String,
    },
    /// Export the signing certificate as .p12
    ExportCert {
        #[arg(short, long)]
        email: String,
        #[arg(short, long, default_value = ".")]
        out: PathBuf,
        #[arg(long)]
        password: Option<String>,
    },
    /// Show app ID usage
    AppIds {
        #[arg(short, long)]
        email: String,
    },
}

fn state_dir() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("japuszkoinjector")
}

fn ask(q: &str) -> String {
    print!("{q}");
    let _ = std::io::stdout().flush();
    let mut s = String::new();
    let _ = std::io::stdin().read_line(&mut s);
    s.trim().to_string()
}

fn handle_event(engine: &Arc<Engine>, ev: Event) {
    match ev {
        Event::Log { level, message } => println!("[{level}] {message}"),
        Event::Progress { stage, value, .. } => {
            println!("  {stage:<22} {:>3}%", (value * 100.0) as u32)
        }
        Event::TwoFactor { prompt, params } => {
            let engine = engine.clone();
            std::thread::spawn(move || {
                let numbers = params["numbers"].as_array().cloned().unwrap_or_default();
                println!("\nTwo-factor code needed.");
                if !numbers.is_empty() {
                    for n in &numbers {
                        println!("  p{}: SMS to {}", n["id"], n["numberWithDialCode"].as_str().unwrap_or("?"));
                    }
                }
                let a = ask("Code (or d = send to devices, p<id> = SMS, r = resend): ");
                let answer = if a == "d" {
                    json!("SendToDevices")
                } else if a == "r" {
                    json!("ResendCode")
                } else if let Some(id) = a.strip_prefix('p').and_then(|x| x.parse::<u32>().ok()) {
                    json!({ "SendSms": id })
                } else {
                    json!({ "SubmitCode": a })
                };
                engine.prompts.answer(prompt, answer);
            });
        }
        Event::MaxCerts { prompt, certs } => {
            let engine = engine.clone();
            std::thread::spawn(move || {
                println!("\nThis account hit its certificate limit. Pick ones to revoke:");
                for (i, c) in certs.iter().enumerate() {
                    println!("  {}: {} ({})", i + 1, c.machine_name, c.serial);
                }
                let a = ask("Numbers, comma separated (empty = cancel): ");
                let picks: Vec<String> = a
                    .split(',')
                    .filter_map(|x| x.trim().parse::<usize>().ok())
                    .filter_map(|i| certs.get(i.wrapping_sub(1)).map(|c| c.serial.clone()))
                    .collect();
                let v = if picks.is_empty() { Value::Null } else { json!(picks) };
                engine.prompts.answer(prompt, json!({ "revoke": v }));
            });
        }
        Event::Raw(v) if v["type"] == "app_slots_full" => {
            let engine = engine.clone();
            std::thread::spawn(move || {
                println!(
                    "\n{} already has 3 apps (free account limit).",
                    v["account"].as_str().unwrap_or("This account")
                );
                let apps = v["apps"].as_array().cloned().unwrap_or_default();
                for (i, a) in apps.iter().enumerate() {
                    println!("  r{}: uninstall {}", i + 1, a["name"].as_str().unwrap_or("?"));
                }
                let others = v["other_accounts"].as_array().cloned().unwrap_or_default();
                for (i, a) in others.iter().enumerate() {
                    println!("  a{}: use {} ({}/3)", i + 1, a["email"].as_str().unwrap_or("?"), a["used"]);
                }
                let pick = ask("Choice (empty = cancel): ");
                let idx = |p: &str| pick.strip_prefix(p).and_then(|n| n.parse::<usize>().ok()).map(|n| n.wrapping_sub(1));
                let answer = if let Some(a) = idx("r").and_then(|i| apps.get(i)) {
                    json!({ "replace": a["id"] })
                } else if let Some(a) = idx("a").and_then(|i| others.get(i)) {
                    json!({ "account": a["email"] })
                } else {
                    json!({ "cancel": true })
                };
                engine.prompts.answer(v["prompt"].as_u64().unwrap_or(0), answer);
            });
        }
        Event::Raw(v) if v["type"] == "app_id_limit" => {
            let engine = engine.clone();
            std::thread::spawn(move || {
                println!(
                    "\n{} has no free app IDs this week. Reuse one? The app on it gets replaced.",
                    v["account"].as_str().unwrap_or("This account")
                );
                let choices = v["choices"].as_array().cloned().unwrap_or_default();
                for (i, c) in choices.iter().enumerate() {
                    println!(
                        "  {}: {}  {}",
                        i + 1,
                        c["identifier"].as_str().unwrap_or("?"),
                        c["used_by"].as_str().map(|u| format!("(used by {u})")).unwrap_or_default()
                    );
                }
                let a = ask("Number (empty = cancel): ");
                let pick = a
                    .parse::<usize>()
                    .ok()
                    .and_then(|i| choices.get(i.wrapping_sub(1)))
                    .map(|c| c["identifier"].clone())
                    .unwrap_or(Value::Null);
                engine.prompts.answer(v["prompt"].as_u64().unwrap_or(0), json!({ "reuse": pick }));
            });
        }
        _ => {}
    }
}

async fn login(engine: &Engine, email: &str) -> Result<(), String> {
    let password = match std::env::var("JINJECT_PASSWORD") {
        Ok(p) => p,
        Err(_) => rpassword::prompt_password(format!("Apple ID password for {email}: "))
            .map_err(|e| e.to_string())?,
    };
    let info = engine.login(email, &password).await?;
    println!("Signed in as {} {} (team {})", info.first_name, info.last_name, info.team_id);
    Ok(())
}

fn configure(engine: &Engine, udid: &Option<String>, anisette: &Option<String>) {
    let mut cfg: Config = engine.config();
    cfg.target = Target::Usb { udid: udid.clone() };
    if let Some(a) = anisette {
        cfg.anisette_servers.retain(|s| s != a);
        cfg.anisette_servers.insert(0, a.clone());
    }
    let _ = engine.set_config(&cfg);
}

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = isideload::init();
    tracing_subscriber::fmt()
        .with_target(false)
        .without_time()
        .with_max_level(tracing::Level::INFO)
        .init();

    let cli = Cli::parse();
    let cell: Arc<OnceLock<Arc<Engine>>> = Arc::new(OnceLock::new());
    let c2 = cell.clone();
    let engine = Arc::new(Engine::new(
        state_dir(),
        Arc::new(move |ev| {
            if let Some(e) = c2.get() {
                handle_event(e, ev);
            }
        }),
    ));
    let _ = cell.set(engine.clone());

    if let Err(e) = run(&engine, cli).await {
        eprintln!("\nerror: {e}");
        std::process::exit(1);
    }
}

async fn run(engine: &Arc<Engine>, cli: Cli) -> Result<(), String> {
    match cli.cmd {
        Cmd::Devices => {
            configure(engine, &cli.udid, &None);
            let p = device::connect(&engine.config().target, &engine.pairing_path()).await?;
            let i = device::info(&p).await?;
            println!("{}  {}  iOS {}  {}", i.name, i.model, i.ios_version, i.udid);
        }
        Cmd::Pair { out } => {
            let (udid, bytes) = device::usb_pairing_file(cli.udid.as_deref()).await?;
            std::fs::write(&out, bytes).map_err(|e| e.to_string())?;
            println!("Pairing file for {udid} saved to {}", out.display());
        }
        Cmd::Bootstrap { ipa, email, anisette } => {
            configure(engine, &cli.udid, &anisette);
            let p = device::connect(&engine.config().target, &engine.pairing_path()).await?;
            let info = device::info(&p).await?;
            println!("Device: {} (iOS {})", info.name, info.ios_version);

            println!("Allowing network lockdown connections (needed for the VPN loopback)…");
            if let Err(e) = device::enable_wifi_connections(&p).await {
                println!("  warning: {e}");
            }

            login(engine, &email).await?;
            let op = engine.next_op();
            let opts = InstallOptions { file_sharing: true, ..Default::default() };
            let rec = engine.install(op, &ipa, opts, Some(&email), Some(SELF_ID)).await?;
            println!("Installed {} as {}", rec.name, rec.installed_bundle_id);

            println!("Handing over pairing file and signing state…");
            let (_, pairing) = device::usb_pairing_file(Some(&info.udid)).await?;
            let tmp = engine.root().join("work/bootstrap");
            std::fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
            let pairing_path = tmp.join("pairing.plist");
            std::fs::write(&pairing_path, pairing).map_err(|e| e.to_string())?;

            let mut phone_cfg = engine.config();
            phone_cfg.target = Target::Network { ip: jinject_core::model::DEFAULT_LOOPBACK_IP.into() };
            let cfg_path = tmp.join("config.json");
            std::fs::write(&cfg_path, serde_json::to_vec_pretty(&phone_cfg).unwrap())
                .map_err(|e| e.to_string())?;

            let mut files = vec![
                (pairing_path, "bootstrap/pairing.plist".to_string()),
                (cfg_path, "bootstrap/config.json".to_string()),
            ];
            // The signing key + anisette state, so the phone reuses this cert
            // instead of burning a new one.
            let state = engine.root().join("isideload");
            collect(&state, &state, &mut files);
            device::push_to_documents(&p, &rec.installed_bundle_id, &files).await?;
            let _ = std::fs::remove_dir_all(&tmp);

            println!("\nDone. On the phone:");
            println!("  1. Settings → General → VPN & Device Management → trust your Apple ID");
            println!("  2. Install LocalDevVPN from the App Store and turn it on");
            println!("  3. Open JapuszkoInjector, sign in once. It refreshes itself from now on.");
        }
        Cmd::Install { ipa, email, name, bundle_id, strip_extensions, anisette } => {
            configure(engine, &cli.udid, &anisette);
            login(engine, &email).await?;
            let opts = InstallOptions {
                custom_name: name,
                custom_bundle_id: bundle_id,
                strip_extensions,
                ..Default::default()
            };
            let op = engine.next_op();
            let rec = engine.install(op, &ipa, opts, Some(&email), None).await?;
            let days = (rec.expires_at - jinject_core::model::now()) as f64 / 86400.0;
            println!("Installed {} {} ({:.1} days left)", rec.name, rec.version, days);
        }
        Cmd::Certs { email } => {
            login(engine, &email).await?;
            for c in engine.certs(Some(&email)).await? {
                println!("{}  {}  {}{}", c.serial, c.machine_name, c.name, if c.is_ours { "  ← ours" } else { "" });
            }
        }
        Cmd::ExportCert { email, out, password } => {
            login(engine, &email).await?;
            let r = engine.export_cert(Some(&email), password, &out, None).await?;
            println!("Saved {} (password: {})", r.p12_path, r.password);
        }
        Cmd::AppIds { email } => {
            login(engine, &email).await?;
            let r = engine.app_ids(Some(&email)).await?;
            println!("available: {:?} / max {:?}", r.available, r.max);
            for a in r.ids {
                println!("  {}  {}", a.identifier, a.name);
            }
        }
    }
    Ok(())
}

fn collect(base: &std::path::Path, dir: &std::path::Path, out: &mut Vec<(PathBuf, String)>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.filter_map(Result::ok) {
        let p = e.path();
        if p.is_dir() {
            collect(base, &p, out);
        } else if let Ok(rel) = p.strip_prefix(base) {
            out.push((p.clone(), format!("bootstrap/isideload/{}", rel.to_string_lossy())));
        }
    }
}
