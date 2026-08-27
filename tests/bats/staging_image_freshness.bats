#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free coverage for scripts/lib/staging-image-freshness.sh (#808): the
# shared "is this base-channel image actually built from a commit at or after
# this PR's base.sha" check used by both scripts/tracked/ensure-pr-staging-images.sh
# and build-push.yml's own "Ensure PR staging tags exist for full-setup
# services" step. sif_image_revision is stubbed via STAGING_IMAGE_REVISION_CMD
# (the same override-hook convention scripts/tracked/ensure-pr-staging-images.sh
# already uses for STAGING_IMAGE_EXISTS_CMD/STAGING_BACKFILL_CMD); the git
# ancestry check itself runs against a real, disposable git repo (via
# STAGING_FRESHNESS_GIT_DIR) with synthetic commits, so the actual
# `git merge-base --is-ancestor` logic is exercised for real rather than
# mocked away.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    lib="$repo_root/scripts/lib/staging-image-freshness.sh"
    # Issue #1095: staging-image-freshness.sh's own _sif_inspect now routes
    # its registry reads through ghcr_retry (scripts/lib/ghcr-retry.sh) --
    # must be sourced first so the real (non-stubbed) docker branch below
    # can find it, matching every other dual script/workflow-step caller's
    # own sourcing convention in this project.
    # shellcheck source=scripts/lib/ghcr-retry.sh
    source "$repo_root/scripts/lib/ghcr-retry.sh"
    # shellcheck source=scripts/lib/staging-image-freshness.sh
    source "$lib"

    # Three sequential commits in a disposable repo: c1 (oldest) -> c2 (the
    # PR's base.sha) -> c3 (a newer commit, standing in for "another PR
    # merged and its build already finished").
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m c1
    c1="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m c2
    c2="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m c3
    c3="$(git -C "$git_dir" rev-parse HEAD)"
    export STAGING_FRESHNESS_GIT_DIR="$git_dir"
}

revision_stub() {
    # Writes a stub that always echoes $1 as the "image revision", and
    # exports it as STAGING_IMAGE_REVISION_CMD.
    local revision="$1"
    stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$stub" <<STUB
#!/usr/bin/env bash
echo "$revision"
STUB
    chmod +x "$stub"
    export STAGING_IMAGE_REVISION_CMD="$stub"
}

missing_revision_stub() {
    # Simulates a tag that doesn't exist yet / a registry call that fails --
    # sif_image_revision must report failure, not an empty success.
    stub="$BATS_TEST_TMPDIR/missing.sh"
    cat > "$stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$stub"
    export STAGING_IMAGE_REVISION_CMD="$stub"
}

@test "sif_is_ancestor_or_equal: candidate equal to base is fresh" {
    run sif_is_ancestor_or_equal "$c2" "$c2"
    [ "$status" -eq 0 ]
}

@test "sif_is_ancestor_or_equal: candidate is a descendant of base is fresh" {
    run sif_is_ancestor_or_equal "$c2" "$c3"
    [ "$status" -eq 0 ]
}

@test "sif_is_ancestor_or_equal: candidate predates base is stale (status 1, not an error)" {
    run sif_is_ancestor_or_equal "$c2" "$c1"
    [ "$status" -eq 1 ]
}

@test "sif_is_ancestor_or_equal: base_sha itself absent from local history fails closed with status 2 (a real checkout/config bug)" {
    run sif_is_ancestor_or_equal "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$c2"
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" | grep -q "fetch-depth: 0"
}

@test "sif_is_ancestor_or_equal: candidate absent even after a recovery fetch returns status 3, distinct from a base_sha config error" {
    # The disposable repo has no 'origin' remote configured at all, so the
    # recovery `git fetch origin` inside sif_is_ancestor_or_equal fails
    # (tolerated via `|| true`) and the commit legitimately never resolves --
    # this proves status 3 (not 2) even when the recovery attempt itself
    # cannot succeed, and that the failure is tolerated gracefully rather
    # than aborting the whole check.
    run sif_is_ancestor_or_equal "$c2" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    [ "$status" -eq 3 ]
    printf '%s\n' "$output" | grep -q "recovery fetch"
}

