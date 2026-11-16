# Third-party software

JapuszkoInjector's own code is MIT licensed (see `LICENSE`). The iOS app and the
`jinject` CLI include these libraries (plus their transitive dependencies, listed
in `Cargo.lock`):

| Library | License | Used for |
|---|---|---|
| [isideload](https://github.com/nab138/isideload) | MIT | Apple ID sign-in, developer services, signing, install |
| [idevice](https://github.com/jkcoxson/idevice) | MIT | lockdown, AFC, installation proxy, house_arrest |
| [apple-codesign-quick](https://github.com/Dadoum/apple-crates) | LGPL-2.1-or-later | Mach-O / bundle code signing |
| [tokio](https://tokio.rs), [serde](https://serde.rs), [plist](https://crates.io/crates/plist), [zip](https://crates.io/crates/zip), [rustls](https://github.com/rustls/rustls) | MIT / Apache-2.0 | runtime, serialization, archives, TLS |

## LGPL notice

`apple-codesign-quick` is licensed under the GNU Lesser General Public License
v2.1 or later and is statically linked into the iOS app and the CLI. Its source is
available from the link above, and the complete source of JapuszkoInjector is in
this repository, so you can rebuild the app against a modified version of the
library with `cargo build` and the GitHub Actions workflow in
`.github/workflows/build.yml`.
