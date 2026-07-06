# Changelog

## Unreleased

- Fixed follow-up DHCP and quickstart installer findings from #476: quickstart
  installs now include the socket-proxy entrypoint, DHCP mode is persisted only
  after Docker reconciliation succeeds, and routed DNS option values may live
  outside the served subnet.
- Switched the Rust builder stages for `services/dns` and `services/ui` to the
  shared `ghcr.io/wiki-mod/lancache-ng/build-tools` image contract.
- Kept BuildKit secret wiring for `sccache` Redis, `sccache-dist`, and
  `distcc` host lists intact while removing local Rust builder tool bootstrap.
- Threaded the selected build-tools image through the build workflow so CI uses
  the same prebuilt builder contract as the Dockerfiles.
- Kept downstream Docker build jobs on a pullable GHCR build-tools image instead
  of exporting runner-local validation tags across jobs.
- Documented that subagent findings must be revalidated against the current
  GitHub head before they are used, and that local Rust builder checks only
  prove compile-farm behavior when the same BuildKit cache secrets are wired.
- Documented that readiness and mergeability statements require a fresh fetch,
  rebase onto the current remote base, and verified head before conclusions.
- Documented the GraphQL Markdown upload guard so PR/issue bodies cannot be
  accidentally written as JSON-escaped strings.
