#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: Docker-free unit coverage for gc-pr-staging-images.sh's manifest-
# graph classification and for the workflow's sparse-checkout-restore step.
# Why: the two suites share no fixture logic, hence separate setup helpers.
# From: Issue #1557 | PR #1559

# What: declares the minimum bats-core version this file requires.
# Why: several tests below use `run --separate-stderr` (bats-core >=1.5.0);
# without this, bats prints a BW02 warning per occurrence, and this repo
# treats any warning as a failure (AG-VAL-001).
# From: Issue #1568
bats_require_minimum_version 1.5.0

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # What: sources scripts/untracked/gc-pr-staging-images.sh, pulling in every
    # gcps_* function/process_service()/config var without running main().
    # Why: the script's own BASH_SOURCE guard only calls main() when
    # executed, never when sourced -- safe without a real GH_TOKEN.
    # From: Issue #1557 | PR #1559
    # shellcheck source=scripts/untracked/gc-pr-staging-images.sh
    source "$repo_root/scripts/untracked/gc-pr-staging-images.sh"
}

teardown() {
    # What: runs for every test; test_repo/restore_script are only set by
    # setup_sparse_checkout_fixture(), so both guards no-op otherwise.
    # Why: `return 0` is load-bearing -- bats treats non-zero teardown as
    # failure, and a short-circuited `[[ ]]` guard's own exit is 1.
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
    # What: two platform manifests plus one Buildx-embedded attestation
    # manifest -- the real shape a multi-arch push produces.
    # From: Issue #1095 | PR #1443
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
    # What: exactly 3 children expected -- no extra lines from the
    # subject.digest extraction.
    # Why: this index has no top-level subject field.
    # From: Issue #1095 | PR #1443
    [ "$(printf '%s\n' "$output" | grep -c '^sha256:')" -eq 3 ]
}

@test "gcps_extract_manifest_children collects a single manifest's own subject.digest" {
    # What: the referrers-API attestation shape -- a single manifest declaring
    # which other digest it is "about" via a top-level `subject` field.
    # Why: this is the shape gcps_fetch_manifest's caller checks when
    # evaluating an about-to-delete orphan candidate for a live attestation.
    # From: Issue #1095 | PR #1443
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
    # What: distinguishes "jq itself could not parse this" from "jq parsed it
    # fine and found no children".
    # Why: the caller treats a non-zero return the same as an outright
    # manifest-fetch failure (abort orphan classification).
    # From: Issue #1095 | PR #1443
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
    # What: a rate limit/auth hiccup must never read as a confirmed-closed
    # PR.
    # Why: `run --separate-stderr`, since this branch also writes a
    # "::warning::" line that would break a plain merged-output check.
    # From: Issue #1095 | PR #1443
    gh() { echo "gh: HTTP 403: API rate limit exceeded" >&2; return 1; }
    export -f gh
    declare -A cache=()
    run --separate-stderr gcps_pr_lookup_state 7 wiki-mod/lancache-ng cache
    [ "$status" -eq 0 ]
    [ "$output" = "LOOKUP_FAILED" ]
}

@test "gcps_pr_lookup_state reports LOOKUP_FAILED when gh succeeds but jq cannot parse the response" {
    # What: same "::warning::" stderr caveat as the test above.
    # Why: `run --separate-stderr` keeps it out of a plain $output check.
    # From: Issue #1095 | PR #1443
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
    # What: second call is a cache hit.
    # Why: the early-return branch must populate the 4th-arg output too,
    # not just the post-lookup branch.
    # From: Issue #1557 | PR #1559
    gcps_pr_lookup_state 66 wiki-mod/lancache-ng cache result >/dev/null
    [ "$result" = "OPEN" ]
}

