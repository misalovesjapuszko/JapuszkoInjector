//! Turning an .ipa (or a live .app) into a clean, tweaked .app directory that
//! isideload can sign. Everything here is local file work, no network.

use std::{
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
};

use plist::{Dictionary, Value};

use crate::model::InstallOptions;

pub type Res<T> = Result<T, String>;

fn e<E: std::fmt::Display>(ctx: &str) -> impl FnOnce(E) -> String + '_ {
    move |err| format!("{ctx}: {err}")
}

pub struct Prepared {
    pub app_dir: PathBuf,
    pub original_bundle_id: String,
    pub name: String,
    pub version: String,
    pub icon: Option<PathBuf>,
    pub extension_count: usize,
}

/// Prepare `source` (.ipa file or .app directory) inside `work`.
///
/// `team_suffix` strips a `.<TEAMID>` suffix left by an earlier sideload, so
/// re-signing an already-installed app (like the injector itself) doesn't end
/// up with `com.x.TEAM.TEAM`.
pub fn prepare(
    source: &Path,
    work: &Path,
    opts: &InstallOptions,
    team_suffix: Option<&str>,
) -> Res<Prepared> {
    if work.exists() {
        fs::remove_dir_all(work).map_err(e("clearing work dir"))?;
    }
    fs::create_dir_all(work).map_err(e("creating work dir"))?;

    let app_dir = if source.is_dir() {
        let name = source
            .file_name()
            .ok_or("source has no file name")?
            .to_owned();
        let dest = work.join(name);
        copy_dir(source, &dest)?;
        dest
    } else {
        extract_ipa(source, work)?
    };

    // Junk free accounts can't sign or don't need.
    for junk in ["Watch", "com.apple.WatchPlaceholder", "SC_Info", "_CodeSignature"] {
        let p = app_dir.join(junk);
        if p.exists() {
            let _ = fs::remove_dir_all(&p);
        }
    }
    let _ = fs::remove_file(app_dir.join("embedded.mobileprovision"));

    if opts.strip_extensions {
        for dir in ["PlugIns", "Extensions"] {
            let p = app_dir.join(dir);
            if p.exists() {
                fs::remove_dir_all(&p).map_err(e("removing extensions"))?;
            }
        }
    }

    let info_path = app_dir.join("Info.plist");
    let mut info = read_dict(&info_path)?;

    let mut bundle_id = info
        .get("CFBundleIdentifier")
        .and_then(Value::as_string)
        .ok_or("Info.plist has no CFBundleIdentifier")?
        .to_string();

    // Rewrite bundle ids (suffix strip and/or custom id), keeping extensions as
    // children of the main id.
    let old_main = bundle_id.clone();
    if let Some(team) = team_suffix {
        let suffix = format!(".{team}");
        if let Some(stripped) = bundle_id.strip_suffix(&suffix) {
            bundle_id = stripped.to_string();
        }
    }
    if let Some(custom) = opts.custom_bundle_id.as_ref().filter(|s| !s.is_empty()) {
        bundle_id = custom.clone();
    }
    if bundle_id != old_main {
        info.insert("CFBundleIdentifier".into(), bundle_id.clone().into());
        for ext_info in extension_infos(&app_dir) {
            let mut d = read_dict(&ext_info)?;
            if let Some(id) = d.get("CFBundleIdentifier").and_then(Value::as_string) {
                if let Some(rest) = id.strip_prefix(&old_main) {
                    let new_id = format!("{bundle_id}{rest}");
                    d.insert("CFBundleIdentifier".into(), new_id.into());
                    write_dict(&ext_info, &d)?;
                }
            }
        }
    }

    if let Some(name) = opts.custom_name.as_ref().filter(|s| !s.is_empty()) {
        info.insert("CFBundleDisplayName".into(), name.clone().into());
        info.insert("CFBundleName".into(), name.clone().into());
    }
    if opts.file_sharing {
        info.insert("UIFileSharingEnabled".into(), true.into());
        info.insert("LSSupportsOpeningDocumentsInPlace".into(), true.into());
    }
    if opts.strip_device_restrictions {
        info.remove("UISupportedDevices");
        info.insert(
            "UIDeviceFamily".into(),
            Value::Array(vec![1.into(), 2.into()]),
        );
    }
    write_dict(&info_path, &info)?;

    let exe = info
        .get("CFBundleExecutable")
        .and_then(Value::as_string)
        .ok_or("Info.plist has no CFBundleExecutable")?;
    if is_encrypted(&app_dir.join(exe))? {
        return Err(
            "This IPA is still FairPlay-encrypted (an App Store copy). \
             It needs a decrypted IPA to run when sideloaded."
                .into(),
        );
    }

    let name = info
        .get("CFBundleDisplayName")
        .or_else(|| info.get("CFBundleName"))
        .and_then(Value::as_string)
        .unwrap_or(exe)
        .to_string();
    let version = info
        .get("CFBundleShortVersionString")
        .or_else(|| info.get("CFBundleVersion"))
        .and_then(Value::as_string)
        .unwrap_or("?")
        .to_string();

    Ok(Prepared {
        icon: find_icon(&app_dir, &info),
        extension_count: extension_infos(&app_dir).len(),
        original_bundle_id: bundle_id,
        name,
        version,
        app_dir,
    })
}

