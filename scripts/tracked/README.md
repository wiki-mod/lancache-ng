# scripts/tracked/

CI-tooling-only scripts (issue #1095 F-16): scripts individually verified to
have no service/product-code dependency at all. No CI 2.0 decision reads this
directory prefix; impact is decided by build identity in
`.github/scripts/ci.sh`, not by where a script lives.

Populated 2026-08-07 (post-v0.3.0-release "touch it, move it" scheme
finalized on 2026-07-31, execution deferred until after the release per an
explicit maintainer instruction -- see issue #1095's F-16 discussion). The
28 scripts here are exactly the ones PR #1341 individually verified and
allowlisted by name before this directory existed; git history preserves
that verification's provenance via `git mv`, not a fresh add.