@test "process_service: caching a PR's state actually works through the real caller call site (issue #1557 item 74)" {
    # What: exercises the real process_service() call site (two versions
    # for one PR) and asserts the pulls API is only invoked once.
    # Why: a direct-invocation caching test alone can pass even while this
    # real call site wraps the lookup in `$(...)`, discarding the cache.
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
    # What: regresses the specific misconfiguration of asking for only
    # one media type, not just "curl was called".
    # Why: a single-media-type request risks the registry silently
    # converting an index into a single-platform manifest with no children.
    # From: Issue #1095 | PR #1443
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
# What: end-to-end -- process_service() against mocked gh/curl, under this
# file's own `set -euo pipefail` (inherited from setup()).
# Why: AG-VAL-030 requires a construct depending on the caller's shell
# options to be proven under those exact options, not a looser environment.
# From: Issue #1095 | PR #1443
# ---------------------------------------------------------------------------

@test "process_service: an index's own platform+attestation children are protected, not deleted" {
    # What: index_digest/plat_a/plat_b/attest are declared and assigned
    # on separate lines (shellcheck SC2155).
    # Why: a combined `local x="$(cmd)"` masks cmd's own exit status
    # behind `local`'s always-0 one.
    # From: Issue #1095 | PR #1443
    local index_digest plat_a plat_b attest
    index_digest="sha256:$(printf '1%.0s' {1..64})"
    plat_a="sha256:$(printf '2%.0s' {1..64})"
    plat_b="sha256:$(printf '3%.0s' {1..64})"
    attest="sha256:$(printf '4%.0s' {1..64})"

    delete_log="$BATS_TEST_TMPDIR/deletes"
    : > "$delete_log"
    export delete_log

    # What: one tagged image index plus its three untagged children (two
    # platform manifests, one attestation) -- a real multi-arch push shape.
    # Why: proves the manifest-graph logic reaches "keep" by tracing the
    # reference, not by accident.
    # From: Issue #1095 | PR #1443
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

# What: a 404 listing a service's own package (mocking `gh api`'s real
# stderr/stdout split) means "nothing to reap yet", not a listing failure.
# Why: a service can appear in the build matrix before its first image is
# pushed; conflating the two would fail the whole run for that service.
# From: Issue #1095 | PR #1443
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
    GH_TOKEN="unused-but-required-by-main"
    services=(proxy dns)
    gc_concurrency=2
    gh() { :; }
    curl() { :; }
    export -f gh curl
    sra_manifest_packages() { :; }
    gc_resolve_retention_history_refs() { printf 'origin/current_dev\n'; }
    gc_run_package_worker() {
        printf '0\t0\t0\t0\t0\t1\n' >"$2"
    }

    # What: worker result records simulate two independently missing packages.
    # Why: this isolates parent-side concurrency aggregation and the systemic
    # 404 threshold from package-listing mechanics covered above.
    # From: Issue #1095.
    run --separate-stderr main
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 of 2 configured packages reported no GHCR package"* ]]
    [[ "$output" == *"One or more package-version listings, manifest fetches, or deletions failed"* ]]
}

@test "process_service: a manifest-fetch failure disables orphan classification for that service (fails closed)" {
    # What: index_digest/plat_a declared/assigned separately (SC2155).
    # Why: same reasoning as the earlier test in this file.
    # From: Issue #1095 | PR #1443
    local index_digest plat_a
    index_digest="sha256:$(printf '5%.0s' {1..64})"
    plat_a="sha256:$(printf '6%.0s' {1..64})"

    # What: GHCR_RETRY_BACKOFF_SECONDS=0 forces instant retries.
    # Why: this test asserts on ghcr_retry exhausting its attempts, not on the
    # real backoff delay.
    # From: Issue #1095 | PR #1443
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
        # What: every manifest fetch fails, simulating a registry outage/rate
        # limit.
        # Why: exercises the had_errors fail-closed path for a Pass-1
        # manifest-fetch failure.
        # From: Issue #1095 | PR #1443
        echo "simulated registry failure" >&2
        return 1
    }
    export -f curl

    process_service proxy

    # What: zero deletions -- specifically zero orphan deletions, since Pass 2
    # never runs once orphan_phase_ok is disabled.
    # Why: the tagged index itself is kept for the pre-existing "protected"
    # (real source tag) reason, not anything this test exercises.
    # From: Issue #1095 | PR #1443
    [ "$deleted" -eq 0 ]
    [ ! -s "$delete_log" ]
    [ "$had_errors" -eq 1 ]
}

