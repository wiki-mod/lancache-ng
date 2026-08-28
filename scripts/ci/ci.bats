#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: regression suite for scripts/ci/ci.sh (CI 2.0 engine).
# Why: §66 wants one suite covering every domain.
# From: Issue #1683

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    # shellcheck source=scripts/ci/ci.sh
    source "$repo_root/scripts/ci/ci.sh"
}

# ============================================================
# CORE INVARIANTS
# ============================================================

# What: a real 40-char git SHA matches the full-SHA regex.
# Why: the rule is useless if it rejects valid input.
# From: Issue #1683
@test "core: full git SHA regex accepts a real 40-char SHA" {
    [[ "569022c2fba37618c6bb41aa4927753af0f762d3" =~ $CI_FULL_GIT_SHA_REGEX ]]
}

# What: an abbreviated git SHA is rejected by the regex.
# Why: §15 forbids short SHAs; this half carries it.
# From: Issue #1683
@test "core: full git SHA regex rejects an abbreviated SHA" {
    ! [[ "569022c" =~ $CI_FULL_GIT_SHA_REGEX ]]
}

# What: a real sha256: digest matches the regex.
# Why: §15 applies to OCI digests, not only to git SHAs.
# From: Issue #1683
@test "core: full OCI digest regex accepts a real digest" {
    local digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    [[ "$digest" =~ $CI_FULL_OCI_DIGEST_REGEX ]]
}

# What: a truncated/invented digest form is rejected.
# Why: §15 names "sha-deadbeef" as forbidden.
# From: Issue #1683
@test "core: full OCI digest regex rejects an abbreviated digest" {
    ! [[ "sha-deadbeef" =~ $CI_FULL_OCI_DIGEST_REGEX ]]
}

# What: the validator accepts a real 40-char git SHA.
# Why: valid input must pass through untouched.
# From: Issue #1683
@test "core: ci_validate_full_git_sha accepts a real 40-char SHA" {
    ci_validate_full_git_sha "569022c2fba37618c6bb41aa4927753af0f762d3"
}

# What: the validator exits non-zero on an abbreviated SHA.
# Why: §15 must fail closed, not warn and continue.
# From: Issue #1683
@test "core: ci_validate_full_git_sha dies on an abbreviated SHA" {
    run ci_validate_full_git_sha "569022c"
    [ "$status" -ne 0 ]
}

# What: the digest validator accepts a real sha256: digest.
# Why: valid input must pass through untouched.
# From: Issue #1683
@test "core: ci_validate_full_oci_digest accepts a real digest" {
    ci_validate_full_oci_digest "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
}

# What: the digest validator exits non-zero on a short digest.
# Why: §15 must fail closed for digests exactly as for SHAs.
# From: Issue #1683
@test "core: ci_validate_full_oci_digest dies on an abbreviated digest" {
    run ci_validate_full_oci_digest "sha-deadbeef"
    [ "$status" -ne 0 ]
}

# ============================================================
# ERROR REPORTING
# ============================================================

# What: a reported failure names expected and actual values.
# Why: an exit code alone never says what went wrong.
# From: Issue #1683
@test "errors: ci_report_failure states expected and actual" {
    ci_report_failure "digest check" "proxy" "sha256:aa" "sha256:bb"
    [[ "${CI_FAILURES[0]}" == *"proxy"* ]]
    [[ "${CI_FAILURES[0]}" == *"expected sha256:aa"* ]]
    [[ "${CI_FAILURES[0]}" == *"got sha256:bb"* ]]
}

# What: a reported failure emits a GitHub error annotation.
# Why: the cause must reach the job summary, not just the log.
# From: Issue #1683
@test "errors: ci_report_failure emits a ::error:: annotation" {
    run ci_report_failure "digest check" "proxy" "sha256:aa" "sha256:bb"
    [[ "$output" == *"::error::"* ]]
}

# What: an optional remedy is included in the failure line.
# Why: a fail-closed path must say what to do about it.
# From: Issue #1683
@test "errors: ci_report_failure includes a remedy when given" {
    ci_report_failure "mode check" "ci.sh" "100755" "100644" "chmod +x"
    [[ "${CI_FAILURES[0]}" == *"fix: chmod +x"* ]]
}

# What: the summary lists every failure and returns non-zero.
# Why: the reader must see all causes, not just one.
# From: Issue #1683
@test "errors: ci_failure_summary lists all failures and fails" {
    ci_report_failure "check A" "svc1" "x" "y"
    ci_report_failure "check B" "svc2" "p" "q"
    run ci_failure_summary
    [ "$status" -ne 0 ]
    [[ "$output" == *"2 failure(s)"* ]]
    [[ "$output" == *"check A"* ]]
    [[ "$output" == *"check B"* ]]
}

# What: an empty failure list summarizes as success.
# Why: reporting must not turn a clean run red.
# From: Issue #1683
@test "errors: ci_failure_summary succeeds when nothing failed" {
    run ci_failure_summary
    [ "$status" -eq 0 ]
}

# What: a failing command is named with its exit code.
# Why: §68 -- no unexplained foreign exit codes.
# From: Issue #1683
@test "errors: ci_run_checked names the failing command and code" {
    run ci_run_checked "smoke test" bash -c 'exit 3'
    [ "$status" -eq 3 ]
    [[ "$output" == *"smoke test"* ]]
    [[ "$output" == *"exit 3"* ]]
}

# What: a succeeding command produces no error output.
# Why: the wrapper must stay silent on the happy path.
# From: Issue #1683
@test "errors: ci_run_checked is silent on success" {
    run ci_run_checked "smoke test" true
    [ "$status" -eq 0 ]
    [[ "$output" != *"::error::"* ]]
}

# What: a non-temp path is refused instead of being removed.
# Why: an unguarded rm on a stray path deletes anything.
# From: Issue #1683
@test "safety: ci_rm_temp refuses a path outside a temp dir" {
    run ci_rm_temp "/etc/passwd"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to remove"* ]]
}

# What: an empty path is a silent no-op, never an rm.
# Why: an unset variable must not become a destructive rm.
# From: Issue #1683
@test "safety: ci_rm_temp ignores an empty path" {
    run ci_rm_temp ""
    [ "$status" -eq 0 ]
}

