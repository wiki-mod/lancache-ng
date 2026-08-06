#!/usr/bin/env bats
# SPDX-License-Identifier: AGPL-3.0-or-later
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Docker-free unit coverage for scripts/lib/gc-pr-staging-images.sh -- the
# manifest-graph classification functions scripts/gc-pr-staging-images.sh
# uses to fix the confirmed root cause (issue #1095) of
# .github/workflows/gc-pr-staging-images.yml never reaping the ~55% of this
# project's GHCR package versions that carry no tag at all (Buildx's own
# per-platform manifests and attestation/SBOM sub-manifests).
#
# Each case here regresses a specific way that classification could
# silently delete something still alive, per the real risk the maintainer's
# own technical review (recorded in this PR) identified before this file
# was written:
#   - an image-index's own `manifests[]` children (platform manifests AND
#     Buildx-embedded attestation/SBOM manifests) must all be collected --
#     missing even one would make a live platform manifest look orphaned
#   - a REFERRERS-API attestation (actions/attest, used by this project's
#     .github/actions/ghcr-attest-retry) is NEVER listed inside an index's
#     `manifests[]` -- it can only be found via its OWN manifest's `subject`
#     field, which is a structurally different case from the index case
#   - a version whose `.name` isn't a real digest must be rejected, not
#     silently compared as if it were one
#   - the 24h age gate must fail closed on an unparseable timestamp, not
#     treat it as "old enough"
#   - gcps_pr_lookup_state's OPEN/CLOSED/LOOKUP_FAILED tri-state (ported
#     from the pre-extraction workflow) must keep collapsing neither
#     direction: an ambiguous API failure is not "closed" (which is exactly
#     the bug #626 already had to fix once), and a real 404 is not
#     "ambiguous" (it would otherwise never reap a deleted PR's tags at all).
#   - a run where PR-state lookups fail pervasively (not just once) must
#     itself fail loudly (see the pr_lookup_failures tests near the bottom
#     of this file) rather than report a healthy-looking summary while the
#     closed-PR tagged-version reap path silently did far less real work
#     than it should have -- added while investigating a coordinator-raised
#     hypothesis for this project's one real historical scheduled run
#     (2026-08-02, 10 deleted/21919 kept); that specific run's own real
#     GitHub Actions log showed zero actual LOOKUP_FAILED occurrences,
#     ruling this out as ITS cause, but the failure mode itself is real and
#     was previously completely unguarded against for any future run.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # Sourcing scripts/gc-pr-staging-images.sh (rather than just its lib)
    # pulls in process_service() and every config variable it needs
    # (org/repo/services/max_deletions_per_service/min_age_seconds/
    # now_epoch/pr_state_cache/had_errors/deleted/kept) for the end-to-end
    # tests further down, without running main() -- the
    # `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard at that script's own
    # bottom only calls main() when the file is EXECUTED, never when
    # `source`d, which is exactly what makes it safe to source here without
    # a real GH_TOKEN or real gh/jq/curl/date binaries. Harmless for the
    # pure-function tests above this line too -- it re-sources
    # scripts/lib/gc-pr-staging-images.sh itself (idempotent function
    # redefinition) and just adds a few extra global variables they don't
    # otherwise use. No GH_TOKEN needs to be set for this: main()'s own
    # `: "${GH_TOKEN:?...}"` line is inside main()'s body, which the guard
    # never invokes here, so it is simply never evaluated during sourcing.
    source "$repo_root/scripts/gc-pr-staging-images.sh"
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
    # The referrers-API attestation shape: a single manifest (not an index)
    # that declares which other digest it is "about" via a top-level subject
    # field. This is the shape gcps_fetch_manifest's caller checks when
    # evaluating an about-to-delete orphan candidate for a live attestation.
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
    # Distinguishes "jq itself could not parse this" from "jq parsed it fine
    # and found no children" -- the caller treats a non-zero return here the
    # same as an outright manifest-fetch failure (abort orphan classification
    # for the whole service), which only works if this function actually
    # signals the difference instead of always returning success.
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
    # This is the exact bug this function's own header documents already
    # having been fixed once: a rate limit, auth hiccup, or network blip
    # must never be treated the same as a confirmed-closed PR.
    #
    # `run --separate-stderr`: this branch also writes a "::warning::" line
    # to stderr (see gcps_pr_lookup_state's own comment for why) -- without
    # separating streams, bats' default merged $output would contain both
    # that warning line and the real "LOOKUP_FAILED" answer, breaking a
    # plain equality check against $output.
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
    declare -A cache=()
    gcps_pr_lookup_state 55 wiki-mod/lancache-ng cache >/dev/null
    gcps_pr_lookup_state 55 wiki-mod/lancache-ng cache >/dev/null
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
    # Asking for only one media type risks the registry silently CONVERTING
    # an index into a single-platform manifest with no manifests[] at all --
    # this test regresses that specific misconfiguration, not just "curl was
    # called". See gcps_fetch_manifest's own header for the full reasoning.
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
# End-to-end: process_service() itself, against mocked gh/curl -- this is
# the case that actually proves the classification-gap fix, not just its
# individual pure-function pieces. Also exercises process_service() under
# this file's own `set -euo pipefail` (inherited from sourcing
# scripts/gc-pr-staging-images.sh in setup() above), per AG-VAL-030's
# requirement that a construct depending on the caller's shell options be
# proven under those exact options, not a looser test environment.
# ---------------------------------------------------------------------------

