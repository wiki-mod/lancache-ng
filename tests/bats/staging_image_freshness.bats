#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free coverage for scripts/lib/staging-image-freshness.sh (#808): the
# shared "is this base-channel image actually built from a commit at or after
# this PR's base.sha" check used by both scripts/ensure-pr-staging-images.sh
# and build-push.yml's own "Ensure PR staging tags exist for full-setup
# services" step. sif_image_revision is stubbed via STAGING_IMAGE_REVISION_CMD
# (the same override-hook convention scripts/ensure-pr-staging-images.sh
# already uses for STAGING_IMAGE_EXISTS_CMD/STAGING_BACKFILL_CMD); the git
# ancestry check itself runs against a real, disposable git repo (via
# STAGING_FRESHNESS_GIT_DIR) with synthetic commits, so the actual
# `git merge-base --is-ancestor` logic is exercised for real rather than
# mocked away.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    lib="$repo_root/scripts/lib/staging-image-freshness.sh"
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