# What: the next three tests cover required-evidence-unavailable cases
# (AG-VAL-001), distinct from the jq-read/manifest-fetch failures above.
# Why: the run must not exit 0 when required evidence was unavailable,
# though the fail-closed keep behavior itself is unchanged.
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
        # What: the candidate-manifest fetch fails here (simulated registry
        # outage).
        # Why: the untagged candidate has no Pass-1 children, so it must reach
        # Pass 2's own candidate-manifest fetch to be classified at all.
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

# What: $attested_orphan is untagged, not in $tagged_index's
# `.manifests[]`; its only protection is $attestation's own tag.
# Why: gcps_extract_manifest_children() only reads a manifest BODY, so
# it can never discover this tag-based convention on its own.
# From: Issue #1095 | PR #1443
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
        # What: tagged_index's and attestation's own manifest bodies are
        # plain, childless manifests -- neither mentions $attested_orphan.
        # Why: isolates this test to the tag-string association only, so a
        # pass proves that parsing, not the `.manifests[]`/`.subject` path.
        # From: Issue #1095 | PR #1443
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
# What: pr_lookup_failures threshold coverage -- a systemic PR-lookup
# failure must not produce a healthy-looking "GC complete" summary.
# Why: a pervasive lookup failure (e.g. GHCR_PACKAGE_DELETE_PAT losing its
# pulls-API scope) is a real, previously-unguarded failure shape.
# From: Issue #1095 | PR #1443
# ---------------------------------------------------------------------------

@test "process_service: pervasive PR-lookup failures are counted and cross the threshold into a hard failure" {
    # What: max_pr_lookup_failures is reassigned directly as a plain script
    # variable, not via GC_MAX_PR_LOOKUP_FAILURES.
    # Why: setup() already sourced the script, evaluating the env-var default
    # once at source time -- overriding the env var now would have no effect.
    # From: Issue #1095 | PR #1443
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
        # What: simulates GHCR_PACKAGE_DELETE_PAT lacking the
        # `repo`/`public_repo` scope its pulls lookups need (a real HTTP 403,
        # never a 404).
        # Why: every single tagged version's PR-state lookup fails this way.
        # From: Issue #1095 | PR #1443
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
        # Why: this test is about the PR-lookup threshold, not manifest-graph
        # classification.
        # From: Issue #1095 | PR #1443
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
        return 0
    }
    export -f curl

    process_service proxy

    # What: all 3 versions kept (an ambiguous PR-state lookup is always safe on
    # its own).
    # Why: this is exactly the shape that must not read as a healthy,
    # unremarkable run once it happens this pervasively.
    # From: Issue #1095 | PR #1443
    [ "$deleted" -eq 0 ]
    [ "$kept" -eq 3 ]
    # shellcheck disable=SC2154 # set as a global by the sourced
    # process_service()
    [ "$pr_lookup_failures" -eq 3 ]
    [ "$pr_lookup_failures" -ge "$max_pr_lookup_failures" ]
}

@test "main(): the same pervasive PR-lookup-failure scenario actually fails the whole run, not just the counter" {
    services=(proxy)
    gc_concurrency=1
    max_pr_lookup_failures=2
    GH_TOKEN="unused-but-required-by-main"
    gh() { :; }
    curl() { :; }
    export -f gh curl
    sra_manifest_packages() { :; }
    gc_resolve_retention_history_refs() { printf 'origin/current_dev\n'; }
    gc_run_package_worker() { printf '0\t0\t3\t0\t3\t0\n' >"$2"; }

    # What: a worker reports three fail-closed PR-state lookups to the parent.
    # Why: package concurrency must not lose the existing systemic-failure gate.
    # From: Issue #1095.
    run --separate-stderr main
    [ "$status" -eq 1 ]
    [[ "$output" == *"PR-state lookups failed this run (threshold: 2)"* ]]
    [[ "$output" == *"One or more package-version listings, manifest fetches, or deletions failed"* ]]
}

