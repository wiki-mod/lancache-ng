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

# =========================================================
# CORE INVARIANTS
# =========================================================

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
    run bash "${CI_SH}" bogus-command
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0002"* ]]
}

# =========================================================
# SEMANTIC IMPACT
# =========================================================

@test "plan picks only proxy for a proxy-only source change" {
    # What: A service's own context selects it alone.
    # Why: No unrelated service is a rebuild candidate.
    # From: Issue #1683
    run bash "${CI_SH}" plan services/proxy/nginx.conf
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy=true"* ]]
    [[ "${output}" == *"ui=false"* ]]
    [[ "${output}" == *"dns=false"* ]]
}

@test "plan rebuilds proxy on a dns-domains (cdn-domains.txt) change" {
    # What: proxy COPYs cdn-domains.txt (named context).
    # Why: The dependency edge must select proxy too.
    # From: Issue #1683
    run bash "${CI_SH}" plan services/dns/cdn-domains.txt
    [[ "${output}" == *"proxy=true"* ]]
}

@test "plan rebuilds every shared-scripts consumer, and no other" {
    # What: shared-scripts feeds 6 services (Finding 93).
    # Why: One shared context, exactly its consumers.
    # From: Issue #1683
    run bash "${CI_SH}" plan scripts/lib/verify-version-banner.sh
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
    run bash "${CI_SH}" plan services/ui/src/main.rs
    [[ "${output}" == *"candidates only; identity/CAS decides build"* ]]
}

@test "plan-candidate is true for a touched context, false otherwise" {
    # What: One candidate rule shared by plan and Base-CI.
    # Why: No second copy of the path-touch decision.
    # From: Issue #1683
    run _ci_plan_candidate proxy services/proxy/Dockerfile
    [ "${status}" -eq 0 ]
    run _ci_plan_candidate proxy services/ntp/Dockerfile
    [ "${status}" -ne 0 ]
}

@test "platform-runner maps each platform to one runner, fail-closed" {
    # What: One owner of platform to GitHub runner label.
    # Why: gate and Base-CI must not both hardcode it.
    # From: Issue #1683
    run _ci_platform_runner linux/amd64
    [ "${output}" = "ubuntu-latest" ]
    run _ci_platform_runner linux/arm64
    [ "${output}" = "ubuntu-24.04-arm" ]
    run _ci_platform_runner linux/riscv64
    [ "${status}" -ne 0 ]
}

@test "matrix-append builds one include object from key=value pairs" {
    # What: One JSON builder from any key=value field set.
    # Why: Base-CI needs a service field too.
    # From: Issue #1683
    run _ci_matrix_append '[]' service=ui arch=amd64 runner=ubuntu-latest platform=linux/amd64
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].service')" = "ui" ]
    [ "$(printf '%s' "${output}" | jq -r '.[0].platform')" = "linux/amd64" ]
}

@test "plan-matrix emits only resolve-build targets, one row per platform" {
    # What: Matrix carries only what resolve says to build.
    # Why: identity filters, not path-sledgehammer.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix services/proxy/Dockerfile
    [ "${status}" -eq 0 ]
    grep -q '^any-build=true$' "${gh}"
    local m; m="$(grep '^matrix=' "${gh}" | sed 's/^matrix=//')"
    [ "$(printf '%s' "${m}" | jq '.include | length')" -eq 2 ]
    [ "$(printf '%s' "${m}" | jq -r '.include[0].service')" = "proxy" ]
    [ "$(printf '%s' "${m}" | jq -r '[.include[].platform]|sort|join(",")')" = "linux/amd64,linux/arm64" ]
}

@test "plan-matrix omits an accepted target (NOOP), any-build=false" {
    # What: An accepted identity is not rebuilt.
    # Why: NOOP/reuse precedes build; a skip stays out.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" CI_RESOLVE_PROBE_CMD="$(_stub p 'echo PRESENT_ACCEPTED')" \
        run bash "${CI_SH}" plan-matrix services/proxy/Dockerfile
    [ "${status}" -eq 0 ]
    grep -q '^any-build=false$' "${gh}"
    local m; m="$(grep '^matrix=' "${gh}" | sed 's/^matrix=//')"
    [ "$(printf '%s' "${m}" | jq '.include | length')" -eq 0 ]
}

# =========================================================
# SERVICE DEPENDENCIES
# =========================================================

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

# =========================================================
# BUILD IDENTITIES
# =========================================================

@test "identity is deterministic for one target+platform, keyed" {
    # What: Same content+platform -> same keyed id, always.
    # Why: NOOP/reuse depends on a stable identity.
    # From: Issue #1683
    run bash "${CI_SH}" identity ui linux/amd64
    [ "${status}" -eq 0 ]
    local first="${output}"
    run bash "${CI_SH}" identity ui linux/amd64
    [ "${output}" = "${first}" ]
    [[ "${output}" =~ ^platform=linux/amd64\ identity=[0-9a-f]{64}$ ]]
}

@test "identity differs across services and build types" {
    # What: proxy(apk), ui(rust), build-tools all differ.
    # Why: An id must key on its own inputs, not collide.
    # From: Issue #1683
    run bash "${CI_SH}" identity proxy linux/amd64
    [ "${status}" -eq 0 ]
    local proxy="${output}"
    run bash "${CI_SH}" identity build-tools linux/amd64
    [ "${status}" -eq 0 ]
    [ "${output}" != "${proxy}" ]
}

@test "an apk service resolves without a masked non-zero exit" {
    # What: identity/resolve of an apk service must exit 0.
    # Why: A printed id with rc=1 masks a broken pipeline.
    # From: Issue #1683
    run bash "${CI_SH}" identity ntp linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^platform=linux/amd64\ identity=[0-9a-f]{64}$ ]]
    run bash "${CI_SH}" resolve ntp linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"state=UNKNOWN"* ]]
}

@test "identity fails closed with a stable id when no service is given" {
    # What: Missing arg must not crash on set -u.
    # Why: Fail-closed with our own message, not a trace.
    # From: Issue #1683
    run bash "${CI_SH}" identity
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IDENTITY-0001"* ]]
}

# =========================================================
# PLATFORMS
# =========================================================

@test "identity fan-out lists every platform, always keyed" {
    # What: No platform arg -> one keyed line per platform.
    # Why: Default = all; output never mixes bare and keyed.
    # From: Issue #1683
    run bash "${CI_SH}" identity ui
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "${output}" == *"platform=linux/amd64 identity="* ]]
    [[ "${output}" == *"platform=linux/arm64 identity="* ]]
}

