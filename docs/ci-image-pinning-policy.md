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
  - `actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0` ✅ Pinned by commit SHA
  - `dtolnay/rust-toolchain@fa04a1451ff1842e2626ccb99004d0195b455a88 # stable` ✅ Pinned by commit SHA
  - `docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0` ✅ Pinned by commit SHA

- `.github/workflows/build-tools.yml`:
  - `actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0` ✅ Pinned by commit SHA
  - `docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0` ✅ Pinned by commit SHA

- `.github/workflows/codeql.yml`:
  - `actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0` ✅ Pinned by commit SHA
  - `github/codeql-action/init@54f647b7e1bb85c95cddabcd46b0c578ec92bc1a # v4` ✅ Pinned by commit SHA

- `.github/workflows/first-interaction.yml`:
  - `actions/setup-node@48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e # v6.4.0` ✅ Pinned by commit SHA
  - `actions/github-script@3a2844b7e9c422d3c10d287c895573f7108da1b3 # v9.0.0` ✅ Pinned by commit SHA

**Status**: ✅ All GitHub Actions are already pinned.

### Docker Base Images in Dockerfiles

All `FROM` directives in first-party Dockerfiles are pinned to explicit SHA-256 digests:

The first-party runtime Dockerfiles intentionally use `mirror.gcr.io/library/*`
for Debian runtime bases, including `services/ui/Dockerfile`. This is a
project-wide cache decision, not a one-off oversight in the Admin UI image:
the immutable digest is the supply-chain control, while `mirror.gcr.io` is the
configured pull source for these public Docker Hub bases. If Google evicts a
cached digest and a build can no longer pull it, the build must fail closed and
the base reference must be refreshed in a reviewed PR; Dockerfiles must not
carry a second fallback `FROM` path because Dockerfile syntax cannot express a
trusted registry-fallback chain without changing the built image provenance.
Operators or CI runners that require Docker Hub as the source should configure
that at the Docker daemon or build infrastructure layer, not by adding
undocumented per-Dockerfile fallback logic.

- `services/proxy/Dockerfile`: `FROM mirror.gcr.io/library/debian:13-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2` ✅
- `services/dns/Dockerfile` (runtime stage): `FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2` ✅
- `services/dhcp/Dockerfile`: `FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2` ✅
- `services/dhcp-proxy/Dockerfile`: `FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2` ✅
- `services/ui/Dockerfile` (runtime stage): `FROM mirror.gcr.io/library/debian:trixie-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2` ✅
- `services/watchdog/Dockerfile`: `FROM mirror.gcr.io/library/debian:13-slim@sha256:28de0877c2189802884ccd20f15ee41c203573bd87bb6b883f5f46362d24c5c2` ✅

**Status**: ✅ All runtime base images are pinned.

### Build-Time Images (Builder Stages)

- `services/dns/Dockerfile` (builder stage): `FROM ${BUILD_TOOLS_IMAGE} AS subscriber-builder`
  - ARG default (line 6): `ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest`
  - **Status**: ⚠️ ARG default is mutable (`:latest`) — intentional fallback
  - **Rationale**: This is a documented, overridable ARG default. Production release builds pass a pinned digest via `--build-arg BUILD_TOOLS_IMAGE=<digest>`. Actual digest pinning for the default is tracked in issue #508.

- `services/ui/Dockerfile` (builder stage): `FROM ${BUILD_TOOLS_IMAGE} AS builder`
  - ARG default (line 12): `ARG BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/lancache-ng/build-tools:latest`
  - **Status**: ⚠️ ARG default is mutable (`:latest`) — intentional fallback
  - **Rationale**: This is a documented, overridable ARG default. Production release builds pass a pinned digest via `--build-arg BUILD_TOOLS_IMAGE=<digest>`. Actual digest pinning for the default is tracked in issue #508.

### Workflow Build-Tools References