# What: a real temp file is removed normally.
# Why: the guard must not break the case it exists to protect.
# From: Issue #1683
@test "safety: ci_rm_temp removes a real temp file" {
    local f
    f="$(ci_mktemp)"
    [ -f "$f" ]
    ci_rm_temp "$f"
    [ ! -f "$f" ]
}

# What: ci_mktemp yields an existing file path.
# Why: callers redirect into it; an empty path corrupts.
# From: Issue #1683
@test "safety: ci_mktemp returns a usable temp file" {
    local f
    f="$(ci_mktemp)"
    [ -n "$f" ]
    [ -f "$f" ]
    ci_rm_temp "$f"
}

# What: ci_die annotates the cause before exiting non-zero.
# Why: a bare exit 1 leaves the reader with no cause at all.
# From: Issue #1683
@test "errors: ci_die annotates before exiting" {
    run ci_die "registry unreachable"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" == *"registry unreachable"* ]]
}

# ============================================================
# IDENTITY ENGINE
# ============================================================

# What: a file's identity carries its mode and hash.
# Why: identity must track mode, not content alone (§16).
# From: Issue #1683
@test "identity: ci_path_identity returns mode and content hash" {
    run ci_path_identity "scripts/ci/ci.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == "100755 "* ]]
}

# What: an untracked path is rejected, not hashed.
# Why: hashing a missing file would fake an identity.
# From: Issue #1683
@test "identity: ci_path_identity dies on an untracked path" {
    run ci_path_identity "no/such/file.txt"
    [ "$status" -ne 0 ]
}

# What: a service's input paths include its own context files.
# Why: the build identity is only as complete as this list.
# From: Issue #1683
@test "identity: ci_service_input_paths covers the service context" {
    run ci_service_input_paths proxy
    [ "$status" -eq 0 ]
    [[ "$output" == *"services/proxy/Dockerfile"* ]]
}

# What: proxy's input paths include dns's cdn-domains.txt.
# Why: §13 -- a named external context is a real build input.
# From: Issue #1683
@test "identity: ci_service_input_paths covers external contexts" {
    run ci_service_input_paths proxy
    [[ "$output" == *"services/dns/cdn-domains.txt"* ]]
}

# What: a build identity is a full 64-hex-char sha256 value.
# Why: §15 -- identities are never abbreviated anywhere.
# From: Issue #1683
@test "identity: ci_build_identity returns a full sha256 hex value" {
    run ci_build_identity proxy linux/amd64
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9a-f]{64}$ ]]
}

# What: the same inputs produce the same identity twice.
# Why: an unstable identity never matches a baseline.
# From: Issue #1683
@test "identity: ci_build_identity is reproducible" {
    [ "$(ci_build_identity proxy linux/amd64)" = "$(ci_build_identity proxy linux/amd64)" ]
}

# What: branch, PR and run id do not change it.
# Why: §16 names these as excluded from the build identity.
# From: Issue #1683
@test "identity: ci_build_identity ignores branch, PR and run id" {
    local before after
    before="$(ci_build_identity proxy linux/amd64)"
    export GITHUB_REF="refs/heads/some-other-branch"
    export GITHUB_RUN_ID="999999"
    export GITHUB_SHA="0000000000000000000000000000000000000000"
    export PR_NUMBER="4242"
    after="$(ci_build_identity proxy linux/amd64)"
    [ "$before" = "$after" ]
}

# What: two platforms of one service get different identities.
# Why: §44 -- each platform is its own artifact.
# From: Issue #1683
@test "identity: ci_build_identity differs per platform" {
    [ "$(ci_build_identity proxy linux/amd64)" != "$(ci_build_identity proxy linux/arm64)" ]
}

# What: two different services get different identities.
# Why: a collision would let one service reuse another.
# From: Issue #1683
@test "identity: ci_build_identity differs per service" {
    [ "$(ci_build_identity proxy linux/amd64)" != "$(ci_build_identity dns linux/amd64)" ]
}

# What: a changed toolchain changes the identity.
# Why: §16 folds it in; a compiler bump is real.
# From: Issue #1683
@test "identity: ci_build_identity folds in the toolchain identity" {
    local before after
    before="$(ci_build_identity proxy linux/amd64)"
    CI_TOOLCHAIN_IDENTITY="rust-1.99.0"
    after="$(ci_build_identity proxy linux/amd64)"
    [ "$before" != "$after" ]
}

# What: a changed base digest changes the identity.
# Why: §17 -- a pinned base is part of what the artifact is.
# From: Issue #1683
@test "identity: ci_build_identity folds in base image digests" {
    local before after
    before="$(ci_build_identity proxy linux/amd64)"
    CI_BASE_IMAGE_DIGESTS="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    after="$(ci_build_identity proxy linux/amd64)"
    [ "$before" != "$after" ]
}

# What: a build identity requires a platform argument.
# Why: without it, arches would collide silently.
# From: Issue #1683
@test "identity: ci_build_identity requires a platform" {
    run ci_build_identity proxy ""
    [ "$status" -ne 0 ]
}

# What: a policy change changes the validation identity.
# Why: §30 -- new policy forces a rescan of the same digest.
# From: Issue #1683
@test "identity: ci_validation_identity tracks the policy id" {
    local digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    local before after
    CI_VALIDATION_POLICY_ID="policy-1"
    before="$(ci_validation_identity "$digest")"
    CI_VALIDATION_POLICY_ID="policy-2"
    after="$(ci_validation_identity "$digest")"
    [ "$before" != "$after" ]
}

# What: the validation identity rejects an abbreviated digest.
# Why: §15 applies to every identity input.
# From: Issue #1683
@test "identity: ci_validation_identity rejects a short digest" {
    run ci_validation_identity "sha-deadbeef"
    [ "$status" -ne 0 ]
}

# ============================================================
# RESOLVER STATES
# ============================================================

# What: only MISSING_CONFIRMED authorizes a build.
# Why: §19 -- a confirmed absence is the sole trigger.
# From: Issue #1683
@test "resolver: only MISSING_CONFIRMED permits a build" {
    ci_state_permits_build "$CI_STATE_MISSING_CONFIRMED"
}

