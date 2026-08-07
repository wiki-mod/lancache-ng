# scripts/tracked/

Destination directory for CI-tooling-only scripts (issue #1095 F-16, decided
2026-07-31). A script belongs here once it has been individually verified to
have no service/product-code dependency at all -- i.e. it is exactly the kind
of script currently enumerated by name in
`scripts/untracked/detect-full-setup-changes.sh`'s `ci_tooling_only_scripts` allowlist.

Any path under this directory is automatically recognized as CI-tooling-only
by that script's `should_run` logic (directory-prefix match), so once a
script moves here it no longer needs its own array entry.

**Empty for now, deliberately**: per an explicit maintainer instruction
("vor Release passiert nix" -- nothing happens before the release), the
actual migration of the 24 currently-allowlisted scripts (and the rest of
`scripts/`'s ~55 files generally) into this directory is deferred until
after the v0.3.0 release. See issue #1095's F-16 discussion for the full
migration methodology and the post-release "touch it, move it" policy that
governs how files land here incrementally.
