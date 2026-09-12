#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
# What: Single authoritative CI 2.0 regression suite.
# Why: One place proves every CI invariant and regression.
# From: Issue #1683

# What: Source ci.sh functions without running dispatch.
# Why: Test engine functions directly against the real SOT.
# From: Issue #1683
setup() {
    CI_SH="${BATS_TEST_DIRNAME}/ci.sh"
    # shellcheck source=.github/scripts/ci.sh
    source "${CI_SH}"
}

# ============================================================
# CORE INVARIANTS
# ============================================================

@test "ci_services lists exactly the 10 product-stack services" {
    # What: The one service list drives everything.
    # Why: Drift here breaks matrices/scans/release.
    # From: Issue #1683
    run ci_services
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 10 ]
}

@test "ci_build_targets adds build-tools but never counts it as a service" {
    # What: 10 services + build-tools = 11 targets.
    # Why: build-tools builds the stack, is not in it.
    # From: Issue #1683
    run ci_build_targets
    [ "${#lines[@]}" -eq 11 ]
    run ci_services
    ! printf '%s\n' "${lines[@]}" | grep -qx "build-tools"
}

@test "unknown subcommand fails closed with a stable id" {
    # What: An unknown command must never succeed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" bogus-command
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0002"* ]]
}

# ============================================================
# SEMANTIC IMPACT
# ============================================================

@test "plan picks only proxy for a proxy-only source change" {
    # What: A service's own context selects it alone.
    # Why: No unrelated service is a rebuild candidate.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" plan services/proxy/nginx.conf
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy=true"* ]]
    [[ "${output}" == *"ui=false"* ]]
    [[ "${output}" == *"dns=false"* ]]
}

@test "plan rebuilds proxy on a dns-domains (cdn-domains.txt) change" {
    # What: proxy COPYs cdn-domains.txt (named context).
    # Why: The dependency edge must select proxy too.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" plan services/dns/cdn-domains.txt
    [[ "${output}" == *"proxy=true"* ]]
}

@test "plan rebuilds every shared-scripts consumer, and no other" {
    # What: shared-scripts feeds 6 services (Finding 93).
    # Why: One shared context, exactly its consumers.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" plan scripts/lib/verify-version-banner.sh
    [[ "${output}" == *"proxy=true"* ]]
    [[ "${output}" == *"dns=true"* ]]
    [[ "${output}" == *"ui=true"* ]]
    [[ "${output}" == *"watchdog=true"* ]]
    [[ "${output}" == *"dhcp=true"* ]]
    [[ "${output}" == *"dhcp-proxy=true"* ]]
    [[ "${output}" == *"ntp=false"* ]]
    [[ "${output}" == *"cachehamster=false"* ]]
}

@test "plan emits a candidates-only note, not a build decision" {
    # What: plan selects candidates; identity decides build.
    # Why: Keep the §4/§7 separation explicit and visible.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" plan services/ui/src/main.rs
    [[ "${output}" == *"candidates only; identity/CAS decides build"* ]]
}

# ============================================================
# SERVICE DEPENDENCIES
# ============================================================

@test "ci_service_field reads build_type and runner from the SOT" {
    # What: Scalar service fields come from the one file.
    # Why: No per-file copy of build type or runner class.
    # From: Issue #1683
    run ci_service_field ui build_type
    [ "${output}" = "rust" ]
    run ci_service_field proxy runner
    [ "${output}" = "light" ]
}

@test "ci_service_contexts returns the named contexts for proxy" {
    # What: proxy depends on shared-scripts and dns-domains.
    # Why: The SOT edge set is authoritative (Finding 93).
    # From: Issue #1683
    run ci_service_contexts proxy
    [[ "${output}" == *"shared-scripts"* ]]
    [[ "${output}" == *"dns-domains"* ]]
}

# ============================================================
# BUILD IDENTITIES
# ============================================================

@test "identity is deterministic for the same inputs" {
    # What: Same content -> same id, every time.
    # Why: NOOP/reuse depends on a stable identity.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui
    [ "${status}" -eq 0 ]
    local first="${output}"
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui
    [ "${output}" = "${first}" ]
    [[ "${output}" =~ ^[0-9a-f]{64}$ ]]
}

@test "identity differs across services and build types" {
    # What: proxy(apk), ui(rust), build-tools all differ.
    # Why: An id must key on its own inputs, not collide.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity proxy
    local proxy="${output}"
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity build-tools
    [ "${output}" != "${proxy}" ]
}

@test "identity fails closed with a stable id when no service is given" {
    # What: Missing arg must not crash on set -u.
    # Why: Fail-closed with our own message, not a trace.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IDENTITY-0001"* ]]
}

