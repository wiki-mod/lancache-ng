#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free coverage for scripts/ensure-pr-staging-images.sh (#715) -- the
# fail-closed staging guard + untouched-service back-fill that reuses the
# #626/#627 pr-<N>-sha-<short> mechanism. The registry probe and the
# imagetools back-fill are stubbed via STAGING_IMAGE_EXISTS_CMD /
# STAGING_BACKFILL_CMD so the touched-vs-untouched decision and the
# fail-closed behaviour are exercised without a real daemon or registry. This
# is the safety property that keeps the deep gate from ever silently
# validating stale base-channel content behind a PR-looking tag.
#
# #895 congestion-probe coverage: the tests below stub
# STAGING_BUILD_RUN_STATUS_CMD (build_push_run_active()'s indirection) the
# same way the tests above stub the registry probe, so the extend-past-
# baseline / fail-fast-when-confirmed-dead / hard-ceiling behavior is
# exercised without a real `gh` CLI, network access, or a real build-push
# run. The default setup() below deliberately leaves BUILD_SHA unset, which
# proves the pre-#895 tests still get the original fail-at-baseline
# behavior unchanged (build_push_run_active() short-circuits on an empty
# BUILD_SHA without needing `gh` to be installed at all).
#
# #975 congestion-probe SHA-key coverage: the #895 tests above all stub
# STAGING_BUILD_RUN_STATUS_CMD, which bypasses build_push_run_active()'s real
# `gh api` query entirely -- exactly why the #975 bug (querying by BUILD_SHA,
# the synthetic merge commit, instead of PR_HEAD_SHA, the PR's real branch
# head that the Actions API's `head_sha` field actually means) shipped
# untested. The tests further down instead leave STAGING_BUILD_RUN_STATUS_CMD
# unset and put a fake `gh` executable on PATH, so the real query construction
# is exercised and would fail against the pre-#975 implementation.
#
# #808 base-channel freshness coverage: every real backfill now first calls
# scripts/lib/staging-image-freshness.sh's sif_wait_for_fresh_base_image().
# The default setup() below makes that check pass immediately for every
# pre-#808 test (a disposable one-commit git repo, BASE_SHA set to that
# commit, and a revision stub that always echoes it back -- "equal" is
# "fresh") so their existing touched/untouched back-fill-count assertions
# stay meaningful without being coupled to the freshness mechanism itself.
# Dedicated staleness/failure coverage for that mechanism lives in
# staging_image_freshness.bats; the tests further down in THIS file only add
# the integration point (a stale base image blocks the back-fill here too).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    script="$repo_root/scripts/ensure-pr-staging-images.sh"
    backfill_log="$BATS_TEST_TMPDIR/backfill.log"
    : > "$backfill_log"

    # Registry-probe stub: an image "exists" iff its ref appears in the
    # newline-separated EXISTING_IMAGES env. Written as a tiny inline script.
    exists_stub="$BATS_TEST_TMPDIR/exists.sh"
    cat > "$exists_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${EXISTING_IMAGES:-}" | grep -qxF "$1"
STUB
    chmod +x "$exists_stub"

    # Back-fill stub: just records "pr_image<TAB>base_image" so the test can
    # assert which services were back-filled from the base channel.
    backfill_stub="$BATS_TEST_TMPDIR/backfill.sh"
    cat > "$backfill_stub" <<STUB
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$backfill_log"
STUB
    chmod +x "$backfill_stub"

    # #808: disposable two-commit repo (older_sha -> base_sha) + a revision
    # stub that always echoes base_sha back, so sif_is_ancestor_or_equal sees
    # "candidate == base" (fresh) for every test that doesn't override it
    # below. older_sha exists so staleness tests have a real, genuinely
    # older commit to report instead of needing to fabricate one.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m older
    older_sha="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m base
    base_sha="$(git -C "$git_dir" rev-parse HEAD)"
    revision_stub="$BATS_TEST_TMPDIR/revision.sh"
    cat > "$revision_stub" <<STUB