@test "sif_is_ancestor_or_equal: a candidate that only exists on the remote (not yet fetched locally) is found via the recovery fetch" {
    # Simulates the real #808 race: another PR's promote landed a NEWER
    # commit on the base branch AFTER this job's own checkout ran. Builds a
    # real bare 'remote' + a clone taken before the new commit is pushed, then
    # proves sif_is_ancestor_or_equal's one recovery `git fetch origin`
    # (no refspec args, reusing whatever the checkout already configured)
    # actually pulls it in and correctly reports "fresh" -- not a false
    # config-error nor a false "still stale".
    remote="$BATS_TEST_TMPDIR/remote.git"
    src="$BATS_TEST_TMPDIR/src"
    clone="$BATS_TEST_TMPDIR/clone"
    git init -q --bare "$remote"
    git init -q "$src"
    git -C "$src" config user.email test@example.com
    git -C "$src" config user.name test
    git -C "$src" remote add origin "$remote"
    git -C "$src" commit -q --allow-empty -m base
    git -C "$src" push -q origin HEAD:refs/heads/main
    base_sha_remote="$(git -C "$src" rev-parse HEAD)"

    # Clone BEFORE the newer commit exists -- this is "this job's own
    # checkout", frozen at this point in time.
    git clone -q --origin origin "$remote" "$clone" 2>/dev/null || true

    # Another PR's merge+promote lands a newer commit on the remote AFTER
    # the clone above.
    git -C "$src" commit -q --allow-empty -m newer
    git -C "$src" push -q origin HEAD:refs/heads/main
    newer_sha="$(git -C "$src" rev-parse HEAD)"

    export STAGING_FRESHNESS_GIT_DIR="$clone"
    run sif_is_ancestor_or_equal "$base_sha_remote" "$newer_sha"
    [ "$status" -eq 0 ]
    # Restore the module-level default for any tests that run after this one
    # in the same bats process.
    export STAGING_FRESHNESS_GIT_DIR="$git_dir"
}

@test "sif_image_revision: missing label renders as <no value>, treated as unreadable" {
    stub="$BATS_TEST_TMPDIR/novalue.sh"
    cat > "$stub" <<'STUB'
#!/usr/bin/env bash
echo "<no value>"
STUB
    chmod +x "$stub"
    export STAGING_IMAGE_REVISION_CMD="$stub"
    run sif_image_revision "ghcr.io/x/dns:nightly"
    [ "$status" -ne 0 ]
}

@test "sif_wait_for_fresh_base_image: already-fresh image resolves on the first poll" {
    revision_stub "$c3"
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:nightly" "$c2" "dns" 900 5400 1
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "Safe to back-fill from"
}

@test "sif_wait_for_fresh_base_image: stdout carries ONLY the confirmed revision, never the ::notice:: log line" {
    # Both real call sites capture this function's output via
    # `$(...)`/`>/dev/null` to get just the revision -- if a log line ever
    # leaked onto stdout it would corrupt that capture (e.g. the caller's
    # `if ! sif_wait_for_fresh_base_image ... >/dev/null` would still work
    # since it only checks the exit status, but anything that captures the
    # revision value itself would break). `run` merges stdout+stderr into
    # `$output`, which would hide such a regression -- this test explicitly
    # separates the two streams instead.
    revision_stub "$c3"
    stdout_only="$(sif_wait_for_fresh_base_image "ghcr.io/x/dns:nightly" "$c2" "dns" 900 5400 1 2>/dev/null)"
    [ "$stdout_only" = "$c3" ]
}

@test "sif_wait_for_fresh_base_image: stale-then-fresh transition (simulates an in-flight promote) succeeds without hitting the ceiling" {
    # Counter-backed stub: stale for the first two probes, then fresh --
    # proves the loop actually re-polls instead of giving up on the first
    # stale read, and that the ceiling is not needed once it catches up.
    counter="$BATS_TEST_TMPDIR/calls"
    : > "$counter"
    stub="$BATS_TEST_TMPDIR/transition.sh"
    cat > "$stub" <<STUB
#!/usr/bin/env bash
calls=\$(wc -l < "$counter")
printf 'x\n' >> "$counter"
if [ "\$calls" -ge 2 ]; then
  echo "$c3"
else
  echo "$c1"
fi
STUB
    chmod +x "$stub"
    export STAGING_IMAGE_REVISION_CMD="$stub"
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:nightly" "$c2" "dns" 900 5400 1
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "predates base commit"
    printf '%s\n' "$output" | grep -q "Safe to back-fill from"
}

@test "sif_wait_for_fresh_base_image: permanently stale fails closed at the hard ceiling" {
    revision_stub "$c1"
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:nightly" "$c2" "dns" 1 2 1
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -q "never became fresh enough"
    printf '%s\n' "$output" | grep -q "#808"
}