/// (bundle id, display name) straight from the archive, without extracting.
pub fn peek_info(source: &Path) -> Res<(String, String)> {
    let info = if source.is_dir() {
        read_dict(&source.join("Info.plist"))?
    } else {
        let file = fs::File::open(source).map_err(e("opening ipa"))?;
        let mut zip = zip::ZipArchive::new(file).map_err(e("reading ipa"))?;
        let name = (0..zip.len())
            .filter_map(|i| zip.name_for_index(i).map(String::from))
            .find(|n| {
                let parts: Vec<&str> = n.split('/').collect();
                parts.len() == 3 && parts[0] == "Payload" && parts[1].ends_with(".app") && parts[2] == "Info.plist"
            })
            .ok_or("ipa has no Payload/*.app/Info.plist")?;
        let mut buf = Vec::new();
        zip.by_name(&name)
            .map_err(e("reading Info.plist"))?
            .read_to_end(&mut buf)
            .map_err(e("reading Info.plist"))?;
        Value::from_reader(std::io::Cursor::new(buf))
            .map_err(e("parsing Info.plist"))?
            .into_dictionary()
            .ok_or("Info.plist is not a dictionary")?
    };
    let s = |k: &str| info.get(k).and_then(Value::as_string).map(String::from);
    let id = s("CFBundleIdentifier").ok_or("Info.plist has no CFBundleIdentifier")?;
    let name = s("CFBundleDisplayName").or_else(|| s("CFBundleName")).unwrap_or_else(|| id.clone());
    Ok((id, name))
}

/// Extract an .ipa into `dest` and return the `Payload/*.app` path.
pub fn extract_ipa(ipa: &Path, dest: &Path) -> Res<PathBuf> {
    let file = fs::File::open(ipa).map_err(e("opening ipa"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(e("reading ipa (is it a real .ipa?)"))?;
    zip.extract(dest).map_err(e("extracting ipa"))?;
    let payload = dest.join("Payload");
    let apps: Vec<PathBuf> = fs::read_dir(&payload)
        .map_err(e("ipa has no Payload folder"))?
        .filter_map(Result::ok)
        .map(|d| d.path())
        .filter(|p| p.is_dir() && p.extension().is_some_and(|x| x == "app"))
        .collect();
    match apps.len() {
        1 => Ok(apps.into_iter().next().unwrap()),
        0 => Err("ipa has no .app inside Payload".into()),
        _ => Err("ipa has more than one .app inside Payload".into()),
    }
}

/// Zip an .app back into an .ipa (for "export signed IPA").
pub fn pack_ipa(app_dir: &Path, out: &Path) -> Res<()> {
    use std::io::Write;
    let file = fs::File::create(out).map_err(e("creating ipa"))?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o755);
    let root = app_dir.parent().ok_or("app has no parent")?;
    let mut stack = vec![app_dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).map_err(e("reading app"))? {
            let path = entry.map_err(e("reading app"))?.path();
            let rel = path.strip_prefix(root).unwrap().to_string_lossy();
            let name = format!("Payload/{rel}");
            if path.is_dir() {
                zip.add_directory(&name, opts).map_err(e("zip"))?;
                stack.push(path);
            } else {
                zip.start_file(&name, opts).map_err(e("zip"))?;
                let data = fs::read(&path).map_err(e("reading file"))?;
                zip.write_all(&data).map_err(e("zip"))?;
            }
        }
    }
    zip.finish().map_err(e("zip"))?;
    Ok(())
}