#!/usr/bin/env bash
echo "$base_sha"
STUB
    chmod +x "$revision_stub"

    export STAGING_IMAGE_EXISTS_CMD="$exists_stub"
    export STAGING_BACKFILL_CMD="$backfill_stub"
    export STAGING_IMAGE_REVISION_CMD="$revision_stub"
    export STAGING_FRESHNESS_GIT_DIR="$git_dir"
    export BASE_SHA="$base_sha"
    # Keep the fail path fast: no real waiting in tests.
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_INTERVAL_SECONDS=0
    export BASE_FRESHNESS_POLL_TIMEOUT_SECONDS=0
    export BASE_FRESHNESS_POLL_HARD_CEILING_SECONDS=0
    export BASE_FRESHNESS_POLL_INTERVAL_SECONDS=0
    export REPOSITORY="wiki-mod/lancache-ng"
    export PR_TAG="pr-715-sha-abcdef0"
    export BASE_CHANNEL_TAG="edge"
}

@test "untouched services are all back-filled from the base channel" {
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # All five full-setup services get a base-channel back-fill.
    [ "$(wc -l < "$backfill_log")" -eq 5 ]
    grep -qF "ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0	ghcr.io/wiki-mod/lancache-ng/proxy:edge" "$backfill_log"
}

@test "a touched service already present passes without a back-fill" {
    export EXISTING_IMAGES="ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0"
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # proxy was touched+present (no back-fill); the other four are back-filled.
    [ "$(wc -l < "$backfill_log")" -eq 4 ]
    ! grep -qF "proxy:pr-715-sha-abcdef0" "$backfill_log"
}

@test "fail-closed: a touched service whose staging tag never appears aborts" {
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "never appeared"
}

@test "workflow change forces every service but build-tools to be treated as touched" {
    # build-tools present (its narrower scoping keeps it touched only if built);
    # proxy/dns/watchdog/ui are forced-touched by the workflow change but none
    # exist -> must fail closed on the first one.
    export EXISTING_IMAGES="ghcr.io/wiki-mod/lancache-ng/build-tools:pr-715-sha-abcdef0"
    export WORKFLOW_CHANGED="true"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "never appeared"
}

@test "workflow change: build-tools untouched is still back-filled, not required" {
    # Every forced-touched service present; build-tools untouched -> back-fill.
    # Declared and exported separately (SC2155): combining them would mask a
    # real failure exit status from the command substitution behind the
    # export builtin's own (always-successful-here) return value.
    EXISTING_IMAGES="$(printf '%s\n' \
        ghcr.io/wiki-mod/lancache-ng/proxy:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/dns:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/watchdog:pr-715-sha-abcdef0 \
        ghcr.io/wiki-mod/lancache-ng/ui:pr-715-sha-abcdef0)"
    export EXISTING_IMAGES
    export WORKFLOW_CHANGED="true"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    # Only build-tools is back-filled.
    [ "$(wc -l < "$backfill_log")" -eq 1 ]
    grep -qF "build-tools:pr-715-sha-abcdef0" "$backfill_log"
}

@test "#895: past the normal budget, a still-active build-push run extends the wait until the tag appears" {
    # A counter-backed exists stub: the tag is "missing" for the first two
    # probes, then "appears" -- simulating a slow-but-healthy build finishing
    # while the congestion probe reports build-push's run as still active.
    # Proves the extension is real (the script keeps polling instead of
    # failing at the normal budget), not just a no-op past baseline.
    counter_file="$BATS_TEST_TMPDIR/exists_calls"
    : > "$counter_file"
    exists_slow_stub="$BATS_TEST_TMPDIR/exists_slow.sh"
    cat > "$exists_slow_stub" <<STUB
#!/usr/bin/env bash
calls=\$(wc -l < "$counter_file")
printf 'x\n' >> "$counter_file"
[ "\$calls" -ge 2 ]
STUB
    chmod +x "$exists_slow_stub"

    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"

    export STAGING_IMAGE_EXISTS_CMD="$exists_slow_stub"
    export STAGING_BUILD_RUN_STATUS_CMD="$active_stub"
    export BUILD_SHA="deadbeef0123"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=5
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "extending the wait"
    printf '%s\n' "$output" | grep -q "staging image is present"
}