- `.github/workflows/build-push.yml`:
  - There is no standalone `BUILD_TOOLS_IMAGE=...:latest` fallback assignment in this file — that mechanism was replaced by the selector script entirely. Every consumer resolves the image by calling `scripts/select-build-tools-image.sh` and writing its stdout to `$GITHUB_ENV` (see lines 300/314/316 for the two call sites, and line 1719 for a third).
  - **Status**: ✅ No mutable tag is assigned directly in this workflow; resolution always goes through the selector script.
  - **Rationale**: The selector script (`scripts/select-build-tools-image.sh`) resolves all `:latest` tags to immutable digest-qualified references before returning them to the workflow. This is the authoritative policy for the active CI path.

- `.github/actions/rust-acceleration-preflight/action.yml`:
  - Input default (line 29): `default: ghcr.io/wiki-mod/lancache-ng/build-tools:latest`
  - **Status**: ⚠️ Input default uses mutable tag — intentional fallback for local use
  - **Rationale**: This action is a validation-only preflight that runs against whatever image the caller specifies. Primary workflows (`build-push.yml`) pass an explicit pinned digest selected via `scripts/select-build-tools-image.sh`. The `:latest` default is provided for developers and other tools that call this action directly without overriding the input.

## Known Mutable References and Decision Summary

### Pending Digest Pinning (Issue #508)

The following references use mutable tags and are planned for actual digest replacement:

1. **`BUILD_TOOLS_IMAGE` ARG defaults** in:
   - `services/dns/Dockerfile` line 6
   - `services/ui/Dockerfile` line 12
   - **Decision**: Keep as documented fallback ARGs (overridable at build time). Real digest pinning is owned by issue #508.
   - **Why**: These are intentional ARG defaults that allow override at build time. Release builds must explicitly pass `--build-arg BUILD_TOOLS_IMAGE=<pinned-digest>` to ensure reproducibility.

### Intentional Mutable Fallbacks (Documented)

The following references use mutable tags and are intentionally kept as fallbacks:

1. **`.github/actions/rust-acceleration-preflight/action.yml` input default** (line 29):
   - **Decision**: Keep as `:latest` fallback for local developer use.
   - **Why**: Primary workflows always override this with a pinned digest from `scripts/select-build-tools-image.sh`. The action is validation-only, not build-time critical.

2. **`scripts/select-build-tools-image.sh` internal `published_image` variable** (line 16):
   - **Decision**: Keep as `:latest` because the script immediately resolves it to a pinned digest (line 98: `printf '%s@%s\n' "${image%:*}" "$digest"`).
   - **Why**: Callers of this script receive a digest-qualified reference, never the mutable tag.

## Remediation Steps

To pin these remaining references, perform the following in order:

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
   - Run `bash scripts/check-mutable-refs.sh` to confirm all references are pinned.
   - Run the full CI workflow to ensure the pinned image is still compatible.

## Local Mutable Channels (Documented Exception)

This project defines several mutable channels in `release/stack-images.yml` for development and release purposes:

- `dev`: development/test channel (mutable)
- `edge`: pre-stable integration channel from master (mutable)
- `latest`: stable releases only (mutable, must not be moved by non-release workflows)

These channels are documented in `release/stack-images.yml` and are intended to be mutable. References to these channels are exempt from the pinning requirement, provided they are explicitly documented as intentional. See `docs/release-versioning.md` for details on the channel model.

## Verification

To verify that all CI-sensitive images are pinned, run:

```bash
bash scripts/check-mutable-refs.sh
```

This script checks for floating-tag patterns in workflows and Dockerfiles and reports violations.

## CONTRIBUTING.md Alignment

This policy formalizes the requirement stated in `CONTRIBUTING.md` section "Quality and release process expectations":

> Keep workflow action references pinned to full commit SHAs with a version comment; floating tags such as `@v4` are forbidden in project PRs, because Dependabot and similar tooling report them as a security finding.

And reinforces:

> release-capable paths must not depend on mutable `build-tools:latest`
