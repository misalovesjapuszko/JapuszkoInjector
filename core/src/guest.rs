//! "Run inside": guest apps that live in the injector's container instead of
//! being installed. Each guest's main executable is patched into a dylib the
//! injector can dlopen, and the whole bundle is signed with the injector's own
//! team certificate (no app IDs, no profiles, no 3-app limit).
//!
//! The runtime half (environment redirect + dlopen + jump to LC_MAIN) lives in
//! ios/JapuszkoInjector/Guest/GuestRuntime.m.

use std::{fs, path::Path};

use apple_codesign_quick::{BundleSigningSettings, RustCryptoCmsSigner};
use isideload::sideload::cert_identity::{
    APPLE_ROOT, APPLE_WWDR_G3_CERTIFICATE_DER, CertificateIdentity,
};
use x509_cert::{Certificate, der::Decode};

use crate::prep::Res;

/// Sign every Mach-O in the bundle with the injector's team certificate.
/// No provisioning profile and no entitlements: guests are loaded as
/// libraries, which only need a valid signature from the same team.
pub fn sign_bundle(app_dir: &Path, ident: &CertificateIdentity, team_id: &str) -> Res<()> {
    let chain = vec![
        Certificate::from_der(APPLE_WWDR_G3_CERTIFICATE_DER).map_err(|e| format!("WWDR cert: {e}"))?,
        Certificate::from_der(APPLE_ROOT).map_err(|e| format!("Apple root cert: {e}"))?,
    ];
    let signer = RustCryptoCmsSigner::new(ident.private_key.clone(), ident.certificate.clone(), chain);
    let settings = BundleSigningSettings::new(team_id, plist::Dictionary::new(), Some(&signer));
    apple_codesign_quick::sign_bundle(app_dir, &settings).map_err(|e| format!("signing guest: {e}"))
}

const MH_MAGIC_64: u32 = 0xfeed_facf;
const MH_DYLIB: u32 = 0x6;
const MH_PIE: u32 = 0x0020_0000;
const MH_NO_REEXPORTED_DYLIBS: u32 = 0x0010_0000;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;

const LC_SEGMENT_64: u32 = 0x19;
const LC_ID_DYLIB: u32 = 0xd;
const LC_LOAD_DYLIB: u32 = 0xc;
const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;
const LC_REEXPORT_DYLIB: u32 = 0x8000_001f;
const LC_LAZY_LOAD_DYLIB: u32 = 0x20;
const LC_RPATH: u32 = 0x8000_001c;
const LC_MAIN: u32 = 0x8000_0028;

#[derive(Debug, Default)]
pub struct PatchReport {
    pub thinned: bool,
    pub inserted_id: bool,
    pub paths_rewritten: usize,
}