@test "#895: a confirmed-finished build-push run fails immediately instead of waiting for the hard ceiling" {
    # The hard ceiling is set generously large (100s); a passing test that
    # completes quickly proves the script did NOT idle out that ceiling once
    # the congestion probe confirmed build-push's run already finished.
    inactive_stub="$BATS_TEST_TMPDIR/inactive.sh"
    cat > "$inactive_stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$inactive_stub"

    export STAGING_BUILD_RUN_STATUS_CMD="$inactive_stub"
    export BUILD_SHA="deadbeef0123"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=100
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"

    start_epoch="$(date +%s)"
    run bash "$script"
    end_epoch="$(date +%s)"

    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "already finished"
    printf '%s\n' "$output" | grep -q "never appeared"
    # Must not have waited anywhere near the 100s hard ceiling.
    [ "$((end_epoch - start_epoch))" -lt 10 ]
}

@test "#895: the hard ceiling still fails closed even while the congestion probe keeps reporting an active run" {
    # Proves the extension is bounded: even a build-push run that never stops
    # reporting "active" must not be allowed to wait forever.
    active_stub="$BATS_TEST_TMPDIR/active.sh"
    cat > "$active_stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$active_stub"

    export STAGING_BUILD_RUN_STATUS_CMD="$active_stub"
    export BUILD_SHA="deadbeef0123"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=1
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "hard 1s ceiling"
}

# Fake `gh` used by the #975 tests below: emulates `gh api <url> --jq <expr>`
# by logging the requested URL (so a test can assert exactly which SHA was
# queried) and rendering a per-head_sha JSON fixture through the real `jq`
# binary, the same way the real `gh api --jq` flag renders its response.
# Returns an empty workflow_runs list for any head_sha with no fixture file,
# mirroring what the real API returns for a SHA it has never seen.
install_fake_gh() {
    fake_bin_dir="$BATS_TEST_TMPDIR/fakebin"
    mkdir -p "$fake_bin_dir"
    fake_gh_call_log="$BATS_TEST_TMPDIR/gh_calls.log"
    : > "$fake_gh_call_log"
    fake_gh_runs_dir="$BATS_TEST_TMPDIR/gh_runs_fixtures"
    mkdir -p "$fake_gh_runs_dir"
    cat > "$fake_bin_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "api" ]]; then
    exit 1
fi
url="$2"
shift 2
jq_expr=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jq) jq_expr="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >> "$GH_FAKE_CALL_LOG"
head_sha="${url#*head_sha=}"
head_sha="${head_sha%%&*}"
fixture="$GH_FAKE_RUNS_DIR/$head_sha.json"
if [[ -f "$fixture" ]]; then
    jq -r "$jq_expr" "$fixture"
else
    printf '{"workflow_runs":[]}' | jq -r "$jq_expr"
fi
STUB
    chmod +x "$fake_bin_dir/gh"
    export PATH="$fake_bin_dir:$PATH"
    export GH_FAKE_CALL_LOG="$fake_gh_call_log"
    export GH_FAKE_RUNS_DIR="$fake_gh_runs_dir"
}

