#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Docker-free unit coverage for scripts/gc-pr-staging-images.sh's manifest-
# graph classification functions (the fix for issue #1095's untagged-version
# reap gap) and for gc-pr-staging-images.yml's sparse-checkout-restore step
# (its own suite near the bottom of this file). Both suites were merged into
# this single file (issue #1557); each keeps its own setup helper since they
# share no fixture logic -- see setup()/teardown() below for why.

# What: declares the minimum bats-core version this file requires.
# Why: several tests below use `run --separate-stderr` (bats-core >=1.5.0);
# without this, bats prints a BW02 warning per occurrence, and this repo
# treats any warning as a failure (AG-VAL-001).
# From: Issue #1568
bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # What: sources scripts/gc-pr-staging-images.sh, pulling in every gcps_* function, process_service(), and its config variables without running main().
    # Why: the script's own BASH_SOURCE guard only calls main() when executed, never when sourced -- safe here without a real GH_TOKEN or gh/jq/curl/date. The former separate scripts/lib/ file existed only to provide this same guarantee and was merged in once that became clear.
    # From: Issue #1557 | PR #1559
    # shellcheck source=scripts/gc-pr-staging-images.sh
    source "$repo_root/scripts/gc-pr-staging-images.sh"
}

teardown() {
    # What: runs unconditionally for every test in this file, not just the sparse-checkout-restore group below; test_repo/restore_script are only ever set by setup_sparse_checkout_fixture(), so both guards no-op for other tests.
    # Why: the trailing `return 0` is load-bearing -- bats treats a non-zero teardown as a test failure, and a short-circuited `[[ ... ]]` guard's own exit status would otherwise be 1.
    # From: Issue #1557 | PR #1559
    [[ -n "${test_repo:-}" ]] && rm -rf "$test_repo"
    [[ -n "${restore_script:-}" ]] && rm -f "$restore_script"
    return 0
}

# ---------------------------------------------------------------------------
# gcps_version_name_is_digest
# ---------------------------------------------------------------------------

@test "gcps_version_name_is_digest accepts a real sha256 digest" {
    run gcps_version_name_is_digest "sha256:$(printf 'a%.0s' {1..64})"
    [ "$status" -eq 0 ]
}

@test "gcps_version_name_is_digest rejects a non-digest name" {
    run gcps_version_name_is_digest "pr-123-sha-abcdef1"
    [ "$status" -ne 0 ]
}

@test "gcps_version_name_is_digest rejects a digest with the wrong hex length" {
    run gcps_version_name_is_digest "sha256:abcdef"
    [ "$status" -ne 0 ]
}

@test "gcps_version_name_is_digest rejects uppercase hex (real digests are lowercase)" {
    run gcps_version_name_is_digest "sha256:$(printf 'A%.0s' {1..64})"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# gcps_manifest_looks_valid
# ---------------------------------------------------------------------------

@test "gcps_manifest_looks_valid accepts a manifest with a mediaType" {
    run gcps_manifest_looks_valid '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}'
    [ "$status" -eq 0 ]
}

@test "gcps_manifest_looks_valid rejects a body with no mediaType (e.g. an error page)" {
    run gcps_manifest_looks_valid '<html><body>404 Not Found</body></html>'
    [ "$status" -ne 0 ]
}

@test "gcps_manifest_looks_valid rejects an empty body" {
    run gcps_manifest_looks_valid ''
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# gcps_extract_manifest_children -- the core manifest-graph logic
# ---------------------------------------------------------------------------

@test "gcps_extract_manifest_children collects every manifests[] child of an image index" {
    # Two platform manifests plus one Buildx-embedded attestation manifest,
    # the real shape a multi-arch push with default provenance produces.
    local manifest='{
      "mediaType": "application/vnd.oci.image.index.v1+json",
      "manifests": [
        {"digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"},
        {"digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"},
        {"digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333", "platform": {"architecture": "unknown", "os": "unknown"}}
      ]
    }'
    run gcps_extract_manifest_children "$manifest"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sha256:1111111111111111111111111111111111111111111111111111111111111111"* ]]
    [[ "$output" == *"sha256:2222222222222222222222222222222222222222222222222222222222222222"* ]]
    [[ "$output" == *"sha256:3333333333333333333333333333333333333333333333333333333333333333"* ]]
    # Exactly 3 children -- no extra/duplicate lines from the subject.digest
    # extraction, since this index has no top-level subject field.
    [ "$(printf '%s\n' "$output" | grep -c '^sha256:')" -eq 3 ]
}

@test "gcps_extract_manifest_children collects a single manifest's own subject.digest" {
    # What: the referrers-API attestation shape -- a single manifest declaring which other digest it is "about" via a top-level `subject` field.
    # Why: this is the shape gcps_fetch_manifest's caller checks when evaluating an about-to-delete orphan candidate for a live attestation.
    # From: Issue #1095
    local manifest='{
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "subject": {"digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444"}
    }'
    run gcps_extract_manifest_children "$manifest"
    [ "$status" -eq 0 ]
    [ "$output" = "sha256:4444444444444444444444444444444444444444444444444444444444444444" ]
}