@test "a selected platform yields one line; amd64 and arm64 differ" {
    # What: Platform selects; each arch has its own id.
    # Why: An amd64 binary must not reuse an arm64 id.
    # From: Issue #1683
    run bash "${CI_SH}" identity ui linux/amd64
    [ "${status}" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    local a="${output}"
    run bash "${CI_SH}" identity ui linux/arm64
    [ "${output}" != "${a}" ]
}

@test "identity rejects a platform not in the target set" {
    # What: An unknown platform fails closed.
    # Why: Unknown input is an error, not a silent fan-out.
    # From: Issue #1683
    run bash "${CI_SH}" identity ui linux/riscv64
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
    amd_before="$(CI_MANIFEST="${m}" bash "${CI_SH}" identity netdata linux/amd64)"
    arm_before="$(CI_MANIFEST="${m}" bash "${CI_SH}" identity netdata linux/arm64)"
    sed -i 's/sha256_aarch64: [0-9a-f]\{64\}/sha256_aarch64: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "${m}"
    amd_after="$(CI_MANIFEST="${m}" bash "${CI_SH}" identity netdata linux/amd64)"
    arm_after="$(CI_MANIFEST="${m}" bash "${CI_SH}" identity netdata linux/arm64)"
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
    CI_MANIFEST="${m}" run bash "${CI_SH}" identity ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IDENTITY-0003"* ]]
    [[ "${output}" != *"identity="* ]]
}

@test "rust identity ignores comment-only and blank edits" {
    # What: A comment-only .rs edit keeps the same id.
    # Why: Comment churn must resolve to NOOP, not build.
    # From: Issue #1683
    local a b
    a="$(printf 'fn main() {}\n' | _ci_rust_content_hash)"
    b="$(printf '// note\nfn main() {}\n\n' | _ci_rust_content_hash)"
    [ -n "${a}" ]
    [ "${a}" = "${b}" ]
}

@test "rust identity keeps a // inside a string literal" {
    # What: Only line-start // is a comment, not in code.
    # Why: A naive strip would fuse distinct sources.
    # From: Issue #1683
    local a b
    a="$(printf 'let u = "//x";\n' | _ci_rust_content_hash)"
    b="$(printf 'let u = "//y";\n' | _ci_rust_content_hash)"
    [ "${a}" != "${b}" ]
}

@test "only compiled sources are identity-normalized" {
    # What: .rs normalizes; copied files stay raw-hashed.
    # Why: A hash in a .conf is payload; strip misreuses.
    # From: Issue #1683
    run _ci_source_is_normalizable "services/ui/src/main.rs"
    [ "${status}" -eq 0 ]
    run _ci_source_is_normalizable "services/proxy/nginx.conf"
    [ "${status}" -ne 0 ]
    run _ci_source_is_normalizable "services/proxy/entrypoint.sh"
    [ "${status}" -ne 0 ]
    run _ci_source_is_normalizable "services/ui/Dockerfile"
    [ "${status}" -ne 0 ]
}

@test "rust strip-safety rejects raw and multiline strings" {
    # What: Strip is safe without string-spanning lines.
    # Why: A raw or multiline string can carry a //-line.
    # From: Issue #1683
    run _ci_rust_strip_is_safe <<< $'fn main() {\n    let x = 1;\n}'
    [ "${status}" -eq 0 ]
    run _ci_rust_strip_is_safe <<< 'let j = r#"x"#;'
    [ "${status}" -ne 0 ]
    run _ci_rust_strip_is_safe <<< $'let s = "opens\nand runs on";'
    [ "${status}" -ne 0 ]
}

@test "raw-string // line is protected from wrong reuse" {
    # What: A // inside a raw string must not be stripped.
    # Why: Normalizing it would reuse a wrong image.
    # From: Issue #1683
    local a b
    a=$'let j = r#"\n// alpha\n"#;'
    b=$'let j = r#"\n// beta\n"#;'
    [ "$(printf '%s' "${a}" | _ci_rust_content_hash)" = "$(printf '%s' "${b}" | _ci_rust_content_hash)" ]
    run _ci_rust_strip_is_safe <<< "${a}"
    [ "${status}" -ne 0 ]
    run _ci_rust_strip_is_safe <<< "${b}"
    [ "${status}" -ne 0 ]
}

@test "impact fails closed without a base ref" {
    # What: impact needs an explicit base ref.
    # Why: No base means no comparison; never guess.
    # From: Issue #1683
    run bash "${CI_SH}" impact
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-IMPACT-0001"* ]]
}

@test "impact of a ref against itself is all NOOP" {
    # What: Identical refs rebuild nothing.
    # Why: No diff means no build; no rebuild.
    # From: Issue #1683
    run bash "${CI_SH}" impact HEAD HEAD
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"impact=NOOP"* ]]
    [[ "${output}" != *"impact=BUILD"* ]]
    [[ "${output}" == *"build=0"* ]]
}

@test "content ids read a given ref and stay comment-invariant" {
    # What: A ref reads that commit; comments do not count.
    # Why: impact diffs base vs head by ref, not index.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/refrepo"
    mkdir -p "${r}/svc"
    git -C "${r}" init -q
    git -C "${r}" config user.email t@t
    git -C "${r}" config user.name t
    printf 'fn main() {}\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm base
    local base; base="$(git -C "${r}" rev-parse HEAD)"
    printf 'fn main() { let x = 1; }\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm head
    local head; head="$(git -C "${r}" rev-parse HEAD)"
    printf '// note\nfn main() {}\n' > "${r}/svc/a.rs"
    git -C "${r}" add -A && git -C "${r}" commit -qm cmt
    local cmt; cmt="$(git -C "${r}" rev-parse HEAD)"
    local b h c
    b="$(CI_REPO_ROOT="${r}" _ci_tracked_content_ids svc "${base}")"
    h="$(CI_REPO_ROOT="${r}" _ci_tracked_content_ids svc "${head}")"
    c="$(CI_REPO_ROOT="${r}" _ci_tracked_content_ids svc "${cmt}")"
    [ -n "${b}" ]
    [ "${b}" != "${h}" ]
    [ "${b}" = "${c}" ]
}

@test "impact fails closed to UNKNOWN (escalate) when base has no SOT" {
    # What: A base without the SOT is UNKNOWN, not BUILD.
    # Why: No base truth MUST NOT authorize BUILD; escalate.
    # From: Issue #1683
    run bash "${CI_SH}" impact 4b825dc642cb6eb9a060e54bf8d69288fbee4904
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"no SOT at base"* ]]
    [[ "${output}" == *"impact=UNKNOWN"* ]]
    [[ "${output}" != *"impact=BUILD"* ]]
    [[ "${output}" != *"impact=NOOP"* ]]
}

@test "identity pins are ref-relative via CI_MANIFEST" {
    # What: A pin-only change shifts the id at a fixed ref.
    # Why: impact base pins must reflect base, not head.
    # From: Issue #1683
    local m1="${BATS_TEST_TMPDIR}/m1.yml" m2="${BATS_TEST_TMPDIR}/m2.yml"
    cp "${BATS_TEST_DIRNAME}/../yaml/build-manifest.yml" "${m1}"
    cp "${m1}" "${m2}"
    sed -i 's/sha256_x86_64: [0-9a-f]\{64\}/sha256_x86_64: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "${m2}"
    local a b
    a="$(CI_MANIFEST="${m1}" _ci_identity_for netdata linux/amd64 HEAD)"
    b="$(CI_MANIFEST="${m2}" _ci_identity_for netdata linux/amd64 HEAD)"
    [ -n "${a}" ]
    [ "${a}" != "${b}" ]
}

@test "resolve rejects a platform not in the target set" {
    # What: A selected unknown platform fails closed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" resolve ui linux/riscv64
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RESOLVE-0004"* ]]
}

@test "build rejects a platform not in the target set" {
    # What: A selected unknown platform fails closed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" build ui linux/riscv64
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0006"* ]]
}

