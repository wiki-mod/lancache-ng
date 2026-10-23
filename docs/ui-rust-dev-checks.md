# Local Admin UI Rust Checks

The Admin UI crate at `services/ui/` is a member of the Rust workspace in
the repository-root `Cargo.toml`. Its checks run inside the project
build-tools container, so contributors do not need `rustc` on the host and
every run uses the same toolchain as CI. `AGENTS.md`'s build-tools
verification contract explains why host-local `cargo`/`rustc` do not count
as verification.

The build-tools image is the published one, resolved to its digest:

```bash
BUILD_TOOLS_IMAGE="$(bash .github/scripts/ci.sh build-tools resolve-image)"
```

`resolve-image` needs `GITHUB_ACTOR` and `GHCR_TOKEN` for GHCR read access.
The tools the image carries are listed in the SOT `build_toolchain` block
(`bash .github/scripts/ci.sh build-tools packages`).

Run from the repository root:

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work" -w /work "$BUILD_TOOLS_IMAGE" \
  bash -c 'cargo fmt --check -p lancache-ui && cargo clippy --locked --all-targets -p lancache-ui -- -D warnings && cargo test --locked -p lancache-ui'
```

These are the same commands `ci.sh test-stack` runs per crate in CI.
`cargo check` stays a manual developer step (`AGENTS.md` **AG-VAL-008**).