@test "#975: the congestion probe queries build-push runs by the PR's real head SHA, checking every returned run" {
    install_fake_gh
    real_head_sha="realhead1234567890"
    merge_sha="mergecommit0987654321"

    # The NEWEST run (workflow_runs[0], as the real API returns it) is already
    # completed, but an OLDER run for the same head_sha is still in_progress.
    # A query keyed on the wrong SHA (the pre-#975 bug) would never find this
    # fixture at all; a fix that only inspected workflow_runs[0] would still
    # wrongly report "not active" and fail this test.
    cat > "$fake_gh_runs_dir/$real_head_sha.json" <<JSON
{"workflow_runs":[{"status":"completed"},{"status":"in_progress"}]}
JSON

    counter_file="$BATS_TEST_TMPDIR/exists_calls"
    : > "$counter_file"
    exists_slow_stub="$BATS_TEST_TMPDIR/exists_slow.sh"
    cat > "$exists_slow_stub" <<STUB
#!/usr/bin/env bash
calls=\$(wc -l < "$counter_file")
printf 'x\n' >> "$counter_file"
[ "\$calls" -ge 2 ]
STUB
    chmod +x "$exists_slow_stub"

    unset STAGING_BUILD_RUN_STATUS_CMD
    export STAGING_IMAGE_EXISTS_CMD="$exists_slow_stub"
    export BUILD_SHA="$merge_sha"
    export PR_HEAD_SHA="$real_head_sha"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=5
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "extending the wait"
    printf '%s\n' "$output" | grep -q "staging image is present"
    # The query used PR_HEAD_SHA, never the merge-commit BUILD_SHA.
    grep -qF "head_sha=$real_head_sha" "$fake_gh_call_log"
    ! grep -qF "head_sha=$merge_sha" "$fake_gh_call_log"
}

@test "#975: a head_sha with only completed runs is correctly reported as not active" {
    install_fake_gh
    real_head_sha="realhead1234567890"
    cat > "$fake_gh_runs_dir/$real_head_sha.json" <<JSON
{"workflow_runs":[{"status":"completed"},{"status":"completed"}]}
JSON

    unset STAGING_BUILD_RUN_STATUS_CMD
    export BUILD_SHA="mergecommit0987654321"
    export PR_HEAD_SHA="$real_head_sha"
    export STAGING_POLL_TIMEOUT_SECONDS=0
    export STAGING_POLL_HARD_CEILING_SECONDS=100
    export STAGING_POLL_CONGESTION_CHECK_INTERVAL_SECONDS=0
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="true" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"

    start_epoch="$(date +%s)"
    run bash "$script"
    end_epoch="$(date +%s)"

    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "already finished"
    printf '%s\n' "$output" | grep -q "never appeared"
    [ "$((end_epoch - start_epoch))" -lt 10 ]
}

@test "#808: an untouched service is NOT back-filled from a base-channel image that is stale relative to BASE_SHA" {
    # Overrides setup()'s default "always fresh" revision stub with one that
    # always reports older_sha -- a real commit that predates BASE_SHA
    # (base_sha) in the disposable repo's own history. Proves the freshness
    # gate actually blocks the back-fill end-to-end, not just in isolation.
    stale_stub="$BATS_TEST_TMPDIR/stale_revision.sh"
    cat > "$stale_stub" <<STUB
#!/usr/bin/env bash
echo "$older_sha"
STUB
    chmod +x "$stale_stub"
    export STAGING_IMAGE_REVISION_CMD="$stale_stub"

    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "#808"
    # No service was actually back-filled: the freshness gate blocked all of
    # them before backfill_from_base ever ran (fail-fast on the first one).
    [ "$(wc -l < "$backfill_log")" -eq 0 ]
}

@test "#808: an untouched service IS back-filled once the base-channel image is fresh (equal to BASE_SHA)" {
    # setup()'s default stub already returns BASE_SHA itself (equal ->
    # fresh) -- this test just asserts the previously-existing behavior
    # (back-fill happens) still holds now that the freshness gate sits in
    # front of it, i.e. the gate does not accidentally block the good case.
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$backfill_log")" -eq 5 ]
}

@test "#808: BASE_SHA is required -- an omitted BASE_SHA fails closed instead of silently skipping the freshness check" {
    unset BASE_SHA
    export EXISTING_IMAGES=""
    export WORKFLOW_CHANGED="false"
    export PROXY_TOUCHED="false" DNS_TOUCHED="false" WATCHDOG_TOUCHED="false" UI_TOUCHED="false" BUILD_TOOLS_TOUCHED="false"
    run bash "$script"
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -q "BASE_SHA"
}