@test "build tags its result line with the selected platform" {
    # What: A selected build emits one platform-keyed line.
    # Why: Downstream assembly keys per-platform digests.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" build ui linux/arm64
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

# =========================================================
# RESOLVER STATES
# =========================================================

# What: A stub probe that returns a fixed state.
# Why: Test the resolver logic without a live GHCR.
# From: Issue #1683
_probe_stub() {
    _stub probe.sh "printf '%s\\n' \"${STUB_STATE}\""
}

@test "resolve maps PRESENT_ACCEPTED to noop (DEFAULT=NOOP)" {
    # What: An accepted identity means no build.
    # Why: NOOP/reuse before build is the core rule.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" resolve ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"state=PRESENT_ACCEPTED"* ]]
    [[ "${output}" == *"action=noop"* ]]
}

@test "resolve maps MISSING_CONFIRMED to build" {
    # What: MISSING_CONFIRMED maps to the build action.
    # Why: resolver action; full BUILD_ACK gate is in build.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" resolve ui
    [[ "${output}" == *"action=build"* ]]
}

@test "resolve maps UNKNOWN to escalate, never build (UNKNOWN != BUILD)" {
    # What: Infra uncertainty must not trigger a build.
    # Why: UNKNOWN != BUILD (Contract section 4).
    # From: Issue #1683
    STUB_STATE=UNKNOWN
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" resolve ui
    [[ "${output}" == *"state=UNKNOWN"* ]]
    [[ "${output}" == *"action=escalate"* ]]
    [[ "${output}" != *"action=build"* ]]
}

@test "resolve with no probe wired defaults to UNKNOWN, not missing" {
    # What: No probe -> UNKNOWN, never assume missing.
    # Why: Absence of evidence is not evidence of absence.
    # From: Issue #1683
    run bash "${CI_SH}" resolve ui
    [[ "${output}" == *"state=UNKNOWN"* ]]
    [[ "${output}" == *"action=escalate"* ]]
}

@test "resolve fails closed when no service is given" {
    # What: Missing arg must fail with a stable id.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" resolve
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RESOLVE-0001"* ]]
}

# =========================================================
# RETRY CLASSIFICATION
# =========================================================

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

# =========================================================
# BUILD ADMISSION
# =========================================================

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
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=reuse-accepted"* ]]
}

@test "build refuses to build on UNKNOWN (escalate, not build)" {
    # What: UNKNOWN must never trigger a build.
    # Why: UNKNOWN != BUILD (Contract section 4).
    # From: Issue #1683
    STUB_STATE=UNKNOWN
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" build ui
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
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 0')" \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=reuse-binary-cas"* ]]
}

@test "build fails closed when GHCR credentials are missing (never anonymous)" {
    # What: A real build needs authenticated GHCR.
    # Why: Anonymous GHCR is rate-limited (maintainer).
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 1')" \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "build runs the backend only with full admission (impact+missing+auth)" {
    # What: The one build path: full BUILD_ACK conjunction.
    # Why: impact & MISSING_CONFIRMED & identity.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 1')" \
    CI_BUILD_CMD="$(_stub build 'exit 0')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"state=BUILD_ACK"* ]]
    [[ "${output}" == *"result=built"* ]]
}

@test "resolve maps MISMATCH to fail, never build" {
    # What: MISMATCH is a detected contradiction.
    # Why: MISMATCH MUST fail, never build (Contract 77 K).
    # From: Issue #1683
    STUB_STATE=MISMATCH
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" resolve ui
    [[ "${output}" == *"state=MISMATCH"* ]]
    [[ "${output}" == *"action=fail"* ]]
    [[ "${output}" != *"action=build"* ]]
}

@test "build fails on MISMATCH: no build, no replacement build" {
    # What: MISMATCH never reaches the build backend.
    # Why: replacement build = 0 (Contract 77 Test K).
    # From: Issue #1683
    STUB_STATE=MISMATCH
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 1')" \
    CI_BUILD_CMD="$(_stub build 'echo BUILD_BACKEND_INVOKED')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"result=fail-mismatch"* ]]
    [[ "${output}" == *"CI-ERROR-BUILD-0010"* ]]
    [[ "${output}" != *"BUILD_BACKEND_INVOKED"* ]]
    [[ "${output}" != *"result=built"* ]]
}

@test "resolve treats a failed probe backend as UNKNOWN, not its stdout" {
    # What: A non-zero probe is UNKNOWN, not its state.
    # Why: A failed probe MUST NOT build (AG-VAL-030).
    # From: Issue #1683
    CI_RESOLVE_PROBE_CMD="$(_stub probe 'echo MISSING_CONFIRMED; exit 7')" \
        run bash "${CI_SH}" resolve ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"state=UNKNOWN"* ]]
    [[ "${output}" == *"action=escalate"* ]]
    [[ "${output}" != *"action=build"* ]]
}

@test "build with a failed probe backend escalates and never builds" {
    # What: probe rc!=0 -> UNKNOWN -> escalate, no backend.
    # Why: the exact committed regression this fix closes.
    # From: Issue #1683
    CI_RESOLVE_PROBE_CMD="$(_stub probe 'echo MISSING_CONFIRMED; exit 7')" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 1')" \
    CI_BUILD_CMD="$(_stub build 'echo BUILD_BACKEND_INVOKED')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"result=escalate"* ]]
    [[ "${output}" != *"BUILD_BACKEND_INVOKED"* ]]
    [[ "${output}" != *"result=built"* ]]
}

@test "build refuses MISSING_CONFIRMED without proven semantic impact" {
    # What: confirmed-missing + impact=NOOP -> no build.
    # Why: MISSING_CONFIRMED alone MUST NOT build.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo NOOP')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 1')" \
    CI_BUILD_CMD="$(_stub build 'echo BUILD_BACKEND_INVOKED')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=no-build-no-impact"* ]]
    [[ "${output}" != *"BUILD_BACKEND_INVOKED"* ]]
    [[ "${output}" != *"result=built"* ]]
}

@test "build fails closed when semantic impact is not wired (escalate)" {
    # What: no impact backend -> UNKNOWN -> escalate.
    # Why: unproven impact MUST NOT authorize build.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 1')" \
    CI_BUILD_CMD="$(_stub build 'echo BUILD_BACKEND_INVOKED')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"result=escalate"* ]]
    [[ "${output}" != *"BUILD_BACKEND_INVOKED"* ]]
}

# =========================================================
# TEST / SCAN
# =========================================================

@test "test fails closed and shows raw output when tests fail" {
    # What: A failed test run is a failed run (AG-VAL-002).
    # Why: Never skip or swallow a real test failure.
    # From: Issue #1683
    CI_TEST_CMD="$(_stub t 'echo boom; exit 1')" run bash "${CI_SH}" test ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-TEST-0003"* ]]
    [[ "${output}" == *"boom"* ]]
}

@test "test passes when the backend succeeds" {
    # What: Green backend -> tested=ok.
    # Why: The one success path.
    # From: Issue #1683
    CI_TEST_CMD="$(_stub t 'exit 0')" run bash "${CI_SH}" test ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
}

@test "scan rejects a /tmp (tmpfs) TMPDIR, requires /var/tmp" {
    # What: tmpfs /tmp risks OOM on image/db export.
    # Why: All CI staging is /var/tmp (maintainer rule).
    # From: Issue #1683
    CI_TMPDIR=/tmp CI_SCAN_CMD="$(_stub s 'exit 0')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0003"* ]]
}

@test "scan is clean on /var/tmp with auth and a passing backend" {
    # What: authed + /var/tmp + green scan -> clean.
    # Why: The one success path for scan.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 0')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"scanned=clean"* ]]
    [[ "${output}" == *"tmpdir=/var/tmp"* ]]
}

@test "scan fails closed without GHCR auth" {
    # What: Scan pulls the image -> authenticated.
    # Why: Never anonymous (rate-limit).
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 0')" run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

# =========================================================
# CACHE FALLBACK
# =========================================================

# =========================================================
# REGISTRY / PUBLISH / READBACK
# =========================================================

@test "publish fails closed without GHCR credentials" {
    # What: Publish is an authenticated GHCR action.
    # Why: Never push anonymously (rate-limit).
    # From: Issue #1683
    CI_PUBLISH_CMD="$(_stub pub 'echo sha256:abc')" run bash "${CI_SH}" publish ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "publish returns the backend digest when authed" {
    # What: A successful push reports its digest.
    # Why: The digest is the ref the next phase verifies.
    # From: Issue #1683
    CI_PUBLISH_CMD="$(_stub pub 'echo sha256:deadbeef')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" publish ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"published=sha256:deadbeef"* ]]
}