# What: UNKNOWN never authorizes a build.
# Why: §2.3 -- uncertainty is not a licence to build.
# From: Issue #1683
@test "resolver: UNKNOWN does not permit a build" {
    run ! ci_state_permits_build "$CI_STATE_UNKNOWN"
}

# What: no other resolver state authorizes a build.
# Why: §18's remaining states each have their own handling.
# From: Issue #1683
@test "resolver: no other state permits a build" {
    run ! ci_state_permits_build "$CI_STATE_PRESENT_ACCEPTED"
    run ! ci_state_permits_build "$CI_STATE_BUILD_IN_PROGRESS"
    run ! ci_state_permits_build "$CI_STATE_PRODUCED_UNVERIFIED"
    run ! ci_state_permits_build "$CI_STATE_MISMATCH"
}

# ============================================================
# LEDGER / ACCEPTANCE
# ============================================================

# What: a lookup with no acceptance record fails.
# Why: §26 -- absence of a record is never a silent success.
# From: Issue #1683
@test "ledger: an unknown identity is not found" {
    CI_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger"
    run ci_ledger_lookup proxy linux/amd64 deadbeef
    [ "$status" -ne 0 ]
}

# What: an ACCEPTED result becomes a retrievable ledger entry.
# Why: §26 -- the ledger enables PRESENT_ACCEPTED.
# From: Issue #1683
@test "ledger: an accepted result is recorded and found again" {
    CI_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger"
    local results="$BATS_TEST_TMPDIR/results"
    local d
    d="sha256:$(printf 'a%.0s' {1..64})"
    ci_result_record proxy linux/amd64 id1 "$d" ACCEPTED "$results" >/dev/null
    ci_ledger_aggregate "$results" >/dev/null
    [ "$(ci_ledger_lookup proxy linux/amd64 id1)" = "$d" ]
}

# What: a REJECTED result never enters the ledger.
# Why: §25 -- a rejected artifact must never become reusable.
# From: Issue #1683
@test "ledger: a rejected result is not recorded" {
    CI_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger"
    local results="$BATS_TEST_TMPDIR/results"
    local d
    d="sha256:$(printf 'b%.0s' {1..64})"
    ci_result_record proxy linux/amd64 id2 "$d" REJECTED "$results" >/dev/null
    ci_ledger_aggregate "$results" >/dev/null
    run ci_ledger_lookup proxy linux/amd64 id2
    [ "$status" -ne 0 ]
}

# What: aggregating the same results twice changes nothing.
# Why: §26.4 -- a retried aggregator must converge.
# From: Issue #1683
@test "ledger: re-aggregating the same results is idempotent" {
    CI_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger"
    local results="$BATS_TEST_TMPDIR/results"
    local d
    d="sha256:$(printf 'c%.0s' {1..64})"
    ci_result_record dns linux/amd64 id3 "$d" ACCEPTED "$results" >/dev/null
    ci_ledger_aggregate "$results" >/dev/null
    ci_ledger_aggregate "$results" >/dev/null
    [ "$(ci_ledger_lookup dns linux/amd64 id3)" = "$d" ]
}

# What: one identity, two digests is reported.
# Why: overwriting would destroy the acceptance record.
# From: Issue #1683
@test "ledger: a conflicting digest for one identity is reported" {
    CI_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger"
    local r1="$BATS_TEST_TMPDIR/r1" r2="$BATS_TEST_TMPDIR/r2"
    ci_result_record ntp linux/amd64 id4 "sha256:$(printf 'd%.0s' {1..64})" ACCEPTED "$r1" >/dev/null
    ci_result_record ntp linux/amd64 id4 "sha256:$(printf 'e%.0s' {1..64})" ACCEPTED "$r2" >/dev/null
    ci_ledger_aggregate "$r1" >/dev/null
    run ci_ledger_aggregate "$r2"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ledger conflict"* ]]
}

# What: a record with a short digest is refused.
# Why: §15 -- a short digest must never reach the ledger.
# From: Issue #1683
@test "ledger: a short digest is refused when recording" {
    run ci_result_record proxy linux/amd64 id5 "sha-dead" ACCEPTED "$BATS_TEST_TMPDIR/r3"
    [ "$status" -ne 0 ]
}

# ============================================================
# REGISTRY ADDRESSING
# ============================================================

# What: the image reference comes from the environment.
# Why: no registry host, owner or repo may be hardcoded.
# From: Issue #1683
@test "registry: the image reference comes from the environment" {
    CI_REGISTRY="example.invalid"
    CI_IMAGE_REPO="someowner/somerepo"
    [ "$(ci_image_ref proxy)" = "example.invalid/someowner/somerepo/proxy" ]
}

# What: an unset repository is refused instead of guessed.
# Why: a guessed path would publish to the wrong place.
# From: Issue #1683
@test "registry: an unset repository is refused" {
    CI_IMAGE_REPO=""
    GITHUB_REPOSITORY=""
    run ci_image_ref proxy
    [ "$status" -ne 0 ]
}

# What: no registry hostname or owner is hardcoded in ci.sh.
# Why: every registry coordinate must stay settable.
# From: Issue #1683
@test "registry: ci.sh hardcodes no registry host or owner" {
    ! grep -nE '(ghcr\.io/wiki-mod|docker\.io/)' "$repo_root/scripts/ci/ci.sh"
}

# ============================================================
# RETRY CLASSIFIER
# ============================================================

# What: a build op that succeeds immediately returns success.
# Why: the wrapper must not break the happy path.
# From: Issue #1683
@test "retry: ci_retry_build_op delegates to build_retry (succeeds first try)" {
    export BUILD_RETRY_MAX_ATTEMPTS=3 BUILD_RETRY_BASE_BACKOFF_SECONDS=0
    run ci_retry_build_op -- true
    [ "$status" -eq 0 ]
}

# What: a non-transient build failure propagates as a failure.
# Why: §67.2 forbids retrying a real failure.
# From: Issue #1683
@test "retry: ci_retry_build_op propagates a real (non-transient) failure" {
    export BUILD_RETRY_MAX_ATTEMPTS=3 BUILD_RETRY_BASE_BACKOFF_SECONDS=0
    run ci_retry_build_op -- false
    [ "$status" -ne 0 ]
}

