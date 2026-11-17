<h1 align="center">JapuszkoInjector</h1>

<p align="center">
  <a href="../../actions/workflows/build.yml"><img src="../../actions/workflows/build.yml/badge.svg" alt="build"></a>
  <img src="https://img.shields.io/badge/iOS-17%2B-0b0d0c?labelColor=101412&color=B6FF3B" alt="iOS 17+">
  <img src="https://img.shields.io/badge/core-Rust-0b0d0c?labelColor=101412&color=B6FF3B" alt="Rust">
  <img src="https://img.shields.io/badge/UI-SwiftUI-0b0d0c?labelColor=101412&color=B6FF3B" alt="SwiftUI">
  <img src="https://img.shields.io/badge/status-early-0b0d0c?labelColor=101412&color=FFB020" alt="status: early">
</p>

**JapuszkoInjector** signs and installs apps on your iPhone or iPad from the device itself, keeps them alive with automatic refreshes, and can run extra apps inside its own container so the free-account limits stop being a problem.

You need a computer once, to set it up. After that everything happens on the phone.

> [!WARNING]
> Early software. The core and the Linux tool build and are tested on Linux, but the iOS app hasn't been through a real-device test cycle yet. Expect rough edges and please [open an issue](../../issues) when something breaks.

## What it does

**Sideloading**
- Sign in with one or more Apple IDs (2FA by trusted device or SMS)
- Sign and install any decrypted `.ipa`, from Files, the share sheet, or a URL
- Install tweaks: rename, change the bundle ID, strip extensions, raise the memory limit, enable file sharing, allow any device
- Tells you up front when an IPA is still App Store-encrypted instead of failing later

**Staying alive**
- Every app is a vial that drains over its 7 days
- Refreshes what's due when you open the app, in the background, and from a **Refresh Apps** Shortcuts action you can automate (daily, or on charger)
- Notifications 24 h and 3 h before anything expires
- Refreshes itself last (installing over itself ends the process)

**Free-account limits, handled**
- **Multiple accounts:** each Apple ID adds 3 app slots and 10 app IDs a week; every app remembers which account signed it
- **Account full (3/3):** switch account, replace an app, or run it inside instead
- **Out of app IDs:** overwrite an app ID you already registered this week instead of being stuck