@test "verify passes when the readback digest matches" {
    # What: readback == expected -> verified.
    # Why: Confirms the accepted artifact is the real one.
    # From: Issue #1683
    CI_READBACK_CMD="$(_stub rb 'echo sha256:match')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" verify ui sha256:match
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"verified=sha256:match"* ]]
}

@test "verify fails with MISMATCH and shows raw readback (BUILT != ACCEPTED)" {
    # What: readback != expected -> hard fail + raw.
    # Why: A mismatch must never be accepted (§7).
    # From: Issue #1683
    CI_READBACK_CMD="$(_stub rb 'echo sha256:other')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" verify ui sha256:expected
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERIFY-0005"* ]]
    [[ "${output}" == *"MISMATCH"* ]]
    [[ "${output}" == *"readback=sha256:other"* ]]
}

# =========================================================
# ASSEMBLY
# =========================================================

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
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0002"* ]]
    [[ "${output}" != *"result=assembled"* ]]
}

@test "assemble refuses PRODUCED_UNVERIFIED (fail-safe stays DISACK)" {
    # What: Unverified is not ACCEPTED, so no assembly.
    # Why: Fail-safe: unaccepted stays a GC candidate.
    # From: Issue #1683
    STUB_STATE=PRODUCED_UNVERIFIED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" run bash "${CI_SH}" assemble ui
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
        run bash "${CI_SH}" assemble ui
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
        run bash "${CI_SH}" assemble ui
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
        run bash "${CI_SH}" assemble ui
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
        run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "assemble fails when an ACCEPTED platform has no digest" {
    # What: ACCEPTED but no digest is an inconsistency.
    # Why: Fail closed, never assemble a partial index.
    # From: Issue #1683
    STUB_STATE=PRESENT_ACCEPTED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" assemble ui
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0003"* ]]
}

@test "assemble fails closed when no service is given" {
    # What: Missing arg must fail with a stable id.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" assemble
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-ASSEMBLE-0001"* ]]
}

# =========================================================
# PROMOTION
# =========================================================

# What: A candidate holding all 10 product services.
# Why: Stack-atomic promotion needs every service.
# From: Issue #1683
_promote_full_candidate() {
    _stub cand "for s in proxy dns watchdog dhcp dhcp-proxy ntp syslog ui cachehamster netdata; do echo \"\$s=$1\"; done"
}
_promote_lock() { _stub lock 'echo "LOCK $1" >> "${BATS_TEST_TMPDIR}/lock.log"'; }
_promote_unlock() { _stub unlock 'echo "UNLOCK $1" >> "${BATS_TEST_TMPDIR}/lock.log"'; }

@test "promote fails closed when no channel is given" {
    # What: Missing arg must fail with a stable id.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" promote
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0001"* ]]
}

@test "promote rejects a channel not in the mutable SOT set" {
    # What: Only known mutable channels may be moved.
    # Why: promote moves refs only; no invented list.
    # From: Issue #1683
    run bash "${CI_SH}" promote bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0002"* ]]
}

@test "promote refuses an incomplete stack (no promote at 8/9)" {
    # What: A missing service blocks the promotion.
    # Why: Promotion is stack-atomic (docs section 50).
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0004"* ]]
}

@test "promote blocks when the stack is not validated" {
    # What: Stack validation is a precondition.
    # Why: Fail-closed without validate (docs section 50).
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0005"* ]]
}

@test "promote fails closed without GHCR auth" {
    # What: Moving refs is an authenticated action.
    # Why: Never anonymous (rate-limit).
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "promote moves refs, confirms readback, releases lock" {
    # What: Fresh promote: lock, move, readback, unlock.
    # Why: The one success path (docs section 51/53).
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'touch "${BATS_TEST_TMPDIR}/moved.$1"')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "[ -f \"\${BATS_TEST_TMPDIR}/moved.\$1\" ] && echo ${dig} || true")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=promoted"* ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/lock.log")" == *"UNLOCK nightly"* ]]
}

@test "promote is idempotent: all refs current, no lock taken" {
    # What: A re-run reuses the state, takes no lock.
    # Why: Same end state on retry (docs section 26.4).
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'true')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "echo ${dig}")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=already-promoted"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/lock.log" ]
}

@test "promote fails on readback MISMATCH but frees the lock" {
    # What: A mismatch fails closed, never leaks the lock.
    # Why: A held lock blocks all future promotions.
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    local other="sha256:$(printf 'b%.0s' {1..64})"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'true')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "echo ${other}")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0009"* ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/lock.log")" == *"UNLOCK nightly"* ]]
}

# =========================================================
# RELEASE
# =========================================================

@test "release fails closed without a validation backend" {
    # What: No freshness verdict must stop the release.
    # Why: Unverified validation is not releasable.
    # From: Issue #1683
    run bash "${CI_SH}" release
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0001"* ]]
}

@test "release fails closed when validation is not fresh" {
    # What: A stale/failed verdict blocks the release.
    # Why: AG-REL-011 requires still-valid validation.
    # From: Issue #1683
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 1')" \
        run bash "${CI_SH}" release
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-RELEASE-0001"* ]]
}

@test "release verifies freshness then promotes latest" {
    # What: Fresh verdict promotes the exact candidate.
    # Why: latest promote is the release success path.
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 0')" \
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'touch "${BATS_TEST_TMPDIR}/moved.$1"')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "[ -f \"\${BATS_TEST_TMPDIR}/moved.\$1\" ] && echo ${dig} || true")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" release
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"channel=latest"* ]]
    [[ "${output}" == *"result=promoted"* ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/lock.log")" == *"UNLOCK latest"* ]]
}

@test "release is idempotent when latest is already current" {
    # What: A re-run promotes nothing, takes no lock.
    # Why: Same end state on retry (docs section 26.4).
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 0')" \
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
    CI_PROMOTE_LOCK_CMD="$(_promote_lock)" CI_PROMOTE_UNLOCK_CMD="$(_promote_unlock)" \
    CI_PROMOTE_MOVE_CMD="$(_stub mv 'true')" \
    CI_CHANNEL_READBACK_CMD="$(_stub rb "echo ${dig}")" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" release
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=already-promoted"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/lock.log" ]
}

@test "release runs the promote gates, not a second model" {
    # What: Fresh verdict still needs a complete stack.
    # Why: One acceptance model; promote gates apply.
    # From: Issue #1683
    local dig="sha256:$(printf 'a%.0s' {1..64})"
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 0')" \
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" release
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0004"* ]]
}

# =========================================================
# GC
# =========================================================

_gc_roots() { _stub roots 'printf "latest\nnightly\n"'; }

@test "gc fails closed with no roots backend wired" {
    # What: Missing roots backend must fail, not proceed.
    # Why: No roots means every artifact looks unreachable.
    # From: Issue #1683
    run bash "${CI_SH}" gc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0001"* ]]
}

@test "gc fails closed on an empty protected-roots set" {
    # What: An empty roots set must stop the pass.
    # Why: Empty roots would mark all artifacts unreachable.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_stub roots 'true')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0007"* ]]
}

@test "gc fails closed with no candidate source wired" {
    # What: Missing candidate source must fail closed.
    # Why: SQLite is the only candidate source (§97).
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0002"* ]]
}

@test "gc is a NOOP when the candidate set is empty" {
    # What: Zero candidates is a clean no-op, not a failure.
    # Why: DEFAULT=NOOP; a clean repo must exit success.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" CI_GC_CANDIDATES_CMD="$(_stub cands 'true')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=noop candidates=0"* ]]
}

@test "gc keeps a candidate that is still referenced" {
    # What: A referenced candidate is kept, not deleted.
    # Why: SQLite may be stale; registry truth wins (§97).
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-abc')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'echo referenced')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"candidate=sha-abc action=KEEP"* ]]
}