# What: a planned old sha root is deleted after exact live revalidation.
# Why: proves the new retention path reaches DELETE rather than remaining
# another protect-only report while preserving the existing age/manifest gates.
# From: Issue #1095.
@test "process_service: an over-budget sha root is deleted after live revalidation" {
    digest="sha256:$(printf 'a%.0s' {1..64})"
    retention_delete_candidates[42]="${digest}"$'\t'"sha-abcdef1"
    delete_log="$BATS_TEST_TMPDIR/retention-delete"
    : >"$delete_log"
    export delete_log

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            printf '[{"id":42,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-abcdef1"]}}}]\n' "$digest"
            return 0
        fi
        if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" ]]; then
            echo "$4" >>"$delete_log"
            return 0
        fi
        echo "unexpected gh call: $*" >&2
        return 1
    }
    export -f gh
    curl() {
        [[ "$*" == *"ghcr.io/token"* ]] && { printf '{"token":"faketoken"}\n'; return 0; }
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
    }
    export -f curl
    github_api_get_with_retry() {
        printf '[{"id":42,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-abcdef1"]}}}]\n' "$digest" \
          | jq '.[0]' >"$2"
    }

    process_service proxy
    [ "$deleted" -eq 1 ]
    [ -s "$delete_log" ]
}

# What: a newly-added protected channel tag invalidates an old retention plan.
# Why: immediate revalidation must fail closed if latest/nightly/release state
# changes while a long GC sweep is running.
# From: Issue #1095.
@test "process_service: changed tags after planning cancel retention deletion" {
    digest="sha256:$(printf 'b%.0s' {1..64})"
    retention_delete_candidates[43]="${digest}"$'\t'"sha-bcdef12"
    delete_log="$BATS_TEST_TMPDIR/retention-revalidation-delete"
    : >"$delete_log"
    export delete_log

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            printf '[{"id":43,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-bcdef12"]}}}]\n' "$digest"
            return 0
        fi
        if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" ]]; then
            echo "$4" >>"$delete_log"
            return 0
        fi
        return 1
    }
    export -f gh
    curl() {
        [[ "$*" == *"ghcr.io/token"* ]] && { printf '{"token":"faketoken"}\n'; return 0; }
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
    }
    export -f curl
    github_api_get_with_retry() {
        printf '[{"id":43,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-bcdef12","latest"]}}}]\n' "$digest" \
          | jq '.[0]' >"$2"
    }

    process_service proxy
    [ "$deleted" -eq 0 ]
    [ ! -s "$delete_log" ]
}

# What: two package workers run concurrently and their counters are aggregated.
# Why: background-shell state must not disappear under the exact strict shell
# options inherited when this test sourced the production script.
# From: Issue #1095.
@test "main(): bounded concurrent package workers preserve result counters" {
    services=(proxy dns)
    gc_concurrency=2
    GH_TOKEN="unused-but-required-by-main"
    gh() { :; }
    curl() { :; }
    export -f gh curl
    sra_manifest_packages() { :; }
    gc_resolve_retention_history_refs() { printf 'origin/current_dev\n'; }
    gc_run_package_worker() { printf '0\t1\t2\t0\t0\t0\n' >"$2"; }

    run --separate-stderr main
    [ "$status" -eq 0 ]
    [[ "$output" == *"deleted 2 version(s)"* ]]
    [[ "$output" == *"kept 4 classification(s)"* ]]
}

# What: transient GitHub DELETE failures use the shared bounded retry policy.
# Why: a temporary 5xx must not strand the whole retention backlog or create
# a false successful run with zero deletions.
# From: Issue #1095.
@test "package-version DELETE retries a transient failure and then succeeds" {
    GHCR_RETRY_BACKOFF_SECONDS=0
    GHCR_RETRY_MAX_ATTEMPTS=3
    attempt_log="$BATS_TEST_TMPDIR/delete-retry-attempts"
    printf '0\n' >"$attempt_log"
    export attempt_log
    gh() {
        local count
        count="$(cat "$attempt_log")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$attempt_log"
        if (( count == 1 )); then
            echo "gh: transient failure (HTTP 502)" >&2
            return 1
        fi
        return 0
    }
    export -f gh

    run ghcr_retry api.github.com "" "" -- gcps_delete_package_version_once "orgs/wiki-mod/packages/container/lancache-ng%2Fproxy/versions/42"
    [ "$status" -eq 0 ]
    [ "$(cat "$attempt_log")" -eq 2 ]
}