pub fn copy_dir(src: &Path, dst: &Path) -> Res<()> {
    fs::create_dir_all(dst).map_err(e("copy"))?;
    for entry in fs::read_dir(src).map_err(e("copy"))? {
        let entry = entry.map_err(e("copy"))?;
        let ft = entry.file_type().map_err(e("copy"))?;
        let to = dst.join(entry.file_name());
        if ft.is_symlink() {
            let target = fs::read_link(entry.path()).map_err(e("copy"))?;
            #[cfg(unix)]
            std::os::unix::fs::symlink(target, &to).map_err(e("copy"))?;
        } else if ft.is_dir() {
            copy_dir(&entry.path(), &to)?;
        } else {
            fs::copy(entry.path(), &to).map_err(e("copy"))?;
        }
    }
    Ok(())
}

pub fn dir_size(path: &Path) -> u64 {
    let Ok(rd) = fs::read_dir(path) else { return 0 };
    rd.filter_map(Result::ok)
        .map(|d| {
            let p = d.path();
            if p.is_dir() {
                dir_size(&p)
            } else {
                d.metadata().map(|m| m.len()).unwrap_or(0)
            }
        })
        .sum()
}

fn extension_infos(app_dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for dir in ["PlugIns", "Extensions"] {
        if let Ok(rd) = fs::read_dir(app_dir.join(dir)) {
            for d in rd.filter_map(Result::ok) {
                let info = d.path().join("Info.plist");
                if info.exists() {
                    out.push(info);
                }
            }
        }
    }
    out
}

pub fn read_dict(path: &Path) -> Res<Dictionary> {
    Value::from_file(path)
        .map_err(e(&format!("reading {}", path.display())))?
        .into_dictionary()
        .ok_or_else(|| format!("{} is not a dictionary", path.display()))
}

fn write_dict(path: &Path, d: &Dictionary) -> Res<()> {
    Value::Dictionary(d.clone())
        .to_file_xml(path)
        .map_err(e(&format!("writing {}", path.display())))
}

/// Picks the biggest PNG app icon the bundle ships loose (not in Assets.car).
fn find_icon(app_dir: &Path, info: &Dictionary) -> Option<PathBuf> {
    let mut names: Vec<String> = Vec::new();
    for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
        let primary = info
            .get(key)
            .and_then(Value::as_dictionary)
            .and_then(|d| d.get("CFBundlePrimaryIcon"))
            .and_then(Value::as_dictionary);
        if let Some(p) = primary {
            if let Some(files) = p.get("CFBundleIconFiles").and_then(Value::as_array) {
                names.extend(files.iter().filter_map(Value::as_string).map(String::from));
            }
            if let Some(n) = p.get("CFBundleIconName").and_then(Value::as_string) {
                names.push(n.to_string());
            }
        }
    }
    if let Some(files) = info.get("CFBundleIconFiles").and_then(Value::as_array) {
        names.extend(files.iter().filter_map(Value::as_string).map(String::from));
    }

    let mut best: Option<(u64, PathBuf)> = None;
    let entries: Vec<_> = fs::read_dir(app_dir)
        .ok()?
        .filter_map(Result::ok)
        .map(|d| d.path())
        .filter(|p| p.extension().is_some_and(|x| x == "png"))
        .collect();
    for p in entries {
        let fname = p.file_name()?.to_string_lossy().to_string();
        let matches = names.iter().any(|n| fname.starts_with(n.as_str()))
            || (names.is_empty() && fname.starts_with("AppIcon"));
        if !matches {
            continue;
        }
        let size = fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
        if best.as_ref().is_none_or(|(s, _)| size > *s) {
            best = Some((size, p));
        }
    }
    best.map(|(_, p)| p)
}