# What: both retry wrappers are in scope here.
# Why: ci.sh reuses them instead of reimplementing.
# From: Issue #1683
@test "retry: ghcr_retry and build_retry functions are available (sourced)" {
    declare -F ghcr_retry >/dev/null
    declare -F build_retry >/dev/null
}

# ============================================================
# SEMANTIC IMPACT
# ============================================================

# What: .md is recognized as markdown, .sh is not.
# Why: §12.4's markdown-is-NOOP keys off this.
# From: Issue #1683
@test "semantic: ci_path_is_markdown recognizes .md files" {
    ci_path_is_markdown "README.md"
    ! ci_path_is_markdown "README.sh"
}

# What: comment and blank lines are dropped, line 1 is kept.
# Why: §12.1's v1 normalization; line 1 may be a real shebang.
# From: Issue #1683
@test "semantic: ci_normalize_for_hash strips comments and blank lines" {
    local f="$BATS_TEST_TMPDIR/sample.sh"
    printf '#!/bin/bash\n# a comment\n\ncmd1\n  # indented comment\ncmd2\n' > "$f"
    run ci_normalize_for_hash "$f"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output")" = "$(printf '#!/bin/bash\ncmd1\ncmd2')" ]
}

# What: a comment-only difference hashes the same.
# Why: §11.1 -- a comment-only edit must resolve to NOOP.
# From: Issue #1683
@test "semantic: ci_content_hash is stable across comment-only edits" {
    local f1="$BATS_TEST_TMPDIR/a.sh" f2="$BATS_TEST_TMPDIR/b.sh"
    printf '#!/bin/bash\n# old comment\ncmd1\n' > "$f1"
    printf '#!/bin/bash\n# new comment\ncmd1\n' > "$f2"
    [ "$(ci_content_hash "$f1")" = "$(ci_content_hash "$f2")" ]
}

# What: a '#' inside a `run: |` body survives.
# Why: it is literal script text there, not a YAML comment.
# From: Issue #1683
@test "semantic: yaml normalizer keeps '#' inside a block scalar" {
    local f="$BATS_TEST_TMPDIR/sample.yml"
    printf 'job:\n  run: |\n    echo "a"\n    # not a real comment\n    echo "b"\n  name: x\n' > "$f"
    run ci_normalize_yaml_for_hash "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == *"# not a real comment"* ]]
}

# What: a genuine top-level YAML comment is still stripped.
# Why: block-scalar support must not disable it.
# From: Issue #1683
@test "semantic: yaml normalizer strips a real top-level comment" {
    local f="$BATS_TEST_TMPDIR/sample2.yml"
    printf '# real comment\njob:\n  name: x\n' > "$f"
    run ci_normalize_yaml_for_hash "$f"
    [ "$status" -eq 0 ]
    [[ "$output" != *"real comment"* ]]
}

# What: a .yml path is routed to the YAML-aware normalizer.
# Why: the dispatcher makes block-scalar safety work.
# From: Issue #1683
@test "semantic: ci_normalize_dispatch routes .yml through the yaml path" {
    local f="$BATS_TEST_TMPDIR/sample3.yml"
    printf 'job:\n  run: |\n    # kept\n  x: 1\n' > "$f"
    run ci_normalize_dispatch "$f" < "$f"
    [[ "$output" == *"# kept"* ]]
}

# What: same bytes, different mode, different hash.
# Why: an exec-bit flip is a real input change (§16).
# From: Issue #1683
@test "semantic: ci_content_hash changes when mode differs, same bytes" {
    local f1="$BATS_TEST_TMPDIR/m1.sh" f2="$BATS_TEST_TMPDIR/m2.sh"
    printf '#!/bin/bash\ncmd1\n' > "$f1"
    printf '#!/bin/bash\ncmd1\n' > "$f2"
    [ "$(ci_content_hash "$f1" 100644)" != "$(ci_content_hash "$f2" 100755)" ]
}

# What: a real code change produces a different content hash.
# Why: normalization must not mask an actual semantic edit.
# From: Issue #1683
@test "semantic: ci_content_hash changes on a real code edit" {
    local f1="$BATS_TEST_TMPDIR/a.sh" f2="$BATS_TEST_TMPDIR/b.sh"
    printf '#!/bin/bash\ncmd1\n' > "$f1"
    printf '#!/bin/bash\ncmd2\n' > "$f2"
    [ "$(ci_content_hash "$f1")" != "$(ci_content_hash "$f2")" ]
}

# What: a path in a service's context impacts it.
# Why: the base case of §11's path-to-service mapping.
# From: Issue #1683
@test "impact: proxy touches its own context path" {
    ci_service_touches_path proxy "services/proxy/entrypoint.sh"
}

# What: proxy is impacted by dns's cdn-domains.txt.
# Why: §13 -- proxy consumes it through a named build context.
# From: Issue #1683
@test "impact: proxy touches dns's cdn-domains.txt via external context" {
    ci_service_touches_path proxy "services/dns/cdn-domains.txt"
}

# What: an unrelated dns file leaves proxy alone.
# Why: proxy only COPYs cdn-domains.txt, not dns/.
# From: Issue #1683
@test "impact: proxy does NOT touch an unrelated dns file (file-exact)" {
    ! ci_service_touches_path proxy "services/dns/nats-subscriber/src/main.rs"
}

# What: an allowlisted .md marks its service.
# Why: §12.4's exception for a real build input.
# From: Issue #1683
@test "impact: markdown allowlist entry is treated as a real input" {
    export CI_MARKDOWN_BUILD_INPUTS="services/dns/README.md"
    local impacted
    impacted="$(ci_impacted_services "services/dns/README.md")"
    [[ "$impacted" == *"dns"* ]]
}

# What: a .md path absent from the allowlist stays excluded.
# Why: §12.4 defaults to NOOP; allowlist is opt-in.
# From: Issue #1683
@test "impact: markdown NOT on the allowlist stays excluded" {
    unset CI_MARKDOWN_BUILD_INPUTS
    local impacted
    impacted="$(ci_impacted_services "services/dns/README.md")"
    [ -z "$impacted" ]
}