# What: a DELETE 404 is idempotent success and consumes no retry budget.
# Why: concurrent/manual cleanup may remove a planned version first; absence
# already satisfies the collector's intended end state.
# From: Issue #1095.
@test "package-version DELETE treats HTTP 404 as already absent" {
    attempt_log="$BATS_TEST_TMPDIR/delete-404-attempts"
    printf '0\n' >"$attempt_log"
    export attempt_log
    gh() {
        local count
        count="$(cat "$attempt_log")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$attempt_log"
        echo "gh: Package version not found. (HTTP 404)" >&2
        return 1
    }
    export -f gh

    run ghcr_retry api.github.com "" "" -- gcps_delete_package_version_once "orgs/wiki-mod/packages/container/lancache-ng%2Fproxy/versions/42"
    [ "$status" -eq 0 ]
    [ "$(cat "$attempt_log")" -eq 1 ]
}

# What: permanent non-rate-limit 4xx DELETE failures stop immediately.
# Why: bad permissions/requests cannot improve through retries and should
# preserve the remaining job budget for other diagnostic work.
# From: Issue #1095.
@test "package-version DELETE does not retry a permanent HTTP 403" {
    GHCR_RETRY_BACKOFF_SECONDS=0
    GHCR_RETRY_MAX_ATTEMPTS=4
    attempt_log="$BATS_TEST_TMPDIR/delete-403-attempts"
    printf '0\n' >"$attempt_log"
    export attempt_log
    gh() {
        local count
        count="$(cat "$attempt_log")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$attempt_log"
        echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2
        return 1
    }
    export -f gh

    run ghcr_retry api.github.com "" "" -- gcps_delete_package_version_once "orgs/wiki-mod/packages/container/lancache-ng%2Fproxy/versions/42"
    [ "$status" -eq "$GHCR_RETRY_PERMANENT_FAILURE_EXIT_CODE" ]
    [ "$(cat "$attempt_log")" -eq 1 ]
}

# What: the run-wide deletion cap is divided across workers before any work starts.
# Why: a large manual per-package cap must never multiply past the global
# destructive ceiling when several packages execute concurrently.
# From: Issue #1095.
@test "main(): run-wide deletion cap bounds the sum of package quotas" {
    services=(proxy dns watchdog)
    gc_concurrency=3
    max_deletions_per_service=500
    max_deletions_total=5
    GH_TOKEN="unused-but-required-by-main"
    quota_dir="$BATS_TEST_TMPDIR/gc-package-quotas"
    mkdir -p "$quota_dir"
    export quota_dir
    gh() { :; }
    curl() { :; }
    export -f gh curl
    sra_manifest_packages() { :; }
    gc_resolve_retention_history_refs() { printf 'origin/current_dev\n'; }
    gc_run_package_worker() {
        printf '%s\n' "$3" >"$quota_dir/$1"
        printf '0\t0\t0\t0\t0\t0\n' >"$2"
    }

    run --separate-stderr main
    [ "$status" -eq 0 ]
    quota_sum="$(awk '{ sum += $1 } END { print sum + 0 }' "$quota_dir"/*)"
    [ "$quota_sum" -eq 5 ]
    quota_set="$(sort -n "$quota_dir"/*)"
    [ "$quota_set" = $'1\n2\n2' ]
}

# What: automatic history discovery includes every supported producer-branch shape.
# Why: release/hotfix SHA roots must age out by the same shared count policy
# instead of becoming immortal merely because they are outside current_dev.
# From: Issue #1095.
@test "retention history discovery includes current_dev master release and v branches" {
    test_repo="$BATS_TEST_TMPDIR/history-ref-repo"
    git init -q "$test_repo"
    git -C "$test_repo" config user.name "GC Test"
    git -C "$test_repo" config user.email "gc-test@example.invalid"
    printf 'base\n' >"$test_repo/file"
    git -C "$test_repo" add file
    git -C "$test_repo" commit -qm base
    git -C "$test_repo" update-ref refs/remotes/origin/current_dev HEAD
    git -C "$test_repo" update-ref refs/remotes/origin/master HEAD
    git -C "$test_repo" update-ref refs/remotes/origin/release/1.2 HEAD
    git -C "$test_repo" update-ref refs/remotes/origin/v1.2 HEAD

    repo_root="$test_repo"
    GC_RETENTION_HISTORY_REFS=""
    run gc_resolve_retention_history_refs
    [ "$status" -eq 0 ]
    [[ " $output " == *" origin/current_dev "* ]]
    [[ " $output " == *" origin/master "* ]]
    [[ " $output " == *" origin/release/1.2 "* ]]
    [[ " $output " == *" origin/v1.2 "* ]]
}

