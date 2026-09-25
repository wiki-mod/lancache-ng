
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

Service Dockerfiles derive their Cargo `--target` from that same architecture
mapping and verify it against `rustc -vV`. They must not call `rustup target
list`, because Alpine's packaged Rust toolchain does not expose a usable
`rustup` executable or the upstream `*-unknown-linux-musl` standard library.

`cargo-audit` and `cargo-tarpaulin` are native Alpine packages. `sccache`
remains a pinned Cargo source install because the available Alpine package does
not provide the repository-required Redis and dist-client feature selection.
The Dockerfile removes Cargo's downloaded source cache after that installation
so it does not become scanner-visible image content.

## Required validation

The Dockerfile's final `required_tools` check is the image-local contract. The
candidate smoke action additionally verifies its command set and runs Bats and
ShellSpec fixtures in the exact candidate image. A changed build-tools image
must complete both architecture builds, scans, candidate smoke checks, and the
published-manifest promotion before downstream CI jobs select it.

## Package-cache refresh

`APT_CACHE_BUST` is the repository-owned cache epoch consumed by the Alpine
package-install layer. Its name is retained for compatibility with the shared
workflow variable; it is not an instruction to use APT. The package layer
still uses `apk` exclusively.

## Known deliberate choices

- GNU `coreutils`, `findutils`, `grep`, `gawk`, and `sed` are installed because
  the Bats and validation scripts use their GNU behavior.
- `parallel` is installed because Bats is executed with `--jobs`.
- `dhclient` has no suitable Alpine package. Jobs needing it request it only
  where the repository's established Alpine-compatible acquisition path is
  available.
- All temporary project validation data uses `/var/tmp` inside candidate
  containers when a stable disk-backed location is required.