@test "gcps_extract_manifest_children prints nothing for a plain single-platform manifest" {
    local manifest='{"mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {"digest": "sha256:5555555555555555555555555555555555555555555555555555555555555555"}}'
    run gcps_extract_manifest_children "$manifest"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "gcps_extract_manifest_children fails closed (non-zero, no output) on genuinely malformed JSON" {
    # What: distinguishes "jq itself could not parse this" from "jq parsed it fine and found no children".
    # Why: the caller treats a non-zero return the same as an outright manifest-fetch failure (abort orphan classification).
    # From: Issue #1095
    run gcps_extract_manifest_children 'not json at all'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# gcps_created_at_to_epoch / gcps_is_old_enough_to_delete -- the 24h gate
# ---------------------------------------------------------------------------

@test "gcps_created_at_to_epoch parses a real GHCR-style ISO-8601 timestamp" {
    run gcps_created_at_to_epoch "2026-01-01T00:00:00Z"
    [ "$status" -eq 0 ]
    [ "$output" = "1767225600" ]
}

@test "gcps_created_at_to_epoch fails (prints nothing usable) on a malformed timestamp" {
    run gcps_created_at_to_epoch "not-a-timestamp"
    [ "$status" -ne 0 ]
}

@test "gcps_is_old_enough_to_delete: a version created 25 hours ago clears a 24h gate" {
    local now=100000
    local created=$((now - 25 * 3600))
    run gcps_is_old_enough_to_delete "$created" "$now" 86400
    [ "$status" -eq 0 ]
}

@test "gcps_is_old_enough_to_delete: a version created 2 hours ago does NOT clear a 24h gate" {
    local now=100000
    local created=$((now - 2 * 3600))
    run gcps_is_old_enough_to_delete "$created" "$now" 86400
    [ "$status" -ne 0 ]
}

@test "gcps_is_old_enough_to_delete: exactly at the boundary counts as old enough" {
    local now=200000
    local created=$((now - 86400))
    run gcps_is_old_enough_to_delete "$created" "$now" 86400
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# gcps_pr_lookup_state -- ported tri-state PR lookup (mocked `gh`)
# ---------------------------------------------------------------------------

@test "gcps_pr_lookup_state reports OPEN for an open PR" {
    gh() { printf '{"state":"open"}\n'; }
    export -f gh
    declare -A cache=()
    run gcps_pr_lookup_state 42 wiki-mod/lancache-ng cache
    [ "$status" -eq 0 ]
    [ "$output" = "OPEN" ]
}

@test "gcps_pr_lookup_state reports CLOSED for a closed (or merged) PR" {
    gh() { printf '{"state":"closed"}\n'; }
    export -f gh
    declare -A cache=()
    run gcps_pr_lookup_state 42 wiki-mod/lancache-ng cache
    [ "$status" -eq 0 ]
    [ "$output" = "CLOSED" ]
}

@test "gcps_pr_lookup_state reports CLOSED for a genuinely deleted/renumbered PR (real HTTP 404)" {
    gh() { echo "gh: HTTP 404: Not Found" >&2; return 1; }
    export -f gh
    declare -A cache=()
    run gcps_pr_lookup_state 999999 wiki-mod/lancache-ng cache
    [ "$status" -eq 0 ]
    [ "$output" = "CLOSED" ]
}

@test "gcps_pr_lookup_state reports LOOKUP_FAILED (not CLOSED) for a non-404 API failure" {
    # What: a rate limit, auth hiccup, or network blip must never be treated the same as a confirmed-closed PR (the exact bug gcps_pr_lookup_state's own header documents fixing once already).
    # Why: `run --separate-stderr` -- this branch also writes a "::warning::" line to stderr; without separating streams, bats' merged $output would break a plain equality check.
    # From: Issue #1095
    gh() { echo "gh: HTTP 403: API rate limit exceeded" >&2; return 1; }
    export -f gh
    declare -A cache=()
    run --separate-stderr gcps_pr_lookup_state 7 wiki-mod/lancache-ng cache
    [ "$status" -eq 0 ]
    [ "$output" = "LOOKUP_FAILED" ]
}

@test "gcps_pr_lookup_state reports LOOKUP_FAILED when gh succeeds but jq cannot parse the response" {
    # Same "::warning::" stderr caveat as the test above.
    gh() { printf 'this is not json'; }
    export -f gh
    declare -A cache=()
    run --separate-stderr gcps_pr_lookup_state 8 wiki-mod/lancache-ng cache
    [ "$status" -eq 0 ]
    [ "$output" = "LOOKUP_FAILED" ]
}

@test "gcps_pr_lookup_state caches a confirmed answer and does not call gh again" {
    call_log="$BATS_TEST_TMPDIR/gh_calls"
    : > "$call_log"
    gh() {
        echo "call" >> "$call_log"
        printf '{"state":"closed"}\n'
    }
    export -f gh
    export call_log
    # shellcheck disable=SC2034 # passed by name to gcps_pr_lookup_state,
    # which populates it via nameref
    declare -A cache=()
    gcps_pr_lookup_state 55 wiki-mod/lancache-ng cache >/dev/null
    gcps_pr_lookup_state 55 wiki-mod/lancache-ng cache >/dev/null
    [ "$(wc -l < "$call_log")" -eq 1 ]
}

@test "gcps_pr_lookup_state populates a 4th-arg result variable without printing being required" {
    gh() { printf '{"state":"open"}\n'; }
    export -f gh
    # shellcheck disable=SC2034 # passed by name to gcps_pr_lookup_state, which populates it via nameref
    declare -A cache=()
    local result
    gcps_pr_lookup_state 66 wiki-mod/lancache-ng cache result >/dev/null
    [ "$result" = "OPEN" ]
    # Second call is a cache hit -- the early-return branch must populate the
    # 4th-arg output too, not just the post-lookup branch.
    gcps_pr_lookup_state 66 wiki-mod/lancache-ng cache result >/dev/null
    [ "$result" = "OPEN" ]
}

@test "process_service: caching a PR's state actually works through the real caller call site (issue #1557 item 74)" {
    # What: exercises the real process_service() call site (two versions tagged for the same PR, matching build-push.yml's amd64/arm64 per-arch-leg shape) and asserts the pulls API is only invoked once.
    # Why: gcps_pr_lookup_state's own direct-invocation caching test above passed even while this real call site was broken -- it used to wrap the lookup in `$(...)`, discarding the nameref cache mutation the instant that subshell exits.
    # From: Issue #1557 | PR #1559
    call_log="$BATS_TEST_TMPDIR/pulls_calls"
    : > "$call_log"
    export call_log

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":1,"name":"sha256:$(printf 'c%.0s' {1..64})","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["pr-77-sha-1234567-amd64"]}}},
  {"id":2,"name":"sha256:$(printf 'd%.0s' {1..64})","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["pr-77-sha-1234567-arm64"]}}}
]
VERSIONS_JSON
            return 0
        fi
        if [[ "$1" == "api" && "$2" == repos/*/pulls/* ]]; then
            echo "call" >> "$call_log"
            printf '{"state":"open"}\n'
            return 0
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    curl() {
        local args="$*"
        if [[ "$args" == *"ghcr.io/token"* ]]; then
            printf '{"token":"faketoken"}\n'
            return 0
        fi
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
        return 0
    }
    export -f curl

    process_service proxy

    # shellcheck disable=SC2154 # set as a global by the sourced
    # process_service()
    [ "$deleted" -eq 0 ]
    # shellcheck disable=SC2154 # see $deleted comment above
    [ "$kept" -eq 2 ]
    [ "$(wc -l < "$call_log")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# gcps_registry_anon_token / gcps_fetch_manifest -- mocked `curl`
# ---------------------------------------------------------------------------

@test "gcps_registry_anon_token extracts the token field from the token endpoint's response" {
    curl() { printf '{"token":"anon-pull-token-xyz","expires_in":300}\n'; }
    export -f curl
    run gcps_registry_anon_token proxy wiki-mod/lancache-ng
    [ "$status" -eq 0 ]
    [ "$output" = "anon-pull-token-xyz" ]
}

@test "gcps_fetch_manifest requests all four Buildx-relevant media types in one Accept header" {
    # What: regresses the specific misconfiguration of asking for only one media type, not just "curl was called".
    # Why: a single-media-type request risks the registry silently converting an index into a single-platform manifest with no manifests[] at all (see gcps_fetch_manifest's own header).
    # From: Issue #1095
    args_log="$BATS_TEST_TMPDIR/curl_args"
    curl() {
        printf '%s\n' "$*" > "$args_log"
        printf '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}\n'
    }
    export -f curl
    export args_log
    run gcps_fetch_manifest proxy "sha256:$(printf 'b%.0s' {1..64})" wiki-mod/lancache-ng faketoken
    [ "$status" -eq 0 ]
    logged="$(cat "$args_log")"
    [[ "$logged" == *"application/vnd.oci.image.index.v1+json"* ]]
    [[ "$logged" == *"application/vnd.docker.distribution.manifest.list.v2+json"* ]]
    [[ "$logged" == *"application/vnd.oci.image.manifest.v1+json"* ]]
    [[ "$logged" == *"application/vnd.docker.distribution.manifest.v2+json"* ]]
    [[ "$logged" == *"Bearer faketoken"* ]]
}

# ---------------------------------------------------------------------------
# What: end-to-end -- process_service() itself against mocked gh/curl, the case that actually proves the classification-gap fix, exercised under this file's own `set -euo pipefail` (inherited from setup()).
# Why: AG-VAL-030 requires a construct depending on the caller's shell options to be proven under those exact options, not a looser test environment.
# From: Issue #1095
# ---------------------------------------------------------------------------

@test "process_service: an index's own platform+attestation children are protected, not deleted" {
    # What: index_digest/plat_a/plat_b/attest are declared and assigned on separate lines (shellcheck SC2155).
    # Why: a combined `local x="$(cmd)"` masks cmd's own exit status behind `local`'s always-0 one; kept uniform here so a later, fallible substitution copy-pasted from this pattern inherits the safe form.
    # From: Issue #1095
    local index_digest plat_a plat_b attest
    index_digest="sha256:$(printf '1%.0s' {1..64})"
    plat_a="sha256:$(printf '2%.0s' {1..64})"
    plat_b="sha256:$(printf '3%.0s' {1..64})"
    attest="sha256:$(printf '4%.0s' {1..64})"

    delete_log="$BATS_TEST_TMPDIR/deletes"
    : > "$delete_log"
    export delete_log

    # What: one tagged image index (a real, non-pr-* source tag) plus its three untagged children (two platform manifests, one Buildx-embedded attestation), the shape a real multi-arch push produces.
    # Why: proves the manifest-graph logic reaches "keep" deliberately, by tracing the reference, not by accident (the pre-fix logic never looked at untagged children at all).
    # From: Issue #1095
    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":1,"name":"$index_digest","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-abc1234"]}}},
  {"id":2,"name":"$plat_a","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":[]}}},
  {"id":3,"name":"$plat_b","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":[]}}},
  {"id":4,"name":"$attest","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":[]}}}
]
VERSIONS_JSON
            return 0
        fi
        if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" ]]; then
            echo "$4" >> "$delete_log"
            return 0
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    curl() {
        local args="$*"
        if [[ "$args" == *"ghcr.io/token"* ]]; then
            printf '{"token":"faketoken"}\n'
            return 0
        fi
        if [[ "$args" == *"manifests/$index_digest"* ]]; then
            printf '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":"%s"},{"digest":"%s"},{"digest":"%s"}]}\n' \
                "$plat_a" "$plat_b" "$attest"
            return 0
        fi
        echo "unexpected curl call: $args" >&2
        return 1
    }
    export -f curl

    process_service proxy

    # shellcheck disable=SC2154 # set as a global by the sourced
    # process_service()
    [ "$deleted" -eq 0 ]
    # shellcheck disable=SC2154 # see $deleted comment above
    [ "$kept" -eq 4 ]
    # shellcheck disable=SC2154 # see $deleted comment above
    [ "$had_errors" -eq 0 ]
    [ ! -s "$delete_log" ]
}

# What: a 404 listing a service's own package (this test's mock reproduces `gh api`'s real stderr/stdout split for a genuinely nonexistent package) means "nothing to reap yet", not a listing failure.
# Why: a service can appear in build-push.yml's matrix before its first image is pushed; conflating the two would set had_errors=1 and fail the whole run for any freshly-scaffolded service.
# From: Issue #1095
@test "process_service: a 404 listing a service's own package (no images published yet) is not an error" {
    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            echo '{"message":"Package not found.","documentation_url":"https://docs.github.com/rest/packages/packages#list-package-versions-for-a-package-owned-by-an-organization","status":"404"}'
            echo "gh: Package not found. (HTTP 404)" >&2
            return 1
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    process_service syslog

    [ "$deleted" -eq 0 ]
    [ "$kept" -eq 0 ]
    [ "$had_errors" -eq 0 ]
    # shellcheck disable=SC2154 # set as a global by the sourced
    # process_service()
    [ "$services_not_found" -eq 1 ]
}

@test "main(): every configured service reporting no GHCR package yet crosses the systemic-404 threshold (issue #1557 item 72)" {
    # shellcheck disable=SC2034 # read by main() in the sourced script
    GH_TOKEN="unused-but-required-by-main"

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            echo '{"message":"Package not found.","documentation_url":"https://docs.github.com/rest/packages/packages#list-package-versions-for-a-package-owned-by-an-organization","status":"404"}'
            echo "gh: Package not found. (HTTP 404)" >&2
            return 1
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    # What: `run` forks a subshell to catch main()'s own `exit 1`.
    # Why: same pattern as the pervasive-PR-lookup-failure main() test further down this file.
    # From: Issue #1557 | PR #1559
    run --separate-stderr main
    [ "$status" -eq 1 ]
    [[ "$output" == *"of ${#services[@]} configured services reported no GHCR package yet this run"* ]]
    [[ "$output" == *"One or more package-version listings, manifest fetches, or deletions failed"* ]]
}

@test "process_service: a manifest-fetch failure disables orphan classification for that service (fails closed)" {
    # What: index_digest/plat_a declared/assigned separately (SC2155).
    # Why: same reasoning as the earlier test in this file.
    # From: Issue #1095
    local index_digest plat_a
    index_digest="sha256:$(printf '5%.0s' {1..64})"
    plat_a="sha256:$(printf '6%.0s' {1..64})"

    # What: GHCR_RETRY_BACKOFF_SECONDS=0 forces instant retries.
    # Why: this test asserts on ghcr_retry exhausting its attempts, not on the real backoff delay.
    # From: Issue #1095
    # shellcheck disable=SC2034 # read by ghcr_retry() in the sourced script
    GHCR_RETRY_BACKOFF_SECONDS=0
    # shellcheck disable=SC2034 # read by ghcr_retry() in the sourced script
    GHCR_RETRY_MAX_ATTEMPTS=2

    delete_log="$BATS_TEST_TMPDIR/deletes2"
    : > "$delete_log"
    export delete_log

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":10,"name":"$index_digest","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-deadbee"]}}},
  {"id":11,"name":"$plat_a","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":[]}}}
]
VERSIONS_JSON
            return 0
        fi
        if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" ]]; then
            echo "$4" >> "$delete_log"
            return 0
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    curl() {
        local args="$*"
        if [[ "$args" == *"ghcr.io/token"* ]]; then
            printf '{"token":"faketoken"}\n'
            return 0
        fi
        # What: every manifest fetch fails, simulating a registry outage/rate limit.
        # Why: exercises the had_errors fail-closed path for a Pass-1 manifest-fetch failure.
        # From: Issue #1095
        echo "simulated registry failure" >&2
        return 1
    }
    export -f curl

    process_service proxy

    # What: zero deletions -- specifically zero orphan deletions, since Pass 2 never runs once orphan_phase_ok is disabled.
    # Why: the tagged index itself is kept for the pre-existing "protected" (real source tag) reason, not anything this test exercises.
    # From: Issue #1095
    [ "$deleted" -eq 0 ]
    [ ! -s "$delete_log" ]
    [ "$had_errors" -eq 1 ]
}

# What: the next three tests cover cases that used to be `::warning::`-only with no had_errors=1, unlike the sibling failure modes above (jq read failure, manifest fetch failure).
# Why: all are the same AG-VAL-001 class -- required classification/deletion-safety evidence was unavailable, so the run must not report a clean exit code, though the fail-closed keep behavior itself is unchanged.
# From: Issue #1557 | PR #1559

@test "process_service: a malformed digest-shape .name sets had_errors (issue #1557 item 79)" {
    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":30,"name":"not-a-real-digest","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-deadbee"]}}}
]
VERSIONS_JSON
            return 0
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    process_service proxy

    [ "$deleted" -eq 0 ]
    [ "$had_errors" -eq 1 ]
}

@test "process_service: an unparseable created_at on a closed-PR candidate sets had_errors (issue #1557 item 79)" {
    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":31,"name":"sha256:$(printf 'e%.0s' {1..64})","created_at":"not-a-real-timestamp","metadata":{"container":{"tags":["pr-55-sha-1234567"]}}}
]
VERSIONS_JSON
            return 0
        fi
        if [[ "$1" == "api" && "$2" == repos/*/pulls/* ]]; then
            printf '{"state":"closed"}\n'
            return 0
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    curl() {
        local args="$*"
        if [[ "$args" == *"ghcr.io/token"* ]]; then
            printf '{"token":"faketoken"}\n'
            return 0
        fi
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
        return 0
    }
    export -f curl

    process_service proxy

    [ "$deleted" -eq 0 ]
    [ "$kept" -eq 1 ]
    [ "$had_errors" -eq 1 ]
}

@test "process_service: a failed candidate-orphan manifest fetch in Pass 2 sets had_errors (issue #1557 item 79)" {
    local orphan_digest
    orphan_digest="sha256:$(printf 'f%.0s' {1..64})"

    # shellcheck disable=SC2034 # read by ghcr_retry() in the sourced script
    GHCR_RETRY_BACKOFF_SECONDS=0
    # shellcheck disable=SC2034 # read by ghcr_retry() in the sourced script
    GHCR_RETRY_MAX_ATTEMPTS=2

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":32,"name":"$orphan_digest","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":[]}}}
]
VERSIONS_JSON
            return 0
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    curl() {
        local args="$*"
        if [[ "$args" == *"ghcr.io/token"* ]]; then
            printf '{"token":"faketoken"}\n'
            return 0
        fi
        # What: the candidate-manifest fetch fails here (simulated registry outage).
        # Why: the untagged candidate has no Pass-1 children, so it must reach Pass 2's own candidate-manifest fetch to be classified at all.
        # From: Issue #1557 | PR #1559
        echo "simulated registry failure" >&2
        return 1
    }
    export -f curl

    process_service proxy

    [ "$deleted" -eq 0 ]
    [ "$kept" -eq 1 ]
    [ "$had_errors" -eq 1 ]
}

# What: reproduces GHCR/Buildx's tag-based attestation convention -- $attested_orphan is untagged, old enough to clear the age gate, and NOT listed in $tagged_index's `.manifests[]`; its only protection is $attestation's `sha256-<hex of $attested_orphan>` tag.
# Why: gcps_extract_manifest_children() only reads a manifest BODY, so it can never discover this convention on its own; live-verified against the real lancache-ng/proxy package that 1107 of 3522 versions carry exactly this tag shape, some pointing at ordinary untagged single-platform manifests Pass 2 would otherwise misclassify as orphans.
# From: Issue #1095
@test "process_service: an untagged version named only by another version's sha256-<hex> attestation TAG (not its manifest body) is protected" {
    local tagged_index attestation attested_orphan
    tagged_index="sha256:$(printf '7%.0s' {1..64})"
    attestation="sha256:$(printf '8%.0s' {1..64})"
    attested_orphan="sha256:$(printf '9%.0s' {1..64})"
    local attested_orphan_hex
    attested_orphan_hex="${attested_orphan#sha256:}"

    delete_log="$BATS_TEST_TMPDIR/deletes3"
    : > "$delete_log"
    export delete_log

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":20,"name":"$tagged_index","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-cafe123"]}}},
  {"id":21,"name":"$attestation","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha256-$attested_orphan_hex"]}}},
  {"id":22,"name":"$attested_orphan","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":[]}}}
]
VERSIONS_JSON
            return 0
        fi
        if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" ]]; then
            echo "$4" >> "$delete_log"
            return 0
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    curl() {
        local args="$*"
        if [[ "$args" == *"ghcr.io/token"* ]]; then
            printf '{"token":"faketoken"}\n'
            return 0
        fi
        # What: tagged_index's and attestation's own manifest bodies are plain, childless manifests, deliberately -- neither mentions $attested_orphan.
        # Why: isolates this test to the tag-string-based association only, so a pass proves the tag-string parsing, not the pre-existing `.manifests[]`/`.subject` extraction.
        # From: Issue #1095
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
        return 0
    }
    export -f curl

    process_service proxy

    [ "$deleted" -eq 0 ]
    [ "$kept" -eq 3 ]
    [ "$had_errors" -eq 0 ]
    [ ! -s "$delete_log" ]
}

# ---------------------------------------------------------------------------
# What: pr_lookup_failures threshold coverage -- a systemic PR-lookup failure must not produce a healthy-looking "GC complete" summary.
# Why: added while investigating whether this project's one real historical scheduled run (2026-08-02, 10 deleted/21919 kept) was caused by GHCR_PACKAGE_DELETE_PAT failing pulls-API calls en masse; its own real Actions log showed zero actual LOOKUP_FAILED occurrences, ruling that specific run out, but the threshold guards a future occurrence of the same failure shape.
# From: Issue #1095
# ---------------------------------------------------------------------------

@test "process_service: pervasive PR-lookup failures are counted and cross the threshold into a hard failure" {
    # What: max_pr_lookup_failures is reassigned directly as a plain script variable, not via GC_MAX_PR_LOOKUP_FAILURES.
    # Why: setup() already sourced the script, evaluating the env-var default once at source time -- overriding the env var now would have no effect.
    # From: Issue #1095
    max_pr_lookup_failures=2

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":1,"name":"sha256:$(printf '7%.0s' {1..64})","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["pr-101-sha-1234567"]}}},
  {"id":2,"name":"sha256:$(printf '8%.0s' {1..64})","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["pr-102-sha-1234567"]}}},
  {"id":3,"name":"sha256:$(printf '9%.0s' {1..64})","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["pr-103-sha-1234567"]}}}
]
VERSIONS_JSON
            return 0
        fi
        # What: simulates GHCR_PACKAGE_DELETE_PAT lacking the `repo`/`public_repo` scope its pulls lookups need (a real HTTP 403, never a 404).
        # Why: every single tagged version's PR-state lookup fails this way.
        # From: Issue #1095
        if [[ "$1" == "api" && "$2" == repos/*/pulls/* ]]; then
            echo "gh: HTTP 403: API rate limit exceeded" >&2
            return 1
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    curl() {
        local args="$*"
        if [[ "$args" == *"ghcr.io/token"* ]]; then
            printf '{"token":"faketoken"}\n'
            return 0
        fi
        # What: a plain single-platform manifest for every fetch.
        # Why: this test is about the PR-lookup threshold, not manifest-graph classification.
        # From: Issue #1095
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
        return 0
    }
    export -f curl

    process_service proxy

    # What: all 3 versions kept (an ambiguous PR-state lookup is always safe on its own).
    # Why: this is exactly the shape that must not read as a healthy, unremarkable run once it happens this pervasively.
    # From: Issue #1095
    [ "$deleted" -eq 0 ]
    [ "$kept" -eq 3 ]
    # shellcheck disable=SC2154 # set as a global by the sourced
    # process_service()
    [ "$pr_lookup_failures" -eq 3 ]
    [ "$pr_lookup_failures" -ge "$max_pr_lookup_failures" ]
}

@test "main(): the same pervasive PR-lookup-failure scenario actually fails the whole run, not just the counter" {
    # What: restricts the sweep to one service so the expected count (3) is exact and the test stays fast.
    # Why: main()'s own `for service in "${services[@]}"` loop would otherwise process all 8 real services against the same mocked gh(), inflating the count to 24 for no additional coverage value.
    # From: Issue #1095
    # shellcheck disable=SC2034 # read by main() in the sourced script
    services=(proxy)
    max_pr_lookup_failures=2
    # shellcheck disable=SC2034 # read by main()'s own required-var guard in
    # the sourced script
    GH_TOKEN="unused-but-required-by-main"

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            cat <<VERSIONS_JSON
[
  {"id":1,"name":"sha256:$(printf '7%.0s' {1..64})","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["pr-101-sha-1234567"]}}},
  {"id":2,"name":"sha256:$(printf '8%.0s' {1..64})","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["pr-102-sha-1234567"]}}},
  {"id":3,"name":"sha256:$(printf '9%.0s' {1..64})","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["pr-103-sha-1234567"]}}}
]
VERSIONS_JSON
            return 0
        fi
        if [[ "$1" == "api" && "$2" == repos/*/pulls/* ]]; then
            echo "gh: HTTP 403: API rate limit exceeded" >&2
            return 1
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh

    curl() {
        local args="$*"
        if [[ "$args" == *"ghcr.io/token"* ]]; then
            printf '{"token":"faketoken"}\n'
            return 0
        fi
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
        return 0
    }
    export -f curl

    # What: `run` forks a subshell, so main()'s own internal `exit 1` terminates only that subshell.
    # Why: this test's own process survives to assert on the captured status/output.
    # From: Issue #1095
    run --separate-stderr main
    [ "$status" -eq 1 ]
    [[ "$output" == *"PR-state lookups failed this run (threshold: 2)"* ]]
    [[ "$output" == *"One or more package-version listings, manifest fetches, or deletions failed"* ]]
}

# ---------------------------------------------------------------------------
# Sparse-checkout restore step (merged in from the former
# tests/bats/gc_pr_staging_images_sparse_checkout_restore.bats, issue #1557)
# ---------------------------------------------------------------------------
# What: regresses gc-pr-staging-images.yml's sparse-checkout-restore step -- actions/checkout's non-cone sparse-checkout doesn't reliably clear on a plain `disable` call, so the fix sweeps remaining index skip-worktree bits directly and verifies the result instead of trusting exit codes.
# Why: self-hosted runners reuse one working directory across unrelated jobs, so a leftover narrow state corrupts whichever job runs next (root-caused live via runner `_diag` logs after real build-push.yml failures). A throwaway local `git init` repository reproduces the same git plumbing behavior with no network or real clone needed.
# From: Issue #1095
# See docs/release-validation-plan.md's sparse-checkout-restore section for the full incident.

# setup_sparse_checkout_fixture
# What: called explicitly as the first line of every test in this group, not via the file-wide setup() above; populates test_repo/restore_script, which the file-wide teardown() already cleans up.
# Why: this suite's fixture is kept separate from the classification suite's setup() -- see this file's own header for why.
# From: Issue #1557 | PR #1559
setup_sparse_checkout_fixture() {
    if ! command -v git >/dev/null 2>&1; then
        skip "git not available"
    fi

    test_repo="$(mktemp -d)"
    git -C "$test_repo" init --quiet --initial-branch=main
    git -C "$test_repo" config user.email "test@example.invalid"
    git -C "$test_repo" config user.name "Test"

    # What: a handful of tracked files standing in for the real repo's tree -- two inside gc-pr-staging-images.yml's actual narrow checkout set, two representing everything else (e.g. a workflow-referenced composite action).
    # Why: a later, unrelated job's checkout step needs the "everything else" files to still be reachable after the restore.
    # From: Issue #1095
    mkdir -p "$test_repo/scripts/lib" "$test_repo/.github/actions/some-action"
    echo "narrow-a" >"$test_repo/scripts/narrow-a.sh"
    echo "narrow-b" >"$test_repo/scripts/lib/narrow-b.sh"
    echo "outside-a" >"$test_repo/README.md"
    echo "outside-b" >"$test_repo/.github/actions/some-action/action.yml"
    git -C "$test_repo" add -A
    git -C "$test_repo" commit --quiet -m "seed"

    # What: gc-pr-staging-images.yml's restore step verbatim, extracted into its own external script file rather than a bash function in this test file.
    # Why: bats' `run` doesn't reliably preserve `set -e` semantics for an in-file function (confirmed: it masked a real fail-closed bug during development) and a real external script is also a closer match to how the workflow itself executes it.
    # From: Issue #1557 | PR #1559
    restore_script="$(mktemp)"
    cat >"$restore_script" <<'RESTORE_SCRIPT'
#!/usr/bin/env bash
cd "$1" || exit 1
set -euo pipefail
git sparse-checkout init || true
git sparse-checkout disable || true
git config --local --unset-all core.sparseCheckout || true
rm -f .git/info/sparse-checkout

# What: sweeps remaining skip-worktree bits directly; captures `git ls-files -v` into a variable before piping to awk.
# Why: a direct pipe into awk would hide a real git failure behind awk's own unrelated exit code, defeating `set -e`.
# From: Issue #1095
ls_files_before="$(git ls-files -v)"
mapfile -t remaining_skip_worktree < <(printf '%s\n' "$ls_files_before" | awk '/^S /{print substr($0,3)}')
if [ "${#remaining_skip_worktree[@]}" -gt 0 ]; then
  git update-index --no-skip-worktree -- "${remaining_skip_worktree[@]}"
fi
git checkout --progress --force HEAD -- .

# What: verifies the restore actually worked (fails loudly if any path is still excluded) instead of trusting the commands above.
# Why: counts with awk rather than `grep -c` so a zero-match result needs no `|| true` fallback -- an empty count would otherwise make the `-ne 0` check a silent non-fatal runtime error under `set -e` instead of failing closed.
# From: Issue #1095
ls_files_after="$(git ls-files -v)"
remaining_after="$(printf '%s\n' "$ls_files_after" | awk '/^S /{c++} END{print c+0}')"
if [ "$remaining_after" -ne 0 ]; then
  echo "::error::${remaining_after} path(s) still carry the skip-worktree bit after the restore sequence" >&2
  exit 1
fi
RESTORE_SCRIPT
}

# Mirrors actions/checkout's sparseCheckoutNonConeMode(): `git config
# core.sparseCheckout true` plus a raw append to .git/info/sparse-checkout,
# never `git sparse-checkout set`. This is the exact setup path
# gc-pr-staging-images.yml's `sparse-checkout-cone-mode: false` selects.
narrow_via_legacy_manual_append() {
    git -C "$test_repo" config core.sparseCheckout true
    printf '\nscripts/narrow-a.sh\nscripts/lib/narrow-b.sh\n' >>"$test_repo/.git/info/sparse-checkout"
    git -C "$test_repo" checkout --progress --force HEAD >/dev/null 2>&1
}

# Runs the restore script (see setup_sparse_checkout_fixture() above)
# against the directory given as $1 -- a real git repo for the recovery-path
# tests below, or a non-repo directory for the fail-closed test.
run_workflow_restore_step() {
    bash "$restore_script" "$1"
}

@test "legacy manual sparse-checkout setup narrows the working tree as expected" {
    setup_sparse_checkout_fixture
    narrow_via_legacy_manual_append
    [ -f "$test_repo/scripts/narrow-a.sh" ]
    [ ! -f "$test_repo/README.md" ]
    [ ! -f "$test_repo/.github/actions/some-action/action.yml" ]
}

@test "plain 'git sparse-checkout disable' does not reliably clear core.sparseCheckout" {
    setup_sparse_checkout_fixture
    narrow_via_legacy_manual_append

    run git -C "$test_repo" sparse-checkout disable
    [ "$status" -eq 0 ]
    run git -C "$test_repo" checkout --progress --force HEAD
    [ "$status" -eq 0 ]

    # What: `disable` reports success, but core.sparseCheckout was never actually cleared.
    # Why: confirmed as the one consistently-reproducible part of this failure across every repetition (against both this fixture and the real repository); whether files outside the narrow set are also still missing varied between repetitions and is deliberately not asserted here.
    # From: Issue #1095
    run git -C "$test_repo" config --local --get core.sparseCheckout
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "the workflow's restore step fully restores a legacy-manual narrow checkout and its assertion passes" {
    setup_sparse_checkout_fixture
    narrow_via_legacy_manual_append

    run run_workflow_restore_step "$test_repo"
    [ "$status" -eq 0 ]

    [ -f "$test_repo/README.md" ]
    [ -f "$test_repo/.github/actions/some-action/action.yml" ]
    [ -f "$test_repo/scripts/narrow-a.sh" ]
    [ -f "$test_repo/scripts/lib/narrow-b.sh" ]

    # What: core.sparseCheckout must genuinely be gone, not just report success.
    # Why: a later job's checkout step never re-sets it, so a lingering true would keep re-narrowing every future tree-changing operation.
    # From: Issue #1095
    run git -C "$test_repo" config --local --get core.sparseCheckout
    [ "$status" -eq 1 ]

    run git -C "$test_repo" ls-files -v
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\nS '* ]]
    [[ "$output" != S\ * ]]
}

@test "the workflow's restore step's own sweep recovers a skip-worktree bit regardless of how it was set" {
    setup_sparse_checkout_fixture
    # What: sets a skip-worktree bit directly, not via the flaky legacy-setup reproduction above.
    # Why: proves the step's own sweep+assert logic (the part not relying on `disable`/`init` succeeding) is sound without depending on that flakiness.
    # From: Issue #1095
    git -C "$test_repo" update-index --skip-worktree README.md
    rm -f "$test_repo/README.md"

    run run_workflow_restore_step "$test_repo"
    [ "$status" -eq 0 ]
    [ -f "$test_repo/README.md" ]

    run git -C "$test_repo" ls-files -v
    [[ "$output" != *$'\nS '* ]]
    [[ "$output" != S\ * ]]
}

@test "the workflow's restore step fails closed (non-zero exit) instead of silently succeeding when git itself is broken" {
    setup_sparse_checkout_fixture
    # What: proves the shipped fail-closed behavior against a directory that isn't a git repository at all, rather than reasoning about it.
    # Why: a `grep -c ... || true` count instead of awk could leave the count variable empty on a genuine git failure, making `[ "$x" -ne 0 ]` a silently-skipped runtime error under `set -e` instead of a fatal one -- this test regresses that subtler hazard.
    # From: Issue #1095
    not_a_repo="$(mktemp -d)"
    run run_workflow_restore_step "$not_a_repo"
    [ "$status" -ne 0 ]
    rm -rf "$not_a_repo"
}