# What: a root that survives live revalidation still protects shared closure.
# Why: a child digest referenced by both a deleted root and a retained root
# must never be removed merely because the first root was successfully reaped.
# From: Issue #1095.
@test "process_service: retained root protects a child digest shared with a deleted retention root" {
    root_a="sha256:$(printf 'a%.0s' {1..64})"
    root_b="sha256:$(printf 'b%.0s' {1..64})"
    child="sha256:$(printf 'c%.0s' {1..64})"
    retention_delete_candidates[51]="${root_a}"$'\t'"sha-aaaaaaa"
    retention_delete_candidates[52]="${root_b}"$'\t'"sha-bbbbbbb"
    delete_log="$BATS_TEST_TMPDIR/shared-child-delete"
    : >"$delete_log"
    export delete_log

    gh() {
        if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
            printf '[{"id":51,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-aaaaaaa"]}}},{"id":52,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-bbbbbbb"]}}},{"id":53,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-aaaaaaa-amd64"]}}}]\n' "$root_a" "$root_b" "$child"
            return 0
        fi
        if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" ]]; then
            echo "$4" >>"$delete_log"
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
        if [[ "$args" == *"manifests/$root_a"* || "$args" == *"manifests/$root_b"* ]]; then
            printf '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":"%s"}]}\n' "$child"
            return 0
        fi
        if [[ "$args" == *"manifests/$child"* ]]; then
            printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
            return 0
        fi
        echo "unexpected curl call: $args" >&2
        return 1
    }
    export -f curl

    github_api_get_with_retry() {
        if [[ "$1" == */versions/51 ]]; then
            printf '{"id":51,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["sha-aaaaaaa"]}}}\n' "$root_a" >"$2"
            return 0
        fi
        if [[ "$1" == */versions/52 ]]; then
            printf '{"id":52,"name":"%s","created_at":"2020-01-01T00:00:00Z","metadata":{"container":{"tags":["latest","sha-bbbbbbb"]}}}\n' "$root_b" >"$2"
            return 0
        fi
        echo "unexpected revalidation URL: $1" >&2
        return 1
    }

    process_service proxy

    [ "$deleted" -eq 1 ]
    [ "$(wc -l <"$delete_log")" -eq 1 ]
    grep -F '/versions/51' "$delete_log"
    ! grep -F '/versions/53' "$delete_log"
}

# ---------------------------------------------------------------------------
# Sparse-checkout restore step
# ---------------------------------------------------------------------------
# What: regresses the workflow's sparse-checkout-restore step; a throwaway
# local `git init` repo reproduces the same git plumbing, no network needed.
# Why: `sparse-checkout disable` doesn't reliably clear on self-hosted
# runners, which reuse one working directory across unrelated jobs.
# From: Issue #1095 | PR #1492