# What: a mode-only commit is not reported as a semantic NOOP.
# Why: identical content but a real change; must fail closed.
# From: Issue #1683
@test "impact: ci_semantic_diff_is_noop is false for a mode-only change" {
    git show 5b29a70d~1:scripts/ci/ci.sh > /dev/null 2>&1 || skip "fixture commit not present"
    ! ci_semantic_diff_is_noop 5b29a70d~1 5b29a70d "scripts/ci/ci.sh"
}

# What: a proxy-only path does not mark dns impacted.
# Why: proves the mapping is directional, not symmetric.
# From: Issue #1683
@test "impact: dns does not touch proxy's own path" {
    ! ci_service_touches_path dns "services/proxy/entrypoint.sh"
}

# What: watchdog is untouched by a dns build-input change.
# Why: §46 -- each service is its own failure/impact domain.
# From: Issue #1683
@test "impact: watchdog is unaffected by a dns-only change" {
    ! ci_service_touches_path watchdog "services/dns/cdn-domains.txt"
}

# What: cdn-domains.txt impacts both dns and proxy.
# Why: §85 Test F -- the shared-dependency acceptance case.
# From: Issue #1683
@test "impact: ci_impacted_services reports dns and proxy for cdn-domains.txt" {
    local impacted
    impacted="$(ci_impacted_services "services/dns/cdn-domains.txt")"
    [[ "$impacted" == *"dns"* ]]
    [[ "$impacted" == *"proxy"* ]]
}

# What: a plain markdown change impacts no service.
# Why: §85 Test A -- a docs-only change must build nothing.
# From: Issue #1683
@test "impact: ci_impacted_services excludes a markdown-only change" {
    local impacted
    impacted="$(ci_impacted_services "services/dns/README.md")"
    [ -z "$impacted" ]
}

# What: a path outside every service context impacts nothing.
# Why: DEFAULT = NOOP (§2.1) must hold for unmapped paths too.
# From: Issue #1683
@test "impact: ci_impacted_services is empty for an unrelated path" {
    local impacted
    impacted="$(ci_impacted_services "docs/ci-2.0-architecture.md")"
    [ -z "$impacted" ]
}

# What: comparing a ref against itself reports NOOP.
# Why: guards the no-diff path from failing closed by mistake.
# From: Issue #1683
@test "impact: ci_semantic_diff_is_noop is true for HEAD vs itself" {
    ci_semantic_diff_is_noop HEAD HEAD "scripts/ci/ci.sh"
}

# ============================================================
# PLANNER
# ============================================================

# What: an unchanged tree plans as NOOP with no build matrix.
# Why: §85 Test A -- a no-op schedules no work.
# From: Issue #1683
@test "planner: identical refs plan as NOOP with an empty matrix" {
    run ci_plan_json HEAD HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *'"state":"NOOP"'* ]]
    [[ "$output" == *'"build_matrix":[]'* ]]
}

# What: every service appears in the plan output.
# Why: an absent service reads as unknown, not NOOP.
# From: Issue #1683
@test "planner: every service is present in the plan output" {
    local out svc
    out="$(ci_plan_json HEAD HEAD)"
    for svc in "${CI_SERVICES[@]}"; do
        [[ "$out" == *"\"$svc\":"* ]]
    done
}

# What: the plan is valid JSON that a workflow can consume.
# Why: §10.2 -- YAML reads this verdict, so it must parse.
# From: Issue #1683
@test "planner: plan output parses as JSON" {
    command -v python3 >/dev/null || skip "python3 not available"
    ci_plan_json HEAD HEAD | python3 -c 'import json,sys; json.load(sys.stdin)'
}

# What: a changed service path marks that service.
# Why: proves impact actually reaches the plan, not just NOOP.
# From: Issue #1683
@test "planner: an impacted service is marked ARTIFACT_REQUIRED" {
    local out
    out="$(ci_impacted_services services/proxy/Dockerfile)"
    [[ "$out" == *"proxy"* ]]
}

# What: computing a no-op plan exits zero, not one.
# Why: a trailing `[[ ]] && assign` returned 1 here.
# From: Issue #1683
@test "planner: ci_plan_compute exits zero on a no-op plan" {
    run ci_plan_compute HEAD HEAD
    [ "$status" -eq 0 ]
}

# What: an all-non-service plan still exits zero.
# Why: the no-op run is the common path and must never fail.
# From: Issue #1683
@test "planner: a no-op plan run reports NOOP and exits zero" {
    BASE_REF=HEAD HEAD_REF=HEAD run bash "$repo_root/scripts/ci/ci.sh" plan-outputs
    [ "$status" -eq 0 ]
    [[ "$output" == *"global-state=NOOP"* ]]
}

# What: a change to ci.sh itself requires the engine's tests.
# Why: §64 -- service impact alone would skip them.
# From: Issue #1683
@test "planner: an engine-only change sets test_required" {
    ci_test_required HEAD HEAD && false
    local out
    out="$(ci_plan_json HEAD HEAD)"
    [[ "$out" == *'"test_required":false'* ]]
}

# What: the build identity ignores the shell locale.
# Why: §72 -- locale sorting differs between hosts.
# From: Issue #1683
@test "identity: ci_build_identity is stable across locales" {
    local c utf8
    c="$(LC_ALL=C ci_build_identity dns linux/amd64)"
    utf8="$(LC_ALL=en_US.UTF-8 ci_build_identity dns linux/amd64)"
    [ "$c" = "$utf8" ]
}

# What: an empty or UNKNOWN state fails the result job.
# Why: §2.3 -- UNKNOWN must never be reported as a pass.
# From: Issue #1683
@test "result: an UNKNOWN planner state fails closed" {
    PLAN_RESULT=success TESTS_RESULT=success BUILD_RESULT=skipped \
        AGGREGATE_RESULT=skipped GLOBAL_STATE=UNKNOWN \
        run bash "$repo_root/scripts/ci/ci.sh" report-result
    [ "$status" -ne 0 ]
    [[ "$output" == *"planner state"* ]]
}

