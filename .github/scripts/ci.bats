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

@test "identity is deterministic for one target+platform, keyed" {
    # What: Same content+platform -> same keyed id, always.
    # Why: NOOP/reuse depends on a stable identity.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui linux/amd64
    [ "${status}" -eq 0 ]
    local first="${output}"
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui linux/amd64
    [ "${output}" = "${first}" ]
    [[ "${output}" =~ ^platform=linux/amd64\ identity=[0-9a-f]{64}$ ]]
}

@test "identity differs across services and build types" {
    # What: proxy(apk), ui(rust), build-tools all differ.
    # Why: An id must key on its own inputs, not collide.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity proxy linux/amd64
    [ "${status}" -eq 0 ]
    local proxy="${output}"
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity build-tools linux/amd64
    [ "${status}" -eq 0 ]
    [ "${output}" != "${proxy}" ]
}

@test "an apk service resolves without a masked non-zero exit" {
    # What: identity/resolve of an apk service must exit 0.
    # Why: A printed id with rc=1 masks a broken pipeline.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ntp linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^platform=linux/amd64\ identity=[0-9a-f]{64}$ ]]
    run bash "${BATS_TEST_DIRNAME}/ci.sh" resolve ntp linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"state=UNKNOWN"* ]]
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
# PLATFORMS
# ============================================================

@test "identity fan-out lists every platform, always keyed" {
    # What: No platform arg -> one keyed line per platform.
    # Why: Default = all; output never mixes bare and keyed.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${output}" == *"platform=linux/amd64 identity="* ]]
    [[ "${output}" == *"platform=linux/arm64 identity="* ]]
}

@test "a selected platform yields one line; amd64 and arm64 differ" {
    # What: Platform selects; each arch has its own id.
    # Why: An amd64 binary must not reuse an arm64 id.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui linux/amd64
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    local a="${output}"
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui linux/arm64
    [ "${output}" != "${a}" ]
}

@test "identity rejects a platform not in the target set" {
    # What: An unknown platform fails closed.
    # Why: Unknown input is an error, not a silent fan-out.
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui linux/riscv64
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IDENTITY-0002"* ]]
}

@test "install identity isolates platforms across arches" {
    # What: An arm64-only edit must not move amd64 id.
    # Why: A platform-irrelevant change must not rebuild.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/manifest.yml"
    cp "${BATS_TEST_DIRNAME}/../yaml/build-manifest.yml" "${m}"
    local amd_before arm_before amd_after arm_after
    amd_before="$(CI_MANIFEST="${m}" bash "${BATS_TEST_DIRNAME}/ci.sh" identity netdata linux/amd64)"
    arm_before="$(CI_MANIFEST="${m}" bash "${BATS_TEST_DIRNAME}/ci.sh" identity netdata linux/arm64)"
    sed -i 's/sha256_aarch64: [0-9a-f]\{64\}/sha256_aarch64: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "${m}"
    amd_after="$(CI_MANIFEST="${m}" bash "${BATS_TEST_DIRNAME}/ci.sh" identity netdata linux/amd64)"
    arm_after="$(CI_MANIFEST="${m}" bash "${BATS_TEST_DIRNAME}/ci.sh" identity netdata linux/arm64)"
    [ "${amd_before}" = "${amd_after}" ]
    [ "${arm_before}" != "${arm_after}" ]
}

@test "a target with no platforms in the SOT fails closed" {
    # What: An empty platform set is an error, not rc0.
    # Why: A masked rc0 fan-out would skip the target.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/manifest.yml"
    cp "${BATS_TEST_DIRNAME}/../yaml/build-manifest.yml" "${m}"
    sed -i '/^  platforms: \[/d' "${m}"
    CI_MANIFEST="${m}" run bash "${BATS_TEST_DIRNAME}/ci.sh" identity ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IDENTITY-0003"* ]]
    [[ "${output}" != *"identity="* ]]
}

@test "resolve rejects a platform not in the target set" {
    # What: A selected unknown platform fails closed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" resolve ui linux/riscv64
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RESOLVE-0004"* ]]
}

@test "build rejects a platform not in the target set" {
    # What: A selected unknown platform fails closed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" build ui linux/riscv64
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0006"* ]]
}

@test "build tags its result line with the selected platform" {
    # What: A selected build emits one platform-keyed line.
    # Why: Downstream assembly keys per-platform digests.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${BATS_TEST_DIRNAME}/ci.sh" build ui linux/arm64
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "${output}" == *"platform=linux/arm64"* ]]
    [[ "${output}" == *"result=reuse-accepted"* ]]
}