@test "gc marks an unreachable candidate DELETE in dry-run" {
    # What: Dry-run classifies but never deletes.
    # Why: Default dry-run per SOT deletion_policy.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-old')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'echo unreachable')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"candidate=sha-old action=DELETE mode=dry-run"* ]]
}

@test "gc fails closed on an UNKNOWN reachability verdict" {
    # What: UNKNOWN neither deletes nor keeps.
    # Why: UNKNOWN is a probe bug to fix, not a keep/delete.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-x')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'echo dunno')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0005"* ]]
}

@test "gc fails closed with no reachability backend wired" {
    # What: Missing reachability backend must fail closed.
    # Why: No probe means no safe delete decision (§97).
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-x')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0003"* ]]
}

@test "gc fails closed when the reachability probe itself fails" {
    # What: A failed probe stops the pass.
    # Why: No verdict means no delete decision is safe.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-x')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'exit 3')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0004"* ]]
}

@test "gc rejects an unknown argument" {
    # What: An unrecognized argument must fail closed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" gc --bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0006"* ]]
}

@test "gc apply fails closed without GHCR auth" {
    # What: Deleting artifacts is an authenticated action.
    # Why: Never anonymous against GHCR (rate-limit).
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-old')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'echo unreachable')" \
        run bash "${CI_SH}" gc --apply
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "gc apply fails closed with no delete backend" {
    # What: apply needs a delete backend to act.
    # Why: apply must never no-op silently while deleting.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-old')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'echo unreachable')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" gc --apply
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0010"* ]]
}

@test "gc apply refuses when the SOT policy forbids automation" {
    # What: apply obeys the SOT deletion_policy gate.
    # Why: A manual-only policy must block automated delete.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/sot.yml"
    printf 'retention:\n  deletion_policy: manual-only\n' > "${m}"
    CI_MANIFEST="${m}" \
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-old')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'echo unreachable')" \
    CI_GC_DELETE_CMD="$(_stub del 'echo "$1" >> "${BATS_TEST_TMPDIR}/deleted.log"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" gc --apply
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0008"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/deleted.log" ]
}

@test "gc apply denies a policy that only contains 'automation'" {
    # What: A negated automation policy must not delete.
    # Why: The allow-list is exact, not a substring match.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/sot.yml"
    printf 'retention:\n  deletion_policy: automation-forbidden\n' > "${m}"
    CI_MANIFEST="${m}" \
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-old')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'echo unreachable')" \
    CI_GC_DELETE_CMD="$(_stub del 'echo "$1" >> "${BATS_TEST_TMPDIR}/deleted.log"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" gc --apply
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0008"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/deleted.log" ]
}

@test "gc apply deletes nothing when any candidate is UNKNOWN" {
    # What: One UNKNOWN aborts before the delete pass runs.
    # Why: Two passes: classify all, then delete (safety).
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'printf "sha-good\nsha-bad\n"')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'case "$1" in *good*) echo unreachable;; *) echo dunno;; esac')" \
    CI_GC_DELETE_CMD="$(_stub del 'echo "$1" >> "${BATS_TEST_TMPDIR}/deleted.log"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" gc --apply
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0005"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/deleted.log" ]
}

@test "gc apply deletes an unreachable candidate via the backend" {
    # What: apply deletes verified-unreachable only.
    # Why: The one destructive path, gated + authed.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-old')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'echo unreachable')" \
    CI_GC_DELETE_CMD="$(_stub del 'echo "$1" >> "${BATS_TEST_TMPDIR}/deleted.log"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" gc --apply
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=classified keep=0 delete=1 deleted=1 mode=apply"* ]]
    [[ "$(cat "${BATS_TEST_TMPDIR}/deleted.log")" == *"sha-old"* ]]
}

@test "gc apply skips a candidate that becomes referenced before delete" {
    # What: Skip a now-referenced id before delete.
    # Why: Check-before-write closes the TOCTOU gap.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_gc_roots)" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'echo sha-old')" \
    CI_GC_REACHABLE_CMD="$(_stub reach 'f="${BATS_TEST_TMPDIR}/seen"; if [ -f "$f" ]; then echo referenced; else : > "$f"; echo unreachable; fi')" \
    CI_GC_DELETE_CMD="$(_stub del 'echo "$1" >> "${BATS_TEST_TMPDIR}/deleted.log"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" gc --apply
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-INFO-GC-0011"* ]]
    [[ "${output}" == *"deleted=0"* ]]
    [ ! -f "${BATS_TEST_TMPDIR}/deleted.log" ]
}

# =========================================================
# VALIDATION
# =========================================================

@test "validate fails closed with no stack candidate" {
    # What: No candidate source means nothing to validate.
    # Why: Fail closed, never validate a phantom stack.
    # From: Issue #1683
    run bash "${CI_SH}" validate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0001"* ]]
}

@test "validate fails closed on an empty stack candidate" {
    # What: An empty candidate cannot be validated.
    # Why: Fail closed, never accept an empty stack.
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub cand 'true')" \
        run bash "${CI_SH}" validate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0002"* ]]
}

@test "validate fails closed without GHCR auth" {
    # What: Deploying the stack pulls images; needs auth.
    # Why: Never anonymous against GHCR (rate-limit).
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub cand 'echo proxy=sha256:x')" \
        run bash "${CI_SH}" validate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "validate fails closed with no validation backend" {
    # What: No backend means the stack cannot be started.
    # Why: Fail closed, never fake a clean stack.
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub cand 'echo proxy=sha256:x')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" validate
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0003"* ]]
}

@test "validate fails with raw evidence when the stack is unhealthy" {
    # What: A failed validation run surfaces its raw output.
    # Why: Raw failure evidence is mandatory (AG-INT-002).
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub cand 'echo proxy=sha256:x')" \
    CI_VALIDATE_CMD="$(_stub val 'echo STACK-UNHEALTHY; exit 1')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0004"* ]]
    [[ "${output}" == *"STACK-UNHEALTHY"* ]]
}

@test "validate accepts a healthy stack candidate" {
    # What: A passing run yields STACK_ACCEPTED.
    # Why: The one success path feeding promote (§49/§50).
    # From: Issue #1683
    CI_STACK_CANDIDATE_CMD="$(_stub cand 'echo proxy=sha256:x')" \
    CI_VALIDATE_CMD="$(_stub val 'exit 0')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" validate
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=STACK_ACCEPTED"* ]]
}

# =========================================================
# VARIABLES
# =========================================================

@test "variables get reads a value from the SOT fallback" {
    # What: With no env override, the SOT default is used.
    # Why: AG-CI-006 fallback, like CARGO_BUILD_JOBS.
    # From: Issue #1683
    run bash "${CI_SH}" variables get REPOSITORY_CI_LEDGER_RETENTION_DAYS
    [ "${status}" -eq 0 ]
    [ "${output}" = "30" ]
}

@test "variables get lets an env value override the SOT default" {
    # What: A set env value wins over the SOT fallback.
    # Why: AG-CI-006: use the variable when set.
    # From: Issue #1683
    REPOSITORY_CI_LEDGER_RETENTION_DAYS=45 \
        run bash "${CI_SH}" variables get REPOSITORY_CI_LEDGER_RETENTION_DAYS
    [ "${status}" -eq 0 ]
    [ "${output}" = "45" ]
}

@test "variables get fails closed with no env and no SOT default" {
    # What: An unknown variable has no value anywhere.
    # Why: Fail closed, never emit an empty value.
    # From: Issue #1683
    run bash "${CI_SH}" variables get NONEXISTENT_VAR_XYZ
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0001"* ]]
}

@test "variables get fails closed with no variable name" {
    # What: A missing name must fail, not read blank.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" variables get
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0003"* ]]
}

@test "variables rejects an unknown subcommand" {
    # What: Only known subcommands are routed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" variables bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0002"* ]]
}