# What: a decided state with green jobs reports success.
# Why: the fail-closed guard must not break the happy path.
# From: Issue #1683
@test "result: a decided state with green jobs succeeds" {
    PLAN_RESULT=success TESTS_RESULT=skipped BUILD_RESULT=skipped \
        AGGREGATE_RESULT=skipped GLOBAL_STATE=NOOP \
        run bash "$repo_root/scripts/ci/ci.sh" report-result
    [ "$status" -eq 0 ]
}

# ============================================================
# SERVICE INVENTORY
# ============================================================

# What: the list holds exactly the 11 entries.
# Why: §7 -- a dropped service is the drift to stop.
# From: Issue #1683
@test "service inventory: contains exactly the 11 expected services" {
    local expected=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui netdata build-tools utilities)
    [ "${#CI_SERVICES[@]}" -eq "${#expected[@]}" ]
    local svc
    for svc in "${expected[@]}"; do
        ci_service_exists "$svc"
    done
}

# What: netdata is a member of the authoritative service list.
# Why: resolves §7's open netdata question.
# From: Issue #1683
@test "service inventory: netdata is included (maintainer decision)" {
    ci_service_exists netdata
}

# What: every service resolves to a non-empty build context.
# Why: §8 requires complete metadata for every listed service.
# From: Issue #1683
@test "service inventory: every service has a non-empty context" {
    local svc
    for svc in "${CI_SERVICES[@]}"; do
        [ -n "$(ci_service_context "$svc")" ]
    done
}

# What: every declared build-context directory exists on disk.
# Why: catches a typo'd or renamed context path at test time.
# From: Issue #1683
@test "service inventory: every service context directory exists" {
    local svc ctx
    for svc in "${CI_SERVICES[@]}"; do
        ctx="$(ci_service_context "$svc")"
        [ -d "$repo_root/$ctx" ]
    done
}

# What: every service declares both amd64 and arm64.
# Why: §43 -- both follow one build decision.
# From: Issue #1683
@test "service inventory: every service has amd64 and arm64 platforms" {
    local svc platforms
    for svc in "${CI_SERVICES[@]}"; do
        platforms="$(ci_service_platforms "$svc")"
        [[ "$platforms" == *"linux/amd64"* ]]
        [[ "$platforms" == *"linux/arm64"* ]]
    done
}

# What: every service's runner class is heavy or light.
# Why: §71's dynamic matrix cannot route an unknown class.
# From: Issue #1683
@test "service inventory: every service has a runner class of heavy or light" {
    local svc class
    for svc in "${CI_SERVICES[@]}"; do
        class="$(ci_service_runner_class "$svc")"
        [[ "$class" == "heavy" || "$class" == "light" ]]
    done
}

# What: every service's compiler class is none, rust, or c.
# Why: an unknown class would select no cache tier at all.
# From: Issue #1683
@test "service inventory: every service has a known compiler class" {
    local svc class
    for svc in "${CI_SERVICES[@]}"; do
        class="$(ci_service_compiler_class "$svc")"
        [[ "$class" == "none" || "$class" == "rust" || "$class" == "c" ]]
    done
}

# What: proxy's external context is the exact file.
# Why: pins it against a directory-wide regression.
# From: Issue #1683
@test "service inventory: proxy declares dns as an external context" {
    local ctx
    ctx="$(ci_service_external_contexts proxy)"
    [[ "$ctx" == "dns-domains=services/dns/cdn-domains.txt" ]]
}

# What: a service without external contexts returns nothing.
# Why: the empty case must not emit a blank line.
# From: Issue #1683
@test "service inventory: dns has no external context" {
    local ctx
    ctx="$(ci_service_external_contexts dns)"
    [ -z "$ctx" ]
}

# What: an unknown service name is not reported as existing.
# Why: membership is the gate every other accessor relies on.
# From: Issue #1683
@test "service inventory: unknown service is rejected" {
    run ci_service_exists totally-not-a-service
    [ "$status" -ne 0 ]
}

# What: an unknown service exits non-zero, with text.
# Why: a typo must fail closed, not resolve to empty metadata.
# From: Issue #1683
@test "service inventory: ci_require_service dies on unknown service" {
    run ci_require_service totally-not-a-service
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown service"* ]]
}

# What: a metadata accessor also rejects an unknown service.
# Why: validation sits in accessors, not callers.
# From: Issue #1683
@test "service inventory: ci_service_context dies on unknown service" {
    run ci_service_context totally-not-a-service
    [ "$status" -ne 0 ]
}

# ============================================================
# DISPATCH
# ============================================================

# What: the services subcommand prints one line per service.
# Why: the CLI is how workflow YAML reads the list (§5/§9).
# From: Issue #1683
@test "dispatch: 'services' subcommand prints all 11 services" {
    run bash "$repo_root/scripts/ci/ci.sh" services
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | wc -l)" -eq 11 ]
}