@test "per-service platform override is a strict subset of build_matrix" {
    # What: An override must be a proper subset.
    # Why: The global list bounds all; equal = drift.
    # From: Issue #1683
    local global svc ov p
    global="$(_ci_build_matrix_platforms | sort | tr '\n' ' ')"
    for svc in $(ci_build_targets); do
        ov="$(_ci_service_platforms_override "${svc}")"
        [ -n "${ov}" ] || continue
        while IFS= read -r p; do
            [ -z "${p}" ] && continue
            printf '%s\n' ${global} | grep -qx "${p}"
        done <<< "${ov}"
        [ "$(printf '%s\n' ${ov} | sort | tr '\n' ' ')" != "${global}" ]
    done
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

# What: Write an executable stub that prints/exits fixed.
# Why: Inject build/CAS/probe backends without real infra.
# From: Issue #1683
_stub() {
    local name="$1" body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "${body}" > "${BATS_TEST_TMPDIR}/${name}"
    chmod +x "${BATS_TEST_TMPDIR}/${name}"
    printf '%s\n' "${BATS_TEST_TMPDIR}/${name}"
}

@test "build reuses (no build) when resolve says accepted" {
    # What: PRESENT_ACCEPTED -> reuse, never build.
    # Why: NOOP/reuse is the default outcome.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${BATS_TEST_DIRNAME}/ci.sh" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=reuse-accepted"* ]]
}

@test "build refuses to build on UNKNOWN (escalate, not build)" {
    # What: UNKNOWN must never trigger a build.
    # Why: UNKNOWN != BUILD (Contract section 4).
    # From: Issue #1683
    STUB_STATE=UNKNOWN
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${BATS_TEST_DIRNAME}/ci.sh" build ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"result=escalate"* ]]
    [[ "${output}" != *"result=built"* ]]
}

@test "build reuses a binary from the CAS before compiling (rust)" {
    # What: A CAS hit skips compile (reuse order, §7).
    # Why: Reuse an identical binary, do not rebuild.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 0')" \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=reuse-binary-cas"* ]]
}

@test "build fails closed when GHCR credentials are missing (never anonymous)" {
    # What: A real build needs authenticated GHCR.
    # Why: Anonymous GHCR is rate-limited (maintainer).
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 1')" \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" build ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "build runs the backend when confirmed-missing, CAS-miss, authed" {
    # What: The one real path: build + push, authed.
    # Why: Only a confirmed-missing artifact compiles.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 1')" \
    CI_BUILD_CMD="$(_stub build 'exit 0')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=built"* ]]
}

# ============================================================
# TEST / SCAN
# ============================================================

@test "test fails closed and shows raw output when tests fail" {
    # What: A failed test run is a failed run (AG-VAL-002).
    # Why: Never skip or swallow a real test failure.
    # From: Issue #1683
    CI_TEST_CMD="$(_stub t 'echo boom; exit 1')" run bash "${BATS_TEST_DIRNAME}/ci.sh" test ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-TEST-0003"* ]]
    [[ "${output}" == *"boom"* ]]
}

@test "test passes when the backend succeeds" {
    # What: Green backend -> tested=ok.
    # Why: The one success path.
    # From: Issue #1683
    CI_TEST_CMD="$(_stub t 'exit 0')" run bash "${BATS_TEST_DIRNAME}/ci.sh" test ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
}

@test "scan rejects a /tmp (tmpfs) TMPDIR, requires /var/tmp" {
    # What: tmpfs /tmp risks OOM on image/db export.
    # Why: All CI staging is /var/tmp (maintainer rule).
    # From: Issue #1683
    CI_TMPDIR=/tmp CI_SCAN_CMD="$(_stub s 'exit 0')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0003"* ]]
}

@test "scan is clean on /var/tmp with auth and a passing backend" {
    # What: authed + /var/tmp + green scan -> clean.
    # Why: The one success path for scan.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 0')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" scan ui sha256:x
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"scanned=clean"* ]]
    [[ "${output}" == *"tmpdir=/var/tmp"* ]]
}

@test "scan fails closed without GHCR auth" {
    # What: Scan pulls the image -> authenticated.
    # Why: Never anonymous (rate-limit).
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 0')" run bash "${BATS_TEST_DIRNAME}/ci.sh" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

# ============================================================
# CACHE FALLBACK
# ============================================================

# ============================================================
# REGISTRY / PUBLISH / READBACK
# ============================================================

@test "publish fails closed without GHCR credentials" {
    # What: Publish is an authenticated GHCR action.
    # Why: Never push anonymously (rate-limit).
    # From: Issue #1683
    CI_PUBLISH_CMD="$(_stub pub 'echo sha256:abc')" run bash "${BATS_TEST_DIRNAME}/ci.sh" publish ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "publish returns the backend digest when authed" {
    # What: A successful push reports its digest.
    # Why: The digest is the ref the next phase verifies.
    # From: Issue #1683
    CI_PUBLISH_CMD="$(_stub pub 'echo sha256:deadbeef')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" publish ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"published=sha256:deadbeef"* ]]
}

