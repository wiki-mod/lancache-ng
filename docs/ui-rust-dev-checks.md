# Local Admin UI Rust Checks

This repository provides local Docker-based Rust checks for `services/ui`, so
contributors do not need `rustc` on the host machine.

Run from the repository root:

```bash
./scripts/ui-rust-checks.sh
```

The script runs, in this order:

- `cargo test --locked --manifest-path services/ui/Cargo.toml`
- `cargo build --locked --release --manifest-path services/ui/Cargo.toml`

The CI workflow still runs the stricter `cargo fmt`, `cargo check`, and
`cargo clippy` jobs separately.

You can also add a format check:

```bash
./scripts/ui-rust-checks.sh --fmt
```

### Optional sccache with Redis

To speed up repeated builds in containers, pass `--sccache` together with Redis.
The script installs `sccache` from source inside the Rust container with `cargo install`.

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
- `--fmt` to include cargo formatting checks
- `--no-test`, `--no-build` to limit the default checks
- `--rust-image <image>` use a different Rust image
