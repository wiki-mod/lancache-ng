# Local Admin UI Rust Checks

This repository provides local Docker-based Rust checks for `services/ui`, so
contributors do not need `rustc` on the host machine.

By default, the script uses the project build-tools image:

```text
ghcr.io/wiki-mod/lancache-ng/build-tools:latest
```

That image is intentionally based on `rust:latest` for developer and CI
validation tooling, then it preinstalls and smoke-tests `rustfmt`, `clippy`,
`sccache`, `cargo-audit`, `shellcheck`, `actionlint`, `distcc`, `distcc-pump`,
DNS/setup fixture tools such as `dig`, `ip`, `openssl`, `rsync`, and
`envsubst`, and the required `PATH`. Trivy image scanning remains part of the
workflow container-scan path rather than this local Rust check image.

Run from the repository root:

```bash
./scripts/ui-rust-checks.sh
```

The script runs, in this order:

- `cargo fmt --all --manifest-path services/ui/Cargo.toml -- --check`
- `cargo check --locked --manifest-path services/ui/Cargo.toml`
- `cargo clippy --locked --manifest-path services/ui/Cargo.toml -- -D warnings`
- `cargo test --locked --manifest-path services/ui/Cargo.toml`
- `cargo build --locked --release --manifest-path services/ui/Cargo.toml`

You can override the image for investigation:

```bash
./scripts/ui-rust-checks.sh --rust-image rust:latest --no-fmt --no-clippy
```

If you override the image, it must already contain `rustfmt`, `clippy`, and
`sccache` when you use the corresponding checks. The script no longer installs
missing Rust tooling inside the container. Plain `rust:latest` is useful for
limited investigation, but it does not provide the full default check contract
unless you prepare an image with the required components installed.

### Optional sccache with Redis

To speed up repeated builds in containers, pass `--sccache` together with Redis.
The build-tools image already includes `sccache`. If you override the image and
the replacement image does not contain `sccache`, the script fails closed
instead of bootstrapping it.

```bash
SCCACHE_REDIS_URL=redis://<redis-host>:6379/0 ./scripts/ui-rust-checks.sh --sccache
```

If you do not already have Redis, the script can start a temporary Redis sidecar:

```bash
./scripts/ui-rust-checks.sh --sccache --with-redis
```

Plain `--sccache` without Redis fails on purpose, because cache results should be shareable and predictable.
If you pass a Redis URL directly, make sure it is reachable from inside the Docker container.
Do not commit internal Redis URLs or credentials to the repository.

### Useful options

- `--manifest <path>` override path to another UI manifest
- `--no-fmt`, `--no-check`, `--no-clippy` to skip specific quality checks
- `--no-test`, `--no-build` to limit the default checks
- `--rust-image <image>` use a different Rust image