@test "verify passes when the readback digest matches" {
    # What: readback == expected -> verified.
    # Why: Confirms the accepted artifact is the real one.
    # From: Issue #1683
    CI_READBACK_CMD="$(_stub rb 'echo sha256:match')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" verify ui sha256:match
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"verified=sha256:match"* ]]
}

@test "verify fails with MISMATCH and shows raw readback (BUILT != ACCEPTED)" {
    # What: readback != expected -> hard fail + raw.
    # Why: A mismatch must never be accepted (§7).
    # From: Issue #1683
    CI_READBACK_CMD="$(_stub rb 'echo sha256:other')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" verify ui sha256:expected
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERIFY-0005"* ]]
    [[ "${output}" == *"MISMATCH"* ]]
    [[ "${output}" == *"readback=sha256:other"* ]]
}

# ============================================================
# ASSEMBLY
# ============================================================

# What: Digest and index-lookup stubs share these constants.
# Why: Idempotency compares assembled vs existing.
# From: Issue #1683
_asm_a() { printf 'sha256:%s' "$(printf 'a%.0s' {1..64})"; }
_asm_b() { printf 'sha256:%s' "$(printf 'b%.0s' {1..64})"; }
_asm_idx() { printf 'sha256:%s' "$(printf 'd%.0s' {1..64})"; }
_asm_digest_stub() {
    _stub dg "case \"\$2\" in */arm64) echo $(_asm_b);; *) echo $(_asm_a);; esac"
}

@test "assemble refuses a non-ACCEPTED platform and does not rebuild" {
    # What: UNKNOWN blocks assembly, never rebuilds success.
    # Why: A missing platform must not rebuild (docs §45).
    # From: Issue #1683
    STUB_STATE=UNKNOWN
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${BATS_TEST_DIRNAME}/ci.sh" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0002"* ]]
    [[ "${output}" != *"result=assembled"* ]]
}

@test "assemble refuses PRODUCED_UNVERIFIED (fail-safe stays DISACK)" {
    # What: Unverified is not ACCEPTED, so no assembly.
    # Why: Fail-safe: unaccepted stays a GC candidate.
    # From: Issue #1683
    STUB_STATE=PRODUCED_UNVERIFIED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${BATS_TEST_DIRNAME}/ci.sh" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0002"* ]]
}

@test "assemble creates an index when every platform is ACCEPTED" {
    # What: All ACCEPTED + digests + authed -> one index.
    # Why: The index is the accepted platform set.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_ACCEPTED_DIGEST_CMD="$(_asm_digest_stub)" \
    CI_ASSEMBLE_CMD="$(_stub asm "echo $(_asm_idx)")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" assemble ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=assembled"* ]]
    [[ "${output}" == *"assembled=$(_asm_idx)"* ]]
    [[ "${output}" == *"platforms=2"* ]]
}

@test "assemble reuses an identical existing index (idempotent)" {
    # What: A retry reuses the same index.
    # Why: Same end state on retry; no backend.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_ACCEPTED_DIGEST_CMD="$(_asm_digest_stub)" \
    CI_INDEX_LOOKUP_CMD="$(_stub idx "echo \"$(_asm_idx) linux/amd64=$(_asm_a) linux/arm64=$(_asm_b)\"")" \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" assemble ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=reuse-index"* ]]
    [[ "${output}" == *"assembled=$(_asm_idx)"* ]]
}

@test "assemble refuses to overwrite a divergent existing index" {
    # What: An index with different digests fails closed.
    # Why: Never silently overwrite an accepted artifact.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_ACCEPTED_DIGEST_CMD="$(_asm_digest_stub)" \
    CI_INDEX_LOOKUP_CMD="$(_stub idx "echo \"$(_asm_idx) linux/amd64=$(_asm_a) linux/arm64=$(_asm_a)\"")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0004"* ]]
}

@test "assemble fails closed without GHCR auth before creating" {
    # What: Creating an index is authenticated.
    # Why: Never anonymous (rate-limit).
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_ACCEPTED_DIGEST_CMD="$(_asm_digest_stub)" \
    CI_ASSEMBLE_CMD="$(_stub asm "echo $(_asm_idx)")" \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "assemble fails when an ACCEPTED platform has no digest" {
    # What: ACCEPTED but no digest is an inconsistency.
    # Why: Fail closed, never assemble a partial index.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${BATS_TEST_DIRNAME}/ci.sh" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0003"* ]]
}

@test "assemble fails closed when no service is given" {
    # What: Missing arg must fail with a stable id.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${BATS_TEST_DIRNAME}/ci.sh" assemble
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0001"* ]]
}

# ============================================================
# PROMOTION
# ============================================================

# ============================================================
# GC
# ============================================================

# ============================================================
# HISTORICAL REGRESSIONS
# ============================================================