fn u32le(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn u64le(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}
fn put32(b: &mut [u8], o: usize, v: u32) {
    b[o..o + 4].copy_from_slice(&v.to_le_bytes());
}
fn put64(b: &mut [u8], o: usize, v: u64) {
    b[o..o + 8].copy_from_slice(&v.to_le_bytes());
}

/// Keep only the arm64 slice of a fat binary.
fn thin(data: Vec<u8>) -> Res<(Vec<u8>, bool)> {
    let magic = u32::from_be_bytes(data[0..4].try_into().unwrap());
    if magic != 0xcafe_babe && magic != 0xcafe_babf {
        return Ok((data, false));
    }
    let is64 = magic == 0xcafe_babf;
    let count = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
    let stride = if is64 { 32 } else { 20 };
    for i in 0..count {
        let a = 8 + i * stride;
        let cpu = u32::from_be_bytes(data[a..a + 4].try_into().unwrap());
        if cpu != CPU_TYPE_ARM64 {
            continue;
        }
        let (off, size) = if is64 {
            (
                u64::from_be_bytes(data[a + 8..a + 16].try_into().unwrap()) as usize,
                u64::from_be_bytes(data[a + 16..a + 24].try_into().unwrap()) as usize,
            )
        } else {
            (
                u32::from_be_bytes(data[a + 8..a + 12].try_into().unwrap()) as usize,
                u32::from_be_bytes(data[a + 12..a + 16].try_into().unwrap()) as usize,
            )
        };
        let slice = data
            .get(off..off + size)
            .ok_or("fat slice out of bounds")?
            .to_vec();
        return Ok((slice, true));
    }
    Err("executable has no arm64 slice".into())
}

/// Rewrite an `@executable_path` prefix in a load-command string in place.
/// For the main executable `@loader_path` means the same directory, but it
/// keeps meaning that after the binary is dlopen'd by the injector.
fn rewrite_path(b: &mut [u8], cmd_off: usize, cmd_size: usize, str_off: usize) -> bool {
    let start = cmd_off + str_off;
    let end = cmd_off + cmd_size;
    if start >= end || end > b.len() {
        return false;
    }
    let field = &b[start..end];
    let len = field.iter().position(|&c| c == 0).unwrap_or(field.len());
    let Ok(s) = std::str::from_utf8(&field[..len]) else { return false };
    let Some(rest) = s.strip_prefix("@executable_path") else { return false };
    let new = format!("@loader_path{rest}");
    // "@loader_path" is shorter, so it always fits; zero the tail.
    let room = end - start;
    if new.len() >= room {
        return false;
    }
    b[start..end].fill(0);
    b[start..start + new.len()].copy_from_slice(new.as_bytes());
    true
}

/// Turn a guest's main executable into a loadable dylib (idempotent).
pub fn patch_executable(path: &Path) -> Res<PatchReport> {
    let raw = fs::read(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
    let (mut b, thinned) = thin(raw)?;
    let mut report = PatchReport { thinned, ..Default::default() };

    if b.len() < 32 || u32le(&b, 0) != MH_MAGIC_64 {
        return Err("main executable is not a 64-bit Mach-O".into());
    }
    if u32le(&b, 4) != CPU_TYPE_ARM64 {
        return Err("main executable is not arm64".into());
    }

    let ncmds = u32le(&b, 16) as usize;
    let sizeofcmds = u32le(&b, 20) as usize;
    let cmds_end = 32 + sizeofcmds;
    if cmds_end > b.len() {
        return Err("load commands run past the end of the file".into());
    }

    // Pass 1: find __TEXT's address, the first section's file offset (end of
    // header padding), and what's already there.
    let mut text_vmaddr = 0x1_0000_0000u64;
    let mut first_section = usize::MAX;
    let mut has_id = false;
    let mut has_main = false;
    let mut off = 32;
    for _ in 0..ncmds {
        let cmd = u32le(&b, off);
        let size = u32le(&b, off + 4) as usize;
        if size < 8 || off + size > cmds_end {
            return Err("malformed load command".into());
        }
        match cmd {
            LC_SEGMENT_64 => {
                let name = &b[off + 8..off + 24];
                if name.starts_with(b"__TEXT\0") {
                    text_vmaddr = u64le(&b, off + 24);
                }
                let nsects = u32le(&b, off + 64) as usize;
                for s in 0..nsects {
                    let so = off + 72 + s * 80;
                    if so + 80 > off + size {
                        break;
                    }
                    let fileoff = u32le(&b, so + 48) as usize;
                    if fileoff != 0 {
                        first_section = first_section.min(fileoff);
                    }
                }
            }
            LC_ID_DYLIB => has_id = true,
            LC_MAIN => has_main = true,
            _ => {}
        }
        off += size;
    }
    if !has_main {
        return Err("No LC_MAIN entry point: this app can't run inside the container".into());
    }

    // Header: executable → dylib.
    let mut flags = u32le(&b, 24);
    flags &= !MH_PIE;
    flags |= MH_NO_REEXPORTED_DYLIBS;
    put32(&mut b, 12, MH_DYLIB);
    put32(&mut b, 24, flags);

    // Pass 2: shrink __PAGEZERO, rewrite @executable_path references.
    let mut off = 32;
    for _ in 0..ncmds {
        let cmd = u32le(&b, off);
        let size = u32le(&b, off + 4) as usize;
        match cmd {
            LC_SEGMENT_64 if b[off + 8..off + 24].starts_with(b"__PAGEZERO\0") => {
                // A 4 GB reservation at 0 can't be mapped into a running
                // process; keep one guard page right below __TEXT instead.
                put64(&mut b, off + 24, text_vmaddr.saturating_sub(0x4000));
                put64(&mut b, off + 32, 0x4000);
            }
            LC_RPATH | LC_LOAD_DYLIB | LC_LOAD_WEAK_DYLIB | LC_REEXPORT_DYLIB
            | LC_LAZY_LOAD_DYLIB => {
                let str_off = u32le(&b, off + 8) as usize;
                if rewrite_path(&mut b, off, size, str_off) {
                    report.paths_rewritten += 1;
                }
            }
            _ => {}
        }
        off += size;
    }

    // A dylib needs an install name. Put one in the header padding.
    if !has_id {
        let exe_name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "guest".into());
        let name = format!("@loader_path/{exe_name}");
        let cmdsize = (24 + name.len() + 1).div_ceil(8) * 8;
        let at = cmds_end;
        if first_section == usize::MAX || at + cmdsize > first_section {
            return Err("No room in the Mach-O header for a dylib ID".into());
        }
        if b[at..at + cmdsize].iter().any(|&c| c != 0) {
            return Err("Mach-O header padding isn't empty".into());
        }
        put32(&mut b, at, LC_ID_DYLIB);
        put32(&mut b, at + 4, cmdsize as u32);
        put32(&mut b, at + 8, 24); // name offset
        put32(&mut b, at + 12, 2); // timestamp
        put32(&mut b, at + 16, 0x0001_0000); // current version 1.0.0
        put32(&mut b, at + 20, 0x0001_0000); // compat version 1.0.0
        b[at + 24..at + 24 + name.len()].copy_from_slice(name.as_bytes());
        put32(&mut b, 16, (ncmds + 1) as u32);
        put32(&mut b, 20, (sizeofcmds + cmdsize) as u32);
        report.inserted_id = true;
    }

    fs::write(path, &b).map_err(|e| format!("writing {}: {e}", path.display()))?;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a tiny fake arm64 executable: __PAGEZERO, __TEXT with one
    /// section, an rpath, LC_MAIN, and header padding.
    fn fake_exe() -> Vec<u8> {
        let mut cmds: Vec<u8> = Vec::new();
        // __PAGEZERO
        let mut seg = vec![0u8; 72];
        seg[0..4].copy_from_slice(&LC_SEGMENT_64.to_le_bytes());
        seg[4..8].copy_from_slice(&72u32.to_le_bytes());
        seg[8..18].copy_from_slice(b"__PAGEZERO");
        seg[32..40].copy_from_slice(&0x1_0000_0000u64.to_le_bytes());
        cmds.extend(&seg);
        // __TEXT with one section at file offset 0x1000
        let mut text = vec![0u8; 72 + 80];
        text[0..4].copy_from_slice(&LC_SEGMENT_64.to_le_bytes());
        text[4..8].copy_from_slice(&152u32.to_le_bytes());
        text[8..14].copy_from_slice(b"__TEXT");
        text[24..32].copy_from_slice(&0x1_0000_0000u64.to_le_bytes());
        text[64..68].copy_from_slice(&1u32.to_le_bytes());
        text[72 + 48..72 + 52].copy_from_slice(&0x1000u32.to_le_bytes());
        cmds.extend(&text);
        // LC_RPATH @executable_path/Frameworks
        let p = b"@executable_path/Frameworks\0";
        let size = (12 + p.len()).div_ceil(8) * 8;
        let mut rp = vec![0u8; size];
        rp[0..4].copy_from_slice(&LC_RPATH.to_le_bytes());
        rp[4..8].copy_from_slice(&(size as u32).to_le_bytes());
        rp[8..12].copy_from_slice(&12u32.to_le_bytes());
        rp[12..12 + p.len()].copy_from_slice(p);
        cmds.extend(&rp);
        // LC_MAIN
        let mut m = vec![0u8; 24];
        m[0..4].copy_from_slice(&LC_MAIN.to_le_bytes());
        m[4..8].copy_from_slice(&24u32.to_le_bytes());
        m[8..16].copy_from_slice(&0x1000u64.to_le_bytes());
        cmds.extend(&m);

        let mut f = vec![0u8; 0x2000];
        f[0..4].copy_from_slice(&MH_MAGIC_64.to_le_bytes());
        f[4..8].copy_from_slice(&CPU_TYPE_ARM64.to_le_bytes());
        f[12..16].copy_from_slice(&2u32.to_le_bytes()); // MH_EXECUTE
        f[16..20].copy_from_slice(&4u32.to_le_bytes());
        f[20..24].copy_from_slice(&(cmds.len() as u32).to_le_bytes());
        f[24..28].copy_from_slice(&MH_PIE.to_le_bytes());
        f[32..32 + cmds.len()].copy_from_slice(&cmds);
        f
    }

    #[test]
    fn patches_fake_executable() {
        let dir = std::env::temp_dir().join(format!("jinject-guest-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("Guest");
        fs::write(&exe, fake_exe()).unwrap();

        let r = patch_executable(&exe).unwrap();
        assert!(r.inserted_id);
        assert_eq!(r.paths_rewritten, 1);

        let b = fs::read(&exe).unwrap();
        assert_eq!(u32le(&b, 12), MH_DYLIB);
        assert_eq!(u32le(&b, 24) & MH_PIE, 0);
        assert_eq!(u32le(&b, 16), 5);
        // __PAGEZERO is now one page below __TEXT
        assert_eq!(u64le(&b, 32 + 24), 0x1_0000_0000 - 0x4000);
        assert_eq!(u64le(&b, 32 + 32), 0x4000);
        let text = String::from_utf8_lossy(&b);
        assert!(text.contains("@loader_path/Frameworks"));
        assert!(text.contains("@loader_path/Guest"));
        assert!(!text.contains("@executable_path"));

        // second run changes nothing structural
        let r2 = patch_executable(&exe).unwrap();
        assert!(!r2.inserted_id);
        assert_eq!(u32le(&fs::read(&exe).unwrap(), 16), 5);
        fs::remove_dir_all(&dir).unwrap();
    }
}