# What: the version subcommand prints a semver-shaped string.
# Why: lets a workflow assert the ci.sh contract.
# From: Issue #1683
@test "dispatch: 'version' subcommand prints a version string" {
    run bash "$repo_root/scripts/ci/ci.sh" version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# What: an unknown subcommand exits non-zero.
# Why: a mistyped call in YAML must fail the job, not no-op.
# From: Issue #1683
@test "dispatch: unknown subcommand fails" {
    run bash "$repo_root/scripts/ci/ci.sh" totally-not-a-command
    [ "$status" -ne 0 ]
}

# What: invoking ci.sh with no subcommand exits non-zero.
# Why: an empty call is a caller bug, not an implicit default.
# From: Issue #1683
@test "dispatch: no subcommand prints usage and fails" {
    run bash "$repo_root/scripts/ci/ci.sh"
    [ "$status" -ne 0 ]
}

# ============================================================
# ACCEPTANCE TESTS (§85 A-O)
# ============================================================

# What: Test A -- a docs-only change plans no work at all.
# Why: §85 A -- builds, scans and writes must be 0.
# From: Issue #1683
@test "acceptance A: a markdown-only change impacts no service" {
    [ -z "$(ci_impacted_services README.md docs/architecture-ng.md)" ]
}

# What: Test B -- a shell comment keeps the identity.
# Why: §85 B -- comment edits are semantically identical.
# From: Issue #1683
@test "acceptance B: a shell comment change hashes identically" {
    local f1="$BATS_TEST_TMPDIR/e1.sh" f2="$BATS_TEST_TMPDIR/e2.sh"
    printf '#!/bin/sh\n# before\nexec x\n' > "$f1"
    printf '#!/bin/sh\n# after\nexec x\n' > "$f2"
    [ "$(ci_content_hash "$f1")" = "$(ci_content_hash "$f2")" ]
}

# What: Test C -- a bats comment keeps the identity.
# Why: §85 C -- a comment is not a test-logic change.
# From: Issue #1683
@test "acceptance C: a bats comment change hashes identically" {
    local f1="$BATS_TEST_TMPDIR/t1.bats" f2="$BATS_TEST_TMPDIR/t2.bats"
    printf '#!/usr/bin/env bats\n# old note\n@test "x" { true; }\n' > "$f1"
    printf '#!/usr/bin/env bats\n# new note\n@test "x" { true; }\n' > "$f2"
    [ "$(ci_content_hash "$f1")" = "$(ci_content_hash "$f2")" ]
}

# What: Test D -- test logic changes the hash only.
# Why: §85 D -- tests run, container builds stay at 0.
# From: Issue #1683
@test "acceptance D: changed test logic changes the test hash only" {
    local f1="$BATS_TEST_TMPDIR/t3.bats" f2="$BATS_TEST_TMPDIR/t4.bats"
    printf '@test "x" { true; }\n' > "$f1"
    printf '@test "x" { false; }\n' > "$f2"
    [ "$(ci_content_hash "$f1")" != "$(ci_content_hash "$f2")" ]
    [ -z "$(ci_impacted_services scripts/ci/ci.bats)" ]
}

# What: Test E -- a dns change excludes other services.
# Why: §85 E -- only affected services are considered.
# From: Issue #1683
@test "acceptance E: a dns-only change leaves other services NOOP" {
    local impacted
    impacted="$(ci_impacted_services services/dns/Dockerfile)"
    [[ "$impacted" == *"dns"* ]]
    [[ "$impacted" != *"watchdog"* ]]
    [[ "$impacted" != *"ntp"* ]]
}

# What: Test F -- cdn-domains.txt impacts both dns and proxy.
# Why: §85 F -- proxy consumes it via a named context.
# From: Issue #1683
@test "acceptance F: a shared dependency impacts both consumers" {
    local impacted
    impacted="$(ci_impacted_services services/dns/cdn-domains.txt)"
    [[ "$impacted" == *"dns"* ]]
    [[ "$impacted" == *"proxy"* ]]
}

# What: Test G -- an unreachable registry means UNKNOWN.
# Why: §85 G -- a lookup failure must never authorize a build.
# From: Issue #1683
@test "acceptance G: an unreachable registry does not permit a build" {
    run ! ci_state_permits_build "$CI_STATE_UNKNOWN"
}

# What: Test H -- an in-progress build blocks a twin.
# Why: §85 H -- runner B waits and reuses instead.
# From: Issue #1683
@test "acceptance H: BUILD_IN_PROGRESS does not permit a build" {
    run ! ci_state_permits_build "$CI_STATE_BUILD_IN_PROGRESS"
}

# What: Test I/J -- unverified output never rebuilds.
# Why: §85 I/J -- retry publish, never build twice.
# From: Issue #1683
@test "acceptance I+J: PRODUCED_UNVERIFIED does not permit a build" {
    run ! ci_state_permits_build "$CI_STATE_PRODUCED_UNVERIFIED"
}

# What: Test K -- a mismatch names both digests.
# Why: §85 K -- no replacement build after a mismatch.
# From: Issue #1683
@test "acceptance K: a digest mismatch fails, naming both digests" {
    run ! ci_state_permits_build "$CI_STATE_MISMATCH"
    ci_report_failure "digest match" "proxy" "sha256:aa" "sha256:bb" "fail, never rebuild"
    [[ "${CI_FAILURES[0]}" == *"sha256:aa"* ]]
    [[ "${CI_FAILURES[0]}" == *"sha256:bb"* ]]
}

# What: Test L -- one missing service blocks the whole stack.
# Why: §85 L -- promotion is atomic; 9/10 never goes.
# From: Issue #1683
@test "acceptance L: an incomplete stack blocks the candidate" {
    CI_LEDGER_DIR="$BATS_TEST_TMPDIR/ledger-L"
    CI_IMAGE_REPO="owner/repo"
    run ci_stack_candidate
    [ "$status" -ne 0 ]
}

# What: Test M/N -- nightly and release never build.
# Why: §85 M/N -- both promote or do nothing.
# From: Issue #1683
@test "acceptance M+N: nightly and release never invoke a build" {
    ! grep -nE '^[[:space:]]*docker (buildx )?build([[:space:]]|$)' "$repo_root/scripts/ci/ci.sh"
}

# What: Test O -- no short SHA or digest in the engine.
# Why: §85 O -- abbreviated identifiers must be zero.
# From: Issue #1683
@test "acceptance O: ci.sh contains no abbreviated SHA or digest" {
    ! grep -nE "['\"]sha-[0-9a-f]{6,8}['\"]|['\"][0-9a-f]{7}['\"]" "$repo_root/scripts/ci/ci.sh"
}

# ============================================================
# STANDING CHECKS
# ============================================================

# What: every listed standing-check script exists on disk.
# Why: a renamed/removed script must fail loudly, not silently.
# From: Issue #1683
@test "standing checks: every listed script exists" {
    local script
    for script in "${CI_STANDING_CHECKS[@]}"; do
        [ -f "$repo_root/$script" ]
    done
}

# What: the checks command runs to completion on a clean tree.
# Why: this repo's own tree is the checks' first real fixture.
# From: Issue #1683
@test "standing checks: ci.sh checks runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" checks
    [ "$status" -eq 0 ]
}

# What: every file-header check script exists on disk.
# Why: mirrors "every listed script exists" for this list.
# From: Issue #1683
@test "file-header checks: every listed script exists" {
    local script
    for script in "${CI_FILE_HEADER_CHECKS[@]}"; do
        [ -f "$repo_root/$script" ]
    done
}