@test "sif_wait_for_fresh_base_image: a channel tag that never existed at all also fails closed at the ceiling, not fast" {
    # Judgment call documented in the library's own header: this is
    # deliberately NOT a fast-fail-on-first-miss case (unlike a git-history
    # error) -- a brand-new branch's channel tag might appear moments later,
    # so it gets the same bounded wait as ordinary staleness.
    missing_revision_stub
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:dev" "$c2" "dns" 1 2 1
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -q "no readable org.opencontainers.image.revision label"
}

@test "sif_wait_for_fresh_base_image: BASE_SHA itself missing from local history fails immediately, not at the ceiling" {
    # An invalid/unresolvable BASE_SHA (not the candidate) is the real
    # checkout/config-bug case (sif_is_ancestor_or_equal status 2) -- this
    # simulates a shallow checkout (missing fetch-depth: 0) that never had
    # this PR's own base commit at all. Must fail fast and must not idle out
    # a generous ceiling waiting for something that structurally cannot
    # resolve.
    revision_stub "$c3"
    start_epoch="$(date +%s)"
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:nightly" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "dns" 1 100 1
    end_epoch="$(date +%s)"
    [ "$status" -eq 2 ]
    printf '%s\n' "$output" | grep -q "configuration bug, not staleness"
    [ "$((end_epoch - start_epoch))" -lt 10 ]
}

@test "sif_wait_for_fresh_base_image: a candidate commit that never resolves (even after recovery fetches) is bounded staleness, not a hard failure" {
    # deadbeef... as the CANDIDATE (base_sha is valid) is status 3 from
    # sif_is_ancestor_or_equal, not status 2 -- this must behave like
    # ordinary staleness (poll to the hard ceiling, then fail with the
    # regular #808 message), NOT like the BASE_SHA-missing config-error case
    # above. Proves the two are not conflated in the wait loop.
    revision_stub "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:nightly" "$c2" "dns" 1 2 1
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -q "never became fresh enough"
    printf '%s\n' "$output" | grep -q "recovery fetch"
}

@test "sif_wait_for_fresh_base_image: without allow_reverse_ancestry, a label predating base_sha still fails closed at the ceiling (default behavior unchanged)" {
    # c1 predates c2 -- the retag-reuse scenario -- but the 7th parameter is
    # omitted here, so this must behave exactly like it did before that
    # parameter existed: a mutable-channel-tag caller (the only kind that
    # existed before this parameter was added) must never silently start
    # accepting reverse ancestry just because this feature now exists.
    revision_stub "$c1"
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:nightly" "$c2" "dns" 1 2 1
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -q "never became fresh enough"
}

@test "sif_wait_for_fresh_base_image: allow_reverse_ancestry=true accepts a label that predates base_sha (the Schritt 4 retag signature)" {
    # c1 predates c2: simulates a per-commit sha-<c2> tag whose label still
    # reads c1 because build-push.yml's Schritt 4 retagged an unchanged
    # image forward instead of rebuilding. Must resolve immediately, not
    # wait out the ceiling.
    revision_stub "$c1"
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:sha-abc1234" "$c2" "dns" 1 2 1 true
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "PREDATES base commit"
    printf '%s\n' "$output" | grep -q "Safe to back-fill from"
}

@test "sif_wait_for_fresh_base_image: allow_reverse_ancestry=true still fails closed when the label is on a diverged, unrelated commit" {
    # A label that is NEITHER an ancestor nor a descendant of base_sha (a
    # genuinely diverged/unrelated commit, not a legitimate retag) must
    # still fail closed even with the flag on -- reverse ancestry only
    # covers "predates", never "unrelated".
    git -C "$git_dir" checkout -q "$c1"
    git -C "$git_dir" commit -q --allow-empty -m diverged
    diverged="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" checkout -q "$c3"

    revision_stub "$diverged"
    run sif_wait_for_fresh_base_image "ghcr.io/x/dns:sha-abc1234" "$c2" "dns" 1 2 1 true
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -q "never became fresh enough"
}