@test "bake-check fails closed without an image ref" {
    # What: bake-check needs an explicit image ref.
    # Why: No target means no proof; never pass blind.
    # From: Issue #1683
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0008"* ]]
}

@test "bake-check fails closed without GHCR auth" {
    # What: Image inspect must be authenticated.
    # Why: GHCR is never accessed anonymously.
    # From: Issue #1683
    run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "bake-check fails closed with no inspect backend" {
    # What: No inspect backend is a hard failure.
    # Why: Unverifiable is not clean (AG-VAL-002).
    # From: Issue #1683
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0004"* ]]
}

@test "bake-check passes on a clean image" {
    # What: No forbidden var and no extra CA is clean.
    # Why: A clean image must not be blocked.
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env PATH=/usr/bin"; echo "env LANG=C"; echo "extra_ca 0"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=clean"* ]]
}

@test "bake-check fails on a baked proxy and hides the value" {
    # What: A baked HTTP_PROXY fails; log the key only.
    # Why: AG-SEC-007: never emit the secret value.
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env HTTP_PROXY=http://10.0.0.9:3128"; echo "extra_ca 0"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0006"* ]]
    [[ "${output}" == *'key="HTTP_PROXY"'* ]]
    [[ "${output}" != *"10.0.0.9"* ]]
}

@test "bake-check fails on a baked accel var by prefix" {
    # What: An SCCACHE_/CCACHE_/DISTCC_ var is forbidden.
    # Why: Accel endpoints are LAN-only, must not bake.
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env SCCACHE_REDIS=redis://h:6379"; echo "extra_ca 0"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0006"* ]]
    [[ "${output}" == *'key="SCCACHE_REDIS"'* ]]
}

@test "bake-check fails on a baked CA and shows only a count" {
    # What: An extra CA in the store fails the guard.
    # Why: Log the count, never the certificate bytes.
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env PATH=/usr/bin"; echo "extra_ca 1"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0007"* ]]
    [[ "${output}" == *'extra_ca="1"'* ]]
    [[ "${output}" != *"BEGIN CERTIFICATE"* ]]
}

@test "bake-check fails closed on an unknown inspect line" {
    # What: An unrecognized inspect line is not ignored.
    # Why: Silent skip could hide a real leak (fail-closed).
    # From: Issue #1683
    CI_BAKE_INSPECT_CMD="$(_stub insp 'echo "env PATH=/usr/bin"; echo "mystery 1"; echo "extra_ca 0"')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" variables bake-check img@sha256:d
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0009"* ]]
}

@test "no Dockerfile mounts the legacy proxy_ca secret id" {
    # What: Every CA mount uses the canonical secret id.
    # Why: A stray proxy_ca = a silently CA-less build.
    # From: Issue #1683
    local root="${BATS_TEST_DIRNAME}/../.."
    run git -C "${root}" grep -nE '(^|[^_])proxy_ca([^a-z_]|$)' -- services tools
    [ "${status}" -ne 0 ]
}

@test "every Dockerfile secret mount id is in the central list" {
    # What: Mounted secret ids come from the one list.
    # Why: No drift; one source drives provisioning.
    # From: Issue #1683
    local root="${BATS_TEST_DIRNAME}/../.." allow ids id
    allow="$(_ci_runtime_secret_ids)"
    ids="$(git -C "${root}" grep -hoE 'mount=type=secret,id=[a-z0-9_]+' -- services tools | sed 's/.*id=//' | sort -u)"
    [ -n "${ids}" ]
    while IFS= read -r id; do
        [ -n "${id}" ] || continue
        printf '%s\n' "${allow}" | grep -qx "${id}"
    done <<< "${ids}"
}

@test "set-runtime rejects an invalid redis mode" {
    # What: SCCACHE_REDIS_MODE is a closed enum.
    # Why: An unknown mode is an error, not a guess.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=bogus \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0010"* ]]
}

@test "set-runtime errors on scheduler without auth token" {
    # What: dist scheduler and token are both-or-neither.
    # Why: A half config would build misauthenticated.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_URL='redis://h' \
    SCCACHE_DIST_SCHEDULER_URL='https://s' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0011"* ]]
}

@test "set-runtime errors when required redis url is missing" {
    # What: mode=required needs SCCACHE_REDIS_URL.
    # Why: A trusted Rust build must have the cache.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=required \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0012"* ]]
}

@test "set-runtime optional mode skips redis when url is empty" {
    # What: mode=optional tolerates a missing redis url.
    # Why: The cache is an optimization, not required.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=optional \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"sccache_redis_url"* ]]
}

@test "set-runtime off mode emits no acceleration secrets" {
    # What: mode=off disables sccache and its redis.
    # Why: A build without the cache must still work.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=off \
    SCCACHE_REDIS_URL='redis://h' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"sccache_redis_url"* ]]
    [[ "${output}" != *"sccache_dist_config"* ]]
}

@test "set-runtime rejects distcc hosts without a pump host" {
    # What: DISTCC_POTENTIAL_HOSTS needs a ,cpp host.
    # Why: Pump mode needs a cpp-capable host present.
    # From: Issue #1683
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt" SCCACHE_REDIS_MODE=off \
    DISTCC_POTENTIAL_HOSTS='h1 h2' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0013"* ]]
}

@test "set-runtime writes 0600 files and hides secret values" {
    # What: Each secret is a 0600 file + a --secret arg.
    # Why: AG-SEC-007: values never reach stdout or args.
    # From: Issue #1683
    local d="${BATS_TEST_TMPDIR}/rt"
    CI_RUNTIME_SECRET_DIR="${d}" SCCACHE_REDIS_MODE=required \
    SCCACHE_REDIS_URL='redis://h:6379' PROJECT_SELFHOSTED_PROXY_CA='CADATA' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--secret id=sccache_redis_url,src=${d}/sccache_redis_url"* ]]
    [[ "${output}" == *"--secret id=ccache_redis_url,src=${d}/ccache_redis_url"* ]]
    [[ "${output}" == *"--secret id=project_selfhosted_proxy_ca,src=${d}/project_selfhosted_proxy_ca"* ]]
    [[ "${output}" != *"redis://h:6379"* ]]
    [[ "${output}" != *"CADATA"* ]]
    [ "$(stat -c '%a' "${d}/project_selfhosted_proxy_ca")" = "600" ]
    [ "$(cat "${d}/sccache_redis_url")" = "redis://h:6379" ]
}

@test "set-runtime assembles the sccache dist config toml" {
    # What: The dist config carries scheduler and token.
    # Why: sccache dist needs both to reach the scheduler.
    # From: Issue #1683
    local d="${BATS_TEST_TMPDIR}/rt"
    CI_RUNTIME_SECRET_DIR="${d}" SCCACHE_REDIS_MODE=required \
    SCCACHE_REDIS_URL='redis://h' SCCACHE_DIST_SCHEDULER_URL='https://sched' \
    SCCACHE_DIST_AUTH_TOKEN='tok123' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--secret id=sccache_dist_config,src=${d}/sccache_dist_config"* ]]
    grep -q 'scheduler_url = "https://sched"' "${d}/sccache_dist_config"
    grep -q 'token = "tok123"' "${d}/sccache_dist_config"
    [ "$(stat -c '%a' "${d}/sccache_dist_config")" = "600" ]
}

@test "clear-runtime removes the runtime secret dir" {
    # What: clear-runtime deletes every secret file.
    # Why: Secrets must not linger after the build.
    # From: Issue #1683
    local d="${BATS_TEST_TMPDIR}/rt"
    mkdir -p "${d}"; printf 'x' > "${d}/project_selfhosted_proxy_ca"
    CI_RUNTIME_SECRET_DIR="${d}" run bash "${CI_SH}" variables clear-runtime
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=cleared"* ]]
    [ ! -e "${d}/project_selfhosted_proxy_ca" ]
}

