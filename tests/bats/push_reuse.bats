#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free coverage for scripts/lib/push-reuse.sh's push_reuse_decide
# (Step 4, issue #1095): the per-service "is it safe to retag the channel
# image instead of rebuilding" decision. Mirrors
# tests/bats/staging_image_freshness.bats's stubbing conventions: sif_image_revision
# is stubbed via STAGING_IMAGE_REVISION_CMD, sif_is_ancestor_or_equal runs
# against a real disposable git repo via STAGING_FRESHNESS_GIT_DIR (so the
# actual `git merge-base --is-ancestor` logic is exercised for real, not
# mocked away), and the one primitive genuinely new to this file --
# classify-image-impact.sh -- is stubbed via PUSH_REUSE_CLASSIFY_CMD.
#
# Covers every fail-closed branch named in this file's own header comment:
# unreadable/missing revision label, a revision that is not a real ancestor
# of github.sha, a classify failure, a classify verdict of "true" (real
# change) for the service under test, a missing/malformed classify key, and
# the one path where all three checks pass and reuse is declared safe. Also
# covers the optional dep_keys parameter (issue #1095): a service whose own
# key is unchanged must still fail closed if a declared base-image
# dependency (e.g. build_tools) changed in the same span. push_reuse_decide
# itself is generic and never hardcodes a real service name; "utilities"
# below is used purely as an illustrative example key, unrelated to the
# now-removed shared utilities image (issue #1781).

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck source=scripts/lib/staging-image-freshness.sh
    source "$repo_root/scripts/lib/staging-image-freshness.sh"
    # shellcheck source=scripts/lib/push-reuse.sh
    source "$repo_root/scripts/lib/push-reuse.sh"

    # Two sequential commits in a disposable repo: c1 (the channel image's
    # claimed build commit) -> c2 (github.sha, the commit under test). c1 is
    # a real ancestor of c2, matching the ordinary "channel is behind but
    # still an ancestor" case this function must accept before also checking
    # content.
    git_dir="$BATS_TEST_TMPDIR/repo"
    git init -q "$git_dir"
    git -C "$git_dir" config user.email test@example.com
    git -C "$git_dir" config user.name test
    git -C "$git_dir" commit -q --allow-empty -m c1
    c1="$(git -C "$git_dir" rev-parse HEAD)"
    git -C "$git_dir" commit -q --allow-empty -m c2
    c2="$(git -C "$git_dir" rev-parse HEAD)"
    export STAGING_FRESHNESS_GIT_DIR="$git_dir"
}

revision_stub() {
    # Writes a stub that always echoes $1 as the "image revision" (or exits
    # 1 with no output if $1 is the literal string "MISSING"), and exports
    # it as STAGING_IMAGE_REVISION_CMD.
    local revision="$1"
    stub="$BATS_TEST_TMPDIR/revision.sh"
    if [[ "$revision" == "MISSING" ]]; then
        cat > "$stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    else
        cat > "$stub" <<STUB
#!/usr/bin/env bash
echo "$revision"
STUB
    fi
    chmod +x "$stub"
    export STAGING_IMAGE_REVISION_CMD="$stub"
}

classify_stub() {
    # Writes a stub that echoes the given key=value lines regardless of its
    # own arguments (or exits 1 with no output if the first line is the
    # literal string "FAIL"), and exports it as PUSH_REUSE_CLASSIFY_CMD.
    local body="$1"
    stub="$BATS_TEST_TMPDIR/classify.sh"
    if [[ "$body" == "FAIL" ]]; then
        cat > "$stub" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    else
        cat > "$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$body"
STUB
    fi
    chmod +x "$stub"
    export PUSH_REUSE_CLASSIFY_CMD="$stub"
}