# --- Real docker-inspect-error-classification coverage (2026-08-06) --------
#
# Every test above drives sif_image_revision through its
# STAGING_IMAGE_REVISION_CMD stub hook, which never goes anywhere near the
# real `docker buildx imagetools inspect`/_sif_inspect code path this fix
# actually changed -- a regression in the real branch would pass every test
# above unnoticed. These tests instead put a FAKE `docker` executable ahead
# of the real one on PATH (no real registry, no real docker daemon -- this
# project's own "no local Windows testing" rule and AG-CI-001's "assume no
# tools" both still hold; only a disposable shell script is exercised) so
# _sif_inspect's own `docker buildx imagetools inspect ... 2>"$err_file"`
# invocation and _sif_inspect_failure_is_confirmed_absence's classification
# of that captured stderr both run for real.
fake_docker_returning_stderr() {
    # Writes a fake `docker` that fails `buildx imagetools inspect` with the
    # given stderr text, and prepends its directory to PATH (kept exported,
    # since PATH already carries the export attribute in this shell, so the
    # reassignment below is visible to the `docker` lookup any later command
    # substitution inside sif_image_revision/_sif_inspect performs).
    local stderr_text="$1"
    local fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    cat > "$fake_bin_dir/docker" <<STUB
#!/usr/bin/env bash
echo "$stderr_text" >&2
exit 1
STUB
    chmod +x "$fake_bin_dir/docker"
    PATH="$fake_bin_dir:$PATH"
}

@test "_sif_inspect_failure_is_confirmed_absence: classifies known absence-signature text" {
    run _sif_inspect_failure_is_confirmed_absence "Error response from daemon: manifest unknown"
    [ "$status" -eq 0 ]
    run _sif_inspect_failure_is_confirmed_absence "ghcr.io/wiki-mod/lancache-ng/build-tools:sha-d2399ee: no such manifest"
    [ "$status" -eq 0 ]
    run _sif_inspect_failure_is_confirmed_absence "NAME_UNKNOWN: repository name not known to registry"
    [ "$status" -eq 0 ]
}

# Issue #1581: the three signatures above are the distribution-spec wording
# this classifier originally assumed; real `docker buildx imagetools
# inspect` against GHCR for a genuinely missing tag does not actually emit
# any of them. Verified live (2026-08-15) against two real buildx builds
# (local v0.36.0, runner host lancache-243's v0.35.0): both print exactly
# this text for a nonexistent tag. Without this case, PR #1532's own
# incident (a brand-new PR staging tag always being absent at the moment
# wait_for_touched_image() starts polling, misclassified as an unconfirmed
# error and failing the wait almost immediately) would regress silently.
@test "_sif_inspect_failure_is_confirmed_absence: classifies buildx's real GHCR \"ERROR: <ref>: not found\" wording as absence" {
    run _sif_inspect_failure_is_confirmed_absence "ERROR: ghcr.io/wiki-mod/lancache-ng/proxy:pr-1532-sha-4c308b3: not found"
    [ "$status" -eq 0 ]
}

@test "_sif_inspect_failure_is_confirmed_absence: does NOT classify a network/timeout-shaped error as absence" {
    run _sif_inspect_failure_is_confirmed_absence "failed to do request: Head https://ghcr.io/v2/...: context deadline exceeded"
    [ "$status" -eq 1 ]
    run _sif_inspect_failure_is_confirmed_absence "dial tcp: lookup ghcr.io: connection refused"
    [ "$status" -eq 1 ]
    run _sif_inspect_failure_is_confirmed_absence "unexpected status from HEAD request: 500 Internal Server Error"
    [ "$status" -eq 1 ]
}

# Issue #1581: the new `^ERROR:.*: not found$` alternative must stay
# anchored to buildx's own line shape, not swallow every "ERROR: ..." line
# buildx can produce. Both lines below are real, live-reproduced
# (2026-08-15, against ghcr.io) buildx error text from an auth failure and a
# DNS failure respectively -- neither ends in ": not found", so neither must
# match.
@test "_sif_inspect_failure_is_confirmed_absence: does NOT classify a real buildx auth/DNS ERROR line as absence" {
    run _sif_inspect_failure_is_confirmed_absence "ERROR: failed to authorize: failed to fetch anonymous token: unexpected status from GET request to https://ghcr.io/token?scope=repository%3Awiki-mod%2Flancache-ng%2Ftotally-nonexistent-service-xyz%3Apull&service=ghcr.io: 403 Forbidden"
    [ "$status" -eq 1 ]
    run _sif_inspect_failure_is_confirmed_absence 'ERROR: failed to do request: Head "https://ghcr.invalid-host-xyz-does-not-exist.example/v2/foo/manifests/bar": dial tcp: lookup ghcr.invalid-host-xyz-does-not-exist.example: no such host'
    [ "$status" -eq 1 ]
}

