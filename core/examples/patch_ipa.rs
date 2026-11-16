//! Dev tool: unpack an IPA and run the Run-inside patcher on its executable.
//! cargo run -p jinject-core --example patch_ipa -- app.ipa /tmp/out
use std::path::PathBuf;
use jinject_core::{guest, model::InstallOptions, prep};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (ipa, out) = (PathBuf::from(&a[1]), PathBuf::from(&a[2]));
    let opts = InstallOptions { strip_extensions: true, ..Default::default() };
    let p = prep::prepare(&ipa, &out, &opts, None).expect("prepare");
    let info = prep::read_dict(&p.app_dir.join("Info.plist")).unwrap();
    let exe = p.app_dir.join(info.get("CFBundleExecutable").unwrap().as_string().unwrap());
    let r = guest::patch_executable(&exe).expect("patch");
    println!("{} {} -> {:?}\nexe: {}", p.name, p.original_bundle_id, r, exe.display());
}