# setup_sparse_checkout_fixture
# What: called as the first line of every test in this group, not via the
# file-wide setup() above; populates test_repo/restore_script.
# Why: this suite's fixture shares no logic with the classification
# suite's setup(), so it stays separate.
# From: Issue #1557 | PR #1559
setup_sparse_checkout_fixture() {
    if ! command -v git >/dev/null 2>&1; then
        skip "git not available"
    fi

    test_repo="$(mktemp -d)"
    git -C "$test_repo" init --quiet --initial-branch=main
    git -C "$test_repo" config user.email "test@example.invalid"
    git -C "$test_repo" config user.name "Test"

    # What: a handful of tracked files standing in for the real tree -- two
    # inside the workflow's narrow checkout set, two representing the rest.
    # Why: a later, unrelated job's checkout step needs the "everything
    # else" files to still be reachable after the restore.
    # From: Issue #1095 | PR #1492
    mkdir -p "$test_repo/scripts/lib" "$test_repo/.github/actions/some-action"
    echo "narrow-a" >"$test_repo/scripts/narrow-a.sh"
    echo "narrow-b" >"$test_repo/scripts/lib/narrow-b.sh"
    echo "outside-a" >"$test_repo/README.md"
    echo "outside-b" >"$test_repo/.github/actions/some-action/action.yml"
    git -C "$test_repo" add -A
    git -C "$test_repo" commit --quiet -m "seed"

    # What: mirrors the workflow's restore step, extracted into an
    # external script rather than a bash function in this test file.
    # Why: bats' `run` doesn't reliably preserve `set -e` semantics for an
    # in-file function.
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

# What: sweeps remaining skip-worktree bits directly; captures
# `git ls-files -v` before piping to awk, not a direct pipe.
# Why: a direct pipe would hide a real git failure behind awk's
# own unrelated exit code, defeating `set -e`.
# From: Issue #1095 | PR #1492
ls_files_before="$(git ls-files -v)"
mapfile -t remaining_skip_worktree < <(printf '%s\n' "$ls_files_before" | awk '/^S /{print substr($0,3)}')
if [ "${#remaining_skip_worktree[@]}" -gt 0 ]; then
  git update-index --no-skip-worktree -- "${remaining_skip_worktree[@]}"
fi
git checkout --progress --force HEAD -- .

# What: verifies the restore worked, failing loudly if any path
# is still excluded, instead of trusting the commands above.
# Why: counts with awk (not `grep -c`) so a zero-match needs no
# `|| true` -- that would make `-ne 0` a silent no-op under `set -e`.
# From: Issue #1095 | PR #1492
ls_files_after="$(git ls-files -v)"
remaining_after="$(printf '%s\n' "$ls_files_after" | awk '/^S /{c++} END{print c+0}')"
if [ "$remaining_after" -ne 0 ]; then
  echo "::error::${remaining_after} path(s) still carry the skip-worktree bit after the restore sequence" >&2
  exit 1
fi
RESTORE_SCRIPT
}

# narrow_via_legacy_manual_append
# What: mirrors actions/checkout's sparseCheckoutNonConeMode() -- a raw
# append to .git/info/sparse-checkout, never `git sparse-checkout set`.
# Why: the exact setup path `sparse-checkout-cone-mode: false` selects.
# From: Issue #1095 | PR #1492
narrow_via_legacy_manual_append() {
    git -C "$test_repo" config core.sparseCheckout true
    printf '\nscripts/narrow-a.sh\nscripts/lib/narrow-b.sh\n' >>"$test_repo/.git/info/sparse-checkout"
    git -C "$test_repo" checkout --progress --force HEAD >/dev/null 2>&1
}

# run_workflow_restore_step <dir>
# What: runs the restore script (see setup_sparse_checkout_fixture()
# above) against <dir>.
# Why: <dir> is a real git repo for the recovery-path tests below, or a
# non-repo directory for the fail-closed test.
# From: Issue #1557 | PR #1559
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

    # What: `disable` reports success, but core.sparseCheckout was never
    # actually cleared.
    # Why: the one consistently-reproducible part of this failure; other
    # symptoms vary, so only this is asserted here.
    # From: Issue #1095 | PR #1492
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

    # What: core.sparseCheckout must genuinely be gone, not just report
    # success.
    # Why: a later job's checkout step never re-sets it, so a lingering true
    # would keep re-narrowing every future tree-changing operation.
    # From: Issue #1095 | PR #1492
    run git -C "$test_repo" config --local --get core.sparseCheckout
    [ "$status" -eq 1 ]

    run git -C "$test_repo" ls-files -v
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\nS '* ]]
    [[ "$output" != S\ * ]]
}

@test "the workflow's restore step's own sweep recovers a skip-worktree bit regardless of how it was set" {
    setup_sparse_checkout_fixture
    # What: sets a skip-worktree bit directly, not via the flaky
    # legacy-setup reproduction above.
    # Why: proves the sweep+assert logic itself is sound, independent of
    # whether `disable`/`init` succeed.
    # From: Issue #1095 | PR #1492
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
    # What: proves the shipped fail-closed behavior against a directory
    # that isn't a git repository at all.
    # Why: a `grep -c` count (unlike awk) could leave the count empty on
    # a git failure, making `-ne 0` a silently-skipped error under `set -e`.
    # From: Issue #1095 | PR #1492
    not_a_repo="$(mktemp -d)"
    run run_workflow_restore_step "$not_a_repo"
    [ "$status" -ne 0 ]
    rm -rf "$not_a_repo"
}
