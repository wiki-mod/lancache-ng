
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

# build-tools

`tools/build-tools/Dockerfile` is the single Alpine Linux build and validation
environment used by Lancache-NG CI. It is built for `linux/amd64` and
`linux/arm64`; no Debian or `rust:*` stage is supported.

## Toolchain contract

The image installs Rust, Cargo, Rustfmt, and Clippy from Alpine packages. The
native target is the target reported by `rustc -vV`:

- `x86_64-alpine-linux-musl` on amd64;
- `aarch64-alpine-linux-musl` on arm64.

`ci.sh build-args` passes that host triple to Rust service builds as
`MUSL_TARGET`, and `ci.sh rust-build` fails closed unless it equals the
`host:` line of `rustc -vV`. Nothing may call `rustup`: Alpine's packaged Rust
has no `rustup` executable and no upstream `*-unknown-linux-musl` standard
library.

Every installed package, including `cargo-audit`, `sccache`, and `trivy`, is
an Alpine package listed in `build_toolchain.build-tools.packages` of
`.github/yaml/build-manifest.yml`; the Dockerfile only consumes that list via
the `APK_PACKAGES` build-arg that `ci.sh build-args build-tools` emits.

## Required validation

`build_toolchain.build-tools.smoke_tools` (executables that must exist) and
`smoke_runs` (commands that must exit 0) in the SOT are the one toolchain
smoke contract. `ci.sh verify` runs both against the pushed per-arch digest;
the Dockerfile keeps no second tool list. A changed build-tools image must
pass both architecture builds, the smoke, and scans before promotion makes
it selectable for downstream CI jobs.

## Known deliberate choices

- GNU `coreutils`, `findutils`, `grep`, `gawk`, and `sed` are installed because
  the Bats and validation scripts use their GNU behavior.
- `parallel` is installed because Bats is executed with `--jobs`.
- `dhclient` has no suitable Alpine package. Jobs needing it request it only
  where the repository's established Alpine-compatible acquisition path is
  available.
- All temporary project validation data uses `/var/tmp` inside candidate
  containers when a stable disk-backed location is required.