**Run inside**
- Load apps into JapuszkoInjector's own container: no app slot, no app ID, they live as long as the injector does
- Full runtime isolation: bundle ID, main bundle, user defaults, file manager, app-group URLs, process name and `__progname` are all swizzled — the guest thinks it's running standalone
- Lazy symbol resolution (`RTLD_LAZY`) so apps with weakly-linked frameworks load correctly
- NIBs, storyboards and Info.plist registered automatically after load
- Optional **JIT** per app through [StikDebug](https://github.com/StikDebug/StikDebug), for emulators and VMs

**Lab**
- **MobileGestalt editor:** read and modify system configuration values
- **TCC manager:** view and edit privacy permission grants (camera, mic, location, etc.)
- **App data browser:** explore sandboxed container contents of any installed app
- List and revoke certificates, see app ID usage per account
- Export the certificate as `.p12` plus the app's `.mobileprovision` (works in signers like Feather or ESign)
- Multiple anisette servers with per-server reachability test — pick the fastest or add your own
- Full log view

## How it works

```
 ┌──────────── iPhone / iPad ─────────────┐
 │ JapuszkoInjector (SwiftUI)             │
 │   └─ jinject-core (Rust, static lib)   │      Apple
 │        ├─ Apple ID + dev portal ───────┼───▶  GSA / developer services
 │        ├─ anisette ────────────────────┼───▶  anisette v3 server (yours or public)
 │        ├─ sign (.ipa → .app)           │
 │        └─ install ─▶ 10.7.0.1 ──┐      │
 │                                 │      │
 │ LocalDevVPN (loopback) ◀────────┘      │
 │   └─▶ lockdownd / installd (pairing)   │
 └────────────────────────────────────────┘
```

The core is written in Rust on top of [isideload](https://github.com/nab138/isideload) and [idevice](https://github.com/jkcoxson/idevice). It talks to the device's own install service through a loopback VPN using a pairing file, the same trick SideStore uses, so no computer is needed after setup.

**Run inside** (based on [LiveContainer](https://github.com/khanhduytran0/LiveContainer)'s approach): the guest's executable is turned into a loadable library (header type, a smaller `__PAGEZERO`, an install name, `@executable_path` paths rewritten), and the whole bundle is signed with the injector's own team certificate. At launch, before any of the injector's UI exists, the runtime sets up the guest's data directory, overrides process identity (`__progname`, `NSProcessInfo.processName`, `argv[0]`), swizzles NSBundle/NSUserDefaults/bundleIdentifier/NSFileManager, loads the guest via `dlopen(RTLD_LAZY | RTLD_GLOBAL | RTLD_FIRST)`, registers its bundle resources, and jumps to its `LC_MAIN` entry point. With **JIT**, StikDebug relaunches the injector with a debugger attached first.

**Lab tools** use the [worse_query](https://github.com/forcequitOS/worse_query) sandbox escape to access system containers outside the app sandbox. On iOS 27.0.1, it queries containermanagerd directly with the correct flags and consumes a sandbox extension token, then falls back to inode enumeration with auto-calibrated ceiling if needed.

**VPN detection** checks utun and ipsec interfaces for private IPs (10.7.0.x, 10.6.x, fd*) and falls back to a TCP probe to 10.7.0.1:62078 (the standard lockdownd port on the loopback tunnel).

## Setup

You need a Linux PC with `usbmuxd` running (`libimobiledevice` installed), a USB cable and an Apple ID.

1. Get `JapuszkoInjector.ipa` and `jinject-linux-x86_64` from [Releases](../../releases/latest) (or [build them](#build-from-source)).
2. Plug in the device, unlock it, tap **Trust**, then:
   ```sh
   idevicepair pair
   ./jinject-linux-x86_64 bootstrap JapuszkoInjector.ipa -e you@icloud.com
   ```
   This installs the app, allows network lockdown connections, and hands the app its pairing file and signing key so the phone keeps using the same certificate.
3. On the device: **Settings → General → VPN & Device Management**, trust your Apple ID.
4. Install **LocalDevVPN** from the App Store and switch it on.
5. Open JapuszkoInjector and add your account in **Lab**. Done.

<details>
<summary>Hands-off refresh with Shortcuts</summary>

Shortcuts → Automation → **+** → Time of Day (e.g. 04:00) → Run Immediately → add **Refresh Apps** (JapuszkoInjector). Leave LocalDevVPN on. You can also use "When charger is connected".
</details>

<details>
<summary>Already have a pairing file?</summary>

Open it with JapuszkoInjector (`.mobiledevicepairing` or `.plist`), share it from iLoader or Files, or use the `japuszkoinjector://pair?url=<file-url>` scheme. `jinject pair -o pairing.plist` writes one from a USB device.
</details>

## Run inside & JIT

| | Install | Run inside |
|---|---|---|
| App slot (3 per free Apple ID) | uses one | none |
| App ID (10 per week) | one per app + extensions | none |
| Expires | 7 days, refreshed | as long as JapuszkoInjector |
| Own home screen icon | yes | launched from the Rack |
| Extensions, push, special entitlements | yes | no |

Switching to a container app restarts JapuszkoInjector. Swipe the guest away in the app switcher to come back.

**JIT:** mark a container app as *Needs JIT* and it launches through StikDebug (`stikjit://enable-jit`). On recent iOS versions with A15 or newer chips, StikDebug only grants JIT to apps it has a script for, so each container app has an optional *StikDebug script* field.

## Build from source

Requirements: Rust (stable). The iOS app is built by GitHub Actions on macOS, no Mac needed locally.

```sh
cargo build --release -p jinject          # Linux CLI
cargo test  -p jinject-core               # core tests
```

Push to `main` (or run the workflow manually) and Actions builds `libjinject_core.a` for `aarch64-apple-ios`, generates the Xcode project with XcodeGen, builds an unsigned `JapuszkoInjector.ipa`, and attaches it plus the Linux CLI to the `latest` release.

Change the app icon with `scripts/set-icon.sh icon.png`.

<details>
<summary>Project layout</summary>

```
core/src/
  engine.rs   accounts, install/refresh, app-ID + slot prompts, certs, export
  prep.rs     ipa → tweaked .app, encryption check, icon, profile expiry
  device.rs   loopback/USB connection, lockdown, install, house_arrest
  guest.rs    Run inside: Mach-O patcher + signing with the team cert
  ffi.rs      C/JSON API used by Swift
cli/          jinject: bootstrap, install, pair, certs, export-cert, app-ids
ios/          SwiftUI app (XcodeGen project.yml), Guest/ runtime (Obj-C), Exploit/ (worse_query, pathleak)
```
</details>

## FAQ

**Why does it need a VPN app?** iOS only lets an app reach the install service over the network. The VPN loops that traffic back to the device itself. A free Apple ID can't sign an app with its own VPN extension, so it lives in a separate app.

**Is the 3-app / 7-day / 10-ID limit gone?** No, Apple enforces it for free accounts. JapuszkoInjector makes it hurt less: more accounts, app ID reuse, automatic refresh and Run inside.

**Can I use a paid developer account?** Yes. Turn off *Free account limits* in Lab → Signing.

**Where does my password go?** Into this device's Keychain, so refreshes can sign in again by themselves. It's only ever sent to Apple.

## Credits

- [isideload](https://github.com/nab138/isideload) by nab138: Apple ID, developer services, signing, install (MIT)
- [idevice](https://github.com/jkcoxson/idevice) by jkcoxson: lockdown, AFC, installation proxy (MIT)
- [apple-codesign-quick](https://github.com/Dadoum/apple-crates) by Dadoum: code signing (LGPL-2.1-or-later)
- [worse_query](https://github.com/forcequitOS/worse_query) by forcequit: sandbox escape for iOS 26–27 (GPL-3.0)
- [StikDebug](https://github.com/StikDebug/StikDebug): JIT enabling for container apps
- [LiveContainer](https://github.com/khanhduytran0/LiveContainer) by khanhduytran0: guest runtime approach (MIT)
- [SideStore](https://github.com/SideStore/SideStore): VPN detection, wireless pairing, anisette architecture
- AltStore, for showing what's possible on stock iOS

## License

JapuszkoInjector is released under the [MIT License](LICENSE). It statically links `apple-codesign-quick` (LGPL-2.1-or-later); see [THIRD_PARTY.md](THIRD_PARTY.md).

Not affiliated with Apple. Use your own Apple ID and only install apps you have the right to use.
