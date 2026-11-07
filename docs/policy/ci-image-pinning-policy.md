# CI Image and Action Reference Policy

This policy states where every image and GitHub Action reference of CI and
release is owned, what form it takes, and how CI checks it. It keeps no copy of
the referenced values; each value has one owner (AG-CI-006).

Valid for `current_dev` at `e223782d`.

## Rules and owners

| Reference | Form | Owner |
| --- | --- | --- |
| GitHub Actions | the major tag `vN` in `uses:`; never a commit SHA, never a branch (AG-CI-001) | SOT `github_actions` names the allowed actions; the workflow `uses:` line carries the tag, which Dependabot moves |
| `docker://` workflow steps | the literal SOT `base_images` value, because a workflow `uses:` cannot read the SOT | SOT `base_images` |
| Base images of first-party Dockerfiles | build argument without a default | SOT `base_images`, supplied by `ci.sh` |
| `build-tools` image | the image `ci.sh build-tools resolve-image` selects | `ci.sh` and the SOT |
| Third-party tool downloads | latest release, resolved by `ci.sh` | SOT `external_versions` (`codeql`, `runner`) |

- **Actions**: `ci.sh check action-node-versions` enforces the reference shape
  and the Node runtime of every used action.
- **Dockerfiles** (AG-CI-008): every first-party Dockerfile declares its image
  build arguments without a default (`ARG ALPINE_IMAGE`, and
  `ARG BUILD_TOOLS_IMAGE` in the Rust builder stages) and starts stages with
  `FROM ${ALPINE_IMAGE:-scratch}` or `FROM ${BUILD_TOOLS_IMAGE:-scratch}`. A
  build without the argument fails on `scratch` instead of pulling a mutable
  tag. `ci.sh` passes `ALPINE_IMAGE` from `base_images.alpine` and fails closed
  when the entry is missing.
- **Base image values**: the SOT `base_images` entries (`alpine`, `buildkit`,
  `git`, `trivy`) are `mirror.gcr.io/...` references with the tag `latest`.
  They are not pinned to a digest. Docker Hub images are pulled through
  `mirror.gcr.io`; Dockerfiles carry no second fallback `FROM` path.
- **External images in compose files**: an image outside the `${LANCACHE_*}`
  first-party references has to equal a SOT `base_images` value
  (`CI-ERROR-CHECK-0014`).
- **Release builds** use the tag-scoped `build-tools` image and never a mutable
  `latest` of it (AG-CI-010).

## Exception: the project's own channels

The channels in SOT `release.channels` (`nightly`, `latest`) are mutable by
design. `docs/combined-release-and-checklist.md` owns their semantics.

## Changing a reference

- An image: change its SOT `base_images` entry and, for a `docker://` step, the
  literal value in the workflow. `ci.sh check all` fails a `docker://` step that
  is not a SOT `base_images` value.
- An action: change the tag in its `uses:` line; the action has to be listed in
  SOT `github_actions`.
- A tool download: the SOT `external_versions` entry names repository and asset;
  `ci.sh` resolves the version.

## Checks

CI runs these in `ci.sh check all` (job `checks` of `ci.yml`); locally they run
inside the `build-tools` container (AG-VAL-016):

```bash
bash .github/scripts/ci.sh check mutable-refs            # image references the SOT does not own
bash .github/scripts/ci.sh check action-node-versions    # action references and Node runtime
bash .github/scripts/ci.sh check stable-external-images  # compose images against SOT base_images
bash .github/scripts/ci.sh check version-drift           # external_versions consumers
```

## Drift and the build identity

CI 2.0 decides reuse the same way for every trigger (`docs/ci-2.0-architecture.md`
sections 6, 27 and 54): a target is rebuilt only when its build identity changed
and no accepted digest exists for it. The base image enters the identity as
`base_digest`. Every image build runs `apk update` and `apk upgrade`
(`ci.sh apk-setup`), so a build takes the current packages.

A run started by one of the events in SOT `build_admission.refresh_events`
(`workflow_dispatch`, `schedule`) compares the installed apk packages of each
accepted image with the APKINDEX of the image's own repositories. When the index
has a newer version, `ci.sh` writes a new `package_refresh` value for that pair
to the records under the `CI_REFRESH_REF` variable, the pair's identity changes
and the pair builds. Every other run reads the recorded value and resolves
nothing. The repository keeps no package version list. The planner run record
(`CI_RUN_IDENTITIES`) fixes every pair's identity for the rest of the run; an
unchanged identity reuses the accepted digest. Such a run has no base commit to
compare against, so the resolver alone decides: a pair with no accepted
artifact for its current identity is built, and a pair that has one is reused.

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