/// True when the arm64 slice of a Mach-O still has FairPlay encryption on.
pub fn is_encrypted(exe: &Path) -> Res<bool> {
    let mut f = fs::File::open(exe).map_err(e("opening main executable"))?;
    let mut magic = [0u8; 4];
    f.read_exact(&mut magic).map_err(e("reading executable"))?;
    let be = u32::from_be_bytes(magic);

    let slice_off: u64 = match be {
        0xcafebabe | 0xcafebabf => {
            let is64 = be == 0xcafebabf;
            let mut n = [0u8; 4];
            f.read_exact(&mut n).map_err(e("fat header"))?;
            let count = u32::from_be_bytes(n);
            let mut chosen = None;
            for _ in 0..count {
                let mut buf = vec![0u8; if is64 { 32 } else { 20 }];
                f.read_exact(&mut buf).map_err(e("fat arch"))?;
                let cputype = u32::from_be_bytes(buf[0..4].try_into().unwrap());
                let off = if is64 {
                    u64::from_be_bytes(buf[8..16].try_into().unwrap())
                } else {
                    u32::from_be_bytes(buf[8..12].try_into().unwrap()) as u64
                };
                if cputype == 0x0100_000c {
                    chosen = Some(off);
                }
            }
            chosen.ok_or("executable has no arm64 slice")?
        }
        _ => 0,
    };

    f.seek(SeekFrom::Start(slice_off)).map_err(e("seek"))?;
    let mut hdr = [0u8; 32];
    f.read_exact(&mut hdr).map_err(e("mach header"))?;
    let m = u32::from_le_bytes(hdr[0..4].try_into().unwrap());
    if m != 0xfeedfacf {
        return Err("main executable is not a 64-bit Mach-O".into());
    }
    let ncmds = u32::from_le_bytes(hdr[16..20].try_into().unwrap());
    let sizeofcmds = u32::from_le_bytes(hdr[20..24].try_into().unwrap()) as usize;
    let mut cmds = vec![0u8; sizeofcmds];
    f.read_exact(&mut cmds).map_err(e("load commands"))?;

    let mut off = 0usize;
    for _ in 0..ncmds {
        if off + 8 > cmds.len() {
            break;
        }
        let cmd = u32::from_le_bytes(cmds[off..off + 4].try_into().unwrap());
        let size = u32::from_le_bytes(cmds[off + 4..off + 8].try_into().unwrap()) as usize;
        // LC_ENCRYPTION_INFO_64
        if cmd == 0x2c && off + 20 <= cmds.len() {
            let cryptid = u32::from_le_bytes(cmds[off + 16..off + 20].try_into().unwrap());
            return Ok(cryptid != 0);
        }
        if size == 0 {
            break;
        }
        off += size;
    }
    Ok(false)
}

/// Expiration date (unix seconds) of a .mobileprovision (CMS-wrapped plist).
pub fn profile_expiry(bytes: &[u8]) -> Option<i64> {
    let start = find(bytes, b"<?xml")?;
    let end = find(&bytes[start..], b"</plist>")? + start + b"</plist>".len();
    let v = Value::from_reader_xml(&bytes[start..end]).ok()?;
    let date = v.as_dictionary()?.get("ExpirationDate")?.as_date()?;
    let st: std::time::SystemTime = date.into();
    st.duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs() as i64)
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}