@test "_sif_inspect_failure_is_confirmed_absence: does NOT classify a missing-docker-binary shell error as absence (AG-CI-001)" {
    # A bare "not found" would also match "docker: command not found" / "bash:
    # docker: command not found" -- exactly what a bare `lancache-light`
    # runner without docker on PATH produces (scripts/tracked/ensure-pr-staging-images.sh,
    # one of this file's two real callers, runs there directly, not inside the
    # pinned build-tools image). Misclassifying that as a confirmed registry
    # absence would report the registry as having confirmed something it was
    # never even asked -- worse than the original ambiguous wording.
    run _sif_inspect_failure_is_confirmed_absence "bash: docker: command not found"
    [ "$status" -eq 1 ]
    run _sif_inspect_failure_is_confirmed_absence "docker: command not found"
    [ "$status" -eq 1 ]
}

@test "sif_image_revision (real docker branch, no stub): a confirmed-absence registry error returns status 2" {
    fake_docker_returning_stderr "Error response from daemon: manifest unknown"
    # Direct `$(... 2>/dev/null)` capture, not bats' `run` (which merges
    # stdout+stderr into $output): issue #1095's ghcr_retry wrapping means a
    # genuine failure path now legitimately logs its own ::warning::/::error::
    # diagnostics to real stderr (this project's normal, desired CI-log
    # visibility for every other ghcr_retry call site) -- `run` would fold
    # that into $output and corrupt this exact stdout-must-be-empty check.
    # Same reasoning tests/bats/push_reuse.bats' own stderr-diagnostics
    # comment documents for the identical situation. `|| status=$?`, not a
    # bare assignment statement: bats fails a test immediately on any
    # non-zero exit inside its body unless the failure is absorbed by a
    # conditional first -- sif_image_revision genuinely returns non-zero
    # here (unlike push_reuse_decide, which always returns 0 by contract),
    # so the bare form would abort the test before these assertions run.
    status=0
    result="$(sif_image_revision "ghcr.io/wiki-mod/lancache-ng/build-tools:sha-d2399ee" 2>/dev/null)" || status=$?
    [ "$status" -eq 2 ]
    [ -z "$result" ]
}

@test "sif_image_revision (real docker branch, no stub): buildx's real GHCR \"not found\" wording returns status 2 (Issue #1581)" {
    # Same end-to-end shape as the confirmed-absence test above, but with the
    # literal wording buildx actually emits (verified live, see Issue #1581)
    # instead of the distribution-spec wording the classifier originally
    # assumed -- this is the exact case that made every touched-service
    # staging-image wait fail almost immediately, since a brand-new PR tag is
    # always missing at the moment the wait starts polling.
    fake_docker_returning_stderr "ERROR: ghcr.io/wiki-mod/lancache-ng/proxy:pr-1532-sha-4c308b3: not found"
    status=0
    result="$(sif_image_revision "ghcr.io/wiki-mod/lancache-ng/proxy:pr-1532-sha-4c308b3" 2>/dev/null)" || status=$?
    [ "$status" -eq 2 ]
    [ -z "$result" ]
}

@test "sif_image_revision (real docker branch, no stub): an unrecognized/transient registry error returns status 1 (unchanged ambiguous case)" {
    fake_docker_returning_stderr "failed to do request: Head https://ghcr.io/v2/...: context deadline exceeded"
    # Issue #1095: sif_image_revision's registry reads now go through
    # ghcr_retry, which defaults to 4 attempts/30s backoff -- a caller-less
    # direct call like this one (unlike sif_wait_for_fresh_base_image, which
    # scopes this down itself) would otherwise genuinely wait up to 90s here
    # for a fake docker that fails identically every attempt. This test is
    # about the final classification (still 1, ambiguous), not about
    # exercising the real retry budget (covered separately by
    # tests/bats/ghcr_retry.bats), so pin a single fast attempt --
    # tests/bats/ghcr_retry.bats' own convention for the same reason.
    # shellcheck disable=SC2034 # read by ghcr_retry() in scripts/lib/ghcr-retry.sh,
    # a cross-file dynamic-scope read shellcheck cannot see.
    GHCR_RETRY_MAX_ATTEMPTS=1
    # Direct capture, not `run` -- see the confirmed-absence test above for
    # both why (ghcr_retry's own real-stderr diagnostics would otherwise
    # corrupt this stdout-must-be-empty check) and why `|| status=$?`
    # specifically (a bare assignment would abort the test on the genuine
    # non-zero exit before these assertions run).
    status=0
    result="$(sif_image_revision "ghcr.io/wiki-mod/lancache-ng/build-tools:sha-d2399ee" 2>/dev/null)" || status=$?
    [ "$status" -eq 1 ]
    [ -z "$result" ]
}

