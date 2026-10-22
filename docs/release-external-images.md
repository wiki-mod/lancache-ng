# Release External Images and Provenance

This document records how lancache-ng handles container images that are not
built from this repository. It does not cover how a first-party release is
actually cut (channel promotion, patch tagging, platform support, rollback);
see [docs/release-versioning.md](release-versioning.md) for that process --
its own "External Images" section links back here for the per-image table
and provenance/SBOM handling below.

The source for every image name and pin below is the SOT
`.github/yaml/build-manifest.yml`; `.github/scripts/ci.sh` and
`.github/workflows/release.yml` read it. This document names the SOT keys
and does not copy their values.

## Policy

First-party images are stack release artifacts: every SOT `services` entry
(`dhcp`, `dns`, `proxy`, `services`, `ui`) and the `build_toolchain` target.

External images are third-party dependencies. They must be handled by the least
risky option that still supports the deployment profile:

1. pin by immutable digest
2. pin by version tag when digest pinning would make an example unusable
3. mirror into a controlled registry when upstream availability is part of the
   supported deployment promise
4. exclude from the supported profile when the image is only an optional helper

Mutable external tags are not authoritative release records.

## Current External Images

| SOT key | Role | Current policy |
| --- | --- | --- |
| `base_images.alpine` | Final base of every first-party image and of the build-tools image; `setup.sh` helper image | Digest-pinned |
| `base_images.buildkit` | BuildKit builder of the CI build step | Digest-pinned |

nginx, PowerDNS, NATS, syslog-ng, chrony, netdata, Kea and dnsmasq are apk
packages inside the first-party images (nginx from the nginx.org Alpine
repository), not separate external images; the per-image SBOM lists them.

Two `uses: docker://` steps in `.github/workflows/ci.yml` and
`.github/workflows/nightly.yml` must name the `base_images.alpine` value
literally, because a workflow `uses:` cannot read the SOT. `ci.sh check all`
fails any `docker://` step that is not a SOT `base_images` pin, and the
`stable-external-images` check fails any compose image outside the
`LANCACHE_*` first-party refs that is not digest-pinned or not a SOT
`base_images` pin (`CI-ERROR-CHECK-0014`).

## Provenance And SBOM Expectations

For first-party images, releases expose the currently available release
evidence and must not claim evidence that the pipeline does not produce yet.
The target evidence set is:

- image tag
- immutable digest
- source commit
- base image digest
- SBOM location
- provenance attestation location
- relevant bundled component versions

Current status:

- **Provenance** attestations are pushed to GHCR for every first-party image
  digest (see "Verifying Release Provenance" below).
- **SBOMs** are generated per released first-party image digest by the
  `release-sbom` job in `.github/workflows/release.yml` (`ci.sh
  release-sbom-stack`). That job runs on release tags, resolves each `vX.Y.Z`
  image reference to its immutable digest, runs Trivy in CycloneDX SBOM mode
  against that digest, and attaches the result to the GitHub release for the
  tag as a `<service>.cdx.json` asset. The covered set is every build target of
  the SOT (`services` plus `build_toolchain` in
  `.github/yaml/build-manifest.yml`).
- **VEX** (vulnerability disposition) for accepted findings is published as the
  `vex.openvex.json` release asset, regenerated fresh from the tag's own
  `.trivyignore.yaml` at release time — see "Vulnerability Disposition (VEX)"
  below.

A release re-run never replaces an attached asset: an SBOM or VEX asset that
is already attached must equal the one derived now, else the job fails; a
missing one is uploaded and read back. Re-running a tag's release workflow
therefore backfills SBOM and VEX assets for a release cut before this job
existed.

For mirrored or repackaged external images, the mirrored artifact must carry the
project's own provenance and SBOM for the mirrored digest.

For upstream external images that are not mirrored, release notes or deployment
metadata must record the approved upstream digest.

## Verifying Release Provenance

Every first-party image digest (every build target of the SOT) gets a
[GitHub Artifact Attestation](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds)
pushed to GHCR alongside it (the `release-provenance` job in
`.github/workflows/release.yml`, wrapping `actions/attest`; `ci.sh
release-images` names the digests). This attestation is a signed, Sigstore-backed statement that
cryptographically binds the exact image digest to the specific GitHub Actions
workflow run (repository, workflow file, and commit) that built it, and does
not depend on trusting GHCR itself as the source of truth.

