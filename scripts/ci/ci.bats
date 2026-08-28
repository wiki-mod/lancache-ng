#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What: regression suite for scripts/ci/ci.sh (CI 2.0 engine).
# Why: §66 wants one suite covering every domain.
# From: Issue #1683 | docs/ci-2.0-architecture.md

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