@test "process_service: an index's own platform+attestation children are protected, not deleted" {
    local index_digest="sha256:$(printf '1%.0s' {1..64})"
    local plat_a="sha256:$(printf '2%.0s' {1..64})"
    local plat_b="sha256:$(printf '3%.0s' {1..64})"
    local attest="sha256:$(printf '4%.0s' {1..64})"

    delete_log="$BATS_TEST_TMPDIR/deletes"
    : > "$delete_log"
    export delete_log

    # One tagged image index (a real, non-pr-* source tag -- e.g. what a
    # push-triggered build's own sha-<commit> tag looks like) plus its three
    # untagged children (two platform manifests and one Buildx-embedded
    # attestation manifest), all present as separate package versions --
    # exactly the shape a real multi-arch push produces. Before this PR, the
    # three untagged children were unconditionally kept (correct, but only
    # by accident: the old logic never even looked at them). This test
    # proves the NEW manifest-graph logic reaches the same safe answer
    # deliberately, by actually tracing the reference instead of never
    # asking the question.
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

    [ "$deleted" -eq 0 ]
    [ "$kept" -eq 4 ]
    [ "$had_errors" -eq 0 ]
    [ ! -s "$delete_log" ]
}

@test "process_service: a manifest-fetch failure disables orphan classification for that service (fails closed)" {
    local index_digest="sha256:$(printf '5%.0s' {1..64})"
    local plat_a="sha256:$(printf '6%.0s' {1..64})"

    # Instant retries -- this test asserts on ghcr_retry exhausting its
    # attempts, not on the real backoff delay.
    GHCR_RETRY_BACKOFF_SECONDS=0
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
        # Every manifest fetch fails -- simulates a registry outage/rate
        # limit hitting the NEW per-version manifest GET this PR adds.
        echo "simulated registry failure" >&2
        return 1
    }
    export -f curl

    process_service proxy

    # Zero deletions -- specifically zero ORPHAN deletions, since Pass 2
    # never runs at all once orphan_phase_ok is disabled. The tagged index
    # itself is also correctly kept, but for the pre-existing "protected"
    # reason (a real source tag), not because of anything this test is
    # exercising.
    [ "$deleted" -eq 0 ]
    [ ! -s "$delete_log" ]
    [ "$had_errors" -eq 1 ]
}

# ---------------------------------------------------------------------------
# pr_lookup_failures threshold -- added 2026-08-06 while investigating a
# coordinator-raised hypothesis for this project's one real historical
# scheduled run (2026-08-02, 10 deleted/21919 kept): could GHCR_PACKAGE_
# DELETE_PAT have been failing `gh api repos/.../pulls/<N>` calls en masse
# (missing scope, rate limit), silently keeping almost everything via the
# LOOKUP_FAILED->protected path rather than because those PRs were
# genuinely still open? Checked against that run's own real GitHub Actions
# log: zero actual LOOKUP_FAILED warnings were emitted during its real
# execution (only the workflow's own pre-run source-code echo contained
# that string) -- so that specific historical run was not affected. This
# threshold exists for a FUTURE occurrence of that different failure shape
# regardless: without it, a systemic PR-lookup failure would produce a
# healthy-looking "GC complete" summary with no signal anything was wrong.
# ---------------------------------------------------------------------------

@test "process_service: pervasive PR-lookup failures are counted and cross the threshold into a hard failure" {
    # max_pr_lookup_failures is a plain script variable, not read fresh from
    # GC_MAX_PR_LOOKUP_FAILURES per call -- setup() already sourced the
    # script (evaluating the env-var default once, at source time), so
    # overriding it here means reassigning the variable itself, not the
    # env var a fresh source would have read.
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
        # Simulates GHCR_PACKAGE_DELETE_PAT lacking the `repo`/`public_repo`
        # scope its pulls lookups need (a real HTTP 403, never a 404) --
        # every single tagged version's PR-state lookup fails this way.
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
        # A plain single-platform manifest for every fetch -- this test is
        # about the PR-lookup threshold, not the manifest-graph classification.
        printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}\n'
        return 0
    }
    export -f curl

    process_service proxy

    # All 3 versions kept (an ambiguous PR-state lookup is always safe on
    # its own), but this is exactly the shape that must not read as a
    # healthy, unremarkable run once it happens this pervasively.
    [ "$deleted" -eq 0 ]
    [ "$kept" -eq 3 ]
    [ "$pr_lookup_failures" -eq 3 ]
    # 3 >= the threshold of 2 configured above.
    [ "$pr_lookup_failures" -ge "$max_pr_lookup_failures" ]
}

@test "main(): the same pervasive PR-lookup-failure scenario actually fails the whole run, not just the counter" {
    # Restricts the sweep to one service so the expected count (3) is exact
    # and the test stays fast -- main()'s own `for service in
    # "${services[@]}"` loop would otherwise process all 8 real services
    # against the same mocked gh(), inflating the count to 24 for no
    # additional coverage value.
    services=(proxy)
    max_pr_lookup_failures=2
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

    # `run` forks a subshell, so main()'s own internal `exit 1` (it is
    # written as a real top-level entry point, not a function a caller
    # resumes after) terminates only that subshell -- this test's own
    # process survives to assert on the captured status/output, the same
    # way `run --separate-stderr` is used elsewhere in this project's bats
    # suites for a command that both writes diagnostics and controls its
    # own exit code.
    run --separate-stderr main
    [ "$status" -eq 1 ]
    [[ "$output" == *"PR-state lookups failed this run (threshold: 2)"* ]]
    [[ "$output" == *"One or more package-version listings, manifest fetches, or deletions failed"* ]]
}