# =========================================================
# BUILD-ARGS EMISSION (SOT -> --build-arg)
# =========================================================

@test "build-args emits base + dhclient values from the SOT" {
    # What: SOT owns base + dhclient; apk tools unpinned.
    # Why: build-tools is a factory, not a version lock.
    # From: Issue #1683
    run bash "${CI_SH}" build-args build-tools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--build-arg ALPINE_IMAGE=mirror.gcr.io"* ]]
    [[ "${output}" == *"--build-arg DHCLIENT_VERSION="* ]]
    [[ "${output}" == *"--build-arg DHCLIENT_SHA256_AMD64="* ]]
    [[ "${output}" == *"--build-arg DHCLIENT_SHA256_ARM64="* ]]
    # What: no apk tool version is emitted anymore.
    # Why: normal apk pkgs must not be a version lock.
    # From: Issue #1683
    [[ "${output}" != *"DOCKER_CLI_VERSION"* ]]
    [[ "${output}" != *"SCCACHE_VERSION"* ]]
}

@test "build-args build-tools <platform> resolves one apk-arch + sha" {
    # What: platform yields DHCLIENT_APK_ARCH + one SHA256.
    # Why: ci.sh resolves the arch, not the Dockerfile.
    # From: Issue #1683
    run bash "${CI_SH}" build-args build-tools --bare linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DHCLIENT_APK_ARCH=x86_64"* ]]
    [[ "${output}" == *"DHCLIENT_SHA256="* ]]
    [[ "${output}" != *"DHCLIENT_SHA256_AMD64="* ]]
    run bash "${CI_SH}" build-args build-tools --bare linux/arm64
    [[ "${output}" == *"DHCLIENT_APK_ARCH=aarch64"* ]]
}

@test "build-tools build-args-out emits one platform's args" {
    # What: build-args-out writes per-platform args.
    # Why: each build job resolves its own arch.
    # From: Issue #1683
    local gho="${BATS_TEST_TMPDIR}/out.txt"; : > "${gho}"
    run env GITHUB_OUTPUT="${gho}" bash "${CI_SH}" build-tools build-args-out linux/arm64
    [ "${status}" -eq 0 ]
    grep -q '^build-args-bare<<' "${gho}"
    grep -q '^DHCLIENT_APK_ARCH=aarch64' "${gho}"
}

@test "build-args fails closed on a missing central base image" {
    # What: A missing base pin must never build unpinned.
    # Why: Empty value = FAIL CLOSED, no partial emit.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/no-rust-alpine.yml"
    grep -v '^  alpine:' "${BATS_TEST_DIRNAME}/../yaml/build-manifest.yml" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args build-tools
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0003"* ]]
}

@test "build-args --bare emits NAME=VALUE without the flag prefix" {
    # What: bare form feeds docker/build-push-action.
    # Why: that action wants NAME=VALUE, not --build-arg.
    # From: Issue #1683
    run bash "${CI_SH}" build-args build-tools --bare
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"DHCLIENT_VERSION="* ]]
    [[ "${output}" == *"ALPINE_IMAGE=mirror.gcr.io"* ]]
    [[ "${output}" != *"--build-arg"* ]]
}

@test "build-args rejects an unknown format (fail closed)" {
    # What: only empty or --bare are valid formats.
    # Why: an unknown flag must not emit a silent default.
    # From: Issue #1683
    run bash "${CI_SH}" build-args build-tools --bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0005"* ]]
}

@test "build-args needs a service argument (fail closed)" {
    # What: No service arg must not emit a silent success.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" build-args
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0001"* ]]
}

@test "build-args emits nothing for a non-toolchain target" {
    # What: Only build-tools owns SOT build-args today.
    # Why: An apk/rust service pins none centrally yet.
    # From: Issue #1683
    run bash "${CI_SH}" build-args proxy
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "build-tools packages lists the apk tools incl. AG-KD-009 set" {
    # What: The SOT feeds the apk input check.
    # Why: AG-KD-009 required tools must all be present.
    # From: Issue #1683
    run bash "${CI_SH}" build-tools packages
    [ "${status}" -eq 0 ]
    for pkg in rust cargo rust-clippy rustfmt actionlint cargo-audit \
               cargo-tarpaulin sccache distcc distcc-pump docker-cli \
               docker-cli-buildx docker-cli-compose; do
        printf '%s\n' "${output}" | grep -qx "${pkg}"
    done
}

@test "build-tools packages reads only build_toolchain.build-tools.packages" {
    # What: same-named packages elsewhere must be ignored.
    # Why: the reader must bind the exact block+entry path.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/other.yml"
    printf 'services:\n  proxy:\n    packages:\n      - WRONG_SVC\n' > "${m}"
    printf 'build_toolchain:\n  build-tools:\n    packages:\n      - right-one\n  other-tool:\n    packages:\n      - WRONG_ENTRY\n' >> "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-tools packages
    [ "${status}" -eq 0 ]
    [ "${output}" = "right-one" ]
}

@test "build-tools packages fails closed on an empty SOT list" {
    # What: no packages in the SOT must not pass.
    # Why: an empty list would blind the input check.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/nopkgs.yml"
    printf 'build_toolchain:\n  build-tools:\n    context: tools/build-tools\n' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-tools packages
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0006"* ]]
}

@test "build-tools signature: same canonical apk state gives same sig" {
    # What: same inputs -> same signature; a bump moves it.
    # Why: weekly check rebuilds only on a real change.
    # From: Issue #1683
    local a b c
    a="$(bash "${CI_SH}" build-tools signature "sccache-0.15.0-r0")"
    b="$(bash "${CI_SH}" build-tools signature "sccache-0.15.0-r0")"
    c="$(bash "${CI_SH}" build-tools signature "sccache-0.16.0-r0")"
    [ -n "${a}" ]
    [ "${a}" = "${b}" ]
    [ "${a}" != "${c}" ]
}

@test "build-tools signature fails closed on empty apk state" {
    # What: a blank apk version state must not sign.
    # Why: a blank scan must never mint a stable signature.
    # From: Issue #1683
    run bash "${CI_SH}" build-tools signature ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0004"* ]]
    run bash "${CI_SH}" build-tools signature "   "
    [ "${status}" -eq 2 ]
}

@test "build-tools signature moves on a dhclient value change" {
    # What: a dhclient version/checksum bump moves the sig.
    # Why: all emitted build-args must feed the signature.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/dh.yml" base changed
    base="$(bash "${CI_SH}" build-tools signature "sccache-0.15.0-r0")"
    sed 's/sha256_amd64: 068c97e534e9c8f03db9064296b1d3c21d957f328e40309278559a92f9a74557/sha256_amd64: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' \
        "${BATS_TEST_DIRNAME}/../yaml/build-manifest.yml" > "${m}"
    changed="$(CI_MANIFEST="${m}" bash "${CI_SH}" build-tools signature "sccache-0.15.0-r0")"
    [ -n "${base}" ]
    [ -n "${changed}" ]
    [ "${base}" != "${changed}" ]
}

@test "build-tools arches lists every build_matrix apk arch" {
    # What: the signature must cover every supported arch.
    # Why: an arm64-only change must be representable.
    # From: Issue #1683
    run bash "${CI_SH}" build-tools arches
    [ "${status}" -eq 0 ]
    printf '%s\n' "${output}" | grep -qx "x86_64"
    printf '%s\n' "${output}" | grep -qx "aarch64"
}

@test "build-tools signature moves on an arm64-only apk change" {
    # What: an aarch64-only change moves the sig.
    # Why: an arm64-only package bump must not be a NOOP.
    # From: Issue #1683
    local a b
    a="$(bash "${CI_SH}" build-tools signature "x86_64:sccache-0.15.0-r0 aarch64:sccache-0.15.0-r0")"
    b="$(bash "${CI_SH}" build-tools signature "x86_64:sccache-0.15.0-r0 aarch64:sccache-0.16.0-r0")"
    [ -n "${a}" ]
    [ "${a}" != "${b}" ]
}

@test "build-tools gate: an unchanged signature is a NOOP" {
    # What: same current/published sig builds nothing.
    # Why: unchanged inputs must not rebuild.
    # From: Issue #1683
    run bash "${CI_SH}" build-tools gate both check SIG SIG
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build-amd64=false"* ]]
    [[ "${output}" == *"build-arm64=false"* ]]
    [[ "${output}" == *'"include":[]'* ]]
}

@test "build-tools gate: a changed signature builds the arches" {
    # What: changed sig or mode=build selects arches.
    # Why: a real change or a forced build must build.
    # From: Issue #1683
    run bash "${CI_SH}" build-tools gate both check SIG OLD
    [[ "${output}" == *"build-amd64=true"* ]]
    [[ "${output}" == *"build-arm64=true"* ]]
    [[ "${output}" == *'"arch":"amd64"'* ]]
    [[ "${output}" == *'"arch":"arm64"'* ]]
    run bash "${CI_SH}" build-tools gate amd64 build SIG SIG
    [[ "${output}" == *"build-amd64=true"* ]]
    [[ "${output}" == *"build-arm64=false"* ]]
}

@test "build-tools gate fails closed on an empty current sig" {
    # What: no current signature must not decide.
    # Why: an empty gate input is fail-closed.
    # From: Issue #1683
    run bash "${CI_SH}" build-tools gate both check "" X
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0013"* ]]
}

@test "build-tools resolve-signature uses the injected resolver" {
    # What: the apk resolver is injectable for tests.
    # Why: signature logic is proven without a container.
    # From: Issue #1683
    local mock; mock="$(_stub apk.sh 'echo "sccache-0.15.0-r0 fake-$2-1.0-r0"')"
    run env CI_APK_RESOLVE_CMD="${mock}" bash "${CI_SH}" build-tools resolve-signature
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

@test "build-tools published-signature uses the injected reader" {
    # What: the registry read is injectable for tests.
    # Why: no live GHCR needed to prove the gate.
    # From: Issue #1683
    local mock; mock="$(_stub pub.sh 'echo PUB-123')"
    run env CI_PUBLISHED_SIG_CMD="${mock}" bash "${CI_SH}" build-tools published-signature img:latest
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PUB-123"* ]]
}

@test "build-tools merge uses the injected assembler" {
    # What: the manifest assembly is injectable.
    # Why: no live registry needed to prove the call.
    # From: Issue #1683
    local mock; mock="$(_stub merge.sh 'echo "merged sha=$1"')"
    run env CI_MERGE_CMD="${mock}" bash "${CI_SH}" build-tools merge abc123
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"merged sha=abc123"* ]]
}