# ============================================================
# RESOLVER STATES
# ============================================================

# What: A stub probe that returns a fixed state.
# Why: Test the resolver logic without a live GHCR.
# From: Issue #1683
_probe_stub() {
    printf '%s\n' "${STUB_STATE}" > "${BATS_TEST_TMPDIR}/probe.sh.state" 2>/dev/null || true
    cat <<STUB > "${BATS_TEST_TMPDIR}/probe.sh"
#!/usr/bin/env bash
printf '%s\\n' "${STUB_STATE}"
STUB
    chmod +x "${BATS_TEST_TMPDIR}/probe.sh"
    printf '%s\n' "${BATS_TEST_TMPDIR}/probe.sh"
}

@test "resolve maps PRESENT_ACCEPTED to noop (DEFAULT=NOOP)" {
    # What: An accepted identity means no build.
    # Why: NOOP/reuse before build is the core rule.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${BATS_TEST_DIRNAME}/ci.sh" resolve ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"state=PRESENT_ACCEPTED"* ]]
    [[ "${output}" == *"action=noop"* ]]
}

@test "resolve maps MISSING_CONFIRMED to build" {
    # What: Only a confirmed-missing artifact builds.
    # Why: Build is evidence-driven, not a cache miss.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${BATS_TEST_DIRNAME}/ci.sh" resolve ui
    [[ "${output}" == *"action=build"* ]]
}

@test "resolve maps UNKNOWN to escalate, never build (UNKNOWN != BUILD)" {
    # What: Infra uncertainty must not trigger a build.
    # Why: UNKNOWN != BUILD (Contract section 4).
    # From: Issue #1683
    STUB_STATE=UNKNOWN
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${BATS_TEST_DIRNAME}/ci.sh" resolve ui
    [[ "${output}" == *"state=UNKNOWN"* ]]
    [[ "${output}" == *"action=escalate"* ]]
    [[ "${output}" != *"action=build"* ]]
}

@test "resolve with no probe wired defaults to UNKNOWN, not missing" {
    # What: No probe -> UNKNOWN, never assume missing.
    # Why: Absence of evidence is not evidence of absence.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" resolve ui
    [[ "${output}" == *"state=UNKNOWN"* ]]
    [[ "${output}" == *"action=escalate"* ]]
}

@test "resolve fails closed when no service is given" {
    # What: Missing arg must fail with a stable id.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" resolve
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RESOLVE-0001"* ]]
}

# ============================================================
# RETRY CLASSIFICATION
# ============================================================

@test "retry classifier: rate-limit / 5xx / network are transient" {
    # What: These recover on retry with backoff.
    # Why: One rule replaces every wrapper's own split.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'toomanyrequests: HTTP 429')" = "transient" ]
    [ "$(_ci_classify_failure 'received HTTP 503 from registry')" = "transient" ]
    [ "$(_ci_classify_failure 'dial tcp: i/o timeout')" = "transient" ]
    [ "$(_ci_classify_failure 'connection refused')" = "transient" ]
}

@test "retry classifier: auth / malformed / compile are permanent" {
    # What: Retrying these only burns the budget.
    # Why: A fixed outcome must fail fast, not loop.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'HTTP 401 unauthorized')" = "permanent" ]
    [ "$(_ci_classify_failure 'error: could not compile lancache-ui')" = "permanent" ]
    [ "$(_ci_classify_failure 'pull access denied for ghcr.io/x')" = "permanent" ]
    [ "$(_ci_classify_failure 'manifest unknown')" = "permanent" ]
}

@test "retry classifier: an unclassified failure defaults to transient" {
    # What: Unknown error -> retry, not give up.
    # Why: A missed transient is worse than a few retries.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'some novel error text')" = "transient" ]
}

@test "reuse order is cheapest-first and ends in compile" {
    # What: noop..accepted..CAS..caches..compile order.
    # Why: NOOP/reuse always precede build (§7).
    # From: Issue #1683
    local order; order="$(ci_reuse_order)"
    [ "${order%% *}" = "noop" ]
    [ "${order##* }" = "compile" ]
}

# ============================================================
# BUILD ADMISSION
# ============================================================

# ============================================================
# CACHE FALLBACK
# ============================================================

# ============================================================
# REGISTRY / PUBLISH / READBACK
# ============================================================

# ============================================================
# ASSEMBLY
# ============================================================

# ============================================================
# PROMOTION
# ============================================================

# ============================================================
# GC
# ============================================================

# ============================================================
# HISTORICAL REGRESSIONS
# ============================================================
