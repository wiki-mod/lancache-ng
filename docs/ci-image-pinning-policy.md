# CI Image Pinning Policy

This document describes the image pinning policy for lancache-ng's CI/release infrastructure, how to compute immutable digests for Docker images and GitHub Actions, and the current inventory of pinned versus mutable references across the build system.

## Why Image Pinning Matters

- **Reproducibility**: A pinned image digest ensures that repeated CI builds use the exact same base images, binaries, and tooling, producing byte-for-byte identical outputs and simplifying debugging of intermittent failures.
- **Supply chain security**: A mutable tag (like `:latest`) can be updated by a registry administrator or compromised maintainer at any time. A released product pinned to a mutable upstream tag can acquire new vulnerabilities or breaking changes on re-release, without any source code change on this project's side.
- **Release integrity**: For stable releases (tagged `vX.Y.Z` in this repo), the release pipeline must produce reproducible artifacts. Mutable base image references can violate this contract.

## Scope

This policy applies to:

- **GitHub Actions references** in `.github/workflows/*.yml` — each `uses:` directive must use an explicit SHA-256 digest (`uses: owner/action@sha256:...`) or a pinned release tag with a comment showing the resolved digest.
- **Docker base images** in `Dockerfile` `FROM` lines — every `FROM` directive outside of builder/intermediate stages must reference an image by a digest or an explicitly stable tag, never a floating tag like `:latest` (with documented exceptions for this project's own mutable channels, see below).
- **Build-time image references** in CI workflows and build scripts that download container images — must use pinned references.

## Computing a Digest

### For a Docker Image

To resolve the immutable digest of a Docker image, use one of:

1. **`docker pull` + inspect (requires local Docker daemon)**:
   ```bash
   docker pull nginx:1.27.2
   docker inspect --format '{{index .RepoDigests 0}}' nginx:1.27.2
   # Output: docker.io/library/nginx@sha256:...
   ```

2. **`crane digest` (Google's container tool, installed via `go install github.com/google/go-containerregistry/cmd/crane@latest`)**:
   ```bash
   crane digest docker.io/library/nginx:1.27.2
   # Output: sha256:...
   ```

3. **`docker manifest inspect` (Docker 20.10+)**:
   ```bash
   docker manifest inspect docker.io/library/nginx:1.27.2 | jq -r '.manifests[0].digest'
   # Output: sha256:...
   ```

4. **GitHub Container Registry (`ghcr.io`)**:
   ```bash
   docker pull ghcr.io/owner/repo/image:tag
   docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/owner/repo/image:tag
   ```

The resulting digest string (format: `sha256:abcdef...`) is globally immutable — it uniquely identifies that exact image content forever.

### For a GitHub Action

GitHub Actions are stored as container images in GitHub's container registry. To pin an action:

1. **Find the commit SHA** of the release tag you wish to pin:
   ```bash
   git ls-remote https://github.com/owner/action.git refs/tags/v1.2.3
   # Output: <sha-hash>  refs/tags/v1.2.3
   ```

2. **Use the commit SHA in the workflow**:
   ```yaml
   - uses: owner/action@<sha-hash>
   ```

3. **Add a comment with the version for clarity**:
   ```yaml
   - uses: owner/action@<sha-hash> # v1.2.3
   ```

Alternatively, some projects publish digest-based references; check the action's repository for a `@v1.2.3` tag's commit history to see if digest pinning is documented.

## Current Inventory

### GitHub Actions (Workflows)

All GitHub Actions in the current set of workflows are already pinned to SHA digests with version comments. Examples:

- `.github/workflows/build-push.yml`:
  - `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` ✅ Pinned by commit SHA
  - `dtolnay/rust-toolchain@4cda84d5c5c54efe2404f9d843567869ab1699d4 # stable` ✅ Pinned by commit SHA
  - `docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0` ✅ Pinned by commit SHA

- `.github/workflows/build-tools.yml`:
  - `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` ✅ Pinned by commit SHA
  - `docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0` ✅ Pinned by commit SHA

- `.github/workflows/codeql.yml`:
  - `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` ✅ Pinned by commit SHA
  - `github/codeql-action/init@e4fba868fa4b1b91e1fdab776edc8cfbe6e9fb81 # v4.37.3` ✅ Pinned by commit SHA

- `.github/workflows/first-interaction.yml`:
  - `actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0` ✅ Pinned by commit SHA
  - `actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0` ✅ Pinned by commit SHA

**Status**: ✅ All GitHub Actions are already pinned.

### Docker Base Images in Dockerfiles

Every first-party Dockerfile's own **runtime** base image is pinned to an explicit SHA-256 digest (see the inventory below). Two categories of **build-time-only, intermediate** stage are a deliberate, documented exception to that: the `BUILD_TOOLS_IMAGE`-based builder stage (`services/dns`, `services/ui`) and, since AG-KD-010, the `UTILITIES_IMAGE`-based `utilities-tools` stage (all seven first-party consumers) -- see "Build-Time Images (Builder Stages)" below for both.

The first-party runtime Dockerfiles intentionally use `mirror.gcr.io/library/*`
as the pull source for their runtime bases. Base OS is mixed, not uniformly
Debian, as issue #815's staged Alpine migration has progressed: `services/dhcp`,
`services/dhcp-proxy`, `services/watchdog`, `services/ntp`, `services/dns`,
`services/proxy`, and `services/ui` have all moved to the same pinned Alpine base
(`services/watchdog`'s own carve-out, revisited and approved 2026-07-31, is
independent of #842's Rust rewrite -- a scaffold now exists for that rewrite, see
`services/watchdog/Cargo.toml`, but it is not yet built or used as this
container's entrypoint, so this base-image decision stays unaffected either
way). `services/ui` landed its own migration in a sibling PR while this
document's `services/proxy` update was still in flight -- confirmed live
against `services/ui/Dockerfile`'s current `FROM` line rather than assumed.
`services/syslog` (the combined fluent-bit + syslog-ng central logging
service, #1431/#1433) is on Alpine too, but was never part of #815's
migration set above -- it was born on Alpine from its first commit, so it
gets its own inventory row below rather than being folded into the
staged-migration list. Every first-party runtime image is now on Alpine
except `tools/build-tools`
(Rule-Ref: AG-KD-009 in `AGENTS.md`, a deliberate, separately-decided
exception, not an oversight). This is a
project-wide cache decision, not a one-off oversight in the Admin UI image:
the immutable digest is the supply-chain control, while `mirror.gcr.io` is the
configured pull source for these public Docker Hub bases, whichever
distribution a given service's base image happens to be. If Google evicts a
cached digest and a build can no longer pull it, the build must fail closed and
the base reference must be refreshed in a reviewed PR; Dockerfiles must not
carry a second fallback `FROM` path because Dockerfile syntax cannot express a
trusted registry-fallback chain without changing the built image provenance.
Operators or CI runners that require Docker Hub as the source should configure
that at the Docker daemon or build infrastructure layer, not by adding
undocumented per-Dockerfile fallback logic.

- `services/proxy/Dockerfile`: `FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` ✅ (migrated from Debian 13-slim to Alpine, issue #815, staged Alpine migration)
- `services/dns/Dockerfile` (runtime stage): `FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` ✅ (migrated from Debian trixie-slim to Alpine, issue #815, staged Alpine migration; PowerDNS/recursor pinned to Alpine's `edge` branch specifically for a CVE fix, see `services/dns/Dockerfile`'s own comment)
- `services/dhcp/Dockerfile`: `FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` ✅ (migrated from Debian trixie-slim to Alpine, issue #815, staged Alpine migration — Kea second)
- `services/dhcp-proxy/Dockerfile`: `FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` ✅ (migrated from Debian trixie-slim to Alpine, issue #815, staged Alpine migration — dnsmasq-first)
- `services/ntp/Dockerfile`: `FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` ✅ (migrated from Debian trixie-slim to Alpine, issue #815, staged Alpine migration)
- `services/ui/Dockerfile` (runtime stage): `FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` ✅ (migrated from Debian trixie-slim to Alpine in a sibling PR, issue #815, staged Alpine migration)
- `services/watchdog/Dockerfile`: `FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` ✅ (migrated from Debian 13-slim to Alpine, issue #815's watchdog carve-out, revisited/approved 2026-07-31 -- independent of #842's Rust rewrite, which now has a scaffold crate but is not yet built or used as this container's entrypoint)
- `services/syslog/Dockerfile`: `FROM mirror.gcr.io/library/alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` ✅ (born on Alpine from its first commit, #1431/#1433 -- not part of issue #815's Debian-to-Alpine migration since it never ran on Debian; originally pinned directly to `alpine:3.20` rather than through `mirror.gcr.io`, an unintentional scaffold-commit inconsistency never a deliberate choice -- issue #1554 brought it onto the same `mirror.gcr.io/library/alpine:3.24` pin every other first-party service already uses; `syslog-ng` stayed available, and newer, on 3.24, see that file's own header comment for the full version rationale)

**Status**: ✅ All runtime base images are pinned.

### Build-Time Images (Builder Stages)

- `services/dns/Dockerfile` (builder stage): `FROM ${BUILD_TOOLS_IMAGE} AS subscriber-builder`
  - ARG default (line 6): `ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest`
  - **Status**: ⚠️ ARG default is mutable (`:latest`) — intentional fallback, permanently
  - **Rationale**: This is a documented, overridable ARG default that only matters for a manual `docker build` invocation without `--build-arg`. Every real CI build (workflow jobs, release jobs) always passes `--build-arg BUILD_TOOLS_IMAGE=<pinned-digest>` explicitly and never falls back to this default. Issue #508 proposed actually pinning this default to a resolved digest and was closed as already-resolved-by-design: pinning/updating the default for "consistency" would introduce a permanently-stale, manually-maintained digest without fixing anything a real build path depends on. See `AGENTS.md`'s Rule-Ref: AG-CI-008 for the codified rule.

- `services/ui/Dockerfile` (builder stage): `FROM ${BUILD_TOOLS_IMAGE} AS builder`
  - ARG default (line 12): `ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest`
  - **Status**: ⚠️ ARG default is mutable (`:latest`) — intentional fallback, permanently
  - **Rationale**: Same as `services/dns/Dockerfile` above — issue #508 closed as already-resolved-by-design; see `AGENTS.md`'s Rule-Ref: AG-CI-008.

- `services/proxy`, `services/dns`, `services/dhcp`, `services/dhcp-proxy`, `services/ntp`, `services/ui`, `services/watchdog` (each Dockerfile's own `utilities-tools` stage): `FROM ${UTILITIES_IMAGE} AS utilities-tools`
  - ARG default: `ARG UTILITIES_IMAGE=ghcr.io/wiki-mod/lancache-ng/utilities:latest`
  - **Status**: ⚠️ ARG default is mutable (`:latest`) — a deliberate reversal of an earlier hardcoded-digest pin, AG-KD-010.
  - **Rationale**: Unlike `BUILD_TOOLS_IMAGE`, this ARG default is not purely a manual-build fallback — real CI builds also override it, but with a digest resolved once per run (`validate-compose`'s "Resolve utilities image digest" step) rather than a hand-maintained pin, so a `utilities` security/tooling update reaches every consumer's next build automatically instead of requiring someone to notice and re-pin seven files. The accepted tradeoff (a `utilities` regression also reaches every consumer's next build) is documented in `AGENTS.md`'s Rule-Ref: AG-KD-010. Every consumer image also carries an `org.opencontainers.image.base.utilities.digest` label recording the exact digest actually baked in at build time, so the release SBOM merge step (and any other later inspection) reads the real, per-image value instead of re-resolving `utilities:latest`/`:<tag>` independently and risking a mismatch against what that specific image actually contains.

### Workflow Build-Tools References

- `.github/workflows/build-push.yml`:
  - There is no standalone `BUILD_TOOLS_IMAGE=...:latest` fallback assignment in this file — that mechanism was replaced by the selector script entirely. Every consumer resolves the image by calling `scripts/untracked/select-build-tools-image.sh` and writing its stdout to `$GITHUB_ENV` (see lines 300/314/316 for the two call sites, and line 1719 for a third).
  - **Status**: ✅ No mutable tag is assigned directly in this workflow; resolution always goes through the selector script.
  - **Rationale**: The selector script (`scripts/untracked/select-build-tools-image.sh`) resolves all `:latest` tags to immutable digest-qualified references before returning them to the workflow. This is the authoritative policy for the active CI path.

- `.github/actions/rust-acceleration-preflight/action.yml`:
  - Input default (line 29): `default: ghcr.io/wiki-mod/lancache-ng/build-tools:latest`
  - **Status**: ⚠️ Input default uses mutable tag — intentional fallback for local use
  - **Rationale**: This action is a validation-only preflight that runs against whatever image the caller specifies. Primary workflows (`build-push.yml`) pass an explicit pinned digest selected via `scripts/untracked/select-build-tools-image.sh`. The `:latest` default is provided for developers and other tools that call this action directly without overriding the input.

## Known Mutable References and Decision Summary

### Resolved: Issue #508 (closed as already-resolved-by-design, not "pending")

Issue #508 asked to actually pin `BUILD_TOOLS_IMAGE` ARG defaults in
`services/dns/Dockerfile` and `services/ui/Dockerfile` to a real digest. It
was closed **without** implementing that pinning: the ARG default only
matters for a manual `docker build` invocation without `--build-arg`; every
real CI build always passes `--build-arg BUILD_TOOLS_IMAGE=<pinned-digest>`
explicitly and never falls back to it, so pinning the default would only add
a manually-maintained value that goes stale with no real build path
depending on it. This decision is codified as `AGENTS.md`'s Rule-Ref: AG-CI-008.

### Intentional Mutable Fallbacks (Documented)

The following references use mutable tags and are intentionally kept as fallbacks:

1. **`.github/actions/rust-acceleration-preflight/action.yml` input default** (line 29):
   - **Decision**: Keep as `:latest` fallback for local developer use.
   - **Why**: Primary workflows always override this with a pinned digest from `scripts/untracked/select-build-tools-image.sh`. The action is validation-only, not build-time critical.

2. **`scripts/untracked/select-build-tools-image.sh` internal `published_image` variable** (line 16):
   - **Decision**: Keep as `:latest` because the script immediately resolves it to a pinned digest (line 98: `printf '%s@%s\n' "${image%:*}" "$digest"`).
   - **Why**: Callers of this script receive a digest-qualified reference, never the mutable tag.

## Remediation Steps (general reference)

The `BUILD_TOOLS_IMAGE` ARG defaults above are intentionally **not** pinned
(see "Resolved: Issue #508" above) — the steps below are kept as general
guidance for pinning a `build-tools` image reference elsewhere (e.g. a real
CI consumption point resolved through `scripts/untracked/select-build-tools-image.sh`),
not an open task against those two ARG defaults:

1. **Determine the target build-tools version**:
   - Identify the stable release tag (e.g., `v0.2.0`) or sha-* tag you wish to use.
   - Example: `ghcr.io/wiki-mod/lancache-ng/build-tools:v0.2.0`

2. **Resolve the digest**:
   ```bash
   docker pull ghcr.io/wiki-mod/lancache-ng/build-tools:v0.2.0
   docker inspect --format '{{index .RepoDigests 0}}' ghcr.io/wiki-mod/lancache-ng/build-tools:v0.2.0
   # Or use crane: crane digest ghcr.io/wiki-mod/lancache-ng/build-tools:v0.2.0
   ```

3. **Update ARG defaults** in the Dockerfiles to use the resolved digest:
   ```dockerfile
   ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools@sha256:...
   ```

4. **Update workflow fallback** to use the pinned tag or digest:
   ```bash
   printf 'BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools@sha256:...\n' >> "$GITHUB_ENV"
   ```

5. **Validate**:
   - Run `bash scripts/tracked/check-mutable-refs.sh` to confirm all references are pinned.
   - Run the full CI workflow to ensure the pinned image is still compatible.

## Local Mutable Channels (Documented Exception)

This project defines several mutable channels in `release/stack-images.yml` for development and release purposes:

- `dev`: development/test channel (mutable)
- `nightly`: pre-stable integration channel from master (mutable; formerly `edge`)
- `latest`: stable releases only (mutable, must not be moved by non-release workflows)

These channels are documented in `release/stack-images.yml` and are intended to be mutable. References to these channels are exempt from the pinning requirement, provided they are explicitly documented as intentional. See `docs/release-versioning.md` for details on the channel model.

## Verification

To verify that all CI-sensitive images are pinned, run:

```bash
bash scripts/tracked/check-mutable-refs.sh
```

This script checks for floating-tag patterns in workflows and Dockerfiles and reports violations.

## CONTRIBUTING.md Alignment

This policy formalizes the requirement stated in `CONTRIBUTING.md` section "Quality and release process expectations":

> Keep workflow action references pinned to full commit SHAs with a version comment; floating tags such as `@v4` are forbidden in project PRs, because Dependabot and similar tooling report them as a security finding.

And reinforces:

> release-capable paths must not depend on mutable `build-tools:latest`

## Note: `workflow_dispatch` always does a full rebuild

The per-push "skip rebuild when nothing relevant changed, retag and scan the existing published image instead" reuse mechanism (`determine push reuse scope`, #1095 Steps 2/4) only evaluates on `push` events -- and even in the reuse case, the resolved channel image still gets a real security scan; nothing here skips scanning. A manual `workflow_dispatch` run of `build-push.yml` (e.g. to force-advance a channel) always performs a full build for every service regardless of whether anything changed -- confirmed live 2026-08-01 (run 30686435421: `determine push reuse scope` reported `skipped`, every `build`/`container-scan` job ran a real, non-trivial-duration build). Do not use a `workflow_dispatch` run as evidence for or against the push-triggered reuse path; it exercises a different, always-rebuild code path entirely.