An operator or downstream consumer can verify both **that a pulled image was
not tampered with** and **that it was actually built by this project's own
release pipeline** (not a third party who pushed to a similarly-named tag) with
the GitHub CLI:

```bash
# Resolve the tag to its immutable digest first (attestation verification is
# digest-based, not tag-based, since a mutable tag like `latest` is not itself
# a fixed subject). The "Images" block of the release notes lists every image
# of the release with its digest; the immutable `sha-<commit>` tag (full
# 40-hex commit) names the same digest for the release commit.
digest=$(docker inspect --format='{{index .RepoDigests 0}}' \
  ghcr.io/wiki-mod/lancache-ng/proxy:sha-<commit>)

# Verify the attestation: confirms the artifact's integrity (the signed digest
# matches what you pulled) and its authenticity (it was produced by a GitHub
# Actions workflow run in the wiki-mod/lancache-ng repository, not an
# unrelated identity).
gh attestation verify "oci://${digest}" --owner wiki-mod
```

A successful verification prints the workflow run, repository, and commit SHA
that produced the image -- this is the "expected identity of the person or
process authoring the release" for lancache-ng: a specific GitHub Actions
workflow run in this repository, not an individual's personal signing key.
Repeat the same two commands with any other first-party image name and its
`sha-<commit>` or `vX.Y.Z` tag (promotion moves `vX.Y.Z` for every image of
the release in one stack-atomic step) to verify that image instead. If `gh attestation verify`
reports no matching attestation, or reports a builder identity outside
`wiki-mod/lancache-ng`, treat the image as unverified and do not deploy it.

For mirrored or repackaged external images, the same command verifies this
project's own re-published attestation for the mirrored digest (see above);
verifying an unmirrored upstream image's own provenance is the responsibility
of that upstream project's own release process, not this document.

## Vulnerability Disposition (VEX)

Accepted, deliberately-suppressed vulnerability findings live in the repo-root
`.trivyignore.yaml` (each entry: the CVE id, the affected file paths, a
`statement` explaining why it is accepted. No exception expiry field is required
by Trivy, and the file is Trivy-specific rather than something a downstream
consumer's non-Trivy tooling can parse.

`ci.sh` (`_ci_generate_vex`) converts those entries into a standard
[OpenVEX](https://openvex.dev) v0.2.0 JSON document, `vex.openvex.json`. Each
entry becomes one OpenVEX statement. An entry without `status:` is an
accepted, tracked risk: status `affected` with an `action_statement` that
carries the acceptance rationale. An entry with `status: not_affected`
asserts non-exploitability: status `not_affected` with a `justification`
(default `vulnerable_code_not_present`, overridable per entry with one of
the OpenVEX justification values) and an `impact_statement`. The reader
accepts only the shape this file uses (`id`, `paths`, a `>-` folded
`statement`, `status`, `justification`); any other key, status or line
shape fails closed.

**`vex.openvex.json` is not committed to `current_dev`** (changed by Issue
#1095's F-22 finding; it was committed there through PR #1194, which produced
two real drift incidents where an edit to `.trivyignore.yaml` shipped without
its companion regeneration -- see that issue for the incident history). It is
entirely and deterministically derived from `.trivyignore.yaml`, so keeping a
second, independently-editable copy in the same branch only recreated the
exact class of bug it was meant to prevent. Instead:

- The OpenVEX document is a release artifact. Each release tag's own
  `vex.openvex.json` asset is regenerated fresh from that exact tag's own
  checked-out `.trivyignore.yaml` by the release path (`ci.sh release-vex`,
  invoked from `release.yml`), alongside the SBOM and provenance assets that
  belong to the release channel.
- `ci.sh check vex-drift` runs the generator on the checked-out
  `.trivyignore.yaml` and requires one statement per entry, failing a change
  that feeds it an unsupported shape, status or justification. No test
  covers the generator or this check (`ci.bats` holds no test).

This complements the Vulnerability Management Policy documentation in
`SECURITY.md` (refs #1130 / #1185).

## Retention

Do not delete digests that are referenced by a supported release, rollback
procedure, or published deployment document. Keep at least the current stable
release and two previous stable release digests for first-party images and any
mirrored external image they depend on.

A floating external reference cannot reach a channel: `ci.sh check all` runs
the `stable-external-images` check on every CI run, and promotion runs only
after a green run. Pin by digest in the SOT `base_images`, mirror, or remove
the external helper from the deployment profile.