# Issue #1095: a fake `docker` that SUCCEEDS with a real multi-platform index
# on --raw, then echoes a fixed revision label on --format, logging every
# invocation's own argv so the test can assert exactly which image
# reference the second (--format) call targeted.
fake_docker_multi_platform_success() {
    local fake_bin_dir="$BATS_TEST_TMPDIR/fakebin_success"
    mkdir -p "$fake_bin_dir"
    call_log="$BATS_TEST_TMPDIR/docker_calls.log"
    : > "$call_log"
    cat > "$fake_bin_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$call_log"
if [[ "\$*" == *"--raw"* ]]; then
  cat <<'JSON'
{"manifests":[{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","platform":{"architecture":"amd64","os":"linux"}},{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","platform":{"architecture":"arm64","os":"linux"}}]}
JSON
  exit 0
elif [[ "\$*" == *"--format"* ]]; then
  printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
  exit 0
fi
exit 1
STUB
    chmod +x "$fake_bin_dir/docker"
    PATH="$fake_bin_dir:$PATH"
}

@test "sif_image_revision (real docker branch): a digest-ref input (repo@sha256:...) resolves its multi-platform child correctly, not truncated mid-digest" {
    # Issue #1095's digest-pinning fix passes sif_image_revision a caller-
    # resolved repo@sha256:... reference (not only a mutable tag), so it can
    # verify safety against, and export, the exact same immutable digest.
    # The ORIGINAL "${image%:*}@digest" strip is only correct for a tag-ref
    # input -- for a digest-ref input, the colon inside "sha256:..." itself
    # would be misidentified as a tag separator, truncating the reference
    # mid-digest ("repo@sha256@childdigest" instead of "repo@childdigest").
    # This proves the fix by inspecting which reference the second
    # (--format) call actually targeted, not just that SOME call succeeded.
    fake_docker_multi_platform_success
    run sif_image_revision "ghcr.io/wiki-mod/lancache-ng/ntp@sha256:pinnedpinnedpinnedpinnedpinnedpinnedpinnedpinnedpinnedpinnedpinn"
    [ "$status" -eq 0 ]
    [ "$output" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
    grep -qF 'ghcr.io/wiki-mod/lancache-ng/ntp@sha256:1111111111111111111111111111111111111111111111111111111111111111' "$call_log"
    # Negative check: the truncated/malformed shape a regression would
    # produce must NOT appear anywhere in the logged calls.
    ! grep -qF '@sha256@sha256:' "$call_log"
}

@test "sif_image_revision (real docker branch): a plain tag-ref input still resolves its multi-platform child correctly (no regression)" {
    fake_docker_multi_platform_success
    run sif_image_revision "ghcr.io/wiki-mod/lancache-ng/ntp:nightly"
    [ "$status" -eq 0 ]
    [ "$output" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]
    grep -qF 'ghcr.io/wiki-mod/lancache-ng/ntp@sha256:1111111111111111111111111111111111111111111111111111111111111111' "$call_log"
}

@test "sif_wait_for_fresh_base_image (real docker branch): a confirmed-absence failure is reported as confirmed absent, not the old ambiguous wording" {
    fake_docker_returning_stderr "Error response from daemon: manifest unknown"
    run sif_wait_for_fresh_base_image "ghcr.io/wiki-mod/lancache-ng/build-tools:sha-d2399ee" "$c2" "build-tools" 1 2 1
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -q "confirmed absent"
    # Must NOT print the old both-cases-conflated wording alongside the new
    # one -- proves the branch was actually replaced, not merely appended to.
    ! printf '%s\n' "$output" | grep -q "or the registry call failed transiently"
}

@test "sif_wait_for_fresh_base_image (real docker branch): a transient-shaped failure is reported as a registry call failure, not confirmed absent" {
    fake_docker_returning_stderr "dial tcp: lookup ghcr.io: connection refused"
    run sif_wait_for_fresh_base_image "ghcr.io/wiki-mod/lancache-ng/build-tools:sha-d2399ee" "$c2" "build-tools" 1 2 1
    [ "$status" -eq 1 ]
    printf '%s\n' "$output" | grep -q "the registry call itself failed"
    ! printf '%s\n' "$output" | grep -q "confirmed absent"
}