@test "build-tools plan writes every determine-job output" {
    # What: plan emits all outputs to $GITHUB_OUTPUT.
    # Why: the run-block stays a single pure ci.sh call.
    # From: Issue #1683
    local apk pub gho
    apk="$(_stub apk.sh 'echo "sccache-0.15.0-r0 fake-$2-1.0-r0"')"
    pub="$(_stub pub.sh 'echo OLD-SIG')"
    gho="${BATS_TEST_TMPDIR}/out.txt"; : > "${gho}"
    run env CI_APK_RESOLVE_CMD="${apk}" CI_PUBLISHED_SIG_CMD="${pub}" \
        BUILD_TOOLS_IMAGE=example/build-tools BT_ARCH=both BT_MODE=check \
        GITHUB_OUTPUT="${gho}" \
        bash "${CI_SH}" build-tools plan
    [ "${status}" -eq 0 ]
    grep -q '^signature=' "${gho}"
    grep -q '^build-amd64=true$' "${gho}"
    grep -q '^build-arm64=true$' "${gho}"
    grep -q '^matrix={"include":' "${gho}"
}

@test "build-tools rejects an unknown subcommand (fail closed)" {
    # What: An unknown sub must not silently succeed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" build-tools bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0003"* ]]
}

@test "check line-endings passes LF, fails CRLF via ci.sh" {
    # What: ci.sh owns the LF invariant; bats calls it.
    # Why: guard logic lives once, tested through ci.sh.
    # From: Issue #1683
    printf 'a\nb\n' > "${BATS_TEST_TMPDIR}/lf.txt"
    run bash "${CI_SH}" check line-endings "${BATS_TEST_TMPDIR}/lf.txt"
    [ "${status}" -eq 0 ]
    printf 'a\r\nb\r\n' > "${BATS_TEST_TMPDIR}/crlf.txt"
    run bash "${CI_SH}" check line-endings "${BATS_TEST_TMPDIR}/crlf.txt"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0002"* ]]
}

@test "check file-headers passes canonical, fails missing via ci.sh" {
    # What: ci.sh owns the header contract; bats calls it.
    # Why: guard logic lives once, tested through ci.sh.
    # From: Issue #1683
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\n' > "${BATS_TEST_TMPDIR}/good.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/good.sh"
    [ "${status}" -eq 0 ]
    printf '#!/usr/bin/env bash\necho hi\n' > "${BATS_TEST_TMPDIR}/bad.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/bad.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0003"* ]]
}

@test "check comment-length passes valid, fails oversize and story-run" {
    # What: ci.sh owns AG-CODE-012 limits; bats calls it.
    # Why: guard logic lives once, tested through ci.sh.
    # From: Issue #1683
    printf '# What: ok short line.\n# Why: also fine here.\n' > "${BATS_TEST_TMPDIR}/ok.sh"
    run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/ok.sh"
    [ "${status}" -eq 0 ]
    printf '# What: %s\n' "$(printf 'x%.0s' $(seq 1 80))" > "${BATS_TEST_TMPDIR}/long.sh"
    run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/long.sh"
    [ "${status}" -ne 0 ]
    printf '# one\n# two\n# three\n# four\n' > "${BATS_TEST_TMPDIR}/story.sh"
    run bash "${CI_SH}" check comment-length "${BATS_TEST_TMPDIR}/story.sh"
    [ "${status}" -ne 0 ]
}

@test "check deny-short-sha passes full SHA, fails a slice via ci.sh" {
    # What: ci.sh owns the short-SHA ban; bats calls it.
    # Why: guard logic lives once, tested through ci.sh.
    # From: Issue #1683
    printf 'x=${SHA}\n' > "${BATS_TEST_TMPDIR}/ok.sh"
    run bash "${CI_SH}" check deny-short-sha "${BATS_TEST_TMPDIR}/ok.sh"
    [ "${status}" -eq 0 ]
    printf 'x=${SHA::7}\n' > "${BATS_TEST_TMPDIR}/bad.sh"
    run bash "${CI_SH}" check deny-short-sha "${BATS_TEST_TMPDIR}/bad.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0005"* ]]
}

@test "check language-policy fails banned ext and inline interpreter" {
    # What: ci.sh owns AG-REL-001; bats calls it.
    # Why: extension ban plus the heredoc foreign-lang gap.
    # From: Issue #1683
    printf 'echo hi\n' > "${BATS_TEST_TMPDIR}/ok.sh"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/ok.sh"
    [ "${status}" -eq 0 ]
    printf 'x = 1\n' > "${BATS_TEST_TMPDIR}/mod.py"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/mod.py"
    [ "${status}" -ne 0 ]
    printf 'python3 -c "print(1)"\n' > "${BATS_TEST_TMPDIR}/inline.sh"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/inline.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0007"* ]]
}

# =========================================================
# HISTORICAL REGRESSIONS
# =========================================================
