# scripts/untracked/

Destination directory for every `scripts/` file that is NOT CI-tooling-only
(issue #1095 F-16, decided 2026-07-31) -- simulation scripts, release/setup/
runtime utilities, and anything that itself decides or influences CI
behavior (e.g. `detect-full-setup-changes.sh`, `plan-deep-validation.sh`,
`classify-image-impact.sh`), which must keep triggering real validation when
touched rather than being exempted.

No special-case handling exists for this prefix in
`scripts/detect-full-setup-changes.sh` -- none is needed, since any path
here that isn't also matched by `scripts/tracked/` or the legacy allowlist
already falls through to should_run-relevant by default, exactly like an
unclassified script today. `scripts/lib/` is treated the same way (also not
tracked) and stays where it is, outside both directories.

**Empty for now, deliberately** -- see `scripts/tracked/README.md` for the
same "vor Release passiert nix" deferral; the actual file migration happens
after the v0.3.0 release.