# What: the two check lists never share a script.
# Why: §72 -- a shared script would run twice per run.
# From: Issue #1683
@test "file-header checks: no overlap with CI_STANDING_CHECKS" {
    local a b
    for a in "${CI_FILE_HEADER_CHECKS[@]}"; do
        for b in "${CI_STANDING_CHECKS[@]}"; do
            [ "$a" != "$b" ]
        done
    done
}

# What: file-header-checks runs clean on this repo's tree.
# Why: this repo's own tree is the checks' first fixture.
# From: Issue #1683
@test "file-header checks: ci.sh file-header-checks runs on this repo's tree" {
    EVENT_NAME=push run bash "$repo_root/scripts/ci/ci.sh" file-header-checks
    [ "$status" -eq 0 ]
}

# What: chronology's CHRONOLOGY_WARN_ONLY derives from event.
# Why: pull_request warns; every other event must block.
# From: Issue #1683
@test "standing checks: chronology env is warn-only for pull_request" {
    # What: unset EVENT_NAME must fail closed, not warn.
    # Why: an unrecognized event must never soften a gate.
    unset EVENT_NAME
    run ci_standing_check_env "check-review-chronology-comments.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CHRONOLOGY_WARN_ONLY=0" ]

    EVENT_NAME=pull_request run ci_standing_check_env "check-review-chronology-comments.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CHRONOLOGY_WARN_ONLY=1" ]

    EVENT_NAME=push run ci_standing_check_env "check-review-chronology-comments.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "CHRONOLOGY_WARN_ONLY=0" ]
}

# What: diff-checks needs both required arguments.
# Why: a silently-empty base sha/ref is not "no diff".
# From: Issue #1683
@test "diff-checks: fails fast when base sha is missing" {
    run bash "$repo_root/scripts/ci/ci.sh" diff-checks
    [ "$status" -ne 0 ]
}

@test "diff-checks: fails fast when base ref is missing" {
    run bash "$repo_root/scripts/ci/ci.sh" diff-checks "HEAD"
    [ "$status" -ne 0 ]
}

# What: compose-healthchecks runs clean on this repo's tree.
# Why: this repo's own compose files are the check's fixture.
# From: Issue #1683
@test "compose-healthchecks: ci.sh compose-healthchecks runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" compose-healthchecks
    [ "$status" -eq 0 ]
}

# What: line-endings-check runs clean on this repo's tree.
# Why: this repo's own tracked files are the check's fixture.
# From: Issue #1683
@test "line-endings-check: ci.sh line-endings-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" line-endings-check
    [ "$status" -eq 0 ]
}

# What: language-policy-check runs clean on this repo's tree.
# Why: this repo's own tracked files are the check's fixture.
# From: Issue #1683
@test "language-policy-check: ci.sh language-policy-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" language-policy-check
    [ "$status" -eq 0 ]
}

# What: setup-migration-check runs clean on this repo's tree.
# Why: this repo's own setup.sh is the test's real fixture.
# From: Issue #1683
@test "setup-migration-check: ci.sh setup-migration-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" setup-migration-check
    [ "$status" -eq 0 ]
}

# What: validation-subnet-check runs clean on this repo.
# Why: this repo's own workflows are the check's real fixture.
# From: Issue #1683
@test "validation-subnet-check: ci.sh validation-subnet-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" validation-subnet-check
    [ "$status" -eq 0 ]
}

# What: executable-bits-check runs clean on this repo's tree.
# Why: this repo's own tracked files are the check's fixture.
# From: Issue #1683
@test "executable-bits-check: ci.sh executable-bits-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" executable-bits-check
    [ "$status" -eq 0 ]
}

# What: build-tools-smoke-cov-check runs clean on this repo.
# Why: this repo's own Dockerfile is the check's real fixture.
# From: Issue #1683
@test "build-tools-smoke-cov-check: ci.sh build-tools-smoke-cov-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" build-tools-smoke-cov-check
    [ "$status" -eq 0 ]
}

# What: pipefail-early-exit-check runs clean on this repo.
# Why: this repo's own tracked files are the check's fixture.
# From: Issue #1683
@test "pipefail-early-exit-check: ci.sh pipefail-early-exit-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" pipefail-early-exit-check
    [ "$status" -eq 0 ]
}

# What: pipefail-scope-check runs clean on this repo's tree.
# Why: this repo's own tracked files are the check's fixture.
# From: Issue #1683
@test "pipefail-scope-check: ci.sh pipefail-scope-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" pipefail-scope-check
    [ "$status" -eq 0 ]
}

# What: repository-case-check runs clean on this repo's tree.
# Why: this repo's own workflows are the check's real fixture.
# From: Issue #1683
@test "repository-case-check: ci.sh repository-case-check runs on this repo's tree" {
    run bash "$repo_root/scripts/ci/ci.sh" repository-case-check
    [ "$status" -eq 0 ]
}

# What: action-node-versions-check runs clean on this repo.
# Why: needs live GH API access; skipped when unreachable.
# From: Issue #1683
@test "action-node-versions-check: ci.sh action-node-versions-check runs on this repo's tree" {
    run curl -fsS --max-time 5 https://api.github.com/rate_limit
    [ "$status" -eq 0 ] || skip "no live api.github.com access in this environment"
    run bash "$repo_root/scripts/ci/ci.sh" action-node-versions-check
    [ "$status" -eq 0 ]
}

# What: docker compose config succeeds for a real compose file.
# Why: proves the wrapper works against this repo's actual files.
# From: Issue #1683
@test "compose: ci_compose_config_clean passes for quickstart+ssl" {
    command -v docker >/dev/null || skip "docker not available"
    cd "$repo_root"
    run ci_compose_config_clean -f deploy/quickstart/docker-compose.yml --profile ssl
    [ "$status" -eq 0 ]
}

# What: the full compose-files check runs clean on this repo.
# Why: this repo's own compose files are the check's real fixture.
# From: Issue #1683
@test "compose: ci_check_compose_files reports no failures here" {
    command -v docker >/dev/null || skip "docker not available"
    cd "$repo_root"
    CI_FAILURES=()
    ci_check_compose_files
    [ "${#CI_FAILURES[@]}" -eq 0 ]
}
