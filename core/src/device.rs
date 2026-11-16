//! Talking to the iPhone/iPad: over the loopback VPN with a pairing file
//! (on-device) or over USB through usbmuxd (Linux bootstrap).

use std::{future::Future, net::IpAddr, path::Path, pin::Pin};

use idevice::{
    Idevice, IdeviceError, IdeviceService,
    afc::opcode::AfcFopenMode,
    house_arrest::HouseArrestClient,
    installation_proxy::InstallationProxyClient,
    lockdown::LockdownClient,
    pairing_file::PairingFile,
    provider::{IdeviceProvider, TcpProvider},
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};

use crate::model::{DeviceInfo, Target};

const LABEL: &str = "JapuszkoInjector";

/// Type-erased provider so the engine doesn't care how the device is reached.
#[derive(Debug)]
pub struct AnyProvider(Box<dyn IdeviceProvider>);

impl IdeviceProvider for AnyProvider {
    fn connect(
        &self,
        port: u16,
    ) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
        self.0.connect(port)
    }
    fn label(&self) -> &str {
        self.0.label()
    }
    fn get_pairing_file(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
        self.0.get_pairing_file()
    }
}

pub async fn connect(target: &Target, pairing_path: &Path) -> Result<AnyProvider, String> {
    match target {
        Target::Network { ip } => {
            let addr: IpAddr = ip
                .parse()
                .map_err(|_| format!("'{ip}' is not a valid IP address"))?;
            if !pairing_path.exists() {
                return Err("No pairing file imported yet. Import one in Lab → Pairing.".into());
            }
            let pairing_file = PairingFile::read_from_file(pairing_path)
                .map_err(|e| format!("Pairing file is unreadable: {e}"))?;
            Ok(AnyProvider(Box::new(TcpProvider {
                addr,
                scope_id: None,
                pairing_file,
                label: LABEL.into(),
            })))
        }
        Target::Usb { udid } => {
            let mut mux = UsbmuxdConnection::default()
                .await
                .map_err(|e| format!("usbmuxd isn't running or reachable: {e}"))?;
            let devices = mux
                .get_devices()
                .await
                .map_err(|e| format!("usbmuxd: {e}"))?;
            let dev = match udid {
                Some(u) => devices.into_iter().find(|d| &d.udid == u),
                None => devices.into_iter().next(),
            }
            .ok_or("No iPhone/iPad found over USB. Plug it in and tap Trust.")?;
            let addr = UsbmuxdAddr::from_env_var().map_err(|e| e.to_string())?;
            Ok(AnyProvider(Box::new(dev.to_provider(addr, LABEL))))
        }
    }
}

/// Explain the usual on-device failures in plain words.
pub fn explain(err: &str) -> String {
    let lower = err.to_lowercase();
    if lower.contains("connection refused")
        || lower.contains("timed out")
        || lower.contains("network is unreachable")
        || lower.contains("no route")
    {
        format!(
            "Can't reach the device through the loopback VPN. Turn on LocalDevVPN \
             (or StosVPN) and make sure Wi-Fi or mobile data is on. ({err})"
        )
    } else if lower.contains("invalidhostid") || lower.contains("pairing") {
        format!(
            "The device rejected the pairing file. It may be from a different \
             device or was reset by 'Reset Location & Privacy'. Make a new one with \
             the Linux bootstrap. ({err})"
        )
    } else {
        err.to_string()
    }
}

async fn lockdown_session(p: &AnyProvider) -> Result<LockdownClient, String> {
    let mut ld = LockdownClient::connect(p)
        .await
        .map_err(|e| explain(&e.to_string()))?;
    let pf = p
        .get_pairing_file()
        .await
        .map_err(|e| explain(&e.to_string()))?;
    ld.start_session(&pf)
        .await
        .map_err(|e| explain(&e.to_string()))?;
    Ok(ld)
}

pub async fn info(p: &AnyProvider) -> Result<DeviceInfo, String> {
    let mut ld = lockdown_session(p).await?;
    let mut get = async |key: &str| -> String {
        ld.get_value(Some(key), None)
            .await
            .ok()
            .and_then(|v| v.as_string().map(String::from))
            .unwrap_or_default()
    };
    Ok(DeviceInfo {
        name: get("DeviceName").await,
        udid: get("UniqueDeviceID").await,
        ios_version: get("ProductVersion").await,
        model: get("ProductType").await,
    })
}

