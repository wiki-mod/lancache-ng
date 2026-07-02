# Changelog

## Unreleased

- Switched the Rust builder stages for `services/dns` and `services/ui` to the
  shared `ghcr.io/wiki-mod/lancache-ng/build-tools` image contract.
- Kept BuildKit secret wiring for `sccache` Redis, `sccache-dist`, and
  `distcc` host lists intact while removing local Rust builder tool bootstrap.
- Threaded the selected build-tools image through the build workflow so CI uses
  the same prebuilt builder contract as the Dockerfiles.