@test "push_reuse_decide: reuse=true when revision is a real ancestor and classify reports the service unchanged" {
    revision_stub "$c1"
    classify_stub $'ntp=false\nworkflow_reuse_scope=false'

    run push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c2"

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "push_reuse_decide: reuse=false when the channel image has no readable revision label" {
    # Diagnostic lines go to stderr (push-reuse.sh's own documented
    # discipline, matching sif_wait_for_fresh_base_image's convention) --
    # captured directly via `$(... 2>/dev/null)` instead of bats' `run`,
    # which merges stdout+stderr into `$output` and would corrupt this exact
    # comparison (see staging_image_freshness.bats's own "stdout carries
    # ONLY the confirmed revision" test for the same reasoning).
    revision_stub "MISSING"
    classify_stub $'ntp=false'

    result="$(push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c2" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=false when the revision is NOT an ancestor of github.sha (wrong-direction/divergent)" {
    # c2 is stubbed as the "revision" while github.sha is c1 -- c2 is a
    # DESCENDANT of c1, not an ancestor, so sif_is_ancestor_or_equal(c2, c1)
    # must fail. This is the "channel image built from a commit that isn't
    # even reachable from github.sha" case -- e.g. a corrupted/mislabeled
    # image, or a divergent ref.
    revision_stub "$c2"
    classify_stub $'ntp=false'

    result="$(push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c1" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=false when classify-image-impact.sh reports this service DID change between revision and sha" {
    # This is the whole point of doing a real content diff instead of
    # trusting ancestry alone (C-7): the channel image is an ancestor, but
    # something under this service's own path landed between revision and
    # sha (e.g. in an earlier push, before nightly's last refresh).
    revision_stub "$c1"
    classify_stub $'ntp=true\nworkflow_reuse_scope=false'

    result="$(push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c2" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=false when classify-image-impact.sh reports a build-affecting workflow change in the full revision span, even though this service's own key is unchanged (#1095 F-21)" {
    # The revision-span gap two Codex review threads on PR #1378 found: a
    # caller's own before..sha diff (build-push.yml's decide_one()) only
    # sees the immediately preceding push, so it cannot detect a
    # build-affecting workflow/composite-action change that landed several
    # pushes earlier, before the channel's own last refresh. This service's
    # own key (ntp=false) alone must NOT be enough to declare reuse safe --
    # the full-span "workflow_reuse_scope" key from the SAME classify_output
    # must also be checked.
    revision_stub "$c1"
    classify_stub $'ntp=false\nworkflow_reuse_scope=true'

    result="$(push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c2" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=false (fail closed) when the classify output is missing the workflow_reuse_scope key entirely" {
    # Mirrors the existing "missing this service's key entirely" test above,
    # for the workflow_reuse_scope key specifically: a malformed/unexpected
    # classify output must not be silently treated as "no workflow change"
    # just because grep found nothing to contradict it.
    revision_stub "$c1"
    classify_stub $'ntp=false'

    result="$(push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c2" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=false (fail closed) when classify-image-impact.sh itself fails" {
    revision_stub "$c1"
    classify_stub "FAIL"

    result="$(push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c2" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=false (fail closed) when the classify output is missing this service's key entirely" {
    # A malformed/unexpected classify output (e.g. a key-name typo, or a
    # future classify-image-impact.sh refactor that drops a key) must not be
    # silently treated as "unchanged" just because grep found nothing to
    # contradict it.
    revision_stub "$c1"
    classify_stub $'workflow_reuse_scope=false\ndns_image=false'

    result="$(push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c2" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=true when a dependency key is given and shows unchanged too" {
    revision_stub "$c1"
    classify_stub $'proxy=false\nworkflow_reuse_scope=false\nutilities=false'

    run push_reuse_decide "proxy" "ghcr.io/example/proxy:nightly" "$c2" "utilities"

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "push_reuse_decide: reuse=false when a declared dependency changed, even though the service's own key is unchanged" {
    revision_stub "$c1"
    classify_stub $'proxy=false\nworkflow_reuse_scope=false\nutilities=true'

    result="$(push_reuse_decide "proxy" "ghcr.io/example/proxy:nightly" "$c2" "utilities" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=false (fail closed) when a declared dependency key is missing from classify output" {
    revision_stub "$c1"
    classify_stub $'proxy=false\nworkflow_reuse_scope=false'

    result="$(push_reuse_decide "proxy" "ghcr.io/example/proxy:nightly" "$c2" "utilities" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=false when the second of two declared dependencies changed" {
    revision_stub "$c1"
    classify_stub $'dns_image=false\nworkflow_reuse_scope=false\nutilities=false\nbuild_tools=true'

    result="$(push_reuse_decide "dns_image" "ghcr.io/example/dns:nightly" "$c2" "utilities build_tools" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: reuse=true when both of two declared dependencies show unchanged" {
    revision_stub "$c1"
    classify_stub $'dns_image=false\nworkflow_reuse_scope=false\nutilities=false\nbuild_tools=false'

    run push_reuse_decide "dns_image" "ghcr.io/example/dns:nightly" "$c2" "utilities build_tools"

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "push_reuse_decide: an empty dependency-keys argument behaves exactly like omitting it" {
    revision_stub "$c1"
    classify_stub $'ntp=false\nworkflow_reuse_scope=false'

    run push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly" "$c2" ""

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "push_reuse_decide: ignore_workflow_gate=true reuses build_tools despite workflow_reuse_scope=true" {
    revision_stub "$c1"
    classify_stub $'build_tools=false\nworkflow_reuse_scope=true'

    run push_reuse_decide "build_tools" "ghcr.io/example/build-tools:nightly" "$c2" "" "true"

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "push_reuse_decide: ignore_workflow_gate=true still fails closed when build_tools' own key changed" {
    revision_stub "$c1"
    classify_stub $'build_tools=true\nworkflow_reuse_scope=false'

    result="$(push_reuse_decide "build_tools" "ghcr.io/example/build-tools:nightly" "$c2" "" "true" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: ignore_workflow_gate=true reuses utilities despite workflow_reuse_scope=true" {
    revision_stub "$c1"
    classify_stub $'utilities=false\nworkflow_reuse_scope=true'

    run push_reuse_decide "utilities" "ghcr.io/example/utilities:nightly" "$c2" "" "true"

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "push_reuse_decide: omitting ignore_workflow_gate still fails closed on workflow_reuse_scope=true (other 8 services unchanged)" {
    revision_stub "$c1"
    classify_stub $'proxy=false\nworkflow_reuse_scope=true'

    result="$(push_reuse_decide "proxy" "ghcr.io/example/proxy:nightly" "$c2" "utilities" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: ignore_workflow_gate=true still fails closed when a dep_key changed" {
    revision_stub "$c1"
    classify_stub $'dns_image=false\nworkflow_reuse_scope=true\nutilities=true\nbuild_tools=false'

    result="$(push_reuse_decide "dns_image" "ghcr.io/example/dns:nightly" "$c2" "utilities build_tools" "true" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: any value other than the literal 'true' for ignore_workflow_gate is treated as unset" {
    revision_stub "$c1"
    classify_stub $'build_tools=false\nworkflow_reuse_scope=true'

    result="$(push_reuse_decide "build_tools" "ghcr.io/example/build-tools:nightly" "$c2" "" "false" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "push_reuse_decide: requires all three positional arguments" {
    run push_reuse_decide
    [ "$status" -ne 0 ]

    run push_reuse_decide "ntp"
    [ "$status" -ne 0 ]

    run push_reuse_decide "ntp" "ghcr.io/example/ntp:nightly"
    [ "$status" -ne 0 ]
}

# --- decide_one() (build-push.yml, inline) manual-dispatch override ---
#
# decide_one() lives inline in build-push.yml's "Decide per-service push
# reuse" step, not in a sourced library, so it has no unit coverage of its
# own today (only push_reuse_decide, which it calls, is unit-tested above).
# extract_decide_one() below pulls allowlist=(...)/is_allowlisted()/
# decide_one() out of the real workflow file VERBATIM (dedenting the
# fixed 10-space YAML indent) so these tests exercise the exact text the
# real workflow runs, never a reimplementation that could silently drift
# from it. push_reuse_decide and ghcr_retry are stubbed at the shell
# level -- their own real behavior is covered by the tests above and by
# tests/bats/ghcr_retry.bats respectively.

extract_decide_one() {
    local wf="$repo_root/.github/workflows/build-push.yml"
    local out="$BATS_TEST_TMPDIR/decide_one.sh"
    awk '
        /^          allowlist=\(/ { printing = 1 }
        printing {
            print
            if ($0 == "          }") {
                closes++
                if (closes == 2) exit
            }
        }
    ' "$wf" | sed 's/^ \{10\}//' > "$out"
    printf '%s\n' "$out"
}

setup_decide_one() {
    # shellcheck disable=SC1090 # extracted decide_one source, path only known at runtime
    source "$(extract_decide_one)"
    # shellcheck disable=SC2034 # read by decide_one/push_reuse_decide once sourced above
    REPOSITORY="wiki-mod/lancache-ng"
    # shellcheck disable=SC2034 # read by decide_one/push_reuse_decide once sourced above
    channel="nightly"
    GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
    : > "$GITHUB_OUTPUT"
}

@test "decide_one: workflow_dispatch forces a real build for build-tools despite ignore_workflow_gate=true, never calling push_reuse_decide" {
    setup_decide_one
    push_reuse_decide() { echo "MUST NOT BE CALLED" >&2; printf 'true\n'; }
    GITHUB_EVENT_NAME="workflow_dispatch"

    # decide_one's own "::notice::" line goes to stderr on this path (matching
    # push_reuse_decide's diagnostic convention above) -- captured directly,
    # not via `run`, which would merge it into stdout's single "false" line.
    result="$(decide_one build_tools build-tools "" "" "true" 2>/dev/null)"

    [ "$result" = "false" ]
}

@test "decide_one: a push event still lets build-tools reuse via ignore_workflow_gate=true (dispatch override does not leak into push)" {
    setup_decide_one
    ghcr_retry() { printf '"sha256:deadbeef"\n'; }
    push_reuse_decide() { printf 'true\n'; }
    GITHUB_EVENT_NAME="push"

    run decide_one build_tools build-tools "" "" "true"

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "decide_one: workflow_dispatch does NOT force a rebuild for one of the other 8 services (no ignore_workflow_gate)" {
    setup_decide_one
    ghcr_retry() { printf '"sha256:deadbeef"\n'; }
    push_reuse_decide() { printf 'true\n'; }
    GITHUB_EVENT_NAME="workflow_dispatch"

    run decide_one proxy proxy "" "utilities"

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "decide_one: a pull_request event still lets build-tools reuse via ignore_workflow_gate=true" {
    setup_decide_one
    ghcr_retry() { printf '"sha256:deadbeef"\n'; }
    push_reuse_decide() { printf 'true\n'; }
    # shellcheck disable=SC2034 # read by decide_one once sourced in setup_decide_one
    GITHUB_EVENT_NAME="pull_request"

    run decide_one build_tools build-tools "" "" "true"

    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}