/// Lets lockdown accept network connections, which the loopback VPN needs.
pub async fn enable_wifi_connections(p: &AnyProvider) -> Result<(), String> {
    let mut ld = lockdown_session(p).await?;
    ld.set_value(
        "EnableWifiDebugging",
        true.into(),
        Some("com.apple.mobile.wireless_lockdown"),
    )
    .await
    .map_err(|e| e.to_string())
}

/// User apps installed on the device: (bundle id, name, version).
pub async fn installed_apps(p: &AnyProvider) -> Result<Vec<(String, String, String)>, String> {
    let mut ip = InstallationProxyClient::connect(p)
        .await
        .map_err(|e| explain(&e.to_string()))?;
    let apps = ip
        .get_apps(Some("User"), None)
        .await
        .map_err(|e| e.to_string())?;
    let mut out: Vec<_> = apps
        .into_iter()
        .map(|(id, v)| {
            let d = v.as_dictionary();
            let s = |k: &str| {
                d.and_then(|d| d.get(k))
                    .and_then(|v| v.as_string())
                    .unwrap_or("")
                    .to_string()
            };
            let name = {
                let n = s("CFBundleDisplayName");
                if n.is_empty() { s("CFBundleName") } else { n }
            };
            (id, name, s("CFBundleShortVersionString"))
        })
        .collect();
    out.sort_by(|a, b| a.1.to_lowercase().cmp(&b.1.to_lowercase()));
    Ok(out)
}

pub async fn uninstall(p: &AnyProvider, bundle_id: &str) -> Result<(), String> {
    let mut ip = InstallationProxyClient::connect(p)
        .await
        .map_err(|e| explain(&e.to_string()))?;
    ip.uninstall(bundle_id, None)
        .await
        .map_err(|e| e.to_string())
}

/// Copy local files into an app's Documents folder (needs UIFileSharingEnabled).
/// `files` = (local path, path relative to Documents).
pub async fn push_to_documents(
    p: &AnyProvider,
    bundle_id: &str,
    files: &[(std::path::PathBuf, String)],
) -> Result<(), String> {
    let ha = HouseArrestClient::connect(p)
        .await
        .map_err(|e| e.to_string())?;
    let mut afc = ha
        .vend_documents(bundle_id)
        .await
        .map_err(|e| format!("Can't open {bundle_id}'s Documents: {e}"))?;
    for (local, rel) in files {
        let remote = format!("/Documents/{rel}");
        if let Some(parent) = Path::new(&remote).parent() {
            // mk_dir is not recursive, walk it.
            let mut acc = String::new();
            for part in parent.to_string_lossy().split('/').filter(|s| !s.is_empty()) {
                acc.push('/');
                acc.push_str(part);
                let _ = afc.mk_dir(&acc).await;
            }
        }
        let data = std::fs::read(local).map_err(|e| format!("{}: {e}", local.display()))?;
        let mut fh = afc
            .open(&remote, AfcFopenMode::WrOnly)
            .await
            .map_err(|e| format!("{remote}: {e}"))?;
        fh.write_entire(&data)
            .await
            .map_err(|e| format!("{remote}: {e}"))?;
        fh.close().await.map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Pairing record for a USB device, as a pairing file the app can import.
pub async fn usb_pairing_file(udid: Option<&str>) -> Result<(String, Vec<u8>), String> {
    let mut mux = UsbmuxdConnection::default()
        .await
        .map_err(|e| format!("usbmuxd: {e}"))?;
    let devices = mux.get_devices().await.map_err(|e| e.to_string())?;
    let dev = match udid {
        Some(u) => devices.into_iter().find(|d| d.udid == u),
        None => devices.into_iter().next(),
    }
    .ok_or("No device over USB")?;
    let mut pf = mux
        .get_pair_record(&dev.udid)
        .await
        .map_err(|e| format!("No pairing record for {} (run `idevicepair pair`): {e}", dev.udid))?;
    pf.udid = Some(dev.udid.clone());
    let bytes = pf.serialize().map_err(|e| e.to_string())?;
    Ok((dev.udid, bytes))
}
