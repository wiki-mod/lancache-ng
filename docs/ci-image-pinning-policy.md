# CI Image Pinning Policy

This policy covers immutable references for CI- and release-sensitive images and
GitHub Actions: why they are pinned, where each pin is owned, the documented
exception, how to compute a pin, and how CI checks it. It keeps no copy of the
pinned values; each value has one owner (AG-CI-006).

Source: issue #489 (pin CI/runtime images by immutable SHA; a short policy doc
and a helper check), PR #497 (first version), issue #508 (Dockerfile build-arg
defaults, decided as AGENTS.md AG-CI-008).

## Why pins

- **Reproducibility**: the same pin gives the same base image, binaries and
  tools on every build.
- **Supply chain**: a mutable tag such as `:latest` can change at any time, so
  a re-release could pick up new vulnerabilities or breaking changes without a
  change in this repository.
- **Release integrity**: a `vX.Y.Z` release must be reproducible; a mutable base
  reference breaks that.

## Rules and owners

- **GitHub Actions** (AGENTS.md AG-CI-001, CONTRIBUTING.md): every `uses:` pins
  the full 40-character commit SHA with a version comment
  (`uses: owner/action@<sha> # vX.Y.Z`). The workflows under
  `.github/workflows/` are the inventory. A `docker://` step is accepted only
  when its image equals a SOT `base_images` pin.
- **Base images** (AG-CI-008): every first-party Dockerfile declares its image
  build arguments without a default (`ARG ALPINE_IMAGE`, and
  `ARG BUILD_TOOLS_IMAGE` in the Rust builder stages) and uses
  `FROM ${ALPINE_IMAGE:-scratch}` / `FROM ${BUILD_TOOLS_IMAGE:-scratch}`. A build
  without the argument fails on `scratch` instead of pulling a mutable tag.
  `ci.sh` passes the digest-pinned SOT `base_images` entries from
  `.github/yaml/build-manifest.yml` and the build-tools image as a digest from
  `ci.sh build-tools resolve-image`.
- **External images run by the stack**: SOT `external_services`. A digest-less
  tag is allowed only for an explicit `policy: tag-latest` entry (netdata,
  maintainer decision recorded on PR #1858, 2026-10-01).
- **Pinned tool downloads**: SOT `external_versions` with their checksums.

Docker Hub bases are pulled through `mirror.gcr.io/library/*`. The digest is the
supply-chain control; the mirror is only the pull source. If the mirror evicts a
cached digest and a build cannot pull it, the build fails closed and the SOT pin
is refreshed in a reviewed PR. Dockerfiles carry no second fallback `FROM`
path: Dockerfile syntax cannot express a trusted registry-fallback chain
without changing the provenance of the built image. Operators or runners that
need Docker Hub as the source configure it at the Docker daemon or build
infrastructure layer.

## Exception: the project's own channels

The channels in SOT `release.channels` (`nightly`, `latest`) are mutable by
design and exempt from the pinning rule; `docs/release-versioning.md` owns their
semantics. Release-capable paths do not depend on a mutable `build-tools`
channel tag (CONTRIBUTING.md).

## Computing a pin

Docker image (multi-arch: pin the index digest, not one platform's manifest):

```bash
docker buildx imagetools inspect docker.io/library/alpine:3.24 --format '{{.Manifest.Digest}}'
# or, with the go-containerregistry CLI (released binary):
crane digest docker.io/library/alpine:3.24
```

`docker pull` followed by `docker inspect --format '{{index .RepoDigests 0}}'`
prints the same index digest as part of the repository digest.

GitHub Action:

```bash
git ls-remote https://github.com/owner/action.git refs/tags/v1.2.3
# <sha>  refs/tags/v1.2.3   ->   uses: owner/action@<sha> # v1.2.3
```

To change a pin, change its SOT entry (or the `uses:` line for an action). The
build identity of every consumer changes with a base pin; see the last section.

## Checks

CI runs these in `ci.sh check all` (job `checks` in `ci.yml`); locally they run
inside the `build-tools` container (AG-VAL-016):

```bash
bash .github/scripts/ci.sh check mutable-refs            # tags, branches, short SHAs, unpinned images
bash .github/scripts/ci.sh check action-node-versions    # pinned actions: runtime and reference shape
bash .github/scripts/ci.sh check stable-external-images  # digest-less external images
bash .github/scripts/ci.sh version verify                # external_versions consumers
```

## Drift is part of the build identity

CI 2.0 decides reuse the same way for every trigger
(docs/ci-2.0-architecture.md sections 6, 27 and 54): a target is rebuilt only
when its build identity changed and no accepted digest exists for it. The base
image enters the identity as its SOT-pinned digest (`base_digest`) and apk
package versions are resolved live whenever an identity is computed
(`package_versions`), so a new pin or a newer package changes the identity and
requires a build; an unchanged one reuses the accepted digest.
