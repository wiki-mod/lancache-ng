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
    CI_MANIFEST_SOURCE="${BATS_TEST_DIRNAME}/../yaml/build-manifest.yml"
    # shellcheck source=.github/scripts/ci.sh
    source "${CI_SH}"
    # What: default apk resolver, rust ids docker-free.
    # Why: rust identity now keys the build-tools signature.
    # From: Issue #1683
    CI_APK_RESOLVE_CMD="$(_stub apkres 'printf "pkg-1.0\n"')"; export CI_APK_RESOLVE_CMD
    # What: GHCR login is a no-op here; docker is absent in tests.
    # Why: auth is ci.sh policy (docker login) with a test hook (§7).
    # From: Issue #1683
    CI_GHCR_LOGIN_CMD="$(_stub ghcrlogin 'exit 0')"; export CI_GHCR_LOGIN_CMD
}

# What: Removes dirs listed in a manifest file.
# Why: Function lets a test prove the cleanup.
# From: Issue #1683 | PR #1858
_trivy_cleanup_var_tmp_dirs() {
    local manifest="$1" d
    if [ -f "${manifest}" ]; then
        while IFS= read -r d; do
            if [ -n "${d}" ]; then
                rm -rf -- "${d}"
            fi
        done < "${manifest}"
    fi
}

# What: Removes /var/tmp scratch dirs this test made.
# Why: a "$(...)"-run helper can't set a var seen here.
# From: Issue #1683 | PR #1858
teardown() {
    _trivy_cleanup_var_tmp_dirs "${BATS_TEST_TMPDIR}/.trivy-var-tmp-dirs"
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

@test "_ci_repo lowercases a real mixed-case GITHUB_REPOSITORY" {
    # What: a real mixed-case owner/repo, not pre-lowered.
    # Why: GHCR needs lowercase; this transform was unseen.
    # From: Issue #1683 | PR #1858
    GITHUB_REPOSITORY='Wiki-Mod/LanCache-NG' run _ci_repo
    [ "${status}" -eq 0 ]
    [ "${output}" = "wiki-mod/lancache-ng" ]
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
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix services/proxy/Dockerfile
    [ "${status}" -eq 0 ]
    grep -q '^any-build=true$' "${gh}"
    local m; m="$(grep '^matrix=' "${gh}" | sed 's/^matrix=//')"
    [ "$(printf '%s' "${m}" | jq '.include | length')" -eq 2 ]
    [ "$(printf '%s' "${m}" | jq -r '.include[0].service')" = "proxy" ]
    [ "$(printf '%s' "${m}" | jq -r '[.include[].platform]|sort|join(",")')" = "linux/amd64,linux/arm64" ]
}

@test "plan-matrix emits docs-only=true for a docs-only change" {
    # What: a docs-only change is a NOOP; no container jobs (§63).
    # Why: container jobs gate on docs-only != true.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix fixture-note.md
    [ "${status}" -eq 0 ]
    grep -q '^docs-only=true$' "${gh}"
    grep -q '^any-build=false$' "${gh}"
}

@test "plan-matrix emits test-services for a path-changed rust service" {
    # What: a changed rust source makes the service a test candidate.
    # Why: tests run on source change, reuse or not (§60).
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix services/watchdog/src/main.rs
    [ "${status}" -eq 0 ]
    grep -q '^test-services=watchdog$' "${gh}"
}

@test "plan-matrix emits no test-services for a path-changed apk service" {
    # What: an apk service has no unit tests; not a test candidate.
    # Why: ci.sh test SKIPs apk; the matrix must not list it.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo MISSING_CONFIRMED')" \
        run bash "${CI_SH}" plan-matrix services/ntp/Dockerfile
    [ "${status}" -eq 0 ]
    grep -q '^test-services=$' "${gh}"
}

@test "plan-matrix omits an accepted target (NOOP), any-build=false" {
    # What: An accepted identity is not rebuilt.
    # Why: NOOP/reuse precedes build; a skip stays out.
    # From: Issue #1683
    local gh="${BATS_TEST_TMPDIR}/out.txt"; : > "${gh}"
    GITHUB_OUTPUT="${gh}" GHCR_USERNAME=u GHCR_TOKEN=t CI_RESOLVE_PROBE_CMD="$(_stub p 'echo PRESENT_ACCEPTED')" \
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
    cp "${CI_MANIFEST_SOURCE}" "${m}"
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
    cp "${CI_MANIFEST_SOURCE}" "${m}"
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
    cp "${CI_MANIFEST_SOURCE}" "${m1}"
    cp "${m1}" "${m2}"
    sed -i 's/sha256_x86_64: [0-9a-f]\{64\}/sha256_x86_64: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "${m2}"
    local a b
    a="$(CI_MANIFEST="${m1}" _ci_identity_for netdata linux/amd64 HEAD)"
    b="$(CI_MANIFEST="${m2}" _ci_identity_for netdata linux/amd64 HEAD)"
    [ -n "${a}" ]
    [ "${a}" != "${b}" ]
}

@test "registry derives from the SOT and drives refs" {
    # What: A changed release.registry moves the built ref.
    # Why: Proves the host is SOT-owned, not hardcoded inline.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/reg.yml" host tag
    sed 's/^  registry: ghcr.io$/  registry: example.io/' "${CI_MANIFEST_SOURCE}" > "${m}"
    host="$(CI_MANIFEST="${m}" _ci_registry)"
    [ "${host}" = "example.io" ]
    tag="$(CI_MANIFEST="${m}" GITHUB_REPOSITORY=wiki-mod/lancache-ng _ci_image_tag proxy linux/amd64 abcd)"
    [[ "${tag}" == example.io/* ]]
}

@test "registry fails closed when release.registry is absent" {
    # What: A SOT without registry yields no empty host.
    # Why: An empty host builds a malformed ref, silently.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/noreg.yml"
    grep -v '^  registry:' "${CI_MANIFEST_SOURCE}" > "${m}"
    run bash -c "source '${CI_SH}'; CI_MANIFEST='${m}' _ci_registry 2>&1"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CORE-0005"* ]]
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
}

@test "retry classifier: a missing manifest is not_found, auth is not" {
    # What: not_found is separate; auth stays permanent.
    # Why: only not_found may build; auth must never build.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'manifest unknown')" = "not_found" ]
    [ "$(_ci_classify_failure 'ghcr.io/x: not found: manifest')" = "not_found" ]
    [ "$(_ci_classify_failure 'denied: requested access to the resource')" = "permanent" ]
}

@test "retry classifier: an unclassified failure defaults to transient" {
    # What: Unknown error -> retry, not give up.
    # Why: A missed transient is worse than a few retries.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'some novel error text')" = "transient" ]
}

@test "retry classifier: matching is case-insensitive (curl/git casing)" {
    # What: Case-insensitive match for transient errors.
    # Why: Go/curl/git have different error text casing.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'Connection reset by peer')" = "transient" ]
    [ "$(_ci_classify_failure 'HTTP 401 Unauthorized')" = "permanent" ]
}

@test "retry classifier: op=github-api 404 is permanent, never not_found" {
    # What: GitHub API 404 maps to permanent, not not_found.
    # Why: Registry 404 can recover; API 404 never can.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'gh: Not Found (HTTP 404)' github-api)" = "permanent" ]
    [ "$(_ci_classify_failure 'gh: Not Found (HTTP 404)' github-api)" != "not_found" ]
}

@test "retry classifier: op=registry (default) still returns not_found on 404-shaped text" {
    # What: Default op returns not_found for 404 text.
    # Why: Preserves legacy registry-probe behavior.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'ghcr.io/x: not found: manifest')" = "not_found" ]
    [ "$(_ci_classify_failure 'ghcr.io/x: not found: manifest' registry)" = "not_found" ]
}

@test "retry classifier: op=buildx retries the layer-lock and go-panic signatures" {
    # What: layer-lock and panic signatures are transient.
    # Why: build-retry.sh/docker-buildx-retry.sh evidence.
    # From: Issue #1683
    [ "$(_ci_classify_failure '(*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:abc locked for 900ms (since t): unavailable' buildx)" = "transient" ]
    [ "$(_ci_classify_failure 'panic: methodref has no signature' buildx)" = "transient" ]
}

@test "retry classifier: buildx signatures never leak into a real compile failure" {
    # What: Unrelated buildx ops stay permanent.
    # Why: op-gating prevents matching widening.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'error: could not compile lancache-ui' buildx)" = "permanent" ]
}

@test "retry classifier: git-fetch-retry.sh's transient signatures are covered" {
    # What: DNS/RPC/disconnect transient signatures.
    # Why: Classifier now owns git-fetch-retry.sh cases.
    # From: Issue #1683
    [ "$(_ci_classify_failure 'unexpected disconnect while reading sideband packet')" = "transient" ]
    [ "$(_ci_classify_failure 'The remote end hung up unexpectedly')" = "transient" ]
    [ "$(_ci_classify_failure 'Could not resolve host: github.com')" = "transient" ]
    [ "$(_ci_classify_failure 'RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly')" = "transient" ]
    [ "$(_ci_classify_failure 'GnuTLS recv error (-9): A TLS packet with unexpected length was received.')" = "transient" ]
}

@test "retry classifier: a missing git ref is permanent, never retried" {
    # What: Missing git ref maps to permanent.
    # Why: Absent refs cannot be fixed by retrying.
    # From: Issue #1683
    [ "$(_ci_classify_failure "fatal: couldn't find remote ref refs/x")" = "permanent" ]
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
    CI_TEST_CMD="$(_stub t 'echo "service=ui tested=ok"; exit 0')" run bash "${CI_SH}" test ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
}

@test "test dispatches a rust service to the cargo checks" {
    # What: A rust service runs the cargo checks.
    # Why: fmt/check/clippy/test are AG-VAL-008.
    # From: Issue #1683 | PR #1858
    CI_RUST_TEST_CMD="$(_stub rt 'echo "service=$1 tested=ok"')" \
        run bash "${CI_SH}" test dns
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
}

@test "test skips an apk-install service without claiming pass" {
    # What: An apk service reports SKIP, not ok.
    # Why: No unit test; PASS would misrepresent.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" test proxy
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=SKIP"* ]]
    [[ "${output}" != *"tested=ok"* ]]
}

@test "test build-tools fails closed without a toolchain image" {
    # What: The smoke needs the candidate image ref.
    # Why: No image means nothing to smoke; fail closed.
    # From: Issue #1683
    run bash "${CI_SH}" test build-tools
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-TEST-0006"* ]]
}

@test "build-tools smoke_tools reads the SOT executable list" {
    # What: The smoke list has one owner in the SOT.
    # Why: No second tool list to drift from packages.
    # From: Issue #1683
    run _ci_build_tools_smoke_tools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cargo"* ]]
    [[ "${output}" == *"sccache"* ]]
    [[ "${output}" == *"actionlint"* ]]
}

@test "build-tools smoke_tools fails closed on an empty SOT list" {
    # What: A blank smoke list must never pass silently.
    # Why: Fail-closed; a missing list is a real error.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/m.yml"
    sed '/^    smoke_tools:/,/^$/d' "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run _ci_build_tools_smoke_tools
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0013"* ]]
}

@test "toolchain smoke passes when every tool is present" {
    # What: command -v every smoke tool in the image.
    # Why: Presence of each accel tool is the contract.
    # From: Issue #1683
    docker() { while [ "${1:-}" != "sh" ] && [ $# -gt 0 ]; do shift; done; "$@"; }
    run _ci_toolchain_smoke fake-img "$(printf 'bash\nsh\n')"
    [ "${status}" -eq 0 ]
}

@test "toolchain smoke fails when a tool is missing" {
    # What: A missing tool fails the smoke loudly.
    # Why: A broken toolchain must not pass as ok.
    # From: Issue #1683
    docker() { while [ "${1:-}" != "sh" ] && [ $# -gt 0 ]; do shift; done; "$@"; }
    run _ci_toolchain_smoke fake-img "$(printf 'bash\nnope-xyz-123\n')"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"missing nope-xyz-123"* ]]
}

@test "test build-tools reports ok via the wired smoke backend" {
    # What: A green smoke yields tested=ok for build-tools.
    # Why: The wired toolchain smoke is the real test.
    # From: Issue #1683
    CI_TOOLCHAIN_TEST_CMD="$(_stub tc 'echo "service=build-tools tested=ok"')" \
        run bash "${CI_SH}" test build-tools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
}

@test "test runs the real cargo pipeline for a rust fixture (no injection)" {
    # What: Default rust path runs real cargo pipeline.
    # Why: AG-VAL-008 must run for real, not via injection.
    # From: Issue #1683
    local root="${BATS_TEST_TMPDIR}/repo-ok"
    mkdir -p "${root}/crate/src"
    cat > "${root}/crate/Cargo.toml" <<'TOML'
[package]
name = "ci-fixture-ok"
version = "0.1.0"
edition = "2021"
TOML
    cat > "${root}/crate/src/main.rs" <<'RS'
fn main() {
    println!("ci fixture ok");
}

#[test]
fn real_cargo_test_runs() {
    // What: Sanity check the real path executes cargo test.
    // Why: Proves _ci_test_rust runs real cargo, not a stub.
    assert_eq!(1 + 1, 2);
}
RS
    local m="${BATS_TEST_TMPDIR}/manifest-ok.yml"
    printf 'services:\n  fixture-ok:\n    context: crate\n    build_type: rust\n' > "${m}"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" run bash "${CI_SH}" test fixture-ok
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"tested=ok"* ]]
}

@test "test propagates a real cargo clippy failure without injection" {
    # What: Real clippy violations fail, unmocked.
    # Why: AG-INT-002: real failures must never hide.
    # From: Issue #1683
    local root="${BATS_TEST_TMPDIR}/repo-fail"
    mkdir -p "${root}/crate/src"
    cat > "${root}/crate/Cargo.toml" <<'TOML'
[package]
name = "ci-fixture-fail"
version = "0.1.0"
edition = "2021"
TOML
    cat > "${root}/crate/src/main.rs" <<'RS'
fn main() {
    let flag = true;
    if flag == true {
        println!("{flag}");
    }
}
RS
    local m="${BATS_TEST_TMPDIR}/manifest-fail.yml"
    printf 'services:\n  fixture-fail:\n    context: crate\n    build_type: rust\n' > "${m}"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" run bash "${CI_SH}" test fixture-fail
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-TEST-0003"* ]]
    [[ "${output}" == *"equality checks against true"* ]]
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

@test "scan fails on a finding backend" {
    # What: A backend exit 1 is a genuine finding.
    # Why: HIGH/CRITICAL findings fail the scan.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 1')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0005"* ]]
}

@test "scan escalates a DB-unavailable backend, not a finding" {
    # What: A backend exit 3 is a DB outage, not a finding.
    # Why: An outage must escalate, never reject the image.
    # From: Issue #1683
    CI_SCAN_CMD="$(_stub s 'exit 3')" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" scan ui sha256:x
    [ "${status}" -eq 3 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0006"* ]]
}

# =========================================================
# CACHE FALLBACK
# =========================================================

@test "cache fallback: an unwired CAS lookup always misses, never a false hit" {
    # What: Unwired CAS lookup misses, not false hit.
    # Why: Fallback defaults to miss, not silent hit.
    # From: Issue #1683
    run _ci_cas_lookup "deadbeef"
    [ "${status}" -ne 0 ]
}

@test "cache fallback: a CAS hit skips the build backend entirely" {
    # What: A CAS hit must never invoke the build backend.
    # Why: Reuse means the compile step is truly skipped.
    # From: Issue #1683
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas 'exit 0')" \
    CI_BUILD_CMD="$(_stub build 'echo BUILD_BACKEND_INVOKED; exit 1')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=reuse-binary-cas"* ]]
    [[ "${output}" != *"BUILD_BACKEND_INVOKED"* ]]
}

@test "cache fallback: a crashing CAS backend still falls back to a real build" {
    # What: Any nonzero CAS exit falls back to build.
    # Why: Broken CAS backend must not block pipeline.
    # From: Issue #1683
    local marker="${BATS_TEST_TMPDIR}/cas-invoked-crash"
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas "touch '${marker}'; echo cas-backend-noise >&2; exit 137")" \
    CI_BUILD_CMD="$(_stub build 'exit 0')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=built"* ]]
    # What: Marker proves CAS backend ran.
    # Why: Skipped stub makes fallback claim empty.
    # From: Issue #1683
    [ -f "${marker}" ]
}

@test "cache fallback: an apk (non-rust) service never consults the CAS" {
    # What: build_type=apk must not call CAS.
    # Why: CAS is rust-binary reuse (§7); apk has none.
    # From: Issue #1683
    local marker="${BATS_TEST_TMPDIR}/cas-invoked-apk"
    STUB_STATE=MISSING_CONFIRMED
    CI_RESOLVE_PROBE_CMD="$(_probe_stub)" \
    CI_IMPACT_CMD="$(_stub impact 'echo BUILD')" \
    CI_CAS_LOOKUP_CMD="$(_stub cas "touch '${marker}'; exit 0")" \
    CI_BUILD_CMD="$(_stub build 'exit 0')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build proxy
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=built"* ]]
    # What: Absent marker proves CAS never invoked.
    # Why: No-op stub passes with no skip proof.
    # From: Issue #1683
    [ ! -f "${marker}" ]
}

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

# What: A valid 64-hex test digest from one char.
# Why: One primitive; assembly/promote/release share it.
# From: Issue #1683
_test_digest() {
    local c="$1" out=""
    while [ "${#out}" -lt 64 ]; do out="${out}${c}"; done
    printf 'sha256:%s' "${out}"
}
# What: Named digest constants built on _test_digest.
# Why: Idempotency compares assembled vs existing.
# From: Issue #1683
_asm_a() { _test_digest a; }
_asm_b() { _test_digest b; }
_asm_idx() { _test_digest d; }
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
    local dig; dig="$(_test_digest a)"
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0004"* ]]
}

@test "promote blocks when the stack is not validated" {
    # What: Stack validation is a precondition.
    # Why: Fail-closed without validate (docs section 50).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0005"* ]]
}

@test "promote fails closed without GHCR auth" {
    # What: Moving refs is an authenticated action.
    # Why: Never anonymous (rate-limit).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
    CI_STACK_CANDIDATE_CMD="$(_promote_full_candidate "${dig}")" CI_STACK_VALIDATED=SUCCESS \
        run bash "${CI_SH}" promote nightly
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILD-0002"* ]]
}

@test "promote moves refs, confirms readback, releases lock" {
    # What: Fresh promote: lock, move, readback, unlock.
    # Why: The one success path (docs section 51/53).
    # From: Issue #1683
    local dig; dig="$(_test_digest a)"
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
    local dig; dig="$(_test_digest a)"
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
    local dig; dig="$(_test_digest a)"
    local other; other="$(_test_digest b)"
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
    local dig; dig="$(_test_digest a)"
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
    local dig; dig="$(_test_digest a)"
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
    local dig; dig="$(_test_digest a)"
    CI_RELEASE_VALIDATION_CMD="$(_stub val 'exit 0')" \
    CI_STACK_CANDIDATE_CMD="$(_stub cand "echo proxy=${dig}")" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" release
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-PROMOTE-0004"* ]]
}

# =========================================================
# GC
# =========================================================

_gc_roots() { _stub roots 'printf "sha256:aaa\nsha256:bbb\n"'; }

@test "default gc roots unions ledger, channel, and index-child digests" {
    # What: Roots = ledger records + channels + children.
    # Why: The transitive protected set, all states (§101).
    # From: Issue #1683
    GITHUB_REPOSITORY=wiki-mod/lancache-ng
    _ci_ledger_blob() { printf 'id1\tproxy\tlinux/amd64\tPRODUCED_UNVERIFIED\tsha256:led\n'; }
    ci_services() { printf 'proxy\n'; }
    _ci_mutable_channels() { printf 'latest\n'; }
    _ci_registry_probe() { printf 'sha256:chan\n'; }
    _ci_index_raw() { printf '{"manifests":[{"platform":{"architecture":"amd64"},"digest":"sha256:child"}]}'; }
    run _ci_default_gc_roots
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:led"* ]]
    [[ "${output}" == *"sha256:chan"* ]]
    [[ "${output}" == *"sha256:child"* ]]
}

@test "default gc roots refuses when the ledger read is UNKNOWN" {
    # What: An unreadable ledger refuses; never empty roots.
    # Why: UNKNOWN roots would delete live artifacts (§26).
    # From: Issue #1683
    GITHUB_REPOSITORY=wiki-mod/lancache-ng
    _ci_ledger_blob() { return 2; }
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0012"* ]]
}

@test "default gc roots refuses on a transient channel probe" {
    # What: A flaky channel probe refuses the whole run.
    # Why: A transient miss must not drop a live channel.
    # From: Issue #1683
    GITHUB_REPOSITORY=wiki-mod/lancache-ng
    _ci_ledger_blob() { return 1; }
    ci_services() { printf 'proxy\n'; }
    _ci_mutable_channels() { printf 'latest\n'; }
    _ci_registry_probe() { return 2; }
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0013"* ]]
}

@test "default gc roots refuses when release.registry is absent" {
    # What: A SOT without registry refuses; never partial roots.
    # Why: An empty host would silently drop a channel from roots.
    # From: Issue #1683
    GITHUB_REPOSITORY=wiki-mod/lancache-ng
    local m="${BATS_TEST_TMPDIR}/noreg.yml"
    grep -v '^  registry:' "${CI_MANIFEST_SOURCE}" > "${m}"
    export CI_MANIFEST="${m}"
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CORE-0005"* ]]
}

@test "default gc roots refuses on a transient index-child read" {
    # What: A flaky child read refuses the whole run.
    # Why: Missing children would orphan-delete live arches.
    # From: Issue #1683
    GITHUB_REPOSITORY=wiki-mod/lancache-ng
    _ci_ledger_blob() { printf 'id1\tproxy\tlinux/amd64\tACCEPTED\tsha256:led\n'; }
    ci_services() { printf '\n'; }
    _ci_mutable_channels() { printf '\n'; }
    _ci_index_raw() { return 2; }
    run _ci_default_gc_roots
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0014"* ]]
}

@test "default gc roots skips a not-yet-promoted channel without failing" {
    # What: A not-found channel is skipped, not a failure.
    # Why: A service never promoted is legitimately absent.
    # From: Issue #1683
    export GITHUB_REPOSITORY=wiki-mod/lancache-ng
    _ci_ledger_blob() { printf 'id1\tproxy\tlinux/amd64\tACCEPTED\tsha256:led\n'; }
    ci_services() { printf 'proxy\n'; }
    _ci_mutable_channels() { printf 'latest\n'; }
    _ci_registry_probe() { return 1; }
    _ci_index_raw() { return 1; }
    run _ci_default_gc_roots
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:led"* ]]
}

@test "default gc reachable keeps a candidate whose digest is a root" {
    # What: A root-set member is referenced, kept.
    # Why: Ledger and channel digests are protected (§101).
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:aaa\nsha256:bbb\n' > "${CI_GC_ROOTS_FILE}"
    run _ci_default_gc_reachable "$(printf 'sha256:aaa\t123\t2020-01-01T00:00:00Z')"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "referenced" ]]
}

@test "default gc reachable keeps a freshly created candidate via the floor" {
    # What: A recent unreferenced candidate is kept.
    # Why: Protects in-flight tags before aggregation.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:root\n' > "${CI_GC_ROOTS_FILE}"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run _ci_default_gc_reachable "$(printf 'sha256:fresh\t9\t%s' "${now}")"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "referenced" ]]
}

@test "default gc reachable marks an old unreferenced candidate unreachable" {
    # What: Old and unreferenced classifies as garbage.
    # Why: Past the grace floor with no root is deletable.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:root\n' > "${CI_GC_ROOTS_FILE}"
    run _ci_default_gc_reachable "$(printf 'sha256:old\t9\t2020-01-01T00:00:00Z')"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "unreachable" ]]
}

@test "default gc reachable refuses without a materialized roots file" {
    # What: No roots file means no safe judgment.
    # Why: Guessing reachability could delete live images.
    # From: Issue #1683
    unset CI_GC_ROOTS_FILE
    run _ci_default_gc_reachable "$(printf 'sha256:x\t9\t2020-01-01T00:00:00Z')"
    [ "${status}" -eq 2 ]
}

@test "default gc reachable refuses a candidate with no created_at" {
    # What: Missing created_at is UNKNOWN, never a delete.
    # Why: The floor cannot judge without a timestamp.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:root\n' > "${CI_GC_ROOTS_FILE}"
    run _ci_default_gc_reachable "sha256:notimestamp"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0016"* ]]
}

@test "default gc reachable refuses an unparseable created_at" {
    # What: A garbage timestamp is UNKNOWN, never a delete.
    # Why: An unreadable date must not classify as garbage.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:root\n' > "${CI_GC_ROOTS_FILE}"
    run _ci_default_gc_reachable "$(printf 'sha256:x\t9\tnot-a-date')"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0016"* ]]
}

@test "default gc reachable refuses when the grace value is missing" {
    # What: A missing grace value fails closed.
    # Why: Empty grace makes the floor now and deletes all.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:root\n' > "${CI_GC_ROOTS_FILE}"
    _ci_manifest_scalar() { printf ''; }
    run _ci_default_gc_reachable "$(printf 'sha256:x\t9\t2020-01-01T00:00:00Z')"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0015"* ]]
}

@test "default gc reachable keeps an attestation whose subject is a root" {
    # What: An attestation lives while its subject lives.
    # Why: sha256-<subj> referrers guard live provenance.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:subj\n' > "${CI_GC_ROOTS_FILE}"
    run _ci_default_gc_reachable "$(printf 'sha256:att\t9\t2020-01-01T00:00:00Z\tsha256-subj')"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "referenced" ]]
}

@test "default gc reachable deletes an attestation of a gone subject" {
    # What: An orphan attestation past grace is garbage.
    # Why: No live subject means dead weight.
    # From: Issue #1683
    CI_GC_ROOTS_FILE="${BATS_TEST_TMPDIR}/roots"
    printf 'sha256:other\n' > "${CI_GC_ROOTS_FILE}"
    run _ci_default_gc_reachable "$(printf 'sha256:att\t9\t2020-01-01T00:00:00Z\tsha256-gone')"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "unreachable" ]]
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

@test "default gc candidates emits the version tuple per package" {
    # What: Each built package's versions become candidates.
    # Why: The tuple feeds reachability and delete (§97).
    # From: Issue #1683
    _ci_gh_versions() { printf 'sha256:aaa\t111\t2020-01-01T00:00:00Z\tsha-abc\n'; }
    ci_build_targets() { printf 'proxy\n'; }
    run _ci_default_gc_candidates
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:aaa"* ]]
    [[ "${output}" == *"111"* ]]
    [[ "${output}" == *"proxy"* ]]
}

@test "default gc candidates skips a 404 package without failing" {
    # What: A not-found package is skipped, not fatal.
    # Why: External services (netdata) have no GHCR package.
    # From: Issue #1683
    _ci_gh_versions() { case "$2" in *netdata*) return 1;; *) printf 'sha256:bbb\t222\t2020-01-01T00:00:00Z\tsha-b\n';; esac; }
    ci_build_targets() { printf 'proxy\nnetdata\n'; }
    run _ci_default_gc_candidates
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:bbb"* ]]
    [[ "${output}" != *"netdata"* ]]
}

@test "default gc candidates fails closed when every package 404s" {
    # What: No package found anywhere refuses the run.
    # Why: A bad prefix/owner/token must not read as noop.
    # From: Issue #1683
    _ci_gh_versions() { return 1; }
    ci_build_targets() { printf 'proxy\ndns\n'; }
    run _ci_default_gc_candidates
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0020"* ]]
}

@test "default gc candidates counts an existing empty package as found" {
    # What: An existing package with zero versions is fine.
    # Why: Empty is not 404; not the no-package case.
    # From: Issue #1683
    _ci_gh_versions() { return 0; }
    ci_build_targets() { printf 'proxy\n'; }
    run _ci_default_gc_candidates
    [ "${status}" -eq 0 ]
}

@test "default gc candidates fails closed on a transient listing error" {
    # What: A transient GHCR error refuses the whole run.
    # Why: A half-enumerated candidate set is unsafe.
    # From: Issue #1683
    _ci_gh_versions() { return 2; }
    ci_build_targets() { printf 'proxy\n'; }
    run _ci_default_gc_candidates
    [ "${status}" -eq 2 ]
}

@test "default gc candidates fails closed when image_prefix is missing" {
    # What: No SOT image_prefix cannot scope candidates.
    # Why: Guessing the owner could target foreign packages.
    # From: Issue #1683
    _ci_manifest_scalar() { printf ''; }
    run _ci_default_gc_candidates
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0017"* ]]
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

@test "default gc delete calls the GHCR delete endpoint by version id" {
    # What: Delete targets /versions/<id> for the service.
    # Why: The one destructive call, package-scoped.
    # From: Issue #1683
    gh() { echo "$@" >> "${BATS_TEST_TMPDIR}/gh.log"; }
    export -f gh
    run _ci_default_gc_delete "$(printf 'sha256:old\t222\t2020-01-01T00:00:00Z\t\tproxy')"
    [ "${status}" -eq 0 ]
    [[ "$(cat "${BATS_TEST_TMPDIR}/gh.log")" == *"api -X DELETE /orgs/wiki-mod/packages/container/lancache-ng%2Fproxy/versions/222"* ]]
}

@test "default gc delete refuses a candidate with no numeric id" {
    # What: A non-numeric id is refused, never guessed.
    # Why: A bad id could delete the wrong version.
    # From: Issue #1683
    run _ci_default_gc_delete "$(printf 'sha256:old\tnotanid\t2020\t\tproxy')"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-GC-0019"* ]]
}

@test "gh_versions retries a transient GH-API failure, then succeeds" {
    # What: Transient GH-API failures retry then succeed.
    # Why: github-api-retry.sh retry-on-transient behavior.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    gh() {
        local n; n="$(($(cat "${cnt}") + 1))"; printf '%s' "${n}" > "${cnt}"
        if [ "${n}" -lt 3 ]; then echo "HTTP 503 Service Unavailable" >&2; return 1; fi
        printf 'v1\t111\t2020-01-01T00:00:00Z\t\n'
    }
    export -f gh
    CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_gh_versions wiki-mod "lancache-ng%2Fproxy"
    [ "${status}" -eq 0 ]
    [ "$(cat "${cnt}")" -eq 3 ]
    [[ "${output}" == *"v1"* ]]
}

@test "gh_versions fails immediately (no retry) on a 404, package skipped" {
    # What: 404 does not consume retry budget.
    # Why: github-api-retry.sh fails 401/404 immediately.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    gh() {
        printf '%s' "$(($(cat "${cnt}") + 1))" > "${cnt}"
        echo "gh: Not Found (HTTP 404)" >&2; return 1
    }
    export -f gh
    CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_gh_versions wiki-mod "lancache-ng%2Fnetdata"
    [ "${status}" -eq 1 ]
    [ "$(cat "${cnt}")" -eq 1 ]
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

@test "gc keeps a candidate the default probe finds in the roots file" {
    # What: Framework makes roots; default probe reads.
    # Why: End-to-end membership KEEP via the roots file.
    # From: Issue #1683
    CI_GC_ROOTS_CMD="$(_stub roots 'printf "sha256:aaa\n"')" \
    CI_GC_CANDIDATES_CMD="$(_stub cands 'printf "sha256:aaa\t7\t2020-01-01T00:00:00Z\n"')" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"action=KEEP"* ]]
}

@test "gc keeps a fresh non-root candidate via the recency floor" {
    # What: A recent non-root candidate is kept end-to-end.
    # Why: In-flight artifacts survive GC (advisor case).
    # From: Issue #1683
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    CI_GC_ROOTS_CMD="$(_stub roots 'printf "sha256:root\n"')" \
    CI_GC_CANDIDATES_CMD="$(_stub cands "printf 'sha256:fresh\t7\t${now}\n'")" \
        run bash "${CI_SH}" gc
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"action=KEEP"* ]]
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

@test "validate default backend fails closed when compose is unreadable" {
    # What: The wired default refuses without compose data.
    # Why: No stub = real backend, still fail-closed.
    # From: Issue #1683 | PR #1858
    CI_STACK_CANDIDATE_CMD="$(_stub cand 'echo proxy=sha256:x')" \
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'exit 3')" \
    TMPDIR="${BATS_TEST_TMPDIR}" GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0006"* ]]
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

@test "validation SOT lists both real dig target domains" {
    # What: DNS test domains come from the SOT, not code.
    # Why: One place owns the check inputs (AG-CI-006).
    # From: Issue #1683 | PR #1858
    run _ci_validation_dns_domains
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"deb.debian.org"* ]]
    [[ "${output}" == *"download.epicgames.com"* ]]
}

@test "validation SOT proxy probe url is a cacheable HTTP target" {
    # What: Only HTTP is cached; the probe URL must be HTTP.
    # Why: No HIT proof exists against passthrough HTTPS.
    # From: Issue #1683 | PR #1858
    run _ci_validation_proxy_probe_url
    [ "${status}" -eq 0 ]
    [[ "${output}" == http://* ]]
}

@test "validate pins one SOT service onto both its compose containers" {
    # What: dns pins both dns-standard and dns-ssl.
    # Why: Pin by image, not key (1 service, 2 containers).
    # From: Issue #1683 | PR #1858
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'printf "dns-standard\tghcr.io/wiki-mod/lancache-ng/dns:latest\ndns-ssl\tghcr.io/wiki-mod/lancache-ng/dns:latest\n"')" \
        run _ci_validate_pin_override "dns=sha256:aaa"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dns-standard:"* ]]
    [[ "${output}" == *"dns-ssl:"* ]]
    [ "$(printf '%s\n' "${output}" | grep -c 'dns@sha256:aaa')" -eq 2 ]
}

@test "validate skips third-party compose images without pinning" {
    # What: nats is third-party; it is never pinned.
    # Why: No first-party digest exists for external images.
    # From: Issue #1683 | PR #1858
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'printf "nats\tnats:2-alpine@sha256:c11\nproxy\tghcr.io/wiki-mod/lancache-ng/proxy:latest\n"')" \
        run _ci_validate_pin_override "proxy=sha256:p"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy@sha256:p"* ]]
    [[ "${output}" != *"nats:"* ]]
}

@test "validate fails closed on a first-party image with no candidate digest" {
    # What: First-party image not in the candidate.
    # Why: Else :latest validates green (silent drift).
    # From: Issue #1683 | PR #1858
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'printf "proxy\tghcr.io/wiki-mod/lancache-ng/proxy:latest\n"')" \
        run _ci_validate_pin_override "watchdog=sha256:w"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0007"* ]]
}

@test "validate reports (not fails) a candidate with no first-party image" {
    # What: netdata first-party, compose uses upstream.
    # Why: Deferred defect stays visible, never a hard fail.
    # From: Issue #1683 | PR #1858
    CI_COMPOSE_IMAGES_CMD="$(_stub imgs 'printf "netdata\tnetdata/netdata@sha256:a13\nproxy\tghcr.io/wiki-mod/lancache-ng/proxy:latest\n"')" \
        run _ci_validate_pin_override "proxy=sha256:p
netdata=sha256:n"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-WARN-VALIDATE-0008"* ]]
    [[ "${output}" == *'unpinned="netdata"'* ]]
}

@test "validate is_collision matches docker contention signatures" {
    # What: Pool/address contention strings are retryable.
    # Why: Distinct from a real image or config failure.
    # From: Issue #1683 | PR #1858
    run _ci_validate_is_collision "Error: Pool overlaps with other one"
    [ "${status}" -eq 0 ]
    run _ci_validate_is_collision "manifest unknown"
    [ "${status}" -ne 0 ]
}

@test "validate default tears the stack down even when up fails" {
    # What: Teardown runs on the failure path.
    # Why: A leaked stack holds the slot, poisons reruns.
    # From: Issue #1683
    export TMPDIR="${BATS_TEST_TMPDIR}"
    _ci_validate_reserve() { echo "subnet=172.16.1.32/27 holder=1234"; }
    _ci_validate_net_override() { echo "networks:"; }
    _ci_validate_pin_override() { echo "services:"; }
    _ci_validate_up() { echo "boom"; return 1; }
    _ci_validate_teardown() { echo "TEARDOWN holder=$1 project=$2"; }
    run _ci_default_validate "proxy=sha256:x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"TEARDOWN holder=1234"* ]]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0017"* ]]
}

@test "validate default flags a subnet collision distinctly" {
    # What: A pool-overlap up failure is a collision id.
    # Why: Diagnosis points at the slot, not the images.
    # From: Issue #1683
    export TMPDIR="${BATS_TEST_TMPDIR}"
    _ci_validate_reserve() { echo "subnet=172.16.1.32/27 holder=1234"; }
    _ci_validate_net_override() { echo "networks:"; }
    _ci_validate_pin_override() { echo "services:"; }
    _ci_validate_up() { echo "Pool overlaps with other one"; return 1; }
    _ci_validate_teardown() { :; }
    run _ci_default_validate "proxy=sha256:x"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0016"* ]]
}

@test "validate slot lock refuses a second holder of one /27" {
    # What: One flock per /27; the second call fails.
    # Why: Two runs must never share a validation subnet.
    # From: Issue #1683
    export TMPDIR="${BATS_TEST_TMPDIR}"
    local first
    first="$(_ci_validate_slot_lock 172.16.1.32/27)"
    [ -n "${first}" ]
    run _ci_validate_slot_lock 172.16.1.32/27
    [ "${status}" -ne 0 ]
    _ci_validate_release "${first}"
}

@test "validate wait_healthy reports every unhealthy service" {
    # What: A failed wait names its service and fails.
    # Why: Parallel waits still surface each failure.
    # From: Issue #1683 | PR #1858
    _ci_validate_health_services() { printf 'proxy\ndns-standard\n'; }
    _ci_validate_no_health_services() { :; }
    _ci_validate_wait_one() { [ "$2" = "dns-standard" ] && return 1; return 0; }
    run _ci_validate_wait_healthy "proj"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0009"* ]]
    [[ "${output}" == *'service="dns-standard"'* ]]
    [[ "${output}" == *'check="healthcheck"'* ]]
}

@test "validate wait_healthy also covers no-healthcheck services" {
    # What: A no-healthcheck service still fails crash-loop.
    # Why: AG-VAL-027: coverage must not skip it.
    # From: Issue #1683
    _ci_validate_health_services() { :; }
    _ci_validate_no_health_services() { printf 'cachehamster\n'; }
    _ci_validate_wait_stable() { return 1; }
    run _ci_validate_wait_healthy "proj"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-VALIDATE-0009"* ]]
    [[ "${output}" == *'service="cachehamster"'* ]]
    [[ "${output}" == *'check="stability"'* ]]
}

@test "validate health list excludes no-healthcheck services" {
    # What: no-health list is disjoint from health list.
    # Why: Each service polled by exactly one wait strategy.
    # From: Issue #1683
    CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'printf "%s" "{\"services\":{\"proxy\":{\"healthcheck\":{}},\"dhcp\":{\"network_mode\":\"host\"},\"cachehamster\":{}}}"')" \
        run _ci_validate_no_health_services
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cachehamster"* ]]
    [[ "${output}" != *"proxy"* ]]
    [[ "${output}" != *"dhcp"* ]]
}

@test "validate wait_stable succeeds once StartedAt holds through the window" {
    # What: A stable StartedAt across polls passes.
    # Why: Proves the settle window actually waits.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) echo cid1 ;;
            inspect) echo running ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=10 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -eq 0 ]
}

@test "validate wait_stable never settles across restarts (crash-loop)" {
    # What: A StartedAt that keeps changing never settles.
    # Why: This is the crash-loop signal, not a count.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    docker() {
        case "$1" in
            compose) echo cid1 ;;
            inspect)
                if [[ "$3" == *StartedAt* ]]; then
                    printf '%s' "$(( $(cat "${cnt}") + 1 ))" > "${cnt}"
                    cat "${cnt}"
                else
                    echo running
                fi
                ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=3 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -ne 0 ]
}

@test "validate wait_stable fails while the container is not running" {
    # What: A non-running status never counts as stable.
    # Why: Restarting/exited must never read as settled.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) echo cid1 ;;
            inspect) echo restarting ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=3 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -ne 0 ]
}

@test "validate wait_stable passes a one-shot exit-0 service" {
    # What: a restart:no service exits 0 by design.
    # Why: A one-shot exit is success, not a crash-loop.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) echo cid1 ;;
            inspect)
                [[ "$3" == *ExitCode* ]] && echo 0 || echo exited
                ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=10 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -eq 0 ]
}

@test "validate wait_stable fails a one-shot service exiting nonzero" {
    # What: A nonzero exit on a one-shot service is a crash.
    # Why: Success needs ExitCode 0, not just exited.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) echo cid1 ;;
            inspect)
                [[ "$3" == *ExitCode* ]] && echo 1 || echo exited
                ;;
        esac
    }
    CI_VALIDATE_STABLE_WINDOW=1 CI_VALIDATE_HEALTH_TIMEOUT=10 \
        run _ci_validate_wait_stable proj cachehamster
    [ "${status}" -ne 0 ]
}

@test "ipv4 to int converts a dotted quad" {
    # What: Dotted quad to a 32-bit integer.
    # Why: Integer masking proves a /27 overlap.
    # From: Issue #1683
    run _ci_ipv4_to_int 172.16.1.32
    [ "${status}" -eq 0 ]
    [ "${output}" -eq 2886730016 ]
}

@test "validate subnet is deterministic and in 172.16/12" {
    # What: Same seed yields the same /27 in 172.16/12.
    # Why: Reproducible slot from the private B block.
    # From: Issue #1683
    local a b o2 host
    a="$(_ci_validate_subnet seed-one)"
    b="$(_ci_validate_subnet seed-one)"
    [ "${a}" = "${b}" ]
    [[ "${a}" == 172.*/27 ]]
    o2="${a#172.}"; o2="${o2%%.*}"
    [ "${o2}" -ge 16 ] && [ "${o2}" -le 31 ]
    host="${a%/27}"; host="${host##*.}"
    [ "$(( host % 32 ))" -eq 0 ]
}

@test "validate detects a /27 overlapping a live network" {
    # What: An overlapping live subnet is reported.
    # Why: Reserve must skip a colliding /27.
    # From: Issue #1683
    docker() {
        case "$1 $2" in
            "network ls") echo netid1 ;;
            "network inspect") echo "172.16.1.0/24" ;;
        esac
    }
    run _ci_validate_subnet_conflicts 172.16.1.32/27
    [ "${status}" -eq 0 ]
    [[ "${output}" == "172.16.1.0/24" ]]
}

@test "validate passes a /27 that overlaps nothing live" {
    # What: A /27 overlapping nothing is free.
    # Why: Free slots must not be falsely skipped.
    # From: Issue #1683
    docker() {
        case "$1 $2" in
            "network ls") echo netid1 ;;
            "network inspect") echo "10.0.0.0/24" ;;
        esac
    }
    run _ci_validate_subnet_conflicts 172.16.1.32/27
    [ "${status}" -ne 0 ]
}

@test "validate reserve prints subnet and holder" {
    # What: Reserve yields a free /27 and lock pid.
    # Why: default_validate reads both as fields.
    # From: Issue #1683
    _ci_validate_subnet_conflicts() { return 1; }
    _ci_validate_slot_lock() { echo 4242; }
    run _ci_validate_reserve
    [ "${status}" -eq 0 ]
    [[ "${output}" == subnet=172.*"/27 holder=4242" ]]
}

@test "validate startable excludes host-mode services" {
    # What: host-mode services are never started.
    # Why: Host-port bindings cannot be isolated.
    # From: Issue #1683
    CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'printf "%s" "{\"services\":{\"proxy\":{},\"dhcp\":{\"network_mode\":\"host\"},\"dns-standard\":{}}}"')" \
        run _ci_validate_startable
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy"* ]]
    [[ "${output}" == *"dns-standard"* ]]
    [[ "${output}" != *"dhcp"* ]]
}

@test "validate health list is started and healthchecked" {
    # What: Health list is started AND healthchecked.
    # Why: Polling an unstarted service hangs out.
    # From: Issue #1683
    CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'printf "%s" "{\"services\":{\"proxy\":{\"healthcheck\":{}},\"dhcp\":{\"network_mode\":\"host\",\"healthcheck\":{}},\"cachehamster\":{}}}"')" \
        run _ci_validate_health_services
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy"* ]]
    [[ "${output}" != *"dhcp"* ]]
    [[ "${output}" != *"cachehamster"* ]]
}

@test "validate net override isolates and resets services" {
    # What: Override sets /27, resets ports and names.
    # Why: No fixed IPs, no port or name collisions.
    # From: Issue #1683
    CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'printf "%s" "{\"services\":{\"proxy\":{},\"dhcp\":{\"network_mode\":\"host\"}}}"')" \
        run _ci_validate_net_override 172.16.1.32/27
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"subnet: 172.16.1.32/27"* ]]
    [[ "${output}" == *"proxy:"* ]]
    [[ "${output}" == *"container_name: !reset null"* ]]
    [[ "${output}" == *"ports: !reset []"* ]]
    [[ "${output}" != *"dhcp:"* ]]
}

@test "validate container ip refuses a non-ipv4 result" {
    # What: A non-IPv4 inspect result is refused.
    # Why: Else a check digs a bogus resolver.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) echo "abc123" ;;
            inspect) echo "<no value>" ;;
        esac
    }
    run _ci_validate_container_ip proj proxy
    [ "${status}" -ne 0 ]
}

@test "validate container ip returns the container ipv4" {
    # What: A real IPv4 from inspect is returned.
    # Why: Checks target the runtime /27 IP.
    # From: Issue #1683
    docker() {
        case "$1" in
            compose) echo "abc123" ;;
            inspect) echo "172.16.1.35" ;;
        esac
    }
    run _ci_validate_container_ip proj proxy
    [ "${status}" -eq 0 ]
    [ "${output}" = "172.16.1.35" ]
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

@test "set-runtime errors on auth token without scheduler" {
    # What: the symmetric half of the both-or-neither pair.
    # Why: only the scheduler-without-token side had a test.
    # From: Issue #1683 | PR #1858
    CI_RUNTIME_SECRET_DIR="${BATS_TEST_TMPDIR}/rt2" \
    SCCACHE_DIST_AUTH_TOKEN='tok' \
        run bash "${CI_SH}" variables set-runtime
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VARIABLES-0011"* ]]
    [[ "${output}" == *"auth token set without scheduler"* ]]
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
    grep -v '^  alpine:' "${CI_MANIFEST_SOURCE}" > "${m}"
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

@test "build-args emits nothing for an unrecognized target" {
    # What: Unrecognized target emits nothing.
    # Why: Only manifest services get args now.
    # From: Issue #1683
    run bash "${CI_SH}" build-args not-a-real-service
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "build-args emits ALPINE_IMAGE for every plain product service" {
    # What: Every product service gets shared ALPINE_IMAGE.
    # Why: One base-image owner (base_images.alpine).
    # From: Issue #1683
    local svc
    for svc in proxy dns watchdog dhcp dhcp-proxy ntp ui cachehamster; do
        run bash "${CI_SH}" build-args "${svc}"
        [ "${status}" -eq 0 ]
        [[ "${output}" == *"--build-arg ALPINE_IMAGE=mirror.gcr.io"* ]]
        [[ "${output}" != *"FLUENT_BIT_IMAGE"* ]]
    done
}

@test "build-args emits ALPINE_IMAGE + FLUENT_BIT_IMAGE for syslog only" {
    # What: syslog emits ALPINE_IMAGE + FLUENT_BIT_IMAGE.
    # Why: syslog has external_image: fluent_bit entry.
    # From: Issue #1683
    run bash "${CI_SH}" build-args syslog
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--build-arg ALPINE_IMAGE=mirror.gcr.io"* ]]
    [[ "${output}" == *"--build-arg FLUENT_BIT_IMAGE=cr.fluentbit.io"* ]]
}

@test "build-args --bare syslog emits FLUENT_BIT_IMAGE without the flag prefix" {
    # What: --bare drops --build-arg flag prefix.
    # Why: docker/build-push-action wants NAME=VALUE format.
    # From: Issue #1683
    run bash "${CI_SH}" build-args syslog --bare
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"FLUENT_BIT_IMAGE=cr.fluentbit.io"* ]]
    [[ "${output}" != *"--build-arg"* ]]
}

@test "build-args emits only ALPINE_IMAGE for netdata (no version pin)" {
    # What: netdata gets ALPINE_IMAGE only.
    # Why: netdata keeps baked-in ARG defaults (SOT-Sync).
    # From: Issue #1683
    run bash "${CI_SH}" build-args netdata
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--build-arg ALPINE_IMAGE=mirror.gcr.io"* ]]
    [[ "${output}" != *"NETDATA_VERSION"* ]]
    [[ "${output}" != *"NETDATA_X86_64_SHA256"* ]]
}

@test "build-args for a product service fails closed on a missing central base image" {
    # What: Missing base_images.alpine pin fails closed.
    # Why: FAIL CLOSED covers every ALPINE_IMAGE emitter.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/no-rust-alpine-proxy.yml"
    grep -v '^  alpine:' "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args proxy
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0007"* ]]
}

@test "build-args fails closed on an unmapped external_image value" {
    # What: Unmapped external_image value fails closed.
    # Why: AG-VAL-030: prove failure path not guess.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/bogus-external-image.yml"
    sed 's/external_image: fluent_bit/external_image: bogus_thing/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-args syslog
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDARGS-0008"* ]]
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
        "${CI_MANIFEST_SOURCE}" > "${m}"
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

@test "build-tools channel maps master to latest, else to nightly" {
    # What: the tooling-image channel per target ref.
    # Why: promote feeds only latest (master) and nightly (else).
    # From: Issue #1683
    [ "$(_ci_build_tools_channel master)" = latest ]
    [ "$(_ci_build_tools_channel current_dev)" = nightly ]
    [ "$(_ci_build_tools_channel feature/claude/x)" = nightly ]
    [ "$(_ci_build_tools_channel "")" = nightly ]
}

@test "build-tools resolve-image fails closed on a drifted published signature" {
    # What: a published toolchain != SOT signature must fail closed.
    # Why: container jobs must not run on a stale toolchain image.
    # From: Issue #1683
    CI_APK_RESOLVE_CMD="$(_stub apk 'printf "pkg-1.0\n"')" \
    CI_PUBLISHED_SIG_CMD="$(_stub psig 'echo drifted-sig')" \
    GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" build-tools resolve-image
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"BUILDTOOLS-0019"* ]]
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

@test "build-tools resolve-signature fails closed on a missing central base image" {
    # What: missing base image must fail closed here.
    # Why: errexit must not swallow the fail-closed path.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/no-resolve-alpine.yml"
    grep -v '^  alpine:' "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" build-tools resolve-signature
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0009"* ]]
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
        GITHUB_REPOSITORY=wiki-mod/lancache-ng BT_ARCH=both BT_MODE=check \
        GITHUB_OUTPUT="${gho}" \
        bash "${CI_SH}" build-tools plan
    [ "${status}" -eq 0 ]
    grep -q '^signature=' "${gho}"
    grep -q '^build-amd64=true$' "${gho}"
    grep -q '^build-arm64=true$' "${gho}"
    grep -q '^matrix={"include":' "${gho}"
    grep -q '^image=ghcr.io/wiki-mod/lancache-ng/build-tools$' "${gho}"
}

@test "build-tools rejects an unknown subcommand (fail closed)" {
    # What: An unknown sub must not silently succeed.
    # Why: Fail-closed dispatch (AG-VAL-002).
    # From: Issue #1683
    run bash "${CI_SH}" build-tools bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-BUILDTOOLS-0003"* ]]
}

@test "build-tools tag is sha-<full>-<arch> for a platform" {
    # What: The tag binds the git sha and the arch.
    # Why: sha-<full>-<arch>; AG-REL-015 form only.
    # From: Issue #1683
    GITHUB_REPOSITORY=wiki-mod/lancache-ng GITHUB_SHA=abc123 \
        run _ci_build_tools_tag linux/arm64
    [ "${status}" -eq 0 ]
    [ "${output}" = "ghcr.io/wiki-mod/lancache-ng/build-tools:sha-abc123-arm64" ]
}

@test "build-tools image is the base ref from the SOT registry" {
    # What: The base build-tools ref from the SOT.
    # Why: One registry-host owner, no env fallback.
    # From: Issue #1683
    GITHUB_REPOSITORY=wiki-mod/lancache-ng run bash "${CI_SH}" build-tools image
    [ "${status}" -eq 0 ]
    [ "${output}" = "ghcr.io/wiki-mod/lancache-ng/build-tools" ]
}

@test "build-tools build pushes the per-arch tag and returns the digest" {
    # What: build+push then read back the pushed digest.
    # Why: One build+push owner; no live registry in test.
    # From: Issue #1683
    export DLOG="${BATS_TEST_TMPDIR}/d.log"; : > "${DLOG}"
    docker() { printf 'docker %s\n' "$*" >> "${DLOG}"; case "$*" in *"imagetools inspect"*) printf 'sha256:dead\n' ;; esac; return 0; }
    export -f docker
    GITHUB_REPOSITORY=wiki-mod/lancache-ng GITHUB_SHA=abc123 \
        run _ci_build_tools_build linux/amd64 sig-xyz
    [ "${status}" -eq 0 ]
    [ "${output}" = "sha256:dead" ]
    grep -q "buildx build --push" "${DLOG}"
    grep -q "sha-abc123-amd64" "${DLOG}"
    grep -q "signature=sig-xyz" "${DLOG}"
    grep -q "tools/build-tools" "${DLOG}"
    grep -q "org.opencontainers.image.revision=abc123" "${DLOG}"
}

@test "oci labels emit provenance from the SOT and env" {
    # What: revision/source/licenses/base from SOT+env.
    # Why: Provenance labels have one owner (Plan §7).
    # From: Issue #1683
    GITHUB_SHA=abc123 run _ci_oci_labels build-tools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"image.revision=abc123"* ]]
    [[ "${output}" == *"image.version=abc123"* ]]
    [[ "${output}" == *"image.source=https://github.com/wiki-mod/lancache-ng"* ]]
    [[ "${output}" == *"image.licenses=AGPL-3.0-or-later"* ]]
    [[ "${output}" == *"image.title=build-tools"* ]]
    [[ "${output}" == *"image.description=LanCache-NG build-tools image"* ]]
    [[ "${output}" == *"image.base.digest=sha256:"* ]]
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

@test "check file-headers fails an extension with no native syntax" {
    # What: a file type _ci_header_expected has no case for.
    # Why: distinct from a missing header on a known type.
    # From: Issue #1683 | PR #1858
    printf 'whatever\n' > "${BATS_TEST_TMPDIR}/weird.xyz"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/weird.xyz"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no native header syntax"* ]]
}

@test "check file-headers fails a legacy lowercase header mention" {
    # What: canonical header, plus a stray legacy mention.
    # Why: the lc>0 branch had zero test coverage before.
    # From: Issue #1683 | PR #1858
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# lancache-ng (https://github.com/wiki-mod/lancache-ng)\n' \
        > "${BATS_TEST_TMPDIR}/legacy.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/legacy.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"legacy lowercase header present"* ]]
}

@test "check file-headers accepts canonical headers across comment syntaxes" {
    # What: shebang/blank line 1 + Lua/CSS/Rust-placeholder native syntax.
    # Why: absorbs check-file-headers.sh's per-format acceptance coverage.
    # From: Issue #1683 | PR #1858
    local h='# LanCache-NG (https://github.com/wiki-mod/lancache-ng)'
    local s='# SPDX-License-Identifier: AGPL-3.0-or-later'
    printf '#!/usr/bin/env bash\n%s\n%s\necho hi\n' "${h}" "${s}" > "${BATS_TEST_TMPDIR}/a.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.sh"; [ "${status}" -eq 0 ]
    printf '\n-- LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n-- SPDX-License-Identifier: AGPL-3.0-or-later\nreturn true\n' > "${BATS_TEST_TMPDIR}/a.lua"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.lua"; [ "${status}" -eq 0 ]
    printf '\n/* LanCache-NG (https://github.com/wiki-mod/lancache-ng) */\n/* SPDX-License-Identifier: AGPL-3.0-or-later */\nbody {}\n' > "${BATS_TEST_TMPDIR}/a.css"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.css"; [ "${status}" -eq 0 ]
    printf '//!\n//! LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n//! SPDX-License-Identifier: AGPL-3.0-or-later\nfn main() {}\n' > "${BATS_TEST_TMPDIR}/a.rs"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.rs"; [ "${status}" -eq 0 ]
    printf '# hello\n' > "${BATS_TEST_TMPDIR}/a.md"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/a.md"; [ "${status}" -eq 0 ]
}

@test "check file-headers rejects layout violations" {
    # What: swapped, duplicate, no-blank line 1, JS-embedded SPDX.
    # Why: absorbs check-file-headers.sh's layout-contract rejections.
    # From: Issue #1683 | PR #1858
    printf '#!/usr/bin/env bash\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "${BATS_TEST_TMPDIR}/sw.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/sw.sh"; [ "${status}" -ne 0 ]
    printf '#!/usr/bin/env bash\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\necho hi\n' > "${BATS_TEST_TMPDIR}/dup.sh"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/dup.sh"; [ "${status}" -ne 0 ]; [[ "${output}" == *"count"* ]]
    printf '# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nkey: value\n' > "${BATS_TEST_TMPDIR}/nb.yml"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/nb.yml"; [ "${status}" -ne 0 ]
    printf '\n// LanCache-NG (https://github.com/wiki-mod/lancache-ng)\nconst license = "SPDX-License-Identifier: AGPL-3.0-or-later";\n' > "${BATS_TEST_TMPDIR}/emb.js"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/emb.js"; [ "${status}" -ne 0 ]
}

@test "check file-headers handles Tera and Docker parser-directive cases" {
    # What: Tera block accept, Docker directive accept + second-line reject.
    # Why: absorbs check-file-headers.sh's line-1-marker edge coverage.
    # From: Issue #1683 | PR #1858
    local t="${BATS_TEST_TMPDIR}/services/ui/src/templates"; mkdir -p "${t}"
    printf '%s\n' '' '{# LanCache-NG (https://github.com/wiki-mod/lancache-ng) #}' '{# SPDX-License-Identifier: AGPL-3.0-or-later #}' '{% extends "base.html" %}' > "${t}/ok.html"
    run bash -c "cd '${BATS_TEST_TMPDIR}' && bash '${CI_SH}' check file-headers services/ui/src/templates/ok.html"; [ "${status}" -eq 0 ]
    printf '# syntax=docker/dockerfile:1\n# LanCache-NG (https://github.com/wiki-mod/lancache-ng)\n# SPDX-License-Identifier: AGPL-3.0-or-later\nFROM scratch\n' > "${BATS_TEST_TMPDIR}/Dockerfile"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/Dockerfile"; [ "${status}" -eq 0 ]
    printf '# syntax=docker/dockerfile:1\n# escape=\140\n# SPDX-License-Identifier: AGPL-3.0-or-later\nFROM scratch\n' > "${BATS_TEST_TMPDIR}/Dockerfile"
    run bash "${CI_SH}" check file-headers "${BATS_TEST_TMPDIR}/Dockerfile"; [ "${status}" -ne 0 ]
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

@test "check deny-short-sha catches naming, prefix, and format slice variants" {
    # What: every sha/commit/candidate/revision slice shape fails.
    # Why: preserves check-deny-short-sha.sh's pattern coverage.
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}"
    printf 'a=${commit:0:7}\nb=${candidate::7}\nc=${revision:0:8}\n' > "${d}/naming.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/naming.sh"
    [ "${status}" -ne 0 ]; [[ "${output}" == *"naming.sh:1"* ]]; [[ "${output}" == *"naming.sh:2"* ]]; [[ "${output}" == *"naming.sh:3"* ]]
    printf 'x=${commit1_sha:0:7}\n' > "${d}/digit.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/digit.sh"; [ "${status}" -ne 0 ]
    printf 'base_sha_short="${base_sha:0:7}"\n' > "${d}/target.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/target.sh"; [ "${status}" -ne 0 ]
    printf 't="ghcr.io/x:sha-${ancestor_sha:0:7}"\n' > "${d}/interp.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/interp.sh"; [ "${status}" -ne 0 ]
    printf 'v=${full_sha:0:length}\n' > "${d}/varlen.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/varlen.sh"; [ "${status}" -ne 0 ]
    printf 'w=${GITHUB_SHA: 0 : 7}\n' > "${d}/ws1.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/ws1.sh"; [ "${status}" -ne 0 ]
    printf 'w=${GITHUB_SHA : : 7}\n' > "${d}/ws2.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/ws2.sh"; [ "${status}" -ne 0 ]
    printf 'n=${COMMIT_SHA::12}\n' > "${d}/len12.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/len12.sh"; [ "${status}" -ne 0 ]
}

@test "check deny-short-sha allows full-SHA refs and git rev-parse --short" {
    # What: full-SHA use and rev-parse --short fallback stay clean.
    # Why: the ban targets bash slices only (issue #1095).
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}"
    printf 'full="ghcr.io/${repo}/${svc}:sha-${commit}"\n' > "${d}/full.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/full.sh"
    [ "${status}" -eq 0 ]; [[ "${output}" == *"deny-short-sha=clean"* ]]
    printf 's="$(git rev-parse --short=7 "$c")"\n' > "${d}/revparse.sh"
    run bash "${CI_SH}" check deny-short-sha "${d}/revparse.sh"
    [ "${status}" -eq 0 ]
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

@test "check language-policy bans JS/TS files but exempts vendored min.js" {
    # What: absorbs check-language-policy.sh's JS/TS extension ban.
    # Why: a new authored .js must fail; vendored min.js must not.
    # From: Issue #1683 | PR #1858
    printf 'let x=1\n' > "${BATS_TEST_TMPDIR}/app.js"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/app.js"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0007"* ]]
    printf 'export const x=1\n' > "${BATS_TEST_TMPDIR}/mod.ts"
    run bash "${CI_SH}" check language-policy "${BATS_TEST_TMPDIR}/mod.ts"
    [ "${status}" -ne 0 ]
    mkdir -p "${BATS_TEST_TMPDIR}/services/ui/src/static"
    printf 'minified\n' > "${BATS_TEST_TMPDIR}/services/ui/src/static/x.min.js"
    run bash -c "cd '${BATS_TEST_TMPDIR}' && bash '${CI_SH}' check language-policy services/ui/src/static/x.min.js"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"language-policy=clean"* ]]
}

@test "check mutable-refs fails a floating action version via ci.sh" {
    # What: ci.sh owns the pin invariant; bats calls it.
    # Why: no :latest / @vN; SHA/digest-pinned only.
    # From: Issue #1683
    printf 'jobs:\n  x:\n    steps:\n      - uses: foo/bar@abc1234\n' > "${BATS_TEST_TMPDIR}/ok.yml"
    run bash "${CI_SH}" check mutable-refs "${BATS_TEST_TMPDIR}/ok.yml"
    [ "${status}" -eq 0 ]
    printf 'jobs:\n  x:\n    steps:\n      - uses: foo/bar@v4\n' > "${BATS_TEST_TMPDIR}/bad.yml"
    run bash "${CI_SH}" check mutable-refs "${BATS_TEST_TMPDIR}/bad.yml"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0008"* ]]
}

@test "check mutable-refs default scan includes composite-action action.yml" {
    # What: the default glob now covers .github/actions/**/action.yml.
    # Why: a composite action could carry a floating @vN ref unguarded.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/mrepo"
    mkdir -p "${r}/.github/actions/x"
    printf 'runs:\n  using: composite\n  steps:\n    - uses: foo/bar@v4\n' > "${r}/.github/actions/x/action.yml"
    ( cd "${r}" && git init -q && git add -A )
    run bash -c "cd '${r}' && bash '${CI_SH}' check mutable-refs"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"action-@vN"* ]]
    printf 'runs:\n  using: composite\n  steps:\n    - uses: foo/bar@abc1234def\n' > "${r}/.github/actions/x/action.yml"
    ( cd "${r}" && git add -A )
    run bash -c "cd '${r}' && bash '${CI_SH}' check mutable-refs"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mutable-refs=clean"* ]]
}

@test "check mutable-refs fails a floating BUILD_TOOLS_IMAGE default" {
    # What: the img-default-latest yml sub-pattern, unseen.
    # Why: a second violation kind in the same yml branch.
    # From: Issue #1683 | PR #1858
    printf 'env:\n  BUILD_TOOLS_IMAGE=ghcr.io/wiki-mod/build-tools:latest\n' \
        > "${BATS_TEST_TMPDIR}/imglatest.yml"
    run bash "${CI_SH}" check mutable-refs "${BATS_TEST_TMPDIR}/imglatest.yml"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"img-default-latest"* ]]
    printf "run: grep -F 'ARG BUILD_TOOLS_IMAGE=ghcr.io/x/build-tools:latest' f\n" \
        > "${BATS_TEST_TMPDIR}/greppat.yml"
    run bash "${CI_SH}" check mutable-refs "${BATS_TEST_TMPDIR}/greppat.yml"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"mutable-refs=clean"* ]]
}

@test "check mutable-refs fails a Dockerfile FROM:latest and untagged FROM" {
    # What: both Dockerfile-side sub-patterns, unseen still.
    # Why: distinct from the yml-side action/@vN case above.
    # From: Issue #1683 | PR #1858
    local d1="${BATS_TEST_TMPDIR}/fromlatest"; mkdir -p "${d1}"
    printf 'FROM alpine:latest\n' > "${d1}/Dockerfile"
    run bash "${CI_SH}" check mutable-refs "${d1}/Dockerfile"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"FROM-latest"* ]]
    local d2="${BATS_TEST_TMPDIR}/untagged"; mkdir -p "${d2}"
    printf 'FROM someimage\n' > "${d2}/Dockerfile"
    run bash "${CI_SH}" check mutable-refs "${d2}/Dockerfile"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"FROM-untagged"* ]]
}

@test "check mutable-refs does not flag a real tag as untagged" {
    # What: AG-WF-027: this found a real bug; fixed here.
    # Why: ':' in the untagged charset false-matched 3.24.
    # From: Issue #1683 | PR #1858
    local d="${BATS_TEST_TMPDIR}/realtag"; mkdir -p "${d}"
    printf 'FROM alpine:3.24\n' > "${d}/Dockerfile"
    run bash "${CI_SH}" check mutable-refs "${d}/Dockerfile"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"FROM-untagged"* ]]
}

@test "check executable-bits fails a non-755 bare-path script via ci.sh" {
    # What: ci.sh owns the mode check; bats calls it.
    # Why: bare-path scripts must carry the exec bit.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/exr"; mkdir -p "${r}"
    git -C "${r}" init -q
    printf '#!/usr/bin/env bash\n' > "${r}/s.sh"
    git -C "${r}" add s.sh
    run bash -c "cd '${r}' && bash '${CI_SH}' check executable-bits s.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0009"* ]]
    git -C "${r}" update-index --chmod=+x s.sh
    run bash -c "cd '${r}' && bash '${CI_SH}' check executable-bits s.sh"
    [ "${status}" -eq 0 ]
}

@test "check review-chronology flags narration and stale line-ref" {
    # What: ci.sh owns AG-CODE-002/003; bats calls it.
    # Why: comments state current code, no chronology.
    # From: Issue #1683
    printf '# a normal current-state comment.\n' > "${BATS_TEST_TMPDIR}/okc.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/okc.sh"
    [ "${status}" -eq 0 ]
    printf '# found during code review earlier.\n' > "${BATS_TEST_TMPDIR}/badc.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/badc.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0010"* ]]
    printf '# the handler (line 42) does the work.\n' > "${BATS_TEST_TMPDIR}/badl.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/badl.sh"
    [ "${status}" -ne 0 ]
}

@test "check review-chronology exempts legacy-excluded file types" {
    # What: Legacy-excluded file types (*.md) skip scan.
    # Why: Parity with legacy script's is_excluded().
    # From: Issue #1683
    printf '# found during code review earlier.\n' > "${BATS_TEST_TMPDIR}/notes.md"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/notes.md"
    [ "${status}" -eq 0 ]
}

@test "check review-chronology CHRONOLOGY_WARN_ONLY downgrades a real violation to exit 0" {
    # What: CHRONOLOGY_WARN_ONLY surfaces but doesn't block.
    # Why: AG-GH-018 transitional warn path (Issue #1095).
    # From: Issue #1683
    printf '# found during code review earlier.\n' > "${BATS_TEST_TMPDIR}/badc.sh"
    run env CHRONOLOGY_WARN_ONLY=1 bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/badc.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"review-chronology=warn"* ]]
    [[ "${output}" == *"CI-ERROR-CHECK-0010"* ]]
}

@test "check review-chronology duplicate #N outside From: is always warn-only" {
    # What: Bare #N outside From: never blocks.
    # Why: PR #1856 downgraded to warn-only.
    # From: Issue #1683
    printf '# From: Issue #1683\n# see #1683 again here\n' > "${BATS_TEST_TMPDIR}/dupref.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/dupref.sh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0010"* ]]
    [[ "${output}" == *"warn-only, PR #1856"* ]]
}

@test "check review-chronology diff-scoped mode scans only the PR's changed files" {
    # What: CHRONOLOGY_DIFF_BASE_SHA scans changed files.
    # Why: Parity: pre-existing violations don't block.
    # From: Issue #1683
    local bare="${BATS_TEST_TMPDIR}/chrono-origin.git" work="${BATS_TEST_TMPDIR}/chrono-work"
    git init --quiet --bare "${bare}"
    git clone --quiet "${bare}" "${work}"
    (
        cd "${work}" || exit 1
        git config user.email chrono-bats@example.invalid
        git config user.name chrono-bats
        printf '# found during code review earlier.\n' > pre-existing.sh
        git add pre-existing.sh
        git commit --quiet -m base
        git push --quiet origin HEAD:refs/heads/chrono-base
    )
    cd "${work}"
    local base_sha; base_sha="$(git rev-parse HEAD)"
    printf '# a normal current-state comment.\n' > touched.sh
    git add touched.sh
    git commit --quiet -m "touch an unrelated file"
    local head_sha; head_sha="$(git rev-parse HEAD)"
    run env CHRONOLOGY_DIFF_BASE_SHA="${base_sha}" CHRONOLOGY_DIFF_BASE_REF=chrono-base \
        GITHUB_SHA="${head_sha}" bash "${CI_SH}" check review-chronology
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"review-chronology=clean"* ]]
}

@test "check review-chronology diff-scoped mode fails closed when git diff itself fails" {
    # What: git diff failure returns 2, not empty file list.
    # Why: Capture to file preserves exit; mapfile drops it.
    # From: Issue #1683
    local bare="${BATS_TEST_TMPDIR}/chronofail-origin.git" work="${BATS_TEST_TMPDIR}/chronofail-work"
    git init --quiet --bare "${bare}"
    git clone --quiet "${bare}" "${work}"
    (
        cd "${work}" || exit 1
        git config user.email chrono-bats@example.invalid
        git config user.name chrono-bats
        git commit --quiet --allow-empty -m base
        git push --quiet origin HEAD:refs/heads/chrono-base
    )
    cd "${work}"
    local base_sha; base_sha="$(git rev-parse HEAD)"
    git commit --quiet --allow-empty -m "second commit"
    local head_sha; head_sha="$(git rev-parse HEAD)"
    local real_git; real_git="$(command -v git)"
    local stub_bin="${BATS_TEST_TMPDIR}/stubbin"
    mkdir -p "${stub_bin}"
    cat > "${stub_bin}/git" <<STUBEOF
#!/usr/bin/env bash
if [ "\$1" = "diff" ]; then
    echo "simulated git diff failure" >&2
    exit 128
fi
exec "${real_git}" "\$@"
STUBEOF
    chmod +x "${stub_bin}/git"
    run env PATH="${stub_bin}:${PATH}" CHRONOLOGY_DIFF_BASE_SHA="${base_sha}" \
        CHRONOLOGY_DIFF_BASE_REF=chrono-base GITHUB_SHA="${head_sha}" \
        bash "${CI_SH}" check review-chronology
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"git diff itself failed"* ]]
    [[ "${output}" != *"review-chronology=clean"* ]]
}

@test "check review-chronology detects varied discovery-verb phrasings" {
    # What: before-this-fix / flagged-in-review / review-finding, incl wrapped.
    # Why: absorbs check_review_chronology_comments.bats verb coverage.
    # From: Issue #1683 | PR #1858
    local p
    for p in "fixed it before this fix landed" "flagged in review on PR #743" "this is a review finding note" "caught during self-review here"; do
        printf '# %s\n' "${p}" > "${BATS_TEST_TMPDIR}/v.sh"
        run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/v.sh"
        [ "${status}" -ne 0 ] || { echo "want fail: ${p}"; false; }
    done
    printf '# noted a review\n# finding in the code\n' > "${BATS_TEST_TMPDIR}/w.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/w.sh"; [ "${status}" -ne 0 ]
    for p in "see the manual review section" "runs after this PR merges" "remembered during review to add this"; do
        printf '# %s\n' "${p}" > "${BATS_TEST_TMPDIR}/ok.sh"
        run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/ok.sh"
        [ "${status}" -eq 0 ] || { echo "want pass: ${p}"; false; }
    done
}

@test "check review-chronology flags stale line-refs, exempts plain prose" {
    # What: (line ~N) and (see line N) fail; prose 'line' passes.
    # Why: absorbs the line-ref-detection coverage.
    # From: Issue #1683 | PR #1858
    printf '# revisit this logic (line ~890) soon\n' > "${BATS_TEST_TMPDIR}/l.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/l.sh"; [ "${status}" -ne 0 ]
    printf '# the fix is above (see line 42 above)\n' > "${BATS_TEST_TMPDIR}/l.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/l.sh"; [ "${status}" -ne 0 ]
    printf '# each line of the config is parsed here\n' > "${BATS_TEST_TMPDIR}/l.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/l.sh"; [ "${status}" -eq 0 ]
}

@test "check review-chronology duplicate-#N string-literal and longer-number cases" {
    # What: a bare From: dup warns; string-literal / longer / different pass.
    # Why: absorbs the bare-#N duplicate edge coverage.
    # From: Issue #1683 | PR #1858
    printf '# From: Issue #887\nlocal x="#887"\n' > "${BATS_TEST_TMPDIR}/d.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"; [ "${status}" -eq 0 ]
    printf '# From: Issue #887\n# see also #999 for context\n' > "${BATS_TEST_TMPDIR}/d.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"; [ "${status}" -eq 0 ]
    printf '# From: Issue #887\n# unrelated #8871 ticket\n' > "${BATS_TEST_TMPDIR}/d.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"; [ "${status}" -eq 0 ]
    printf '# From: Issue #887\n# duplicate ref #887 here\n' > "${BATS_TEST_TMPDIR}/d.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/d.sh"
    [ "${status}" -eq 0 ]; [[ "${output}" == *"CI-ERROR-CHECK-0010"* ]]
}

@test "check review-chronology explicit args scan only the listed files" {
    # What: only listed files scanned; a violation elsewhere is ignored.
    # Why: absorbs the explicit-file-args scoping coverage.
    # From: Issue #1683 | PR #1858
    printf '# clean note\n' > "${BATS_TEST_TMPDIR}/clean.sh"
    printf '# caught in review here\n' > "${BATS_TEST_TMPDIR}/dirty.sh"
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/clean.sh"; [ "${status}" -eq 0 ]
    run bash "${CI_SH}" check review-chronology "${BATS_TEST_TMPDIR}/dirty.sh"; [ "${status}" -ne 0 ]
}

@test "check pipefail-early-exit flags grep -q, not plain sed -n" {
    # What: ci.sh owns the SIGPIPE check; bats calls it.
    # Why: only true early-exit consumers risk exit 141.
    # From: Issue #1683
    printf 'set -o pipefail\nx="$(seq 1 9)"\n' > "${BATS_TEST_TMPDIR}/okp.sh"
    run bash "${CI_SH}" check pipefail-early-exit "${BATS_TEST_TMPDIR}/okp.sh"
    [ "${status}" -eq 0 ]
    printf 'set -o pipefail\nseq 1 9 | grep -q 3\n' > "${BATS_TEST_TMPDIR}/badp.sh"
    run bash "${CI_SH}" check pipefail-early-exit "${BATS_TEST_TMPDIR}/badp.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0011"* ]]
    printf 'set -o pipefail\nseq 1 9 | sed -n "s/3/x/p"\n' > "${BATS_TEST_TMPDIR}/sedp.sh"
    run bash "${CI_SH}" check pipefail-early-exit "${BATS_TEST_TMPDIR}/sedp.sh"
    [ "${status}" -eq 0 ]
}

@test "check pr-title accepts valid conventional, warns by default on bad scope/format" {
    # What: ci.sh owns the title taxonomy; bats calls it.
    # Why: AG-GH-018: warn is the default, not a hard fail.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check pr-title "feat(proxy): add ipv6 lease support"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pr-title=ok"* ]]
    run bash "${CI_SH}" check pr-title "feat(bogus): x"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pr-title=warn"* ]]
    run bash "${CI_SH}" check pr-title "not conventional at all"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0013"* ]]
    [[ "${output}" == *"pr-title=warn"* ]]
}

@test "check pr-title skips dependabot and fails closed with none" {
    # What: dependabot skip and the no-title-given branches.
    # Why: both existed in code with no prior test coverage.
    # From: Issue #1683 | PR #1858
    PR_AUTHOR='dependabot[bot]' run bash "${CI_SH}" check pr-title "anything at all"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pr-title=skip-dependabot"* ]]
    run bash "${CI_SH}" check pr-title
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0012"* ]]
}

@test "check pr-title accepts breaking-marker, optional scope, security type, CRLF" {
    # What: !, no-scope, scope+!, security, and a CRLF title pass.
    # Why: preserves check-pr-title-convention.sh grammar coverage.
    # From: Issue #1683 | PR #1858
    local t
    for t in "fix: correct cache key" "feat!: drop legacy flag" "fix(build-tools)!: bump base" "security: patch cve" "security(proxy): patch cve"; do
        run bash "${CI_SH}" check pr-title "${t}"
        [ "${status}" -eq 0 ] || { echo "rejected: ${t} -> ${output}"; false; }
        [[ "${output}" == *"pr-title=ok"* ]]
    done
    PR_TITLE=$'feat(dns): ok\r' run bash "${CI_SH}" check pr-title
    [ "${status}" -eq 0 ]; [[ "${output}" == *"pr-title=ok"* ]]
}

@test "check pr-title warns (default mode) on a disallowed type" {
    # What: a title matching the pattern but a bad type.
    # Why: distinct from the not-conventional regex miss.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check pr-title "bogus(proxy): x"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"type 'bogus' not allowed"* ]]
    [[ "${output}" == *"pr-title=warn"* ]]
}

@test "check pr-title block mode fails a non-compliant title" {
    # What: LINT_MODE=block must hard-fail (AG-GH-018 gate).
    # Why: this branch had zero coverage before this wave.
    # From: Issue #1683 | PR #1858
    PR_TITLE_LINT_MODE=block run bash "${CI_SH}" check pr-title "not conventional at all"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0013"* ]]
    [[ "${output}" == *"reason=\"PR title convention\""* ]]
}

@test "check pr-title draft PR warns non-blocking even in block mode" {
    # What: AG-GH-018: draft always overrides block mode.
    # Why: draft titles are expected to settle before ready.
    # From: Issue #1683 | PR #1858
    PR_TITLE_LINT_MODE=block PR_DRAFT=true \
        run bash "${CI_SH}" check pr-title "not conventional at all"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pr-title=warn-draft"* ]]
}

@test "check pr-title allows the tests scope" {
    # What: "tests" was missing from ci.sh's scope set.
    # Why: the authoritative checker script allows it too.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check pr-title "test(tests): add coverage"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pr-title=ok"* ]]
}

@test "check stable-external-images fails a non-digest external image" {
    # What: ci.sh owns the pin gate; bats calls it.
    # Why: floating external tag breaks reproducibility.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/dep"; mkdir -p "${r}"
    printf 'services:\n  x:\n    image: redis:7\n' > "${r}/docker-compose.yml"
    run bash "${CI_SH}" check stable-external-images "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0014"* ]]
    printf 'services:\n  x:\n    image: ghcr.io/wiki-mod/lancache-ng/proxy:latest\n' > "${r}/docker-compose.yml"
    run bash "${CI_SH}" check stable-external-images "${r}"
    [ "${status}" -eq 0 ]
}

@test "check pr-template requires every current template section filled" {
    # What: ci.sh derives required sections from template.
    # Why: Hardcoded list drifts with template changes.
    # From: Issue #1683
    local body='## Summary
Fixes the thing.

## Linked Issues
Refs #1

## What This Actually Changes
Before/after text.

## What This PR Fixes / Adds
The bug.

## What Changed In Code
Touched foo.sh.

## Why This Matters For Users / Operators
Operators see X.

## Scope Boundaries
Does not touch Y.

## Risk / Rollback / Follow-up
Low risk, revert commit.

## Local Scope Evidence
```text
foo.sh
```

## Validation
```bash
bash foo.sh
```

## Type of change
- [x] Bug fix

## Changelog
Fixed foo.'
    printf '%s' "${body}" > "${BATS_TEST_TMPDIR}/full.md"
    run bash "${CI_SH}" check pr-template "${BATS_TEST_TMPDIR}/full.md"
    [ "${status}" -eq 0 ]
}

@test "check pr-template fails an unfilled section and an unchecked type-of-change" {
    # What: Untouched heading or unchecked box must fail.
    # Why: Legacy missed checkbox case in validation.
    # From: Issue #1683
    local body='## Summary
Fixes the thing.

## Type of change
- [ ] Bug fix
- [ ] New feature
'
    printf '%s' "${body}" > "${BATS_TEST_TMPDIR}/bad.md"
    run bash "${CI_SH}" check pr-template "${BATS_TEST_TMPDIR}/bad.md"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0015"* ]]
    [[ "${output}" == *"Linked Issues: heading not found"* ]]
    [[ "${output}" == *"Type of change: no checkbox marked"* ]]
}

@test "check workflow-line-limit fails a workflow file over the line ceiling" {
    # What: ci.sh owns GitHub dispatch-cliff size limit.
    # Why: GitHub drops runs for oversized workflow files.
    # From: Issue #1683
    local d="${BATS_TEST_TMPDIR}/wf"; mkdir -p "${d}"
    printf 'name: ok\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n' \
        > "${d}/ok.yml"
    run bash "${CI_SH}" check workflow-line-limit "${d}"
    [ "${status}" -eq 0 ]
    {
        printf 'name: big\non: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n'
        local _i
        for _i in $(seq 1 9000); do printf '      - run: echo hi\n'; done
    } > "${d}/big.yml"
    run bash "${CI_SH}" check workflow-line-limit "${d}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0016"* ]]
}

@test "check pr-tracking-metadata requires PR context, labels, and milestone" {
    # What: ci.sh owns AG-GH-008 metadata gate.
    # Why: Metadata gaps must fail before network access.
    # From: Issue #1683
    run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 2 ]
    PR_NUMBER=12 REPO=wiki-mod/lancache-ng PR_LABELS_JSON='[]' \
        run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0017"* ]]
    PR_NUMBER=12 REPO=wiki-mod/lancache-ng PR_LABELS_JSON='["bug"]' PR_MILESTONE_TITLE=v1 \
        run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 0 ]
}

@test "check pr-tracking-metadata fails when the project-board token is rejected" {
    # What: Rejected GH_TOKEN is config problem, fails loud.
    # Why: Distinguishes missing vs. bad token.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    cat > "${bin}/curl" <<'EOF'
#!/usr/bin/env bash
out="" prev=""
for a in "$@"; do
    [ "${prev}" = "-o" ] && out="${a}"
    prev="${a}"
done
[ -n "${out}" ] && : > "${out}"
printf '403'
EOF
    chmod +x "${bin}/curl"
    PATH="${bin}:${PATH}" PR_NUMBER=12 REPO=wiki-mod/lancache-ng PR_LABELS_JSON='["bug"]' \
        PR_MILESTONE_TITLE=v1 GH_TOKEN=badtoken \
        run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0017"* ]]
    [[ "${output}" == *"rejected"* ]]
}

@test "check pr-tracking-metadata warns fork-specific with no token" {
    # What: PR_IS_FORK=true never reached by any prior test.
    # Why: forks get no secrets; warn, don't pass silently.
    # From: Issue #1683 | PR #1858
    PR_NUMBER=12 REPO=wiki-mod/lancache-ng PR_LABELS_JSON='["bug"]' \
        PR_MILESTONE_TITLE=v1 PR_IS_FORK=true \
        run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"fork PRs get no repo secrets"* ]]
}

@test "check pr-tracking-metadata passes on a real 200 board hit" {
    # What: the GH_TOKEN-set 200-success path was untested.
    # Why: only its 403-rejected sibling had any coverage.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin2"; mkdir -p "${bin}"
    cat > "${bin}/curl" <<'EOF'
#!/usr/bin/env bash
out="" prev=""
for a in "$@"; do
    [ "${prev}" = "-o" ] && out="${a}"
    prev="${a}"
done
[ -n "${out}" ] && printf '{"data":{"repository":{"pullRequest":{"projectItems":{"nodes":[{"project":{"number":6}}]}}}}}' > "${out}"
printf '200'
EOF
    chmod +x "${bin}/curl"
    PATH="${bin}:${PATH}" PR_NUMBER=12 REPO=wiki-mod/lancache-ng PR_LABELS_JSON='["bug"]' \
        PR_MILESTONE_TITLE=v1 GH_TOKEN=goodtoken \
        run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pr-tracking-metadata=ok"* ]]
}

@test "check pr-tracking-metadata fails a real 200 board miss" {
    # What: 200 response, PR on no matching project item.
    # Why: the "not on project board" branch was untested.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin3"; mkdir -p "${bin}"
    cat > "${bin}/curl" <<'EOF'
#!/usr/bin/env bash
out="" prev=""
for a in "$@"; do
    [ "${prev}" = "-o" ] && out="${a}"
    prev="${a}"
done
[ -n "${out}" ] && printf '{"data":{"repository":{"pullRequest":{"projectItems":{"nodes":[]}}}}}' > "${out}"
printf '200'
EOF
    chmod +x "${bin}/curl"
    PATH="${bin}:${PATH}" PR_NUMBER=12 REPO=wiki-mod/lancache-ng PR_LABELS_JSON='["bug"]' \
        PR_MILESTONE_TITLE=v1 GH_TOKEN=goodtoken \
        run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"Not on project board"* ]]
}

@test "check pr-tracking-metadata warns non-blocking on a draft PR" {
    # What: a draft PR missing metadata warns but exits 0.
    # Why: metadata settles before a PR leaves draft (AG-GH-008).
    # From: Issue #1683 | PR #1858
    PR_DRAFT=true PR_NUMBER=12 REPO=wiki-mod/lancache-ng PR_LABELS_JSON='[]' \
        run bash "${CI_SH}" check pr-tracking-metadata
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"pr-tracking-metadata=warn-draft"* ]]
}

# What: fixture repo + a fake action-manifest resolver.
# Why: one owner for the harness; asserts contract not curl.
# From: Issue #1683 | PR #1858
_anv_setup() {
    local r="$1"
    mkdir -p "${r}/.github/workflows" "${r}/.github/actions"
    cat > "${r}/resolver" <<'RS'
#!/usr/bin/env bash
case "$4" in
  *deprecated*) printf 'OK\nname: x\nruns:\n  using: node16\n' ;;
  *notfound*)   printf 'NOTFOUND\n' ;;
  *infra*)      printf 'INFRA:403\n' ;;
  *)            printf 'OK\nname: x\nruns:\n  using: node24\n' ;;
esac
RS
    chmod +x "${r}/resolver"
}

# What: run the owner against a fixture via the fake resolver.
# Why: one call site for the shared invocation (AG-CODE-011).
# From: Issue #1683 | PR #1858
_anv_run() {
    CI_ACTION_MANIFEST_CMD="$1/resolver" run bash "${CI_SH}" check action-node-versions "$1"
}

@test "check action-node-versions passes current, fails deprecated runtimes" {
    # What: current pins pass; a dead runtime (local/external) fails.
    # Why: the #799 node-runtime invariant, plus no-manifest/skip.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvR"
    _anv_setup "${r}"
    mkdir -p "${r}/.github/actions/loc"
    printf 'name: L\nruns:\n  using: composite\n  steps: []\n' > "${r}/.github/actions/loc/action.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-ok\n      - uses: ./.github/actions/loc\n      - uses: ./.github/workflows/re.yml\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"
    [ "${status}" -eq 0 ] || { echo "${output}"; false; }
    [[ "${output}" == *"action-node-versions=clean"* ]]
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-deprecated\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"node16"* ]]
    printf 'name: L\nruns:\n  using: node12\n  steps: []\n' > "${r}/.github/actions/loc/action.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: ./.github/actions/loc\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"node12"* ]]
    printf 'jobs:\n  b:\n    steps:\n      - uses: ./.github/actions/missing\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"no action.yml"* ]]
}

@test "check action-node-versions fails an unresolvable pin, warns on infra" {
    # What: NOTFOUND is a broken pin (fail); infra hiccup warns.
    # Why: fail-closed on a bad pin vs cannot-check-now split.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvF"
    _anv_setup "${r}"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-notfound\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"broken pin"* ]]
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-infra\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -eq 0 ]; [[ "${output}" == *"infra hiccup"* ]]
}

@test "check action-node-versions enforces ref hygiene" {
    # What: literal repeat + cross-file drift fail; anchor/composite ok.
    # Why: one canonical ref per key; anchors don't load in composites.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvH"
    _anv_setup "${r}"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-ok\n      - uses: o/act@ref-ok\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"repeats third-party ref"* ]]
    rm "${r}/.github/workflows/ci.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-ok\n' > "${r}/.github/workflows/a.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@ref-two\n' > "${r}/.github/workflows/b.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"multiple refs"* ]]
    rm "${r}/.github/workflows/b.yml"
    printf 'jobs:\n  b:\n    steps:\n      - uses: &a o/act@ref-ok\n  c:\n    steps:\n      - uses: *a\n' > "${r}/.github/workflows/a.yml"
    _anv_run "${r}"; [ "${status}" -eq 0 ] || { echo "${output}"; false; }
    rm "${r}/.github/workflows/a.yml"
    mkdir -p "${r}/.github/actions/cmp"
    printf 'jobs:\n  b:\n    steps:\n      - uses: ./.github/actions/cmp\n' > "${r}/.github/workflows/ci.yml"
    printf 'runs:\n  using: composite\n  steps:\n    - uses: o/act@ref-ok\n    - uses: o/act@ref-ok\n' > "${r}/.github/actions/cmp/action.yml"
    _anv_run "${r}"; [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "check action-node-versions fails a description expression, allows prose" {
    # What: an expression in a composite description fails; prose ok.
    # Why: the manifest validator evaluates description bodies.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvD"
    _anv_setup "${r}"
    mkdir -p "${r}/.github/actions/x"
    printf 'jobs:\n  b:\n    steps:\n      - uses: ./.github/actions/x\n' > "${r}/.github/workflows/ci.yml"
    printf 'name: X\ndescription: >-\n  see %s here\nruns:\n  using: composite\n  steps: []\n' '${{ inputs.y }}' > "${r}/.github/actions/x/action.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"description: field contains"* ]]
    printf 'name: X\ndescription: plain prose\nruns:\n  using: composite\n  steps:\n    - run: echo %s\n      shell: bash\n' '${{ y }}' > "${r}/.github/actions/x/action.yml"
    _anv_run "${r}"; [ "${status}" -eq 0 ] || { echo "${output}"; false; }
}

@test "check action-node-versions aggregates failures, separates extraction" {
    # What: all bad pins reported; run: uses ignored; alias = extraction.
    # Why: one run surfaces every defect; parse gaps not mislabeled.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvA"
    _anv_setup "${r}"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/one@ref-deprecated\n      - uses: o/two@ref-deprecated\n      - run: |\n          echo "uses: o/three@ref-deprecated"\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]
    [[ "${output}" == *"o/one@ref-deprecated"* ]]; [[ "${output}" == *"o/two@ref-deprecated"* ]]; [[ "${output}" != *"o/three"* ]]
    printf 'jobs:\n  b:\n    steps:\n      - uses: *undefined\n' > "${r}/.github/workflows/ci.yml"
    _anv_run "${r}"; [ "${status}" -ne 0 ]; [[ "${output}" == *"unresolved YAML alias"* ]]
}

@test "check all diff-scopes its checks and gates PR checks on PR context" {
    # What: stub the dispatcher; record what check-all invokes.
    # Why: prove scope+gating without running 36 real checks.
    # From: Issue #1683
    local log="${BATS_TEST_TMPDIR}/checkall.calls"; : > "${log}"
    ci_cmd_check() { printf '%s|%s\n' "$1" "${2:-}" >> "${log}"; return 0; }
    CHANGED_FILES="" PR_NUMBER="" ci_cmd_check_all services/dns/Dockerfile
    grep -qx 'line-endings|services/dns/Dockerfile' "${log}"
    grep -qx 'action-node-versions|' "${log}"
    ! grep -q '^pr-title|' "${log}"
}

@test "check all runs PR-metadata checks when a PR number is present" {
    # What: with PR_NUMBER set, the PR checks are invoked.
    # Why: they have a PR to check only on a pull request (§60).
    # From: Issue #1683
    local cf="${BATS_TEST_TMPDIR}/checkall.cf"; printf 'services/dns/Dockerfile\n' > "${cf}"
    local log="${BATS_TEST_TMPDIR}/checkall.pr"; : > "${log}"
    ci_cmd_check() { printf '%s\n' "$1" >> "${log}"; return 0; }
    CHANGED_FILES="${cf}" PR_NUMBER=42 ci_cmd_check_all
    grep -qx 'pr-title' "${log}"
    grep -qx 'pr-tracking-metadata' "${log}"
}

@test "docs-only is true only when every changed path is docs" {
    # What: a docs-only change is a NOOP (§63).
    # Why: container jobs must not run on docs-only.
    # From: Issue #1683
    _ci_docs_only fixture-note.md docs/fixture-asset
    ! _ci_docs_only fixture-note.md fixture-src/code.rs
    ! _ci_docs_only
}

@test "check shellcheck noops without shell files and fails on findings" {
    # What: injected shellcheck; prove noop + fail.
    # Why: real shellcheck needs the toolchain image; hook it.
    # From: Issue #1683
    local cf="${BATS_TEST_TMPDIR}/sc.cf" doc="${BATS_TEST_TMPDIR}/note.md"
    : > "${doc}"
    printf '%s\n' "${doc}" > "${cf}"
    CHANGED_FILES="${cf}" run bash "${CI_SH}" check shellcheck
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"shellcheck=noop"* ]]
    local sh="${BATS_TEST_TMPDIR}/fixture.sh"; : > "${sh}"
    printf '%s\n' "${sh}" > "${cf}"
    CI_SHELLCHECK_CMD="$(_stub sc 'exit 1')" CHANGED_FILES="${cf}" run bash "${CI_SH}" check shellcheck
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0056"* ]]
}

@test "check actionlint passes clean and fails on findings" {
    # What: injected actionlint; prove pass/fail.
    # Why: real actionlint needs the toolchain image; hook it.
    # From: Issue #1683
    CI_ACTIONLINT_CMD="$(_stub al 'exit 0')" run bash "${CI_SH}" check actionlint
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"actionlint=clean"* ]]
    CI_ACTIONLINT_CMD="$(_stub al2 'exit 1')" run bash "${CI_SH}" check actionlint
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0057"* ]]
}

@test "check cargo-audit passes clean, fails on advisory and on warnings" {
    # What: injected auditor; prove the pass/fail policy.
    # Why: real cargo audit needs the toolchain image; hook it.
    # From: Issue #1683
    CI_CARGO_AUDIT_CMD="$(_stub aud 'exit 0')" run bash "${CI_SH}" check cargo-audit
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cargo-audit=clean"* ]]
    CI_CARGO_AUDIT_CMD="$(_stub aud2 'echo "error: vulnerability RUSTSEC-x"; exit 1')" run bash "${CI_SH}" check cargo-audit
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0055"* ]]
    CI_CARGO_AUDIT_CMD="$(_stub aud3 'echo "warning: yanked crate"; exit 0')" run bash "${CI_SH}" check cargo-audit
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0055"* ]]
}

@test "coverage skips a no-SOT service, passes the floor, fails below it" {
    # What: injected tarpaulin; prove the floor policy.
    # Why: real tarpaulin needs the toolchain image; hook it.
    # From: Issue #1683
    run bash "${CI_SH}" coverage watchdog
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"coverage=SKIP"* ]]
    CI_TARPAULIN_CMD="$(_stub tp 'echo 12.5')" run bash "${CI_SH}" coverage dns
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"coverage=12.5"* ]]
    CI_TARPAULIN_CMD="$(_stub tp2 'echo 20')" run bash "${CI_SH}" coverage ui
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-COVERAGE-0004"* ]]
    CI_TARPAULIN_CMD="$(_stub tp3 'echo 40')" run bash "${CI_SH}" coverage ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"coverage=40"* ]]
}

@test "check dockerfile-build-tools flags both image and hardcoded-tuning violations" {
    # What: rust Dockerfiles must consume the build-tools image and hardcode no tuning.
    # Why: AG-CI-008/AG-REL-002 (image) plus AG-CI-006 (jobs/lto/codegen from CI vars).
    # From: Issue #1683
    run bash "${CI_SH}" check dockerfile-build-tools
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dockerfile-build-tools=clean"* ]]
    local r="${BATS_TEST_TMPDIR}/dfrepo" s ctx n=0
    while IFS= read -r s; do
        [ "$(ci_service_field "$s" build_type)" = rust ] || continue
        ctx="$(ci_service_field "$s" context)"
        mkdir -p "${r}/${ctx}"
        case "${n}" in
            0) printf 'FROM alpine\nRUN cargo install sccache\n' > "${r}/${ctx}/Dockerfile" ;;
            1) printf 'ARG BUILD_TOOLS_IMAGE\nFROM ${BUILD_TOOLS_IMAGE}\nENV CARGO_BUILD_JOBS=4\n' > "${r}/${ctx}/Dockerfile" ;;
            *) printf 'ARG BUILD_TOOLS_IMAGE\nFROM ${BUILD_TOOLS_IMAGE}\nARG PROJECT_CARGO_LTO=\n' > "${r}/${ctx}/Dockerfile" ;;
        esac
        n=$((n + 1))
    done < <(ci_services)
    run bash "${CI_SH}" check dockerfile-build-tools "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0058"* ]]
    [[ "${output}" == *"CI-ERROR-CHECK-0060"* ]]
}

@test "check cargo-profile-tuning flags hardcoded [profile] lto/codegen-units" {
    # What: no Cargo.toml may set [profile] lto/codegen-units.
    # Why: they come from CARGO_PROFILE_RELEASE env (AG-CI-006).
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/cptrepo"
    mkdir -p "${r}/crate-a" "${r}/crate-b"
    printf '[package]\nname = "a"\n\n[profile.release]\n# no tuning here\n' > "${r}/crate-a/Cargo.toml"
    printf '[package]\nname = "b"\n\n[profile.release]\nlto = "thin"\ncodegen-units = 1\n' > "${r}/crate-b/Cargo.toml"
    git -C "${r}" init -q
    git -C "${r}" add -A
    run bash "${CI_SH}" check cargo-profile-tuning "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0059"* ]]
    [[ "${output}" == *"crate-b/Cargo.toml"* ]]
    printf '[package]\nname = "b"\n\n[profile.release]\n' > "${r}/crate-b/Cargo.toml"
    git -C "${r}" add -A
    run bash "${CI_SH}" check cargo-profile-tuning "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"cargo-profile-tuning=clean"* ]]
}

@test "check no-source-compiled-tools flags cargo install of a prebuilt SOT tool" {
    # What: no Dockerfile may cargo-install a tool the SOT ships prebuilt.
    # Why: INSTALL-DON'T-COMPILE; build-tools is the toolchain owner (AG-REL-002).
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/nsctrepo" pkg
    pkg="$(_ci_build_tools_packages | grep -E '^(sccache|cargo-audit|cargo-tarpaulin)$' | head -1)"
    [ -n "${pkg}" ]
    mkdir -p "${r}/svc-a" "${r}/svc-b"
    printf 'FROM alpine\nRUN cargo build --release --locked\n' > "${r}/svc-a/Dockerfile"
    printf 'FROM alpine\nRUN cargo install --locked %s\n' "${pkg}" > "${r}/svc-b/Dockerfile"
    git -C "${r}" init -q
    git -C "${r}" add -A
    run bash "${CI_SH}" check no-source-compiled-tools "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0061"* ]]
    [[ "${output}" == *"${pkg}"* ]]
    printf 'FROM alpine\nRUN cargo build --release --locked\n' > "${r}/svc-b/Dockerfile"
    git -C "${r}" add -A
    run bash "${CI_SH}" check no-source-compiled-tools "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no-source-compiled-tools=clean"* ]]
}

@test "stack-candidate reader emits service=index-digest and fails closed on a missing index" {
    # What: the production stack candidate is exact multi-arch index digests (§48).
    # Why: promote/validate consume exact digests, never moving service tags.
    # From: Issue #1683
    _ci_collect_accepted_digests() { printf 'linux/amd64=sha256:a\nlinux/arm64=sha256:b\n'; }
    _ci_reconcile_index() { printf 'sha256:idx-%s\n' "$1"; }
    run _ci_stack_candidate_ledger
    [ "${status}" -eq 0 ]
    local s
    for s in $(ci_services); do
        [[ "${output}" == *"${s}=sha256:idx-${s}"* ]]
    done
    _ci_reconcile_index() { printf '\n'; }
    run _ci_stack_candidate_ledger
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CANDIDATE-0001"* ]]
}

@test "emit-result produces an ACCEPTED record and fails closed on a missing digest" {
    # What: the single aggregator's input record for one service/platform (§26.1).
    # Why: state ACCEPTED with the exact GHCR digest, verified from the registry.
    # From: Issue #1683
    _ci_require_ghcr_auth() { return 0; }
    _ci_identity_for() { echo "id-$1"; }
    _ci_image_tag() { echo "reg/$1:$3"; }
    _ci_registry_digest() { echo "sha256:deadbeef"; }
    run ci_cmd_emit_result dns linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *'"service":"dns"'* ]]
    [[ "${output}" == *'"state":"ACCEPTED"'* ]]
    [[ "${output}" == *'"digest":"sha256:deadbeef"'* ]]
    _ci_registry_digest() { return 1; }
    run ci_cmd_emit_result dns linux/amd64
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-RESULT-0003"* ]]
}

@test "action-node-versions resolver: yaml fallback, transient retry, permanent stop" {
    # What: real curl path -- .yml->.yaml, 403 retries, 401 stops.
    # Why: fetch mechanics have no hook; a counted mock proves them.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/anvM" bin="${BATS_TEST_TMPDIR}/anvMbin" cnt="${BATS_TEST_TMPDIR}/anvMcnt"
    mkdir -p "${r}/.github/workflows" "${bin}"
    printf 'jobs:\n  b:\n    steps:\n      - uses: o/act@sha1\n' > "${r}/.github/workflows/ci.yml"
    cat > "${bin}/curl" <<'C1'
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "$@"; do [ "${prev}" = "-o" ] && out="${a}"; url="${a}"; prev="${a}"; done
case "${url}" in
  *action.yaml*) printf 'runs:\n  using: node24\n' > "${out}"; printf '200' ;;
  *) : > "${out}"; printf '404' ;;
esac
C1
    chmod +x "${bin}/curl"
    PATH="${bin}:${PATH}" CI_RETRY_BACKOFF_BASE_SECONDS=0 run bash "${CI_SH}" check action-node-versions "${r}"
    [ "${status}" -eq 0 ] || { echo "fallback: ${output}"; false; }
    echo 0 > "${cnt}"
    cat > "${bin}/curl" <<C2
#!/usr/bin/env bash
n=\$(cat "${cnt}"); n=\$((n+1)); echo "\$n" > "${cnt}"
out=""; prev=""
for a in "\$@"; do [ "\${prev}" = "-o" ] && out="\${a}"; prev="\${a}"; done
if [ "\$n" -lt 2 ]; then : > "\${out}"; printf '403'; else printf 'runs:\n  using: node24\n' > "\${out}"; printf '200'; fi
C2
    chmod +x "${bin}/curl"
    PATH="${bin}:${PATH}" CI_RETRY_BACKOFF_BASE_SECONDS=0 run bash "${CI_SH}" check action-node-versions "${r}"
    [ "${status}" -eq 0 ] || { echo "retry: ${output}"; false; }
    [ "$(cat "${cnt}")" -ge 2 ]
    echo 0 > "${cnt}"
    cat > "${bin}/curl" <<C3
#!/usr/bin/env bash
n=\$(cat "${cnt}"); echo "\$((n+1))" > "${cnt}"
out=""; prev=""
for a in "\$@"; do [ "\${prev}" = "-o" ] && out="\${a}"; prev="\${a}"; done
: > "\${out}"; printf '401'
C3
    chmod +x "${bin}/curl"
    PATH="${bin}:${PATH}" CI_RETRY_MAX_ATTEMPTS=4 CI_RETRY_BACKOFF_BASE_SECONDS=0 run bash "${CI_SH}" check action-node-versions "${r}"
    [ "${status}" -eq 0 ]; [[ "${output}" == *"infra hiccup"* ]]
    [ "$(cat "${cnt}")" -le 2 ]
}

@test "check governance-guards flags a stale TODO on a closed issue" {
    # What: ci.sh owns the governance scan; bats calls it.
    # Why: TODO on closed issue is stale, must fail loud.
    # From: Issue #1683
    printf '# TODO(#42): revisit once fixed\n' > "${BATS_TEST_TMPDIR}/stale.sh"
    CI_GOVERNANCE_ISSUE_STATE='42=closed' \
        run bash "${CI_SH}" check governance-guards "${BATS_TEST_TMPDIR}/stale.sh"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0018"* ]]
    CI_GOVERNANCE_ISSUE_STATE='42=open' \
        run bash "${CI_SH}" check governance-guards "${BATS_TEST_TMPDIR}/stale.sh"
    [ "${status}" -eq 0 ]
}

@test "check governance-guards requires an open Refs issue for partial-scope text" {
    # What: Partial-scope text needs open issue reference.
    # Why: Prevent merging known-incomplete changes.
    # From: Issue #1683
    GOVERNANCE_PR_BODY='This is a partial fix, TODO later.' \
        run bash "${CI_SH}" check governance-guards
    [ "${status}" -ne 0 ]
    GOVERNANCE_PR_BODY='This is a partial fix. Refs #7' CI_GOVERNANCE_ISSUE_STATE='7=open' \
        run bash "${CI_SH}" check governance-guards
    [ "${status}" -eq 0 ]
    GOVERNANCE_PR_BODY='No TODO items left, nothing deferred here.' \
        run bash "${CI_SH}" check governance-guards
    [ "${status}" -eq 0 ]
}

@test "check governance-guards flags a malformed PR-body upload" {
    # What: a body that is a literal @/tmp upload path, not text.
    # Why: an upload mistake must not pass as real PR body text.
    # From: Issue #1683 | PR #1858
    GOVERNANCE_PR_BODY='@/tmp/pr-body-1234.txt' \
        run bash "${CI_SH}" check governance-guards
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0018"* ]]
    [[ "${output}" == *"@/tmp"* ]]
}

@test "check naming-consistency requires every allowlist name as a real container_name" {
    # What: ci.sh owns cross-file name-consistency gate.
    # Why: socket-proxy denies unknown container names.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${r}/deploy/prod" "${r}/deploy/quickstart" "${r}/scripts/untracked"
    printf 'name: lancache-ng\nservices:\n  proxy:\n    container_name: lancache-proxy\n' \
        > "${r}/deploy/prod/docker-compose.yml"
    printf 'name: lancache-ng\nservices:\n  proxy:\n    container_name: lancache-proxy${LANCACHE_CONTAINER_SUFFIX:-}\n' \
        > "${r}/deploy/quickstart/docker-compose.yml"
    printf 'acl lancache_container path,url_dec -m reg ^/containers/(lancache-proxy)(/|$)\nacl lancache_lifecycle path,url_dec -m reg ^/containers/lancache-proxy/(start|stop|restart|wait)$\n' \
        > "${r}/scripts/untracked/docker-socket-proxy.sh"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -eq 0 ]
    printf 'name: lancache-ng\nservices:\n  proxy:\n    container_name: lancache-wrong\n' \
        > "${r}/deploy/prod/docker-compose.yml"
    run _ci_check_naming_consistency "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0019"* ]]
}

@test "check compose-healthchecks passes clean on the real repo" {
    # What: migrated from check-compose-healthchecks.sh.
    # Why: rewritten in ci.sh; real deploy/*/ must pass.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check compose-healthchecks
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"compose-healthchecks=clean"* ]]
}

@test "check compose-healthchecks fails a service with no healthcheck" {
    # What: a real, un-excluded service has no healthcheck.
    # Why: issue #1169: every service needs one.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/nohc/docker-compose.yml"
    mkdir -p "$(dirname "${f}")"
    printf 'services:\n  good:\n    image: x\n    healthcheck:\n      test: ["CMD", "true"]\n  bad:\n    image: y\n' \
        > "${f}"
    run bash "${CI_SH}" check compose-healthchecks "${f}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0021"* ]]
    [[ "${output}" == *"service 'bad' has no healthcheck"* ]]
}

@test "check compose-healthchecks honors the documented exclusion list" {
    # What: dhcp-probe is documented as exempt, not a fail.
    # Why: issue #1169's exclusion contract still applies.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/excl/deploy/prod/docker-compose.yml"
    mkdir -p "$(dirname "${f}")"
    printf 'services:\n  dhcp-probe:\n    image: x\n' > "${f}"
    run bash "${CI_SH}" check compose-healthchecks "${f}"
    [ "${status}" -eq 0 ]
}

@test "check compose-healthchecks fails closed with no compose files" {
    # What: a vacuous scan (no matched files) must not pass.
    # Why: mirrors the legacy script's anti-vacuous guard.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check compose-healthchecks "${BATS_TEST_TMPDIR}/nope/docker-compose.yml"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0020"* ]]
}

@test "check proxy-cache-env-doc-drift passes clean on the real repo" {
    # What: migrated from check-proxy-cache-env-doc-drift.
    # Why: rewritten in ci.sh; real config/docs must agree.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check proxy-cache-env-doc-drift
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"proxy-cache-env-doc-drift=clean"* ]]
}

@test "check proxy-cache-env-doc-drift fails a real default mismatch" {
    # What: proxy.env's value disagrees with its doc row.
    # Why: bug-hunt #1068: a copied default can go stale.
    # From: Issue #1683 | PR #1858
    local env="${BATS_TEST_TMPDIR}/proxy.env" doc="${BATS_TEST_TMPDIR}/arch.md"
    printf 'CACHE_MEM_MB=999\n' > "${env}"
    printf "| \`CACHE_MEM_MB\` | \`512\` | some description |\n" > "${doc}"
    run bash "${CI_SH}" check proxy-cache-env-doc-drift "${env}" "${doc}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0023"* ]]
    [[ "${output}" == *"proxy.env=999 vs doc=512"* ]]
}

@test "check proxy-cache-env-doc-drift ignores an undocumented CACHE_* var" {
    # What: a CACHE_* var with no matching doc row is fine.
    # Why: not every variable needs a table row.
    # From: Issue #1683 | PR #1858
    local env="${BATS_TEST_TMPDIR}/proxy2.env" doc="${BATS_TEST_TMPDIR}/arch2.md"
    printf 'CACHE_UNDOCUMENTED=1\n' > "${env}"
    printf '# no matching row here\n' > "${doc}"
    run bash "${CI_SH}" check proxy-cache-env-doc-drift "${env}" "${doc}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"scanned=1 checked=0"* ]]
}

@test "check dependabot-docker-base-consistency passes on the real repo" {
    # What: migrated from the legacy dependabot check.
    # Why: rewritten in ci.sh; the real group must agree.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check dependabot-docker-base-consistency
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dependabot-docker-base-consistency=clean"* ]]
}

@test "check dependabot-docker-base-consistency resolves a global ARG" {
    # What: FROM \${BASE} resolves via its pre-FROM ARG.
    # Why: AG-VAL-036: real ARG grammar, not a guess.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/argmatch"
    mkdir -p "${r}/.github" "${r}/services/a" "${r}/services/b"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directories:\n      - /services/a\n      - /services/b\n    schedule:\n      interval: weekly\n' \
        > "${r}/.github/dependabot.yml"
    printf "ARG BASE=alpine:3.24\nFROM \${BASE}\n" > "${r}/services/a/Dockerfile"
    printf 'FROM alpine:3.24\n' > "${r}/services/b/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"
    [ "${status}" -eq 0 ]
}

@test "check dependabot-docker-base-consistency resolves a bare SOT ARG with no default" {
    # What: Bare ARG ALPINE_IMAGE resolves from manifest.
    # Why: Bare ARG (no default) requires ci.sh build-args.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/barearg"
    mkdir -p "${r}/.github" "${r}/services/a" "${r}/services/b"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directories:\n      - /services/a\n      - /services/b\n    schedule:\n      interval: weekly\n' \
        > "${r}/.github/dependabot.yml"
    printf "ARG ALPINE_IMAGE\nFROM \${ALPINE_IMAGE}\n" > "${r}/services/a/Dockerfile"
    printf "ARG ALPINE_IMAGE\nFROM \${ALPINE_IMAGE}\n" > "${r}/services/b/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dependabot-docker-base-consistency=clean"* ]]
}

@test "check dependabot-docker-base-consistency resolves a stage alias" {
    # What: FROM builder resolves to its real origin image.
    # Why: the alias text is never the compared value.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/alias"
    mkdir -p "${r}/.github" "${r}/services/a" "${r}/services/b"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directories:\n      - /services/a\n      - /services/b\n    schedule:\n      interval: weekly\n' \
        > "${r}/.github/dependabot.yml"
    printf 'FROM alpine:3.24 AS builder\nRUN true\nFROM builder\n' > "${r}/services/a/Dockerfile"
    printf 'FROM alpine:3.24\n' > "${r}/services/b/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"
    [ "${status}" -eq 0 ]
}

@test "check dependabot-docker-base-consistency ignores a heredoc FROM" {
    # What: a FROM inside a RUN heredoc body is not real.
    # Why: only Docker instructions outside heredocs count.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/heredoc"
    mkdir -p "${r}/.github" "${r}/services/a" "${r}/services/b"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directories:\n      - /services/a\n      - /services/b\n    schedule:\n      interval: weekly\n' \
        > "${r}/.github/dependabot.yml"
    printf 'FROM alpine:3.24\nRUN <<EOT\nFROM should-be-ignored\nEOT\n' > "${r}/services/a/Dockerfile"
    printf 'FROM alpine:3.24\n' > "${r}/services/b/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"
    [ "${status}" -eq 0 ]
}

@test "check dependabot-docker-base-consistency fails on real drift" {
    # What: two grouped Dockerfiles, real different bases.
    # Why: this is the guard's one real, enforced invariant.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/drift"
    mkdir -p "${r}/.github" "${r}/services/a" "${r}/services/b"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directories:\n      - /services/a\n      - /services/b\n    schedule:\n      interval: weekly\n' \
        > "${r}/.github/dependabot.yml"
    printf 'FROM alpine:3.24\n' > "${r}/services/a/Dockerfile"
    printf 'FROM alpine:3.20\n' > "${r}/services/b/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0032"* ]]
    [[ "${output}" == *"diverges"* ]]
}

@test "check dependabot-docker-base-consistency distinguishes missing paths" {
    # What: a declared, parseable dir, missing Dockerfile.
    # Why: distinct from a block with zero directories.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/missingfile"
    mkdir -p "${r}/.github"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directory: /services/missing\n    schedule:\n      interval: weekly\n' \
        > "${r}/.github/dependabot.yml"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0030"* ]]
    local r2="${BATS_TEST_TMPDIR}/emptyblock"
    mkdir -p "${r2}/.github"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    schedule:\n      interval: weekly\n' \
        > "${r2}/.github/dependabot.yml"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r2}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0029"* ]]
}

@test "check dependabot-docker-base-consistency fails on unresolved ARG" {
    # What: a FROM \${VAR} with no matching global ARG.
    # Why: unresolved must fail closed, never a guess.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/unresolved"
    mkdir -p "${r}/.github" "${r}/services/a"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directory: /services/a\n    schedule:\n      interval: weekly\n' \
        > "${r}/.github/dependabot.yml"
    printf "FROM \${UNKNOWN_ARG}\n" > "${r}/services/a/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0031"* ]]
}

@test "check dependabot-docker-base-consistency fails with no dependabot.yml" {
    # What: a repo root with no .github/dependabot.yml.
    # Why: a missing input file must never silently pass.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0027"* ]]
}

@test "check dependabot-docker-base-consistency Dockerfile FROM parsing edges" {
    # What: only the last FROM counts; lowercase from; no-FROM fails.
    # Why: absorbs the legacy FROM-parsing coverage.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/ddb-from"; mkdir -p "${r}/.github" "${r}/services/a" "${r}/services/b"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directories:\n      - /services/a\n      - /services/b\n    schedule:\n      interval: weekly\n' > "${r}/.github/dependabot.yml"
    printf 'FROM golang:1 AS builder\nRUN true\nfrom alpine:3.24\n' > "${r}/services/a/Dockerfile"
    printf 'FROM alpine:3.24 AS final\n' > "${r}/services/b/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"; [ "${status}" -eq 0 ]
    printf 'RUN true\n' > "${r}/services/a/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"; [ "${status}" -ne 0 ]
}

@test "check dependabot-docker-base-consistency resolves an unbraced ARG token" {
    # What: FROM \$BASE (no braces) resolves via its ARG default.
    # Why: absorbs the legacy unbraced-ARG-substitution coverage.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/ddb-arg"; mkdir -p "${r}/.github" "${r}/services/a" "${r}/services/b"
    printf 'version: 2\nupdates:\n  - package-ecosystem: docker\n    directories:\n      - /services/a\n      - /services/b\n    schedule:\n      interval: weekly\n' > "${r}/.github/dependabot.yml"
    printf 'ARG BASE=alpine:3.24\nFROM $BASE\n' > "${r}/services/a/Dockerfile"
    printf 'FROM alpine:3.24\n' > "${r}/services/b/Dockerfile"
    run bash "${CI_SH}" check dependabot-docker-base-consistency "${r}"; [ "${status}" -eq 0 ]
}

# What: seeds every real WRITER_TEST_EVIDENCE pair.
# Why: mirrors the legacy script's own fixture builder.
# From: Issue #1683 | PR #1858
_idempotence_fixture() {
    local root="$1" at_test='@test'
    mkdir -p "${root}/tests/bats" "${root}/services/dns" "${root}/services/watchdog" \
        "${root}/services/ui/src/routes" "${root}/services/proxy" "${root}/services/dhcp-proxy" \
        "${root}/services/dns/nats-subscriber/src" "${root}/deploy/prod" "${root}/deploy/quickstart"
    printf '#!/usr/bin/env bash\n' > "${root}/setup.sh"
    mkdir -p "${root}/.github/scripts"
    cat > "${root}/.github/scripts/ci.bats" <<EOF
${at_test} "migrate_env_for_update converges a legacy .env and is stable on rerun" {
    true
}
EOF
    printf '#!/usr/bin/env bash\n' > "${root}/services/dns/entrypoint.sh"
    cat > "${root}/tests/bats/dns_config_snapshot_idempotence.bats" <<EOF
${at_test} "rollback repeats to the same known-good config" {
    true
}
EOF
    printf '#!/usr/bin/env bash\n' > "${root}/services/watchdog/watchdog.sh"
    cat > "${root}/tests/bats/watchdog_idempotence.bats" <<EOF
${at_test} "write_status converges across repeated writes" {
    true
}
EOF
    printf '// fixture\n' > "${root}/services/ui/src/kea_snapshots.rs"
    cat > "${root}/services/ui/src/routes/dhcp.rs" <<'EOF'
#[test]
fn kea_modify_repeat_rollback_converges() {
    assert!(true);
}
EOF
    cat > "${root}/services/dns/nats-subscriber/src/zone_snapshots.rs" <<'EOF'
#[test]
fn create_snapshot_repeat_writes_converge() {
    assert!(true);
}
EOF
    cat > "${root}/services/ui/src/routes/secondaries.rs" <<'EOF'
#[tokio::test]
async fn nats_conf_write_converges_across_repeated_writes() {
    assert!(true);
}
EOF
    printf '#!/usr/bin/env bash\n' > "${root}/services/proxy/entrypoint.sh"
    cat > "${root}/tests/bats/proxy_known_good_snapshot.bats" <<EOF
${at_test} "retention converges across repeated valid starts" {
    true
}
EOF
    printf '#!/usr/bin/env bash\n' > "${root}/services/dhcp-proxy/entrypoint.sh"
    cat > "${root}/tests/bats/dhcp_proxy_known_good_snapshot.bats" <<EOF
${at_test} "retention converges across repeated valid starts" {
    true
}
EOF
    printf 'services:\n  nats:\n    command: ["true"]\n' > "${root}/deploy/prod/docker-compose.yml"
    printf 'services:\n  nats:\n    command: ["true"]\n' > "${root}/deploy/quickstart/docker-compose.yml"
    cat > "${root}/tests/bats/nats_conf_entrypoint_idempotence.bats" <<EOF
${at_test} "nats entrypoint regenerates a converged nats.conf" {
    true
}
EOF
    cat > "${root}/services/ui/src/netdata_alarms.rs" <<'EOF'
#[test]
fn append_is_idempotent_for_the_same_unique_id() {
    assert!(true);
}
EOF
}

@test "check idempotence-test-coverage passes on the real repo" {
    # What: migrated from the legacy idempotence check.
    # Why: rewritten in ci.sh; writers must stay covered.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check idempotence-test-coverage
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"idempotence-test-coverage=clean"* ]]
}

@test "check idempotence-test-coverage passes a full seeded fixture" {
    # What: every real writer/evidence pair, freshly seeded.
    # Why: proves the shared fixture below is itself valid.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-ok"
    _idempotence_fixture "${r}"
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -eq 0 ]
}

@test "check idempotence-test-coverage fails a missing writer file" {
    # What: a known config-writer source no longer exists.
    # Why: distinct from a missing evidence file to fix.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-nowriter"
    _idempotence_fixture "${r}"
    rm "${r}/services/watchdog/watchdog.sh"
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no longer exists"* ]]
}

@test "check idempotence-test-coverage fails a missing evidence file" {
    # What: the writer exists but its evidence file is gone.
    # Why: no repeat-run proof left for that config-writer.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-noevidence"
    _idempotence_fixture "${r}"
    rm "${r}/tests/bats/watchdog_idempotence.bats"
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"evidence file"* ]]
    [[ "${output}" == *"missing"* ]]
}

@test "check idempotence-test-coverage rejects a commented-out bats test" {
    # What: a disabled test bats never actually runs.
    # Why: issue #732: must not silently satisfy the guard.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-commented" at_test='@test'
    _idempotence_fixture "${r}"
    cat > "${r}/tests/bats/watchdog_idempotence.bats" <<EOF
# ${at_test} "write_status converges across repeated writes" {
#     true
# }
EOF
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
}

@test "check idempotence-test-coverage rejects an #[ignore]d Rust test" {
    # What: a disqualified test cargo never actually runs.
    # Why: issue #732: must not silently satisfy the guard.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-ignored"
    _idempotence_fixture "${r}"
    cat > "${r}/services/ui/src/netdata_alarms.rs" <<'EOF'
#[test]
#[ignore]
fn append_is_idempotent_for_the_same_unique_id() {
    assert!(true);
}
EOF
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
}

@test "check idempotence-test-coverage rejects the NATS extra_marker evasion" {
    # What: a repeat-named test unrelated to nats_conf.
    # Why: secondaries.rs is its own evidence file here.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-extramarker"
    _idempotence_fixture "${r}"
    cat > "${r}/services/ui/src/routes/secondaries.rs" <<'EOF'
#[test]
fn generate_nats_password_is_high_entropy_and_never_repeats() {
    assert!(true);
}
EOF
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"secondaries.rs"* ]]
}

@test "check idempotence-test-coverage rejects an active bats test with no marker" {
    # What: an active @test whose name lacks the marker.
    # Why: distinct path from a commented-out test line.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-nomarker" at_test='@test'
    _idempotence_fixture "${r}"
    cat > "${r}/tests/bats/dns_config_snapshot_idempotence.bats" <<EOF
${at_test} "rollback validates a config once" {
    true
}
EOF
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no matching"* ]]
}

@test "check idempotence-test-coverage reports every missing pair, not just the first" {
    # What: two writers lose evidence in a single run.
    # Why: proves all violations surface, not only one.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-multi"
    _idempotence_fixture "${r}"
    rm "${r}/tests/bats/watchdog_idempotence.bats"
    rm "${r}/tests/bats/dns_config_snapshot_idempotence.bats"
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"watchdog.sh"* ]]
    [[ "${output}" == *"dns/entrypoint.sh"* ]]
}

@test "check idempotence-test-coverage rejects an #[ignore = \"reason\"]d Rust test" {
    # What: an #[ignore] with a reason string, not bare.
    # Why: the prefix match must catch this common form.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-ignorereason"
    _idempotence_fixture "${r}"
    cat > "${r}/services/ui/src/netdata_alarms.rs" <<'EOF'
#[test]
#[ignore = "flaky under CI load"]
fn append_is_idempotent_for_the_same_unique_id() {
    assert!(true);
}
EOF
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"netdata_alarms.rs"* ]]
}

@test "check idempotence-test-coverage rejects a commented-out Rust test block" {
    # What: a //-commented #[test]/fn pair is dead code.
    # Why: distinct path from the #[ignore] disqualifier.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/idem-rustcomment"
    _idempotence_fixture "${r}"
    cat > "${r}/services/ui/src/netdata_alarms.rs" <<'EOF'
// #[test]
// fn append_is_idempotent_for_the_same_unique_id() {
//     assert!(true);
// }
EOF
    run bash "${CI_SH}" check idempotence-test-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"netdata_alarms.rs"* ]]
}

# What: seed a minimal prebuilt-only prod/quickstart tree.
# Why: shared by the prebuilt-prod checks below.
# From: Issue #1683 | PR #1858
_prebuilt_fixture() {
    local root="$1"
    mkdir -p "${root}/deploy/prod" "${root}/deploy/quickstart"
    printf 'services:\n  proxy:\n    image: ghcr.io/example/proxy:sha-abc\n' > "${root}/deploy/prod/docker-compose.yml"
    printf 'services:\n  proxy:\n    image: ghcr.io/example/proxy:sha-abc\n' > "${root}/deploy/quickstart/docker-compose.yml"
    printf '# LanCache-NG\nRun: docker compose up -d\n' > "${root}/README.md"
    printf '#!/usr/bin/env bash\n' > "${root}/setup.sh"
}

@test "check prebuilt-prod passes a prebuilt-only tree" {
    # What: no build: and no --build anywhere user-facing.
    # Why: prod runs prebuilt first-party images (versioning).
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/prebuilt-ok"
    _prebuilt_fixture "${r}"
    run bash "${CI_SH}" check prebuilt-prod "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"prebuilt-prod=clean"* ]]
}

@test "check prebuilt-prod fails a build: directive in prod compose" {
    # What: a prod compose that would build locally.
    # Why: prod must consume prebuilt images, not build.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/prebuilt-build"
    _prebuilt_fixture "${r}"
    printf 'services:\n  proxy:\n    build: .\n' > "${r}/deploy/prod/docker-compose.yml"
    run bash "${CI_SH}" check prebuilt-prod "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"prebuilt"* ]]
}

@test "check prebuilt-prod fails a --build instruction in README" {
    # What: a user-facing doc telling users to build.
    # Why: install paths must not instruct local builds.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/prebuilt-readme"
    _prebuilt_fixture "${r}"
    printf '# LanCache-NG\nRun: docker compose up -d --build\n' > "${r}/README.md"
    run bash "${CI_SH}" check prebuilt-prod "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"prebuilt"* ]]
}

# What: seed a prod tree whose state derives from LANCACHE_STATE_DIR.
# Why: shared by the prod-state-wiring checks below.
# From: Issue #1683 | PR #1858
_prod_state_wiring_fixture() {
    local root="$1" k
    mkdir -p "${root}/deploy/prod" "${root}/docs"
    : > "${root}/deploy/prod/docker-compose.yml"
    : > "${root}/deploy/prod/.env"
    : > "${root}/docs/backup-restore.md"
    for k in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        printf '      - ${%s:-${LANCACHE_STATE_DIR:-/opt/lancache-ng}/x}:/y\n' "${k}" >> "${root}/deploy/prod/docker-compose.yml"
        printf '%s=\n' "${k}" >> "${root}/deploy/prod/.env"
        printf '%s documented\n' "${k}" >> "${root}/docs/backup-restore.md"
    done
}

@test "check prod-state-wiring passes a fully derived, documented tree" {
    # What: all five keys derive from LANCACHE_STATE_DIR + documented.
    # Why: AG-SETUP-001 one state root, manual upgrades documented.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/psw-ok"
    _prod_state_wiring_fixture "${r}"
    run bash "${CI_SH}" check prod-state-wiring "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"prod-state-wiring=clean"* ]]
}

@test "check prod-state-wiring fails a key not derived from LANCACHE_STATE_DIR" {
    # What: a per-service dir hardcoded off LANCACHE_STATE_DIR.
    # Why: breaks the single state-root contract (AG-SETUP-001).
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/psw-noderive"
    _prod_state_wiring_fixture "${r}"
    grep -v 'NATS_CONF_DIR' "${r}/deploy/prod/docker-compose.yml" > "${r}/deploy/prod/dc.tmp"
    printf '      - /hard/coded/nats-conf:/etc/nats\n' >> "${r}/deploy/prod/dc.tmp"
    mv "${r}/deploy/prod/dc.tmp" "${r}/deploy/prod/docker-compose.yml"
    run bash "${CI_SH}" check prod-state-wiring "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"NATS_CONF_DIR"* ]]
}

@test "check prod-state-wiring fails cleanly when an input file is missing" {
    # What: a missing compose/.env/doc yields a clear error.
    # Why: must not read as an undocumented-key violation.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/psw-missing"
    _prod_state_wiring_fixture "${r}"
    rm "${r}/docs/backup-restore.md"
    run bash "${CI_SH}" check prod-state-wiring "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"input missing"* ]]
}

@test "check compose-config passes when all SOT targets validate" {
    # What: every SOT file[:profile] target renders warning-free.
    # Why: prod/quickstart/secondary compose must be valid.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/cc-ok" m="${BATS_TEST_TMPDIR}/cc-ok.yml"
    mkdir -p "${r}/deploy/prod" "${r}/deploy/quickstart"
    : > "${r}/deploy/prod/docker-compose.yml"
    : > "${r}/deploy/quickstart/docker-compose.yml"
    printf 'validation:\n  compose_targets: deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml:ssl\n  compose_env_file_targets: deploy/quickstart/docker-compose.yml:ssl\n' > "${m}"
    CI_MANIFEST="${m}" CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'exit 0')" \
        run bash "${CI_SH}" check compose-config "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"compose-config=clean"* ]]
}

@test "check compose-config fails when a SOT target is invalid" {
    # What: one target renders a docker compose error.
    # Why: an invalid target must fail the whole check.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/cc-bad" m="${BATS_TEST_TMPDIR}/cc-bad.yml"
    mkdir -p "${r}/deploy/prod"
    : > "${r}/deploy/prod/docker-compose.yml"
    printf 'validation:\n  compose_targets: deploy/prod/docker-compose.yml:logging\n' > "${m}"
    CI_MANIFEST="${m}" CI_COMPOSE_CONFIG_CMD="$(_stub cfg '[ "$2" = logging ] && { echo boom; exit 1; }; exit 0')" \
        run bash "${CI_SH}" check compose-config "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"logging"* ]]
}

@test "check compose-config treats docker compose warnings as errors" {
    # What: a warning line in config output fails the check.
    # Why: warnings hide real drift; fail closed.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/cc-warn" m="${BATS_TEST_TMPDIR}/cc-warn.yml"
    mkdir -p "${r}/deploy/prod"
    : > "${r}/deploy/prod/docker-compose.yml"
    printf 'validation:\n  compose_targets: deploy/prod/docker-compose.yml\n' > "${m}"
    CI_MANIFEST="${m}" CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'echo "level=warning drift"; exit 0')" \
        run bash "${CI_SH}" check compose-config "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"config invalid"* ]]
}

@test "check compose-config fails when a SOT target file is missing" {
    # What: a listed target compose file does not exist.
    # Why: a renamed/removed deployment must surface here.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/cc-miss" m="${BATS_TEST_TMPDIR}/cc-miss.yml"
    mkdir -p "${r}/deploy/prod"
    printf 'validation:\n  compose_targets: deploy/prod/docker-compose.yml\n' > "${m}"
    CI_MANIFEST="${m}" CI_COMPOSE_CONFIG_CMD="$(_stub cfg 'exit 0')" \
        run bash "${CI_SH}" check compose-config "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"compose target missing"* ]]
}

@test "check compose-config fails when the SOT lists no targets" {
    # What: the SOT has no compose_targets entry at all.
    # Why: fail closed rather than validate nothing silently.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/cc-nosot" m="${BATS_TEST_TMPDIR}/cc-nosot.yml"
    printf 'validation:\n  dns_test_domains: [x]\n' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" check compose-config "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no compose_targets"* ]]
}

# What: seed a tree whose shared configs write atomically.
# Why: shared by the nats-atomic-write checks below.
# From: Issue #1683 | PR #1858
_nats_atomic_fixture() {
    local root="$1" cf
    mkdir -p "${root}/deploy/prod" "${root}/deploy/quickstart" \
        "${root}/services/dns" "${root}/services/ui/src/routes"
    for cf in deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml; do
        cat > "${root}/${cf}" <<'EOF'
        tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"
        chown 10001:10001 "$$tmp_nats_conf"
        mv "$$tmp_nats_conf" /etc/nats/nats.conf
EOF
    done
    cat > "${root}/services/ui/src/routes/secondaries.rs" <<'EOF'
fn write_nats_conf_atomically() {}
fs::rename(&tmp_path, target)
EOF
    cat > "${root}/services/dns/entrypoint.sh" <<'EOF'
render_template_atomic
mktemp "${target_dir}/.${target_name}.tmp.XXXXXX"
EOF
    cat > "${root}/setup.sh" <<'EOF'
write_generated_runtime_file "${secondary_dir}/docker-compose.yml"
write_env_file "${secondary_dir}/.env"
EOF
}

@test "check nats-atomic-write passes a fully atomic tree" {
    # What: compose/rust/entrypoint/setup all write atomically.
    # Why: shared config must never be torn on write.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/naw-ok"
    _nats_atomic_fixture "${r}"
    run bash "${CI_SH}" check nats-atomic-write "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"nats-atomic-write=clean"* ]]
}

@test "check nats-atomic-write fails a non-atomic nats.conf replace" {
    # What: compose overwrites nats.conf without temp+mv.
    # Why: a torn config can start a broken shared stack.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/naw-bad"
    _nats_atomic_fixture "${r}"
    printf 'tmp_nats_conf="$(mktemp /etc/nats/.nats.conf.XXXXXX)"\n' > "${r}/deploy/prod/docker-compose.yml"
    run bash "${CI_SH}" check nats-atomic-write "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"atomically replace nats.conf"* ]]
}

# What: seed a deny-by-default docker-socket-proxy tree.
# Why: shared by the docker-socket-proxy checks below.
# From: Issue #1683 | PR #1858
_socket_proxy_fixture() {
    local root="$1" cf
    mkdir -p "${root}/deploy/prod" "${root}/deploy/quickstart" "${root}/scripts/untracked"
    for cf in deploy/prod/docker-compose.yml deploy/quickstart/docker-compose.yml; do
        printf '      - scripts/untracked/docker-socket-proxy.sh:/usr/local/bin/lancache-docker-socket-proxy.sh:ro\n' > "${root}/${cf}"
    done
    cat > "${root}/scripts/untracked/docker-socket-proxy.sh" <<'EOF'
acl safe_service_restart x
acl safe_dhcp_action x
acl safe_probe_action x
acl safe_netdata_restart x
lancache-netdata/restart
acl lancache_container x
lancache-dns-standard|lancache-dns-ssl
lancache-proxy|lancache-dns-standard|lancache-dns-ssl|lancache-nats)/restart
lancache-dhcp|lancache-dhcp-proxy)/(start|stop)
lancache-dhcp-probe/(start|stop|wait)
http-request deny if docker_container_path !lancache_container
http-request deny
EOF
}

@test "check docker-socket-proxy passes a deny-by-default allowlist" {
    # What: every required allowlist rule present, no broad rule.
    # Why: the socket proxy must stay deny-by-default.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-ok"
    _socket_proxy_fixture "${r}"
    run bash "${CI_SH}" check docker-socket-proxy "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"docker-socket-proxy=clean"* ]]
}

@test "check docker-socket-proxy fails when Docker exec is enabled" {
    # What: a compose re-enables the banned EXEC endpoint.
    # Why: exec re-exposes arbitrary command execution.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-exec"
    _socket_proxy_fixture "${r}"
    printf '        EXEC: "1"\n' >> "${r}/deploy/prod/docker-compose.yml"
    run bash "${CI_SH}" check docker-socket-proxy "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"exec is banned"* ]]
}

@test "check docker-socket-proxy fails a forbidden broad container rule" {
    # What: a broad create/json rule re-enters the allowlist.
    # Why: generic container APIs must stay denied.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dsp-broad"
    _socket_proxy_fixture "${r}"
    printf '/containers/json\n' >> "${r}/scripts/untracked/docker-socket-proxy.sh"
    run bash "${CI_SH}" check docker-socket-proxy "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"forbidden broad rule"* ]]
}

# What: seed a quickstart tree with required env keys set.
# Why: shared by the quickstart-required-env checks below.
# From: Issue #1683 | PR #1858
_qs_required_env_fixture() {
    local root="$1"
    mkdir -p "${root}/deploy/quickstart"
    printf 'services:\n  x:\n    environment:\n      A: ${A:?set A}\n      B: ${B:?set B}\n' > "${root}/deploy/quickstart/docker-compose.yml"
    printf 'A=1\nB=2\n' > "${root}/deploy/quickstart/.env"
}

@test "check quickstart-required-env passes when all required keys are set" {
    # What: every required ${VAR:?} key is non-empty in .env.
    # Why: a required-but-unset key breaks compose at start.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/qre-ok"
    _qs_required_env_fixture "${r}"
    run bash "${CI_SH}" check quickstart-required-env "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"quickstart-required-env=clean"* ]]
}

@test "check quickstart-required-env fails when a required key is unset" {
    # What: a required ${VAR:?} key is missing from .env.
    # Why: quickstart would fail at compose interpolation.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/qre-bad"
    _qs_required_env_fixture "${r}"
    printf 'A=1\n' > "${r}/deploy/quickstart/.env"
    run bash "${CI_SH}" check quickstart-required-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"define non-empty B"* ]]
}

# What: seed a dhcp-proxy tree that meets the env/PXE contract.
# Why: shared by the dhcp-proxy-env checks below.
# From: Issue #1683 | PR #1858
_dhcp_proxy_env_fixture() {
    local root="$1" k
    mkdir -p "${root}/deploy/prod" "${root}/deploy/quickstart" \
        "${root}/config/prod" "${root}/services/dhcp-proxy"
    cat > "${root}/deploy/prod/docker-compose.yml" <<'EOF'
services:
  dhcp-proxy:
    image: x
    env_file:
      - ../../config/prod/dhcp-proxy.env
EOF
    : > "${root}/config/prod/dhcp-proxy.env"
    : > "${root}/deploy/quickstart/.env"
    for k in DHCP_PROXY_INTERFACE DHCP_PROXY_ROUTER DHCP_NTP_SERVERS DHCP_PROXY_DOMAIN \
        DHCP_PROXY_BOOT_FILENAME DHCP_PROXY_BOOT_SERVER DHCP_PROXY_CUSTOM_OPTIONS \
        DHCP_PROXY_PXE_BOOT_SERVER DHCP_PROXY_PXE_BOOT_FILENAME_BIOS DHCP_PROXY_PXE_BOOT_FILENAME_UEFI; do
        printf '%s=\n' "${k}" >> "${root}/config/prod/dhcp-proxy.env"
        printf '%s=\n' "${k}" >> "${root}/deploy/quickstart/.env"
    done
    cat > "${root}/deploy/quickstart/docker-compose.yml" <<'EOF'
        - DHCP_PROXY_INTERFACE=${DHCP_PROXY_INTERFACE:-}
        - DHCP_PROXY_CUSTOM_OPTIONS=${DHCP_PROXY_CUSTOM_OPTIONS:-}
        - DHCP_PROXY_PXE_BOOT_SERVER=${DHCP_PROXY_PXE_BOOT_SERVER:-}
        - DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=${DHCP_PROXY_PXE_BOOT_FILENAME_BIOS:-}
        - DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=${DHCP_PROXY_PXE_BOOT_FILENAME_UEFI:-}
EOF
    cat > "${root}/services/dhcp-proxy/entrypoint.sh" <<'EOF'
_dhcp_proxy_render_optional_directives() { :; }
_dhcp_proxy_render_optional_directives /etc/dnsmasq.conf
EOF
    : > "${root}/services/dhcp-proxy/dnsmasq.conf.template"
}

@test "check dhcp-proxy-env passes a compliant env/PXE tree" {
    # What: env_file used, all optional/PXE keys present + passed.
    # Why: the dnsmasq relay/proxy surface must stay intact.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-ok"
    _dhcp_proxy_env_fixture "${r}"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dhcp-proxy-env=clean"* ]]
}

@test "check dhcp-proxy-env fails a missing optional key" {
    # What: an optional dnsmasq key is absent from an env file.
    # Why: the whole optional surface must be declared.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-key"
    _dhcp_proxy_env_fixture "${r}"
    grep -v 'DHCP_PROXY_ROUTER' "${r}/config/prod/dhcp-proxy.env" > "${r}/config/prod/dhcp-proxy.env.tmp"
    mv "${r}/config/prod/dhcp-proxy.env.tmp" "${r}/config/prod/dhcp-proxy.env"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"DHCP_PROXY_ROUTER"* ]]
}

@test "check dhcp-proxy-env fails compose environment interpolation" {
    # What: prod dhcp-proxy uses environment instead of env_file.
    # Why: env_file is the prod contract; loses setup-managed keys.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-env"
    _dhcp_proxy_env_fixture "${r}"
    cat > "${r}/deploy/prod/docker-compose.yml" <<'EOF'
services:
  dhcp-proxy:
    image: x
    environment:
      - DHCP_SUBNET_START=${DHCP_SUBNET_START}
EOF
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"dhcp-proxy"* ]]
}

@test "check dhcp-proxy-env fails cleanly when an input file is missing" {
    # What: a missing compose/env/entrypoint yields a clear error.
    # Why: must not read as a dhcp-proxy contract violation.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/dpe-miss"
    _dhcp_proxy_env_fixture "${r}"
    rm "${r}/services/dhcp-proxy/dnsmasq.conf.template"
    run bash "${CI_SH}" check dhcp-proxy-env "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"input missing"* ]]
}

@test "check vex-drift passes valid non-empty OpenVEX" {
    # What: generate-vex.sh emits parseable JSON with statements.
    # Why: the generator smoke test's core success path.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/vex-ok"
    mkdir -p "${r}"
    printf 'ignore:\n  - id: CVE-1\n' > "${r}/.trivyignore.yaml"
    CI_VEX_GENERATE_CMD="$(_stub vg 'printf "{\"statements\":[{\"x\":1}]}"')" \
        run bash "${CI_SH}" check vex-drift "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"vex-drift=clean"* ]]
}

@test "check vex-drift fails invalid JSON" {
    # What: generate-vex.sh emits non-JSON output.
    # Why: a broken generator must fail closed.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/vex-bad"
    mkdir -p "${r}"
    printf 'ignore:\n  - id: CVE-1\n' > "${r}/.trivyignore.yaml"
    CI_VEX_GENERATE_CMD="$(_stub vg 'printf "not json"')" \
        run bash "${CI_SH}" check vex-drift "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"invalid JSON"* ]]
}

@test "check vex-drift fails entries with zero statements" {
    # What: real ignore entries but an empty statement list.
    # Why: silently-empty output is broken, valid JSON or not.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/vex-empty"
    mkdir -p "${r}"
    printf 'ignore:\n  - id: CVE-1\n' > "${r}/.trivyignore.yaml"
    CI_VEX_GENERATE_CMD="$(_stub vg 'printf "{\"statements\":[]}"')" \
        run bash "${CI_SH}" check vex-drift "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"0 VEX statements"* ]]
}

# What: Write a SOT with a netdata curl-pin policy block.
# Why: The check reads version/threshold/until/cves from SOT.
# From: Issue #1304 | PR #1858
_netdata_sot() {
    local m="${BATS_TEST_TMPDIR}/netdata-manifest.yml"
    cat > "${m}" <<EOF
external_versions:
  netdata:
    version: v2.10.4
    curl_safe_threshold: 8.21.0
    curl_accepted_until: 2030-12-31
    curl_tracked_cves: [CVE-2026-12064, CVE-2026-9545]
EOF
    printf '%s\n' "${m}"
}

# What: Stub the bundled-packages fetch to a fixed curl tag.
# Why: Deterministic offline coverage without GitHub.
# From: Issue #1304 | PR #1858
_netdata_fetch() {
    _stub nf "printf 'PACKAGES=(\"CURL\")\nCURL_VERSION=\"curl-${1}\"\n'"
}

@test "check netdata-curl-pin warns (non-blocking) below threshold before deadline" {
    # What: curl 8.17.0 < 8.21.0, today before ACCEPTED_UNTIL.
    # Why: known time-boxed acceptance must warn, not block.
    # From: Issue #1304 | PR #1858
    CI_MANIFEST="$(_netdata_sot)" CI_NETDATA_FETCH_CMD="$(_netdata_fetch 8_17_0)" \
        CI_NETDATA_TODAY="2026-08-01" run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"netdata-curl-pin=warn"* ]]
    [[ "${output}" == *"CVE-2026-12064"* ]]
    [[ "${output}" == *"CVE-2026-9545"* ]]
}

@test "check netdata-curl-pin fails (blocking) below threshold after deadline" {
    # What: same vulnerable pin, today past ACCEPTED_UNTIL.
    # Why: the grace period escalates to a hard failure.
    # From: Issue #1304 | PR #1858
    CI_MANIFEST="$(_netdata_sot)" CI_NETDATA_FETCH_CMD="$(_netdata_fetch 8_17_0)" \
        CI_NETDATA_TODAY="2031-01-01" run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"grace period"* ]]
    [[ "${output}" == *"passed"* ]]
    [[ "${output}" == *"CVE-2026-12064"* ]]
}

@test "check netdata-curl-pin warns exactly on the deadline (inclusive)" {
    # What: today equals ACCEPTED_UNTIL exactly.
    # Why: the deadline day itself is still non-blocking.
    # From: Issue #1304 | PR #1858
    CI_MANIFEST="$(_netdata_sot)" CI_NETDATA_FETCH_CMD="$(_netdata_fetch 8_17_0)" \
        CI_NETDATA_TODAY="2030-12-31" run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"netdata-curl-pin=warn"* ]]
}

@test "check netdata-curl-pin passes clean exactly at threshold" {
    # What: curl 8.21.0 == threshold, any date.
    # Why: at or above the fixed version is not affected.
    # From: Issue #1304 | PR #1858
    CI_MANIFEST="$(_netdata_sot)" CI_NETDATA_FETCH_CMD="$(_netdata_fetch 8_21_0)" \
        CI_NETDATA_TODAY="2027-01-01" run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"netdata-curl-pin=clean"* ]]
    [[ "${output}" != *"warn"* ]]
}

@test "check netdata-curl-pin passes clean well above threshold, differing segments" {
    # What: curl 9.0 vs 8.21.0 (fewer segments) compares right.
    # Why: sort -V must order differing segment counts correctly.
    # From: Issue #1304 | PR #1858
    CI_MANIFEST="$(_netdata_sot)" CI_NETDATA_FETCH_CMD="$(_netdata_fetch 9_0)" \
        run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"netdata-curl-pin=clean"* ]]
}

@test "check netdata-curl-pin fails closed on unparseable fetch content" {
    # What: fetched content has no CURL_VERSION line.
    # Why: a broken parse must fail, never pass silently.
    # From: Issue #1304 | PR #1858
    CI_MANIFEST="$(_netdata_sot)" CI_NETDATA_FETCH_CMD="$(_stub nf 'printf "no curl line here\n"')" \
        run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"no parseable CURL_VERSION"* ]]
}

@test "check netdata-curl-pin returns 2 when SOT netdata policy is missing" {
    # What: manifest lacks external_versions.netdata fields.
    # Why: a missing policy is a config error, not clean.
    # From: Issue #1304 | PR #1858
    local m="${BATS_TEST_TMPDIR}/empty-manifest.yml"
    printf 'external_versions:\n  dhclient:\n    version: x\n' > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"missing version/curl_safe_threshold"* ]]
}

@test "check netdata-curl-pin skips (non-blocking) on transient network failure" {
    # What: fetch exits 6 (resolve/connect), not a 404.
    # Why: transient infra must not block merges (GOAL section 4).
    # From: Issue #1304 | PR #1858
    CI_MANIFEST="$(_netdata_sot)" CI_NETDATA_FETCH_CMD="$(_stub nf 'exit 6')" \
        run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"netdata-curl-pin=skip"* ]]
    [[ "${output}" == *"reason=network"* ]]
}

@test "check netdata-curl-pin fails on a real upstream 404 (curl exit 22)" {
    # What: exit 22 means the netdata tag is missing upstream.
    # Why: a wrong pinned version is a real, blocking config error.
    # From: Issue #1304 | PR #1858
    CI_MANIFEST="$(_netdata_sot)" CI_NETDATA_FETCH_CMD="$(_stub nf 'exit 22')" \
        run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"missing upstream"* ]]
}

@test "check netdata-curl-pin runs against the real SOT netdata version" {
    # What: default SOT + a still-affected curl tag warns.
    # Why: proves the real external_versions.netdata pin parses.
    # From: Issue #1304 | PR #1858
    CI_NETDATA_FETCH_CMD="$(_netdata_fetch 8_20_0)" CI_NETDATA_TODAY="2026-08-01" \
        run bash "${CI_SH}" check netdata-curl-pin
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"netdata-curl-pin=warn"* ]]
}

# What: seed a setup.sh/dhcp tree meeting the keys+Kea contract.
# Why: shared by the setup-keys-kea checks below.
# From: Issue #1683 | PR #1858
_setup_keys_kea_fixture() {
    local root="$1" k
    mkdir -p "${root}/deploy/quickstart" "${root}/deploy/prod" "${root}/services/dhcp"
    : > "${root}/deploy/quickstart/.env"
    : > "${root}/deploy/prod/.env"
    {
        for k in DDNS_TSIG_KEY KEA_CTRL_TOKEN LANCACHE_IMAGE_TAG NATS_DNS_REPLICA_PASSWORD \
            NATS_DNS_REPLICA_USER NATS_DNS_WRITER_PASSWORD NATS_DNS_WRITER_USER \
            NATS_CALLOUT_PASSWORD NATS_CALLOUT_USER NATS_SYS_PASSWORD NATS_SYS_USER \
            NATS_UI_PASSWORD NATS_UI_USER PDNS_API_KEY SECONDARY_REGISTRATION_TOKEN; do
            printf '# %s\n' "${k}"
        done
        printf 'run_kea_dhcp_activation_preflight() { :; }\n'
        printf 'run_kea_dhcp_activation_preflight "$INSTALL_DIR/.env"\n'
        printf 'nmap --script broadcast-dhcp-discover --script-args broadcast-dhcp-discover.timeout=5\n'
    } > "${root}/setup.sh"
    printf 'RUN apk add nmap\n' > "${root}/services/dhcp/Dockerfile"
    printf 'nmap|/usr/bin/nmap|/bin/nmap)\n' > "${root}/services/dhcp/entrypoint.sh"
}

@test "check setup-keys-kea passes a compliant tree" {
    # What: all required keys + Kea preflight + nmap present.
    # Why: first-time setup depends on this whole surface.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/skk-ok"
    _setup_keys_kea_fixture "${r}"
    run bash "${CI_SH}" check setup-keys-kea "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"setup-keys-kea=clean"* ]]
}

@test "check setup-keys-kea fails a missing required key" {
    # What: a required runtime key is absent from setup.sh.
    # Why: setup must generate/migrate every runtime key.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/skk-key"
    _setup_keys_kea_fixture "${r}"
    grep -v 'PDNS_API_KEY' "${r}/setup.sh" > "${r}/setup.sh.tmp"
    mv "${r}/setup.sh.tmp" "${r}/setup.sh"
    run bash "${CI_SH}" check setup-keys-kea "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"PDNS_API_KEY"* ]]
}

@test "check setup-keys-kea fails a deprecated NATS token key" {
    # What: an env template reintroduces NATS_TOKEN.
    # Why: role credentials replaced the deprecated token keys.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/skk-nats"
    _setup_keys_kea_fixture "${r}"
    printf 'NATS_TOKEN=x\n' > "${r}/deploy/quickstart/.env"
    run bash "${CI_SH}" check setup-keys-kea "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"deprecated NATS token"* ]]
}

@test "migrate_env_for_update repairs every empty required key" {
    # What: each SOT required-repair key is non-empty after update.
    # Why: an empty required key breaks the stack (AG-OP-007).
    # From: Issue #1683 | PR #1858
    local repo_root keys key d ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    keys="$(grep -E '^  setup_required_repairs:' "${repo_root}/.github/yaml/build-manifest.yml" | sed 's/^[^:]*:[[:space:]]*//')"
    [ -n "${keys}" ]
    _load_setup_update_helpers "${repo_root}"
    for key in ${keys}; do
        [ "${key}" = "LANCACHE_IMAGE_TAG" ] && continue  # tag derives from git/VERSION context, no static default
        d="${BATS_TEST_TMPDIR}/req-${key}"
        mkdir -p "${d}"
        ef="${d}/.env"
        _write_converged_env_fixture "${ef}"
        awk -F= -v k="${key}" '$1==k{print k"=";next}{print}' "${ef}" > "${ef}.t"
        mv "${ef}.t" "${ef}"
        migrate_env_for_update "${d}" >/dev/null 2>&1 || { echo "migrate failed for ${key}"; return 1; }
        grep -Eq "^${key}=..*" "${ef}" || { echo "required key ${key} not repaired"; return 1; }
    done
}

@test "migrate_env_for_update derives CACHE_MAX_SIZE from CACHE_MAX_GB" {
    # What: an empty CACHE_MAX_SIZE is rebuilt from CACHE_MAX_GB.
    # Why: repair must reuse the operator's size, not a default.
    # From: Issue #1683 | PR #1858
    local repo_root ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ef="${BATS_TEST_TMPDIR}/cms/.env"
    mkdir -p "${BATS_TEST_TMPDIR}/cms"
    _load_setup_update_helpers "${repo_root}"
    _write_converged_env_fixture "${ef}"
    awk -F= '$1=="CACHE_MAX_GB"{print "CACHE_MAX_GB=77";next} $1=="CACHE_MAX_SIZE"{print "CACHE_MAX_SIZE=";next} {print}' "${ef}" > "${ef}.t"
    mv "${ef}.t" "${ef}"
    run migrate_env_for_update "$(dirname "${ef}")"; [ "${status}" -eq 0 ]
    grep -Eq '^CACHE_MAX_SIZE=.*77' "${ef}"
}

@test "get_env_assignment_value_raw_nonempty preserves the raw assignment" {
    # What: the raw (unparsed) value of a key is returned intact.
    # Why: templated/quoted overrides must not be flattened.
    # From: Issue #1683 | PR #1858
    local repo_root ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ef="${BATS_TEST_TMPDIR}/raw.env"
    _load_setup_update_helpers "${repo_root}"
    printf 'FOO=${BAR}/baz\n' > "${ef}"
    run get_env_assignment_value_raw_nonempty FOO "${ef}"
    [ "${status}" -eq 0 ]
    [ "${output}" = '${BAR}/baz' ]
}

@test "validate_ui_session_ttl_seconds rejects invalid and accepts valid" {
    # What: TTL must be a positive integer within the max bound.
    # Why: a bad TTL would be written or reused unchecked.
    # From: Issue #1683 | PR #1858
    local repo_root
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_update_helpers "${repo_root}"
    run validate_ui_session_ttl_seconds abc src
    [[ "${output}" == *"unsigned integer"* ]]
    run validate_ui_session_ttl_seconds 0 src
    [[ "${output}" == *"greater than zero"* ]]
    run validate_ui_session_ttl_seconds 86400 src
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "set_env_key collapses duplicate assignments to one" {
    # What: a key present twice ends up assigned exactly once.
    # Why: repair must not rewrite every duplicate line.
    # From: Issue #1683 | PR #1858
    local repo_root ef
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    ef="${BATS_TEST_TMPDIR}/dup.env"
    _load_setup_update_helpers "${repo_root}"
    printf 'FOO=1\nFOO=2\nBAR=3\n' > "${ef}"
    set_env_key FOO 9 "${ef}"
    [ "$(grep -c '^FOO=' "${ef}")" -eq 1 ]
    grep -qx 'FOO=9' "${ef}"
    grep -qx 'BAR=3' "${ef}"
}

# What: builds a fixture doc + quickstart web_log copy.
# Why: shared by the logging-matrix tests below.
# From: Issue #1683 | PR #1858
_logging_matrix_fixture() {
    local root="$1" rows="${2:-svc-a}"
    mkdir -p "${root}/docs" "${root}/services/syslog" "${root}/deploy/quickstart"
    {
        printf '**Logging matrix** (test):\n\n'
        printf '| Service | Logging path | Notes |\n'
        printf '| --- | --- | --- |\n'
        local n
        for n in ${rows}; do
            printf '| %s | Via x | note |\n' "${n}"
        done
    } > "${root}/docs/architecture-ng.md"
    printf 'header\njobs:\n  - name: real\n    path: /x\n' > "${root}/services/syslog/netdata-web_log.conf"
    cat > "${root}/deploy/quickstart/docker-compose.yml" <<'EOF'
services:
  netdata:
    command: |
      cat > /etc/netdata/go.d/web_log.conf <<'CONF'
        jobs:
          - name: real
            path: /x
        CONF
EOF
}

@test "check logging-matrix passes clean on the real repo" {
    # What: migrated from check-logging-matrix.sh.
    # Why: rewritten in ci.sh; real docs/compose must agree.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check logging-matrix
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"logging-matrix=clean"* ]]
}

@test "_ci_logging_matrix_canonical is a single deterministic awk pass" {
    # What: the flake this exists to prevent, at scale.
    # Why: stress-tested at 80 rows, 30 repeated runs.
    # From: Issue #1683 | PR #1858
    local doc="${BATS_TEST_TMPDIR}/big.md" i first cur
    {
        printf '**Logging matrix** (test):\n\n'
        printf '| Service | Logging path | Notes |\n'
        printf '| --- | --- | --- |\n'
        for i in $(seq 1 80); do
            printf '| svc-%d (label) | Via x | note %d |\n' "${i}" "${i}"
        done
    } > "${doc}"
    first="$(_ci_logging_matrix_canonical "${doc}")"
    [[ "${first}" == *"##ROWS## 80 80"* ]]
    for i in $(seq 1 30); do
        cur="$(_ci_logging_matrix_canonical "${doc}")"
        [ "${cur}" = "${first}" ]
    done
}

@test "check logging-matrix fails a service with no matrix row" {
    # What: a real Compose service, absent from the matrix.
    # Why: issue #633: every service needs a declared row.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-extra"
    _logging_matrix_fixture "${r}" "svc-a"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svc 'printf "svc-a\nsvc-b\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0038"* ]]
    [[ "${output}" == *"service 'svc-b' has no logging-matrix row"* ]]
}

@test "check logging-matrix fails a stale row with no real service" {
    # What: a matrix row for a service no longer real.
    # Why: a renamed service must not leave a stale row.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-stale"
    _logging_matrix_fixture "${r}" "svc-a svc-gone"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svc 'printf "svc-a\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"row 'svc-gone' is not a real Compose service"* ]]
}

@test "check logging-matrix fails a collapsed/duplicate row" {
    # What: two rows whose names normalize to the same one.
    # Why: a genuine row-parsing defense, distinct from #1.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-dup"
    mkdir -p "${r}/docs"
    printf '**Logging matrix** (test):\n\n| Service | Logging path | Notes |\n| --- | --- | --- |\n| svc-a (nginx) | Via x | note |\n| svc-a (alias) | Via x | note |\n' \
        > "${r}/docs/architecture-ng.md"
    run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0037"* ]]
}

@test "check logging-matrix fails closed on a missing architecture doc" {
    # What: a repo root with no docs/architecture-ng.md.
    # Why: a missing input must never silently pass.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check logging-matrix "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0035"* ]]
}

@test "check logging-matrix fails closed with no matrix marker" {
    # What: a doc with no logging-matrix marker at all.
    # Why: a vacuous parse must never report clean.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-nomarker"
    mkdir -p "${r}/docs"
    printf '# no marker here\n' > "${r}/docs/architecture-ng.md"
    run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0036"* ]]
}

@test "check logging-matrix fails closed when a compose lookup errors" {
    # What: a while/process-sub loop once hid this failure.
    # Why: a real docker-compose error must not vanish.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-cmderr"
    _logging_matrix_fixture "${r}" "svc-a"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svcfail 'exit 3')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0034"* ]]
}

@test "check logging-matrix fails a drifted quickstart web_log job" {
    # What: quickstart's inline job no longer matches it.
    # Why: #849's own stated byte-identical promise.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-weblog"
    _logging_matrix_fixture "${r}" "svc-a"
    cat > "${r}/deploy/quickstart/docker-compose.yml" <<'EOF'
services:
  netdata:
    command: |
      cat > /etc/netdata/go.d/web_log.conf <<'CONF'
        jobs:
          - name: different
            path: /y
        CONF
EOF
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svc 'printf "svc-a\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"quickstart's inline web_log job config has drifted"* ]]
}

@test "check logging-matrix passes a matching quickstart web_log fixture" {
    # What: an in-sync inline web_log job passes the parity check.
    # Why: the fixture-level match case (from the old weblog-parity bats).
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/lm-weblog-ok"
    _logging_matrix_fixture "${r}" "svc-a"
    CI_LOGGING_MATRIX_SERVICES_CMD="$(_stub svc 'printf "svc-a\n"')" \
        run bash "${CI_SH}" check logging-matrix "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"logging-matrix=clean"* ]]
}

@test "check trivy-action-direct-usage passes clean on the real repo" {
    # What: real tree has no direct call site, all wired.
    # Why: proves the rewrite against production state.
    # From: Issue #1683
    run bash "${CI_SH}" check trivy-action-direct-usage
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trivy-action-direct-usage=clean"* ]]
}

@test "check trivy-action-direct-usage flags a direct call outside the wrapper" {
    # What: a workflow bypassing the centralized wrapper.
    # Why: AG-VAL-029: bypass loses retry/auth/mirror fixes.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/trivy-direct"
    mkdir -p "${r}/.github/workflows" "${r}/.github/actions/aquasecurity-trivy-action-centralized-version"
    printf 'runs:\n  using: composite\n  steps:\n    - uses: aquasecurity/trivy-action@deadbeef\n' \
        > "${r}/.github/actions/aquasecurity-trivy-action-centralized-version/action.yml"
    printf 'jobs:\n  scan:\n    steps:\n      - uses: aquasecurity/trivy-action@deadbeef\n' \
        > "${r}/.github/workflows/scan.yml"
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0039"* ]]
    [[ "${output}" == *"scan.yml"* ]]
}

@test "check trivy-action-direct-usage flags a trivy-scan-retry call with no with: block" {
    # What: Call site missing whole with: block.
    # Why: Silently drops required credentials.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/trivy-nowith"
    mkdir -p "${r}/.github/workflows"
    printf 'jobs:\n  scan:\n    steps:\n      - uses: ./.github/actions/trivy-scan-retry\n      - run: echo hi\n' \
        > "${r}/.github/workflows/scan.yml"
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0040"* ]]
    [[ "${output}" == *"no with: block"* ]]
}

@test "check trivy-action-direct-usage flags an empty dockerhub-username value" {
    # What: Present but empty credential value.
    # Why: Key-presence-only check would wrongly pass.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/trivy-empty"
    mkdir -p "${r}/.github/workflows"
    cat > "${r}/.github/workflows/scan.yml" <<'EOF'
jobs:
  scan:
    steps:
      - uses: ./.github/actions/trivy-scan-retry
        with:
          dockerhub-username: ""
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"dockerhub-username not a real"* ]]
}

@test "check trivy-action-direct-usage flags a hardcoded dockerhub-password value" {
    # What: Literal string instead of secrets./inputs. ref.
    # Why: Same silent-fallback risk as empty value.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/trivy-hardcoded"
    mkdir -p "${r}/.github/workflows"
    cat > "${r}/.github/workflows/scan.yml" <<'EOF'
jobs:
  scan:
    steps:
      - uses: ./.github/actions/trivy-scan-retry
        with:
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
          dockerhub-password: hunter2
EOF
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"dockerhub-password not a real"* ]]
}

@test "check trivy-action-direct-usage flags a secret name sharing the expected prefix" {
    # What: Prefix-matching secret name wrongly accepted.
    # Why: Unanchored substring match is too loose.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/trivy-prefix"
    mkdir -p "${r}/.github/workflows"
    cat > "${r}/.github/workflows/scan.yml" <<'EOF'
jobs:
  scan:
    steps:
      - uses: ./.github/actions/trivy-scan-retry
        with:
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME_OLD }}
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"dockerhub-username not a real"* ]]
}

@test "check trivy-action-direct-usage passes a forwarded inputs.* reference" {
    # What: Wrapper action forwards caller's own inputs.
    # Why: Nested-composite-action forwarding is legal.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/trivy-inputs"
    mkdir -p "${r}/.github/actions/some-wrapper"
    cat > "${r}/.github/actions/some-wrapper/action.yml" <<'EOF'
runs:
  using: composite
  steps:
    - uses: ./.github/actions/trivy-scan-retry
      with:
        dockerhub-username: ${{ inputs.dockerhub-username }}
        dockerhub-password: ${{ inputs.dockerhub-password }}
EOF
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"trivy-action-direct-usage=clean"* ]]
}

@test "check trivy-action-direct-usage flags direct + unwired calls in composite actions" {
    # What: a non-wrapper composite calling trivy-action, and one calling
    # trivy-scan-retry with no dockerhub wiring.
    # Why: absorbs the composite-action call-site coverage.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/trivy-comp"
    mkdir -p "${r}/.github/actions/aquasecurity-trivy-action-centralized-version" "${r}/.github/actions/other"
    printf 'runs:\n  using: composite\n  steps:\n    - uses: aquasecurity/trivy-action@deadbeef\n' \
        > "${r}/.github/actions/aquasecurity-trivy-action-centralized-version/action.yml"
    printf 'runs:\n  using: composite\n  steps:\n    - uses: aquasecurity/trivy-action@deadbeef\n' \
        > "${r}/.github/actions/other/action.yml"
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -ne 0 ]; [[ "${output}" == *"other/action.yml"* ]]
    printf 'runs:\n  using: composite\n  steps:\n    - uses: ./.github/actions/trivy-scan-retry\n' \
        > "${r}/.github/actions/other/action.yml"
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"; [ "${status}" -ne 0 ]
}

@test "check trivy-action-direct-usage dockerhub-key wiring variants" {
    # What: interleaved-comment + both keys pass; only-one / bare uses fail.
    # Why: absorbs the trivy-scan-retry dockerhub-wiring edge coverage.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/trivy-keys"; mkdir -p "${r}/.github/workflows"
    cat > "${r}/.github/workflows/s.yml" <<'EOF'
jobs:
  scan:
    steps:
      - uses: ./.github/actions/trivy-scan-retry
        with:
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
          # interleaved comment
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"; [ "${status}" -eq 0 ]
    cat > "${r}/.github/workflows/s.yml" <<'EOF'
jobs:
  scan:
    steps:
      - uses: ./.github/actions/trivy-scan-retry
        with:
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
EOF
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"; [ "${status}" -ne 0 ]
    cat > "${r}/.github/workflows/s.yml" <<'EOF'
jobs:
  scan:
    steps:
      - uses: "./.github/actions/trivy-scan-retry"
EOF
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"; [ "${status}" -ne 0 ]
}

@test "check trivy-action-direct-usage handles a quoted uses: at deeper list nesting" {
    # What: Quoted uses: scalar under dash-only list item.
    # Why: Indentation/quoting variation escapes scan.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/trivy-quoted"
    mkdir -p "${r}/.github/workflows"
    cat > "${r}/.github/workflows/scan.yml" <<'EOF'
jobs:
  scan:
    steps:
      -
        uses: './.github/actions/trivy-scan-retry'
        with:
          dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
          dockerhub-password: ${{ secrets.DOCKERHUB_TOKEN }}
EOF
    run bash "${CI_SH}" check trivy-action-direct-usage "${r}"
    [ "${status}" -eq 0 ]
}

@test "check entrypoint-lib-wiring passes when the Dockerfile COPYs the sourced path" {
    # What: Entrypoint sources lib; Dockerfile COPYs it.
    # Why: the wired-correctly baseline case.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-ok"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    printf 'FROM alpine:3.24\nCOPY scripts/lib/domain-validation.sh /usr/local/lib/domain-validation.sh\n' \
        > "${r}/services/proxy/Dockerfile"
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -eq 0 ]
}

@test "check entrypoint-lib-wiring fails closed when sourced but never COPYd" {
    # What: Entrypoint sources lib Dockerfile never brings.
    # Why: Runtime-only failure the guard detects.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-nocopy"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    printf 'FROM alpine:3.24\nRUN echo hi\n' > "${r}/services/proxy/Dockerfile"
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0041"* ]]
    [[ "${output}" == *"no matching final-stage COPY"* ]]
}

@test "check entrypoint-lib-wiring fails closed on a COPY destination path drift" {
    # What: Dockerfile COPYs lib to different path.
    # Why: Drifted destination same as no COPY.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-drift"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    printf 'FROM alpine:3.24\nCOPY scripts/lib/domain-validation.sh /opt/lib/domain-validation.sh\n' \
        > "${r}/services/proxy/Dockerfile"
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0041"* ]]
}

@test "check entrypoint-lib-wiring ignores a COPY that only exists in a builder stage" {
    # What: Builder-stage-only COPY missed by final stage.
    # Why: Entrypoint.sh runs in final stage only.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-builderonly"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    cat > "${r}/services/proxy/Dockerfile" <<'EOF'
FROM alpine:3.24 AS builder
COPY scripts/lib/domain-validation.sh /usr/local/lib/domain-validation.sh
FROM alpine:3.24
RUN echo final
EOF
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -ne 0 ]
}

@test "check entrypoint-lib-wiring passes a directory-form COPY covering the sourced path" {
    # What: COPY scripts/lib/ /usr/local/lib/ (dir form).
    # Why: not every consumer COPYs one file at a time.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-dircopy"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    printf 'FROM alpine:3.24\nCOPY scripts/lib/ /usr/local/lib/\n' > "${r}/services/proxy/Dockerfile"
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -eq 0 ]
}

@test "check entrypoint-lib-wiring requires no COPY when nothing is sourced" {
    # What: Entrypoint never sources absolute-path lib.
    # Why: Guard is one-directional: source implies COPY.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-nosource"
    mkdir -p "${r}/services/proxy"
    printf 'echo "nothing sourced here"\n' > "${r}/services/proxy/entrypoint.sh"
    printf 'FROM alpine:3.24\nRUN echo hi\n' > "${r}/services/proxy/Dockerfile"
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -eq 0 ]
}

@test "check entrypoint-lib-wiring accepts a COPY --from a declared builder stage" {
    # What: COPY --from=builder with real FROM ... AS stage.
    # Why: Consolidation copies from builder stage.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-fromstage"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    cat > "${r}/services/proxy/Dockerfile" <<'EOF'
FROM alpine:3.24 AS builder
RUN echo build
FROM alpine:3.24
COPY --from=builder /build/domain-validation.sh /usr/local/lib/domain-validation.sh
EOF
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -eq 0 ]
}

@test "check entrypoint-lib-wiring fails closed on a COPY --from an undeclared stage" {
    # What: COPY --from=oldbuilder stage doesn't exist.
    # Why: Renamed/typo'd stage must fail closed.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-badstage"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    cat > "${r}/services/proxy/Dockerfile" <<'EOF'
FROM alpine:3.24 AS builder
RUN echo build
FROM alpine:3.24
COPY --from=oldbuilder /build/domain-validation.sh /usr/local/lib/domain-validation.sh
EOF
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -ne 0 ]
}

@test "check entrypoint-lib-wiring accepts a COPY --from an external image" {
    # What: COPY --from=external image, not local stage.
    # Why: External image contents out of scope.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-fromexternal"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    printf 'FROM alpine:3.24\nCOPY --from=ghcr.io/example/image:latest /x/domain-validation.sh /usr/local/lib/domain-validation.sh\n' \
        > "${r}/services/proxy/Dockerfile"
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -eq 0 ]
}

@test "check entrypoint-lib-wiring accepts a COPY --from a SOT named build context" {
    # What: COPY --from=shared-scripts (SOT named context).
    # Why: Real domain-validation consolidation pattern.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/elw-buildcontext"
    mkdir -p "${r}/services/proxy"
    printf '. /usr/local/lib/domain-validation.sh\n' > "${r}/services/proxy/entrypoint.sh"
    printf 'FROM alpine:3.24\nCOPY --from=shared-scripts domain-validation.sh /usr/local/lib/domain-validation.sh\n' \
        > "${r}/services/proxy/Dockerfile"
    run bash "${CI_SH}" check entrypoint-lib-wiring "${r}"
    [ "${status}" -eq 0 ]
}

@test "check entrypoint-lib-wiring passes clean and meaningfully on the real repo" {
    # What: Domain-validation consolidation live in repo.
    # Why: Guard validates real source lines now.
    # From: Issue #1683
    run bash "${CI_SH}" check entrypoint-lib-wiring
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"entrypoint-lib-wiring=clean"* ]]
}

@test "check changelog-direct-edit is clean when CHANGELOG.md is untouched" {
    # What: migrated from check-changelog-direct-edit.sh.
    # Why: rewritten in ci.sh; stays non-blocking always.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check changelog-direct-edit "foo.txt" "bar.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"changelog-direct-edit=clean"* ]]
}

@test "check changelog-direct-edit warns without the release label" {
    # What: a direct CHANGELOG.md edit, no exemption label.
    # Why: issue #893: warn-only, never blocks the build.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check changelog-direct-edit "CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"CI-INFO-CHECK-0001"* ]]
    [[ "${output}" == *"warn-only"* ]]
    [[ "${output}" == *"changelog-direct-edit=warn"* ]]
}

@test "check changelog-direct-edit notices the release label exemption" {
    # What: same edit, but the PR carries the release label.
    # Why: the documented manual release-notes exemption.
    # From: Issue #1683 | PR #1858
    PR_LABELS_JSON='["release"]' \
        run bash "${CI_SH}" check changelog-direct-edit "CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"edited with release label; expected"* ]]
}

# What: builds a fixture Dockerfile + smoke script pair.
# Why: shared by the build-tools-smoke-coverage tests below.
# From: Issue #1683 | PR #1858
_smoke_coverage_fixture() {
    local root="$1" extra_dockerfile_tool="${2:-}"
    mkdir -p "${root}/tools/build-tools" "${root}/scripts/untracked"
    {
        printf 'FROM alpine\n'
        printf 'RUN true\n'
        printf 'required_tools=(\n'
        printf '  bash\n'
        [ -n "${extra_dockerfile_tool}" ] && printf '  %s\n' "${extra_dockerfile_tool}"
        printf ')\n'
    } > "${root}/tools/build-tools/Dockerfile"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'smoke_test_image() {\n'
        printf '  required_tools=(\n'
        printf '    bash\n'
        printf '  )\n'
        printf '}\n'
    } > "${root}/scripts/untracked/select-build-tools-image.sh"
    # What: Minimal SOT fixture with smoke_tools "bash".
    # Why: Check hard-fails SOT/smoke divergence.
    # From: Issue #1683
    printf 'build_toolchain:\n  build-tools:\n    smoke_tools:\n      - bash\n' \
        > "${root}/build-manifest.yml"
}

@test "check build-tools-smoke-coverage passes on the real repo" {
    # What: real SOT/smoke pair is consistent, not a gap.
    # Why: cargo-tarpaulin (opt-in) + timeout (wrapper) are covered.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check build-tools-smoke-coverage
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build-tools-smoke-coverage=clean"* ]]
}

@test "check build-tools-smoke-coverage passes clean when Dockerfile/smoke/SOT all agree" {
    # What: Fixture where Dockerfile, smoke, and SOT match.
    # Why: Positive baseline for cross-check validation.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/allmatch"
    _smoke_coverage_fixture "${r}"
    CI_MANIFEST="${r}/build-manifest.yml" run bash "${CI_SH}" check build-tools-smoke-coverage "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build-tools-smoke-coverage=clean"* ]]
}

@test "check build-tools-smoke-coverage fails an uncovered tool" {
    # What: a Dockerfile tool, absent from smoke/exclusions.
    # Why: issue #790/#791/#822's exact failure shape.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/uncovered"
    _smoke_coverage_fixture "${r}" newtool
    CI_MANIFEST="${r}/build-manifest.yml" run bash "${CI_SH}" check build-tools-smoke-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0026"* ]]
    [[ "${output}" == *"'newtool' verified by the Dockerfile"* ]]
}

@test "check build-tools-smoke-coverage allows an excluded tool" {
    # What: a build tool on the reviewed exclusion list.
    # Why: excluded tools must never trip the gap error.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/excluded"
    _smoke_coverage_fixture "${r}" make
    CI_MANIFEST="${r}/build-manifest.yml" run bash "${CI_SH}" check build-tools-smoke-coverage "${r}"
    [ "${status}" -eq 0 ]
}

@test "check build-tools-smoke-coverage fails an SOT tool smoke never covers" {
    # What: SOT lists a tool absent from smoke and its mechanisms.
    # Why: SOT owns the list; an uncovered entry is a false claim.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/sotgap"
    _smoke_coverage_fixture "${r}"
    printf 'build_toolchain:\n  build-tools:\n    smoke_tools:\n      - bash\n      - phantomtool\n' \
        > "${r}/build-manifest.yml"
    CI_MANIFEST="${r}/build-manifest.yml" run bash "${CI_SH}" check build-tools-smoke-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0026"* ]]
    [[ "${output}" == *"SOT smoke_tools lists 'phantomtool'"* ]]
}

@test "check build-tools-smoke-coverage accepts SOT timeout and opt-in tools" {
    # What: SOT lists timeout (wrapper) plus an EXTRA opt-in tool.
    # Why: smoke covers both without a static required_tools entry.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/sotalt"
    mkdir -p "${r}/tools/build-tools" "${r}/scripts/untracked"
    printf 'FROM alpine\nrequired_tools=(\n  bash\n)\n' > "${r}/tools/build-tools/Dockerfile"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'smoke_test_image() {\n'
        printf '  docker run --rm -e "EXTRA_REQUIRED_TOOLS=${EXTRA_REQUIRED_TOOLS:-}" "$1" timeout 60 true\n'
        printf '  required_tools=(\n    bash\n  )\n'
        printf '  # cargo-tarpaulin is opt-in via EXTRA_REQUIRED_TOOLS\n'
        printf '}\n'
    } > "${r}/scripts/untracked/select-build-tools-image.sh"
    printf 'build_toolchain:\n  build-tools:\n    smoke_tools:\n      - bash\n      - timeout\n      - cargo-tarpaulin\n' \
        > "${r}/build-manifest.yml"
    CI_MANIFEST="${r}/build-manifest.yml" run bash "${CI_SH}" check build-tools-smoke-coverage "${r}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"build-tools-smoke-coverage=clean"* ]]
}

@test "check build-tools-smoke-coverage fails an uncovered docker capability" {
    # What: Dockerfile checks docker buildx, smoke does not.
    # Why: array-only diffing can't see a subcommand check.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/cap"
    mkdir -p "${r}/tools/build-tools" "${r}/scripts/untracked"
    printf 'FROM alpine\nrequired_tools=(\n  bash\n)\ndocker buildx version\n' \
        > "${r}/tools/build-tools/Dockerfile"
    printf '#!/usr/bin/env bash\nsmoke_test_image() {\n  required_tools=(\n    bash\n  )\n}\n' \
        > "${r}/scripts/untracked/select-build-tools-image.sh"
    printf 'build_toolchain:\n  build-tools:\n    smoke_tools:\n      - bash\n' \
        > "${r}/build-manifest.yml"
    CI_MANIFEST="${r}/build-manifest.yml" run bash "${CI_SH}" check build-tools-smoke-coverage "${r}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"'docker buildx version' verified"* ]]
}

@test "check build-tools-smoke-coverage fails closed when the SOT lacks smoke_tools" {
    # What: Missing build_toolchain smoke_tools in SOT.
    # Why: Absence must fail closed, not silent.
    # From: Issue #1683
    local r="${BATS_TEST_TMPDIR}/nosot"
    _smoke_coverage_fixture "${r}"
    printf 'build_toolchain:\n  build-tools:\n    packages:\n      - bash\n' \
        > "${r}/build-manifest.yml"
    CI_MANIFEST="${r}/build-manifest.yml" run bash "${CI_SH}" check build-tools-smoke-coverage "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0025"* ]]
}

@test "check build-tools-smoke-coverage fails closed on a vacuous scan" {
    # What: a Dockerfile with no required_tools array.
    # Why: mirrors the legacy script's anti-vacuous guard.
    # From: Issue #1683 | PR #1858
    local r="${BATS_TEST_TMPDIR}/vacuous"
    mkdir -p "${r}/tools/build-tools" "${r}/scripts/untracked"
    printf 'FROM alpine\n' > "${r}/tools/build-tools/Dockerfile"
    printf '#!/usr/bin/env bash\n' > "${r}/scripts/untracked/select-build-tools-image.sh"
    run bash "${CI_SH}" check build-tools-smoke-coverage "${r}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0025"* ]]
}

@test "check build-tools-smoke-coverage fails closed with no files" {
    # What: neither expected file exists at the given root.
    # Why: a missing input must never silently pass.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" check build-tools-smoke-coverage "${BATS_TEST_TMPDIR}/nope"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-CHECK-0024"* ]]
}

@test "verify-version-banner.sh matches a banner and ignores the tool exit code" {
    # What: banner match passes; mismatch / too-few-args fail closed.
    # Why: shared lsof-banner check; lsof -v's exit code is unreliable.
    # From: Issue #1613 | PR #1858
    local vb="${BATS_TEST_DIRNAME}/../../scripts/lib/verify-version-banner.sh"
    [ -f "${vb}" ]
    run sh "${vb}" "hello banner" printf "hello banner\n"; [ "${status}" -eq 0 ]
    run sh "${vb}" "hello banner" printf "goodnight\n"; [ "${status}" -ne 0 ]; [[ "${output}" == *"ERROR"* ]]
    run sh "${vb}" "only-one-arg"; [ "${status}" -ne 0 ]; [[ "${output}" == *"usage:"* ]]
    cat > "${BATS_TEST_TMPDIR}/fake-lsof" <<'FXEOF'
#!/bin/sh
printf 'lsof version information: fake\n'
exit 1
FXEOF
    chmod +x "${BATS_TEST_TMPDIR}/fake-lsof"
    run sh "${vb}" "lsof version information" "${BATS_TEST_TMPDIR}/fake-lsof" -v; [ "${status}" -eq 0 ]
}

@test "the six lsof consumers COPY and invoke the shared verify-version-banner.sh" {
    # What: shared COPY + invoke, no inline lsof / utilities-tools stage.
    # Why: the shared script must replace the drifted inline banner checks.
    # From: Issue #1613 | PR #1858
    local root="${BATS_TEST_DIRNAME}/../.." f df
    for f in dhcp-proxy dhcp dns proxy ui watchdog; do
        df="${root}/services/${f}/Dockerfile"
        grep -qF 'COPY --from=shared-scripts verify-version-banner.sh /usr/local/bin/verify-version-banner.sh' "${df}" || { echo "no COPY: ${f}"; false; }
        grep -qF 'sh /usr/local/bin/verify-version-banner.sh "lsof version information" lsof -v' "${df}" || { echo "no invoke: ${f}"; false; }
        ! grep -qF 'lsof_out="$(lsof -v 2>&1)"' "${df}" || { echo "inline lsof: ${f}"; false; }
        ! grep -qF 'utilities-tools' "${df}" || { echo "utilities-tools: ${f}"; false; }
    done
}

@test "docker-build builds a per-identity per-arch tag via buildx" {
    # What: ci.sh executes the build; YAML only calls it.
    # Why: engine owns execution, orchestrator just calls.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho "docker $*"\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        run _ci_docker_build proxy abc123 linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"buildx build --load"* ]]
    [[ "${output}" == *"ghcr.io/wiki-mod/lancache-ng/proxy:sha-abc123-amd64"* ]]
    [[ "${output}" == *"--platform linux/amd64"* ]]
    [[ "${output}" == *"org.opencontainers.image.title=proxy"* ]]
}

@test "docker-build omits cache-from/cache-to when unset (unchanged default)" {
    # What: no CI_BUILD_CACHE_* means no cache flags at all.
    # Why: unset vars must not change existing callers.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho "docker $*"\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        run _ci_docker_build proxy abc123 linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"--cache-from"* ]]
    [[ "${output}" != *"--cache-to"* ]]
}

@test "docker-build wires per-service cache-from/cache-to from CI_BUILD_CACHE_FROM/TO" {
    # What: buildx gets a cache-from/cache-to per service.
    # Why: needs one cache scope per service, not shared.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho "docker $*"\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        CI_BUILD_CACHE_FROM="type=registry,ref=ghcr.io/wiki-mod/lancache-ng/proxy:cache" \
        CI_BUILD_CACHE_TO="type=registry,ref=ghcr.io/wiki-mod/lancache-ng/proxy:cache,mode=max" \
        run _ci_docker_build proxy abc123 linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--cache-from type=registry,ref=ghcr.io/wiki-mod/lancache-ng/proxy:cache"* ]]
    [[ "${output}" == *"--cache-to type=registry,ref=ghcr.io/wiki-mod/lancache-ng/proxy:cache,mode=max,ignore-error=true"* ]]

    # What: a 2nd service call gets its own cache ref.
    # Why: proves scope is per-call, not one constant value.
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        CI_BUILD_CACHE_FROM="type=registry,ref=ghcr.io/wiki-mod/lancache-ng/ui:cache" \
        CI_BUILD_CACHE_TO="type=registry,ref=ghcr.io/wiki-mod/lancache-ng/ui:cache,mode=max" \
        run _ci_docker_build ui def456 linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--cache-from type=registry,ref=ghcr.io/wiki-mod/lancache-ng/ui:cache"* ]]
    [[ "${output}" == *"--cache-to type=registry,ref=ghcr.io/wiki-mod/lancache-ng/ui:cache,mode=max,ignore-error=true"* ]]
    [[ "${output}" != *"proxy:cache"* ]]
}

@test "docker-build cache-from miss fails cache import only, build still succeeds" {
    # What: a bad cache-from ref must not fail the build.
    # Why: §35: a cache miss must cost time, not the build.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    cat > "${bin}/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"--cache-from"*)
        echo "importing cache manifest from target" >&2
        echo "ERROR: failed to configure registry cache import: not found" >&2
        exit 0
        ;;
    *) echo "docker $*" ;;
esac
EOF
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        CI_BUILD_CACHE_FROM="type=registry,ref=ghcr.io/wiki-mod/lancache-ng/proxy:cache" \
        run _ci_docker_build proxy abc123 linux/amd64
    [ "${status}" -eq 0 ]
    # What: raw evidence of the miss stays visible.
    # Why: AG-INT-002 forbids hiding it.
    [[ "${output}" == *"failed to configure registry cache import"* ]]
}

@test "docker-build cache-to already carrying ignore-error is untouched" {
    # What: ignore-error is kept, never duplicated.
    # Why: a repeated CSV key must not reach buildx.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho "docker $*"\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        CI_BUILD_CACHE_TO="type=registry,ref=ghcr.io/wiki-mod/lancache-ng/proxy:cache,ignore-error=false" \
        run _ci_docker_build proxy abc123 linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--cache-to type=registry,ref=ghcr.io/wiki-mod/lancache-ng/proxy:cache,ignore-error=false"* ]]
    [[ "${output}" != *"ignore-error=false,ignore-error=true"* ]]
}

@test "docker-build cache-to shorthand is passed through with a warning" {
    # What: a shorthand ref is forwarded unmodified.
    # Why: appending CSV attrs would break its syntax.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho "docker $*"\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        CI_BUILD_CACHE_TO="ghcr.io/wiki-mod/lancache-ng/proxy:cache" \
        run _ci_docker_build proxy abc123 linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--cache-to ghcr.io/wiki-mod/lancache-ng/proxy:cache"* ]]
    [[ "${output}" == *"CI-WARN-BUILD-0012"* ]]
}

@test "build-tools build cache-to carries ignore-error for §35 resilience" {
    # What: build-tools cache-to also gets ignore-error.
    # Why: same failure class as build (AG-WF-011).
    # From: Issue #1683
    export DLOG="${BATS_TEST_TMPDIR}/d.log"; : > "${DLOG}"
    docker() { printf 'docker %s\n' "$*" >> "${DLOG}"; case "$*" in *"imagetools inspect"*) printf 'sha256:dead\n' ;; esac; return 0; }
    export -f docker
    GITHUB_REPOSITORY=wiki-mod/lancache-ng GITHUB_SHA=abc123 \
        CI_BUILD_CACHE_TO="type=registry,ref=ghcr.io/wiki-mod/lancache-ng/build-tools:cache,mode=max" \
        run _ci_build_tools_build linux/amd64 sig-xyz
    [ "${status}" -eq 0 ]
    grep -q -- "--cache-to type=registry,ref=ghcr.io/wiki-mod/lancache-ng/build-tools:cache,mode=max,ignore-error=true" "${DLOG}"
}

@test "docker-publish pushes then reads back the registry digest" {
    # What: publish retries push, then reads the digest.
    # Why: BUILD != PUBLISH; same digest, many retries.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\ncase "$*" in *"imagetools inspect"*) echo sha256:deadbeef ;; *) : ;; esac\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        run _ci_docker_publish proxy abc123 linux/amd64
    [ "${status}" -eq 0 ]
    [ "${output}" = "sha256:deadbeef" ]
}

# =========================================================
# RETRY ENGINE (_ci_retry) + BUILD != PUBLISH INVARIANT
# =========================================================

@test "_ci_retry retries a transient failure and returns on success" {
    # What: 2 transient failures then success (3 tries).
    # Why: Engine owns every wrapper's retry loop.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _flaky() {
        local n; n="$(($(cat "${cnt}") + 1))"; printf '%s' "${n}" > "${cnt}"
        if [ "${n}" -lt 3 ]; then echo "connection reset by peer" >&2; return 1; fi
        echo ok
    }
    export -f _flaky
    CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry registry _flaky
    [ "${status}" -eq 0 ]
    [ "${output}" = "ok" ]
    [ "$(cat "${cnt}")" -eq 3 ]
}

@test "_ci_retry fails on the first attempt for a permanent classification" {
    # What: 401 failure doesn't consume retry budget.
    # Why: Retrying fixed outcome wastes wall-clock time.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _denied() {
        printf '%s' "$(($(cat "${cnt}") + 1))" > "${cnt}"
        echo "HTTP 401 unauthorized" >&2; return 1
    }
    export -f _denied
    CI_RETRY_BACKOFF_BASE_SECONDS=0 run _ci_retry registry _denied
    [ "${status}" -eq 2 ]
    [ "$(cat "${cnt}")" -eq 1 ]
}

@test "_ci_retry exhausts after CI_RETRY_MAX_ATTEMPTS on a persistent transient failure" {
    # What: An always-transient failure still stops at max.
    # Why: A retry loop must be bounded, never infinite.
    # From: Issue #1683
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    _alwaysflaky() {
        printf '%s' "$(($(cat "${cnt}") + 1))" > "${cnt}"
        echo "connection refused" >&2; return 1
    }
    export -f _alwaysflaky
    CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RETRY_MAX_ATTEMPTS=3 run _ci_retry registry _alwaysflaky
    [ "${status}" -eq 2 ]
    [ "$(cat "${cnt}")" -eq 3 ]
}

@test "publish retry-exhaustion never invokes build (RETRY OPERATION != REBUILD)" {
    # What: Failed retry exhausts retries without rebuild.
    # Why: Retry-fail must never trigger rebuild.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local buildmarker="${BATS_TEST_TMPDIR}/build-was-called"
    cat > "${bin}/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"buildx build"*) printf 'called\n' >> "${buildmarker}"; exit 0 ;;
    *"push "*) echo "connection reset by peer" >&2; exit 1 ;;
    *) : ;;
esac
EOF
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
    CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RETRY_MAX_ATTEMPTS=3 \
        run _ci_docker_publish proxy abc123 linux/amd64
    [ "${status}" -eq 2 ]
    [ ! -e "${buildmarker}" ]
}

@test "docker-build retries only its own known transient buildx signature" {
    # What: Layer-lock fail then success; build succeeds.
    # Why: Historical buildx transient signature match.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    cat > "${bin}/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"buildx build"*)
        n="\$(( \$(cat "${cnt}") + 1 ))"; printf '%s' "\$n" > "${cnt}"
        if [ "\$n" -lt 2 ]; then
            echo "(*service).Write failed: rpc error: code = Unavailable desc = ref layer-sha256:abc locked for 900ms (since t): unavailable" >&2
            exit 1
        fi
        exit 0
        ;;
    *) : ;;
esac
EOF
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng CI_RETRY_BACKOFF_BASE_SECONDS=0 \
        run _ci_docker_build proxy abc123 linux/amd64
    [ "${status}" -eq 0 ]
    [ "$(cat "${cnt}")" -eq 2 ]
}

@test "docker-build fails immediately on a real compile error (no retry)" {
    # What: Compile failure must never be retried.
    # Why: Blind retry would only delay real feedback.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    cat > "${bin}/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"buildx build"*)
        printf '%s' "\$(( \$(cat "${cnt}") + 1 ))" > "${cnt}"
        echo "error: could not compile lancache-ui" >&2; exit 1 ;;
    *) : ;;
esac
EOF
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng CI_RETRY_BACKOFF_BASE_SECONDS=0 \
        run _ci_docker_build proxy abc123 linux/amd64
    [ "${status}" -eq 2 ]
    [ "$(cat "${cnt}")" -eq 1 ]
}

# What: mktemp -d under /var/tmp, tracked for teardown.
# Why: cache-dir tests must pass under any ambient TMPDIR.
# From: Issue #1683 | PR #1858
_trivy_var_tmp_dir() {
    local d
    d="$(mktemp -d "/var/tmp/ci-bats-trivy.XXXXXX")" || return 1
    printf '%s\n' "${d}" >> "${BATS_TEST_TMPDIR}/.trivy-var-tmp-dirs"
    printf '%s\n' "${d}"
}

@test "trivy var-tmp-dir manifest survives its own subshell for cleanup" {
    # What: Array append survives subshell for cleanup.
    # Why: Process substitution loses exit status.
    # From: Issue #1683 | PR #1858
    local vt; vt="$(_trivy_var_tmp_dir)"
    [ -d "${vt}" ]
    local manifest="${BATS_TEST_TMPDIR}/.trivy-var-tmp-dirs"
    grep -qxF -- "${vt}" "${manifest}"
    _trivy_cleanup_var_tmp_dirs "${manifest}"
    [ ! -d "${vt}" ]
}

# What: PATH-shim trivy for a clean/finding/db outcome.
# Why: One trivy mock; the scan tests share it.
# From: Issue #1683
_trivy_stub() {
    local mode="$1" bin="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${bin}"
    {
        printf '#!/usr/bin/env bash\nout=""\n'
        printf 'while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done\n'
        case "${mode}" in
            clean)   printf '[ -n "$out" ] && : > "$out"\nexit 0\n' ;;
            finding) printf '[ -n "$out" ] && echo "HIGH vuln" > "$out"\nexit 1\n' ;;
            db)      printf 'echo "failed to download vulnerability DB" >&2\nexit 1\n' ;;
        esac
    } > "${bin}/trivy"
    chmod +x "${bin}/trivy"
    printf '%s' "${bin}"
}

@test "trivy error kind classifies a DB miss versus other errors" {
    # What: DB-download text is retryable; others are not.
    # Why: Only a DB miss should trigger a retry.
    # From: Issue #1683
    run _ci_trivy_error_kind "failed to download vulnerability DB: timeout"
    [ "${output}" = "db-missing" ]
    run _ci_trivy_error_kind "manifest unknown: pull denied"
    [ "${output}" = "pre-report-error" ]
}

@test "scan default is clean when trivy exits zero" {
    # What: A zero exit is a clean image, no retry.
    # Why: The success path returns clean directly.
    # From: Issue #1683
    local bin vt; bin="$(_trivy_stub clean)"; vt="$(_trivy_var_tmp_dir)"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
    CI_TRIVY_SHARED_DIR="${vt}/no-shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/trivy-cache" \
        run _ci_trivy_scan proxy sha256:abc
    [ "${status}" -eq 0 ]
}

@test "scan default fails on a written report (a finding)" {
    # What: A written report is a deterministic finding.
    # Why: Findings fail once; retrying is wasted work.
    # From: Issue #1683
    local bin vt; bin="$(_trivy_stub finding)"; vt="$(_trivy_var_tmp_dir)"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
    CI_TRIVY_SHARED_DIR="${vt}/no-shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/trivy-cache" \
        run _ci_trivy_scan proxy sha256:abc
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"HIGH vuln"* ]]
}

@test "scan default escalates a DB miss after retries" {
    # What: No report plus a DB miss retries, then exits 3.
    # Why: A DB outage escalates, never reads as a finding.
    # From: Issue #1683
    local bin vt; bin="$(_trivy_stub db)"; vt="$(_trivy_var_tmp_dir)"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
    CI_TRIVY_SHARED_DIR="${vt}/no-shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/trivy-cache" \
        CI_TRIVY_MAX=2 CI_TRIVY_BACKOFF=0 run _ci_trivy_scan proxy sha256:abc
    [ "${status}" -eq 3 ]
}

@test "scan runs trivy with the vuln+secret scanners" {
    # What: The scan covers vulnerabilities and secrets.
    # Why: Secret-scan parity with the retired action.
    # From: Issue #1683
    local vt; vt="$(_trivy_var_tmp_dir)"
    export TLOG="${BATS_TEST_TMPDIR}/t.log"; : > "${TLOG}"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> "%s"\n' "${TLOG}"
        printf 'out=""\nwhile [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done\n'
        printf '[ -n "$out" ] && : > "$out"\nexit 0\n'
    } > "${bin}/trivy"
    chmod +x "${bin}/trivy"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
    CI_TRIVY_SHARED_DIR="${vt}/no-shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/trivy-cache" \
        run _ci_trivy_scan proxy sha256:abc
    [ "${status}" -eq 0 ]
    grep -q -- "--scanners vuln,secret" "${TLOG}"
    grep -q -- "--cache-dir ${vt}/trivy-cache" "${TLOG}"
}

@test "trivy dir writable proves a real file+subdir round-trip" {
    # What: A real dir passes the write+read+delete probe.
    # Why: Proves the probe itself, not just its caller.
    # From: Issue #1683
    run _ci_trivy_dir_writable "${BATS_TEST_TMPDIR}"
    [ "${status}" -eq 0 ]
}

@test "trivy dir writable refuses a missing directory" {
    # What: A nonexistent dir fails the probe.
    # Why: mkdir/write must never silently create the root.
    # From: Issue #1683
    run _ci_trivy_dir_writable "${BATS_TEST_TMPDIR}/does-not-exist"
    [ "${status}" -ne 0 ]
}

@test "trivy cache-dir prefers a writable shared dir" {
    # What: A writable shared-dir wins over the fallback.
    # Why: The shared NFS DB is the intended common cache.
    # From: Issue #1683
    local vt; vt="$(_trivy_var_tmp_dir)"
    mkdir -p "${vt}/shared"
    CI_TRIVY_SHARED_DIR="${vt}/shared" \
    CI_TRIVY_FALLBACK_DIR="${vt}/fallback" \
        run _ci_trivy_cache_dir
    [ "${status}" -eq 0 ]
    [[ "${output}" == "dir=${vt}/shared source=nfs-shared" ]]
}

@test "trivy cache-dir falls back to local disk when shared is absent" {
    # What: A missing shared-dir falls back to local disk.
    # Why: An unmounted NFS share must not block scanning.
    # From: Issue #1683
    local vt; vt="$(_trivy_var_tmp_dir)"
    CI_TRIVY_SHARED_DIR="${vt}/no-such-share" \
    CI_TRIVY_FALLBACK_DIR="${vt}/fallback" \
        run _ci_trivy_cache_dir
    [ "${status}" -eq 0 ]
    # What: run merges the INFO notice into output too.
    # Why: a substring match tolerates that extra line.
    # From: Issue #1683
    [[ "${output}" == *"dir=${vt}/fallback source=local-fallback"* ]]
    [ -d "${vt}/fallback" ]
}

@test "trivy cache-dir refuses tmpfs /tmp for shared or fallback" {
    # What: A /tmp shared or fallback dir is rejected.
    # Why: /tmp is tmpfs; a prior outage was OOM there.
    # From: Issue #1683
    CI_TRIVY_SHARED_DIR="/tmp/whatever" CI_TRIVY_FALLBACK_DIR="${BATS_TEST_TMPDIR}/fallback" \
        run _ci_trivy_cache_dir
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0007"* ]]
    CI_TRIVY_SHARED_DIR="${BATS_TEST_TMPDIR}/no-such-share" CI_TRIVY_FALLBACK_DIR="/tmp/whatever" \
        run _ci_trivy_cache_dir
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0007"* ]]
}

@test "trivy db fresh is false with no db file" {
    # What: A missing trivy.db is stale, never fine.
    # Why: Presence must never be assumed from an empty dir.
    # From: Issue #1683
    run _ci_trivy_db_fresh "${BATS_TEST_TMPDIR}/empty"
    [ "${status}" -ne 0 ]
}

@test "trivy db fresh is true before NextUpdate" {
    # What: A future NextUpdate reads as fresh.
    # Why: This is the one true freshness signal.
    # From: Issue #1683
    mkdir -p "${BATS_TEST_TMPDIR}/db/db"
    printf 'x' > "${BATS_TEST_TMPDIR}/db/db/trivy.db"
    printf '{"NextUpdate":"%s"}' "$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')" \
        > "${BATS_TEST_TMPDIR}/db/db/metadata.json"
    run _ci_trivy_db_fresh "${BATS_TEST_TMPDIR}/db"
    [ "${status}" -eq 0 ]
}

@test "trivy db fresh is false past NextUpdate" {
    # What: A past NextUpdate reads as stale, not present.
    # Why: skip-db-update never re-checks staleness itself.
    # From: Issue #1683
    mkdir -p "${BATS_TEST_TMPDIR}/db/db"
    printf 'x' > "${BATS_TEST_TMPDIR}/db/db/trivy.db"
    printf '{"NextUpdate":"%s"}' "$(date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ')" \
        > "${BATS_TEST_TMPDIR}/db/db/metadata.json"
    run _ci_trivy_db_fresh "${BATS_TEST_TMPDIR}/db"
    [ "${status}" -ne 0 ]
}

@test "trivy db lock serializes a second concurrent holder" {
    # What: A second locked_run waits for the first to end.
    # Why: Two writers must never race the same DB file.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/lockdb"; mkdir -p "${cache}"
    local order="${BATS_TEST_TMPDIR}/order"; : > "${order}"
    export CI_TRIVY_LOCK_POLL=1
    (
        _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c \
            'echo first-start >> "'"${order}"'"; sleep 1; echo first-end >> "'"${order}"'"'
    ) &
    local p1=$!
    sleep 0.3
    _ci_trivy_db_lock_run "${cache}" 10 60 -- bash -c \
        'echo second-start >> "'"${order}"'"'
    wait "${p1}"
    [ "$(sed -n 1p "${order}")" = "first-start" ]
    [ "$(sed -n 2p "${order}")" = "first-end" ]
    [ "$(sed -n 3p "${order}")" = "second-start" ]
}

@test "trivy db lock reclaims a stale lock directory" {
    # What: An old lock dir is reclaimed, not waited out.
    # Why: A crashed holder must never wedge later callers.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/staledb"; mkdir -p "${cache}"
    mkdir -p "${cache}/.trivy-db-update.lock"
    touch -d '-1 hour' "${cache}/.trivy-db-update.lock"
    CI_TRIVY_LOCK_POLL=1 run _ci_trivy_db_lock_run "${cache}" 10 5 -- true
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"reclaiming stale trivy DB refresh lock"* ]]
}

@test "trivy db lock fails closed when stale-lock reclaim itself fails" {
    # What: rm -rf not removing the stale lock is SCAN-0015.
    # Why: NFS can leave stale lock; must not spin.
    # From: Issue #1683 | PR #1858
    local cache="${BATS_TEST_TMPDIR}/wedgeddb"; mkdir -p "${cache}"
    local lock="${cache}/.trivy-db-update.lock"
    mkdir -p "${lock}"
    touch -d '-1 hour' "${lock}"
    # What: PATH-shim rm that no-ops only on the lock path.
    # Why: portably simulates a reclaim rm -rf that fails.
    # From: Issue #1683 | PR #1858
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for a; do [ "$a" = "%s" ] && exit 0; done\n' "${lock}"
        printf 'exec /bin/rm "$@"\n'
    } > "${bin}/rm"
    chmod +x "${bin}/rm"
    PATH="${bin}:${PATH}" CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_lock_run "${cache}" 10 5 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0015"* ]]
}

@test "trivy db lock fails closed when cache-dir cannot be created" {
    # What: A blocked cache-dir mkdir fails, never polls.
    # Why: distinguishes a real error from a held lock.
    # From: Issue #1683
    local blocker="${BATS_TEST_TMPDIR}/blocker"; : > "${blocker}"
    CI_TRIVY_LOCK_POLL=1 run _ci_trivy_db_lock_run "${blocker}/cache" 1 5 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0013"* ]]
}

@test "trivy db lock never polls a missing-parent failure forever" {
    # What: A non-lock mkdir failure fails fast, not slow.
    # Why: never spend the full lock-timeout poll budget.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/filelock"; mkdir -p "${cache}"
    # What: a plain file at the lock path is not a lock.
    # Why: mkdir fails there on every platform, portably.
    : > "${cache}/.trivy-db-update.lock"
    CI_TRIVY_LOCK_POLL=1 run _ci_trivy_db_lock_run "${cache}" 1 3600 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0014"* ]]
}

@test "trivy db lock times out on a genuinely held lock" {
    # What: A fresh, still-held lock is never bypassed.
    # Why: Falling through risks two concurrent writers.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/heldlock"; mkdir -p "${cache}"
    mkdir -p "${cache}/.trivy-db-update.lock"
    CI_TRIVY_LOCK_POLL=1 run _ci_trivy_db_lock_run "${cache}" 1 3600 -- true
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0011"* ]]
}

@test "trivy ensure_fresh skips the download when already fresh" {
    # What: An already-fresh DB skips lock and download.
    # Why: This is the intended common no-op case.
    # From: Issue #1683
    mkdir -p "${BATS_TEST_TMPDIR}/fresh/db"
    printf 'x' > "${BATS_TEST_TMPDIR}/fresh/db/trivy.db"
    printf '{"NextUpdate":"%s"}' "$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')" \
        > "${BATS_TEST_TMPDIR}/fresh/db/metadata.json"
    CI_TRIVY_DB_DOWNLOAD_CMD="$(_stub dl 'echo SHOULD-NOT-RUN; exit 1')" \
        run _ci_trivy_db_ensure_fresh "${BATS_TEST_TMPDIR}/fresh"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "present=true" ]]
}

@test "trivy ensure_fresh downloads under lock when stale" {
    # What: A stale/missing DB triggers one locked download.
    # Why: The lock is required exactly for the cold path.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/stale"; mkdir -p "${cache}"
    local next; next="$(date -u -d '+1 day' '+%Y-%m-%dT%H:%M:%SZ')"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    cat > "${bin}/dl" <<EOF
#!/usr/bin/env bash
mkdir -p "${cache}/db"
printf 'x' > "${cache}/db/trivy.db"
printf '{"NextUpdate":"%s"}' "${next}" > "${cache}/db/metadata.json"
EOF
    chmod +x "${bin}/dl"
    CI_TRIVY_DB_DOWNLOAD_CMD="${bin}/dl" \
    CI_TRIVY_LOCK_TIMEOUT=5 CI_TRIVY_LOCK_STALE=60 CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_ensure_fresh "${cache}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "present=true" ]]
}

@test "trivy ensure_fresh reports present=false after a failed download" {
    # What: A plain download failure stays present=false.
    # Why: Permissive; trivy's own retry can still run.
    # From: Issue #1683
    mkdir -p "${BATS_TEST_TMPDIR}/stillstale"
    CI_TRIVY_DB_DOWNLOAD_CMD="$(_stub dl 'exit 1')" \
    CI_TRIVY_LOCK_TIMEOUT=5 CI_TRIVY_LOCK_STALE=60 CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_ensure_fresh "${BATS_TEST_TMPDIR}/stillstale"
    [ "${status}" -eq 0 ]
    [[ "${output}" == "present=false" ]]
}

@test "trivy ensure_fresh hard-fails on a genuine lock timeout" {
    # What: A held lock fails ensure_fresh, not degrades.
    # Why: A silent downgrade risks a concurrent DB write.
    # From: Issue #1683
    local cache="${BATS_TEST_TMPDIR}/lockedstale"; mkdir -p "${cache}"
    mkdir -p "${cache}/.trivy-db-update.lock"
    CI_TRIVY_LOCK_TIMEOUT=1 CI_TRIVY_LOCK_STALE=3600 CI_TRIVY_LOCK_POLL=1 \
        run _ci_trivy_db_ensure_fresh "${cache}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-SCAN-0012"* ]]
}

@test "verify default reads back the registry digest via imagetools" {
    # What: default readback reads the registry digest.
    # Why: expected == registry digest continues (§23).
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho sha256:match\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng GHCR_USERNAME=u GHCR_TOKEN=t \
        run bash "${CI_SH}" verify ui sha256:match linux/amd64
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"verified=sha256:match"* ]]
}

@test "assemble default merges digests into one sha index" {
    # What: default assemble writes one multi-arch index.
    # Why: shared writer; digest read back from registry.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local log="${BATS_TEST_TMPDIR}/create.log"
    printf '#!/usr/bin/env bash\ncase "$*" in *"imagetools create"*) echo "$*" >> "%s" ;; *"imagetools inspect"*) echo sha256:idx ;; esac\n' "${log}" > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng GITHUB_SHA=deadbeef \
        run _ci_docker_assemble ui linux/amd64=sha256:aaa linux/arm64=sha256:bbb
    [ "${status}" -eq 0 ]
    [ "${output}" = "sha256:idx" ]
    run cat "${log}"
    [[ "${output}" == *"--tag ghcr.io/wiki-mod/lancache-ng/ui:sha-deadbeef"* ]]
    [[ "${output}" == *"ghcr.io/wiki-mod/lancache-ng/ui@sha256:aaa"* ]]
    [[ "${output}" == *"ghcr.io/wiki-mod/lancache-ng/ui@sha256:bbb"* ]]
}

@test "build-tools merge default shares the imagetools writer" {
    # What: default merge writes sha and latest indexes.
    # Why: one writer, no live registry; proves reuse.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local log="${BATS_TEST_TMPDIR}/create.log"
    printf '#!/usr/bin/env bash\ncase "$*" in *"imagetools create"*) echo "$*" >> "%s" ;; esac\n' "${log}" > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        run _ci_build_tools_merge abc123
    [ "${status}" -eq 0 ]
    run cat "${log}"
    [[ "${output}" == *"--tag ghcr.io/wiki-mod/lancache-ng/build-tools:sha-abc123"* ]]
    [[ "${output}" == *"--tag ghcr.io/wiki-mod/lancache-ng/build-tools:latest"* ]]
    [[ "${output}" == *"build-tools:sha-abc123-amd64"* ]]
}

# What: bare repo + two host clones for real CAS tests.
# Why: real git CAS proof, no live remote (AG-VAL-030).
_cas_setup() {
    CAS_BARE="${BATS_TEST_TMPDIR}/bare.git"
    CAS_A="${BATS_TEST_TMPDIR}/host-a"
    CAS_B="${BATS_TEST_TMPDIR}/host-b"
    git init --quiet --bare "${CAS_BARE}"
    git clone --quiet "${CAS_BARE}" "${CAS_A}"
    (
        cd "${CAS_A}" || exit 1
        git config user.email cas-bats@example.invalid
        git config user.name cas-bats
        git commit --quiet --allow-empty -m init
        git push --quiet origin HEAD:refs/heads/master
    )
    git clone --quiet "${CAS_BARE}" "${CAS_B}"
}

@test "cas ref_sha reports an absent ref as free" {
    # What: ls-remote miss maps to absent, not error.
    # Why: a free lock must read as free, code 1.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    run _ci_cas_ref_sha origin refs/ci/lock/t
    [ "${status}" -eq 1 ]
    [ -z "${output}" ]
}

@test "cas lock_try creates the ref on a free lock" {
    # What: a free lock is created atomically.
    # Why: create-against-zero is the acquire path.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    run _ci_lock_try origin refs/ci/lock/t holder-a 600
    [ "${status}" -eq 0 ]
    run _ci_cas_ref_sha origin refs/ci/lock/t
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

@test "cas lock_try refuses a fresh lock held elsewhere" {
    # What: a held, non-stale lock refuses a second host.
    # Why: mutual exclusion across hosts (code 1).
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    cd "${CAS_B}"
    run _ci_lock_try origin refs/ci/lock/t holder-b 600
    [ "${status}" -eq 1 ]
}

@test "cas release lets another host acquire" {
    # What: release frees the ref for the next host.
    # Why: normal hand-off between two runs.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    run _ci_lock_release origin refs/ci/lock/t holder-a
    [ "${status}" -eq 0 ]
    cd "${CAS_B}"
    run _ci_lock_try origin refs/ci/lock/t holder-b 600
    [ "${status}" -eq 0 ]
}

@test "cas release never deletes another holder's lock" {
    # What: release checks ownership before deleting.
    # Why: a takeover must not lose the new holder.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    cd "${CAS_B}"
    run _ci_lock_release origin refs/ci/lock/t not-holder
    [ "${status}" -eq 0 ]
    run _ci_cas_ref_sha origin refs/ci/lock/t
    [ "${status}" -eq 0 ]; [ -n "${output}" ]
}

@test "lock_release retries a transient git-fetch failure, then succeeds" {
    # What: Transient fail then success; retry works.
    # Why: Fetch lacked retry until op=git was added.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    local realgit; realgit="$(command -v git)"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    cat > "${bin}/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"fetch --quiet"*)
        n="\$(( \$(cat "${cnt}") + 1 ))"; printf '%s' "\$n" > "${cnt}"
        if [ "\$n" -lt 2 ]; then echo "unexpected disconnect while reading sideband packet" >&2; exit 1; fi
        ;;
esac
exec "${realgit}" "\$@"
EOF
    chmod +x "${bin}/git"
    PATH="${bin}:${PATH}" CI_RETRY_BACKOFF_BASE_SECONDS=0 \
        run _ci_lock_release origin refs/ci/lock/t holder-a
    [ "${status}" -eq 0 ]
    [ "$(cat "${cnt}")" -eq 2 ]
}

@test "lock_release fails fast (no retry) on a not_found-shaped git-fetch error" {
    # What: Missing ref must not consume retry budget.
    # Why: Permanent cascade; retrying won't fix it.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    local realgit; realgit="$(command -v git)"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    cat > "${bin}/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"fetch --quiet"*)
        printf '%s' "\$(( \$(cat "${cnt}") + 1 ))" > "${cnt}"
        echo "fatal: couldn't find remote ref refs/ci/lock/t" >&2; exit 1 ;;
esac
exec "${realgit}" "\$@"
EOF
    chmod +x "${bin}/git"
    PATH="${bin}:${PATH}" CI_RETRY_BACKOFF_BASE_SECONDS=0 \
        run _ci_lock_release origin refs/ci/lock/t holder-a
    [ "${status}" -eq 1 ]
    [ "$(cat "${cnt}")" -eq 1 ]
}

@test "lock_release exhausts after CI_RETRY_MAX_ATTEMPTS on a persistent transient fetch failure" {
    # What: Transient fail respects retry max limit.
    # Why: Bounded retry is a hard requirement.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    local realgit; realgit="$(command -v git)"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local cnt="${BATS_TEST_TMPDIR}/n"; printf '0' > "${cnt}"
    cat > "${bin}/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *"fetch --quiet"*)
        printf '%s' "\$(( \$(cat "${cnt}") + 1 ))" > "${cnt}"
        echo "connection refused" >&2; exit 1 ;;
esac
exec "${realgit}" "\$@"
EOF
    chmod +x "${bin}/git"
    PATH="${bin}:${PATH}" CI_RETRY_BACKOFF_BASE_SECONDS=0 CI_RETRY_MAX_ATTEMPTS=3 \
        run _ci_lock_release origin refs/ci/lock/t holder-a
    [ "${status}" -eq 1 ]
    [ "$(cat "${cnt}")" -eq 3 ]
}

@test "cas lock_try takes over a stale lock" {
    # What: an aged lock is taken over via lease swap.
    # Why: a crashed holder must not block forever.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    sleep 2
    cd "${CAS_B}"
    run _ci_lock_try origin refs/ci/lock/t holder-b 1
    [ "${status}" -eq 0 ]
    git fetch --quiet origin refs/ci/lock/t
    [ "$(git log -1 --format=%s FETCH_HEAD)" = holder-b ]
}

@test "cas acquire fails closed after exhausting attempts" {
    # What: an unbeatable lock exhausts retries and fails.
    # Why: proceeding unlocked would race the section.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t holder-a 600
    cd "${CAS_B}"
    run _ci_lock_acquire origin refs/ci/lock/t holder-b 3 1 600
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-CAS-0002"* ]]
}

@test "cas concurrent create has exactly one winner" {
    # What: two simultaneous creators; one wins atomically.
    # Why: git ref create is compare-against-zero.
    # From: Issue #1683
    _cas_setup
    local ra="${BATS_TEST_TMPDIR}/ra" rb="${BATS_TEST_TMPDIR}/rb"
    ( set +e; cd "${CAS_A}"; _ci_lock_try origin refs/ci/lock/t race-a 600; echo "$?" > "${ra}" ) &
    ( set +e; cd "${CAS_B}"; _ci_lock_try origin refs/ci/lock/t race-b 600; echo "$?" > "${rb}" ) &
    wait || true
    local sa sb; sa="$(cat "${ra}")"; sb="$(cat "${rb}")"
    if [ "${sa}" = 0 ]; then [[ "${sb}" == 1 || "${sb}" == 2 ]]; else [[ "${sa}" == 1 || "${sa}" == 2 ]]; fi
}

@test "ledger read on an empty ledger reports the record absent" {
    # What: no ledger ref yet means a record is absent.
    # Why: empty ledger is absent (1), not UNKNOWN (2).
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    run _ci_ledger_read origin some-identity
    [ "${status}" -eq 1 ]
}

@test "ledger append then read returns state and digest" {
    # What: a written record round-trips through the ref.
    # Why: proves the write/read format agree.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    _ci_ledger_append origin id-1 dns linux/amd64 ACCEPTED sha256:aaa
    run _ci_ledger_read origin id-1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ACCEPTED"* ]]
    [[ "${output}" == *"sha256:aaa"* ]]
}

@test "ledger append upserts an identity to its latest record" {
    # What: a second write replaces the same identity.
    # Why: one current record per identity, no duplicates.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    _ci_ledger_append origin id-1 dns linux/amd64 PRODUCED_UNVERIFIED sha256:aaa
    _ci_ledger_append origin id-1 dns linux/amd64 ACCEPTED sha256:aaa
    run _ci_ledger_read origin id-1
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"ACCEPTED"* ]]
    git fetch --quiet origin refs/ci/acceptance/ledger
    [ "$(git cat-file -p FETCH_HEAD:records | grep -c '^id-1')" -eq 1 ]
}

@test "ledger keeps distinct identities independently" {
    # What: two identities coexist in one ledger.
    # Why: an append must not drop other records.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    _ci_ledger_append origin id-a dns linux/amd64 ACCEPTED sha256:aaa
    _ci_ledger_append origin id-b dns linux/arm64 PRODUCED_UNVERIFIED sha256:bbb
    run _ci_ledger_read origin id-a
    [[ "${output}" == *"ACCEPTED"* ]]; [[ "${output}" == *"sha256:aaa"* ]]
    run _ci_ledger_read origin id-b
    [[ "${output}" == *"PRODUCED_UNVERIFIED"* ]]; [[ "${output}" == *"sha256:bbb"* ]]
}

@test "ledger read of an unknown identity is absent in a non-empty ledger" {
    # What: an unlisted identity reads as absent.
    # Why: absent (1) must not be confused with UNKNOWN.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    _ci_ledger_append origin id-a dns linux/amd64 ACCEPTED sha256:aaa
    run _ci_ledger_read origin id-missing
    [ "${status}" -eq 1 ]
}

@test "accepted_digest default returns the digest only when ACCEPTED" {
    # What: default reads the ledger via the identity.
    # Why: only an ACCEPTED record yields a digest.
    # From: Issue #1683
    _ci_identity_for() { echo fixed-id; }
    _ci_ledger_read() { printf 'ACCEPTED\tsha256:xyz\n'; }
    run _ci_accepted_digest ui linux/amd64
    [ "${status}" -eq 0 ]
    [ "${output}" = sha256:xyz ]
}

@test "accepted_digest default yields nothing for a non-ACCEPTED record" {
    # What: an unverified record is not a reusable digest.
    # Why: fail-safe; only ACCEPTED is reusable.
    # From: Issue #1683
    _ci_identity_for() { echo fixed-id; }
    _ci_ledger_read() { printf 'PRODUCED_UNVERIFIED\tsha256:xyz\n'; }
    run _ci_accepted_digest ui linux/amd64
    [ "${status}" -eq 1 ]
}

@test "accepted_digest default propagates a ledger UNKNOWN read" {
    # What: an unknown ledger read is not a missing digest.
    # Why: UNKNOWN != absent; the caller must not reuse.
    # From: Issue #1683
    _ci_identity_for() { echo fixed-id; }
    _ci_ledger_read() { return 2; }
    run _ci_accepted_digest ui linux/amd64
    [ "${status}" -eq 2 ]
}

@test "registry_probe maps a missing manifest to not-found" {
    # What: a genuine miss returns 1 (may build).
    # Why: not-found is the only build-eligible miss.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho "ghcr.io/x: not found: manifest unknown" >&2\nexit 1\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" run _ci_registry_probe ghcr.io/x/y:z
    [ "${status}" -eq 1 ]
}

@test "registry_probe maps an auth failure to unknown, not not-found" {
    # What: an auth failure returns 2 (never build).
    # Why: a credential problem is not a missing artifact.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho "denied: requested access to the resource" >&2\nexit 1\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" run _ci_registry_probe ghcr.io/x/y:z
    [ "${status}" -eq 2 ]
}

@test "registry_probe returns the digest on success" {
    # What: a present tag yields its digest, code 0.
    # Why: the happy path feeds the resolver.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho sha256:ok\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" run _ci_registry_probe ghcr.io/x/y:z
    [ "${status}" -eq 0 ]
    [ "${output}" = sha256:ok ]
}

@test "resolve state: an unreadable ledger is UNKNOWN" {
    # What: a failed policy read blocks resolution.
    # Why: UNKNOWN never builds (§26).
    # From: Issue #1683
    _ci_ledger_read() { return 2; }
    _ci_image_tag() { echo tag; }
    _ci_registry_probe() { echo sha256:g; }
    run _ci_resolve_state ui id-x linux/amd64
    [ "${output}" = UNKNOWN ]
}

@test "resolve state: an unreadable registry is UNKNOWN" {
    # What: a failed artifact read blocks resolution.
    # Why: transient registry error is not a miss.
    # From: Issue #1683
    _ci_ledger_read() { return 1; }
    _ci_image_tag() { echo tag; }
    _ci_registry_probe() { return 2; }
    run _ci_resolve_state ui id-x linux/amd64
    [ "${output}" = UNKNOWN ]
}

@test "resolve state: no record and no artifact is MISSING_CONFIRMED" {
    # What: nothing built yet -> build is warranted.
    # Why: the only state that authorizes a build.
    # From: Issue #1683
    _ci_ledger_read() { return 1; }
    _ci_image_tag() { echo tag; }
    _ci_registry_probe() { return 1; }
    run _ci_resolve_state ui id-x linux/amd64
    [ "${output}" = MISSING_CONFIRMED ]
}

@test "resolve state: no record but artifact present is PRODUCED_UNVERIFIED" {
    # What: built but unaccepted -> verify path.
    # Why: an unverified artifact must not be reused.
    # From: Issue #1683
    _ci_ledger_read() { return 1; }
    _ci_image_tag() { echo tag; }
    _ci_registry_probe() { echo sha256:g; }
    run _ci_resolve_state ui id-x linux/amd64
    [ "${output}" = PRODUCED_UNVERIFIED ]
}

@test "resolve state: ACCEPTED with a matching digest is PRESENT_ACCEPTED" {
    # What: policy and artifact agree -> reuse.
    # Why: the noop path; no rebuild.
    # From: Issue #1683
    _ci_ledger_read() { printf 'ACCEPTED\tsha256:g\n'; }
    _ci_image_tag() { echo tag; }
    _ci_registry_probe() { echo sha256:g; }
    run _ci_resolve_state ui id-x linux/amd64
    [ "${output}" = PRESENT_ACCEPTED ]
}

@test "resolve state: ACCEPTED with a divergent digest is MISMATCH" {
    # What: policy and artifact disagree -> fail.
    # Why: never silently accept a different digest.
    # From: Issue #1683
    _ci_ledger_read() { printf 'ACCEPTED\tsha256:g\n'; }
    _ci_image_tag() { echo tag; }
    _ci_registry_probe() { echo sha256:other; }
    run _ci_resolve_state ui id-x linux/amd64
    [ "${output}" = MISMATCH ]
}

@test "resolve state: ACCEPTED but artifact gone is MISMATCH, never rebuild" {
    # What: accepted yet missing -> fail, not rebuild.
    # Why: §23.2; rebuild would discard test/scan evidence.
    # From: Issue #1683
    _ci_ledger_read() { printf 'ACCEPTED\tsha256:g\n'; }
    _ci_image_tag() { echo tag; }
    _ci_registry_probe() { return 1; }
    run _ci_resolve_state ui id-x linux/amd64
    [[ "${output}" == *MISMATCH* ]]
    [[ "${output}" != *MISSING_CONFIRMED* ]]
}

@test "resolve state: a non-ACCEPTED record is PRODUCED_UNVERIFIED" {
    # What: a recorded but unaccepted state verifies.
    # Why: only ACCEPTED is reusable.
    # From: Issue #1683
    _ci_ledger_read() { printf 'PRODUCED_UNVERIFIED\tsha256:g\n'; }
    _ci_image_tag() { echo tag; }
    _ci_registry_probe() { echo sha256:g; }
    run _ci_resolve_state ui id-x linux/amd64
    [ "${output}" = PRODUCED_UNVERIFIED ]
}

@test "resolve state: a missing platform is UNKNOWN" {
    # What: no platform means no registry probe.
    # Why: fail closed rather than guess an artifact.
    # From: Issue #1683
    run _ci_resolve_state ui id-x ""
    [ "${output}" = UNKNOWN ]
}

@test "index_lookup default reads the multi-arch index and drops attestations" {
    # What: default reads the index digest + arch children.
    # Why: reconcile compares against the real registry.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    cat > "${bin}/docker" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *--raw*) echo '{"manifests":[{"platform":{"os":"linux","architecture":"amd64"},"digest":"sha256:a"},{"platform":{"os":"linux","architecture":"arm64"},"digest":"sha256:b"},{"platform":{"os":"unknown","architecture":"unknown"},"digest":"sha256:att"}]}' ;;
  *) echo sha256:idx ;;
esac
SH
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng GITHUB_SHA=deadbeef \
        run _ci_index_lookup ui
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"sha256:idx"* ]]
    [[ "${output}" == *"linux/amd64=sha256:a"* ]]
    [[ "${output}" == *"linux/arm64=sha256:b"* ]]
    [[ "${output}" != *"sha256:att"* ]]
}

@test "index_lookup default returns nothing when no index exists" {
    # What: a missing index is not a reusable index.
    # Why: assemble then creates one from accepted digests.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho "not found: manifest unknown" >&2\nexit 1\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng GITHUB_SHA=deadbeef \
        run _ci_index_lookup ui
    [ "${status}" -eq 1 ]
}

@test "ledger upsert writes many records in one commit" {
    # What: a batch of records lands in one CAS commit.
    # Why: §26.1 one write per workflow, not per record.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    printf 'id-a\tdns\tlinux/amd64\tACCEPTED\tsha256:a\nid-b\tui\tlinux/arm64\tACCEPTED\tsha256:b\n' \
        | _ci_ledger_upsert origin
    run _ci_ledger_read origin id-a
    [[ "${output}" == *"sha256:a"* ]]
    run _ci_ledger_read origin id-b
    [[ "${output}" == *"sha256:b"* ]]
    git fetch --quiet origin refs/ci/acceptance/ledger
    [ "$(git cat-file -p FETCH_HEAD:records | grep -c .)" -eq 2 ]
    [ "$(git rev-list --count FETCH_HEAD)" -eq 1 ]
}

@test "aggregate writes result.json files as one ledger write" {
    # What: many result.json -> one aggregated ledger write.
    # Why: §26.1 single aggregator, not per-job writes.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    local rd="${BATS_TEST_TMPDIR}/results"; mkdir -p "${rd}"
    printf '{"service":"dns","platform":"linux/amd64","build_identity":"id-a","state":"ACCEPTED","digest":"sha256:a"}' > "${rd}/a.json"
    printf '{"service":"ui","platform":"linux/arm64","build_identity":"id-b","state":"ACCEPTED","digest":"sha256:b"}' > "${rd}/b.json"
    run ci_cmd_aggregate "${rd}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"result=written"* ]]
    [[ "${output}" == *"records=2"* ]]
    run _ci_ledger_read origin id-a
    [[ "${output}" == *"ACCEPTED"* ]]
}

@test "aggregate re-run over the same results converges (idempotent)" {
    # What: re-aggregating the same set is a no-op content.
    # Why: §26.4 idempotency; same inputs -> same blob.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    local rd="${BATS_TEST_TMPDIR}/results"; mkdir -p "${rd}"
    printf '{"service":"dns","platform":"linux/amd64","build_identity":"id-a","state":"ACCEPTED","digest":"sha256:a"}' > "${rd}/a.json"
    ci_cmd_aggregate "${rd}"
    git fetch --quiet origin refs/ci/acceptance/ledger
    local first; first="$(git cat-file -p FETCH_HEAD:records)"
    ci_cmd_aggregate "${rd}"
    git fetch --quiet origin refs/ci/acceptance/ledger
    local second; second="$(git cat-file -p FETCH_HEAD:records)"
    [ "${first}" = "${second}" ]
}

@test "aggregate fails closed on a malformed result.json" {
    # What: a partial result.json aborts the aggregation.
    # Why: never record an incomplete acceptance.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    local rd="${BATS_TEST_TMPDIR}/results"; mkdir -p "${rd}"
    printf '{"service":"dns","platform":"linux/amd64"}' > "${rd}/bad.json"
    run ci_cmd_aggregate "${rd}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-AGGREGATE-0004"* ]]
}

@test "aggregate fails closed when the results dir is empty" {
    # What: no result.json means nothing to write.
    # Why: an empty run must not silently succeed.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    local rd="${BATS_TEST_TMPDIR}/results"; mkdir -p "${rd}"
    run ci_cmd_aggregate "${rd}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-AGGREGATE-0003"* ]]
}

@test "default channel move points the channel tag at the digest" {
    # What: default promote move retargets svc:channel.
    # Why: shares the index writer; moves, not builds.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    local log="${BATS_TEST_TMPDIR}/create.log"
    printf '#!/usr/bin/env bash\ncase "$*" in *"imagetools create"*) echo "$*" >> "%s" ;; esac\n' "${log}" > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        run _ci_default_channel_move ui latest sha256:abc
    [ "${status}" -eq 0 ]
    run cat "${log}"
    [[ "${output}" == *"--tag ghcr.io/wiki-mod/lancache-ng/ui:latest"* ]]
    [[ "${output}" == *"ghcr.io/wiki-mod/lancache-ng/ui@sha256:abc"* ]]
}

@test "default channel readback reads the channel digest" {
    # What: default readback returns the channel digest.
    # Why: one digest reader confirms the promotion.
    # From: Issue #1683
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${bin}"
    printf '#!/usr/bin/env bash\necho sha256:chan\n' > "${bin}/docker"
    chmod +x "${bin}/docker"
    PATH="${bin}:${PATH}" GITHUB_REPOSITORY=wiki-mod/lancache-ng \
        run _ci_default_channel_readback ui latest
    [ "${status}" -eq 0 ]
    [ "${output}" = sha256:chan ]
}

@test "default promote lock acquires the per-channel ref" {
    # What: default promote lock takes refs/ci/promote-lock.
    # Why: reuses the CAS mutex, scoped per channel.
    # From: Issue #1683
    _cas_setup
    cd "${CAS_A}"
    run _ci_default_promote_lock latest
    [ "${status}" -eq 0 ]
    run _ci_cas_ref_sha origin refs/ci/promote-lock/latest
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
}

# =========================================================
# VERSION MANAGEMENT
# =========================================================

# What: Copies the two version-pinned Dockerfiles for sync.
# Why: sync tests must never touch the real repo files.
# From: Issue #1683 | PR #1858
_version_fixture_repo() {
    local root="${BATS_TEST_TMPDIR}/vrepo"
    mkdir -p "${root}/services/netdata" "${root}/tools/build-tools"
    cp "${BATS_TEST_DIRNAME}/../../services/netdata/Dockerfile" \
        "${root}/services/netdata/Dockerfile"
    cp "${BATS_TEST_DIRNAME}/../../tools/build-tools/Dockerfile" \
        "${root}/tools/build-tools/Dockerfile"
    printf '%s' "${root}"
}

@test "version verify (default) passes clean on the real repo" {
    # What: default subcommand is verify, read-only.
    # Why: netdata+dhclient must match today's real files.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" version
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"key=netdata.version"*"match=yes"* ]]
    [[ "${output}" == *"key=dhclient.consumer.DHCLIENT_SHA256 shape=bare"* ]]
}

@test "version verify explicit subcommand matches the default" {
    # What: 'version verify' behaves like bare 'version'.
    # Why: the default-arg wiring must not silently diverge.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" version verify
    [ "${status}" -eq 0 ]
}

@test "version verify fails closed on a netdata version drift" {
    # What: SOT bumped, Dockerfile default left behind.
    # Why: verify is the CI gate; drift must fail the run.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/nd-version.yml"
    sed 's/version: v2.11.0/version: v2.99.0/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" version verify
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0010"* ]]
    [[ "${output}" == *"sot=v2.99.0"* ]]
    [[ "${output}" == *"dockerfile=v2.11.0"* ]]
}

@test "version verify fails closed on a netdata sha256 drift" {
    # What: SOT sha256_x86_64 changed, Dockerfile did not.
    # Why: a silent hash drift must fail the run too.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/nd-sha.yml"
    sed 's/sha256_x86_64: b42d9937807f28812502a967906d370cff9ab443453813656b99ff6a9b3c5649/sha256_x86_64: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" version verify
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0010"* ]]
}

@test "version verify fails closed on a netdata aarch64 sha256 drift" {
    # What: SOT aarch64 sha256 changed; Dockerfile didn't.
    # Why: Verify arm64 as hard as x86_64.
    # From: Issue #1683
    local m="${BATS_TEST_TMPDIR}/nd-sha-arm.yml"
    sed 's/sha256_aarch64: 8cd056d64078c109409c08e30d55324c82e3855f9d8e4b304cacc7c612610e09/sha256_aarch64: deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" version verify
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0010"* ]]
    [[ "${output}" == *"netdata.sha256_aarch64"* ]]
}

@test "version verify fails closed on a missing SOT dhclient field" {
    # What: SOT dhclient.sha256_arm64 line removed.
    # Why: dhclient stays fail-closed on a blank field.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/dh-missing.yml"
    grep -v 'sha256_arm64:' "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" version verify
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0011"* ]]
}

@test "version verify fails closed on a malformed dhclient sha256" {
    # What: SOT sha256_amd64 shortened to non-hex64 text.
    # Why: a truncated/garbled pin must never pass silently.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/dh-badsha.yml"
    sed 's/sha256_amd64: 068c97e534e9c8f03db9064296b1d3c21d957f328e40309278559a92f9a74557/sha256_amd64: not-a-real-hash/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" version verify
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0011"* ]]
}

@test "version verify fails closed if a dhclient ARG is missing" {
    # What: build-tools loses its DHCLIENT_SHA256 ARG line.
    # Why: the SOT-to-consumer contract must not just break.
    # From: Issue #1683 | PR #1858
    local root; root="$(_version_fixture_repo)"
    sed -i '/^ARG DHCLIENT_SHA256$/d' \
        "${root}/tools/build-tools/Dockerfile"
    CI_REPO_ROOT="${root}" run bash "${CI_SH}" version verify
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0012"* ]]
}

@test "version verify fails closed on a baked-in dhclient default" {
    # What: someone re-pins DHCLIENT_VERSION with a default.
    # Why: dhclient stays SOT-driven, no local re-pin ever.
    # From: Issue #1683 | PR #1858
    local root; root="$(_version_fixture_repo)"
    sed -i 's/^ARG DHCLIENT_VERSION$/ARG DHCLIENT_VERSION=4.4.3_p1-r4/' \
        "${root}/tools/build-tools/Dockerfile"
    CI_REPO_ROOT="${root}" run bash "${CI_SH}" version verify
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0013"* ]]
}

@test "version audit reports the netdata aarch64 orphan when no consumer exists" {
    # What: aarch64 ARG orphan still visible always.
    # Why: Audit must fail closed when required ARG missing.
    # From: Issue #1683
    local root; root="$(_version_fixture_repo)"
    sed -i '/^ARG NETDATA_AARCH64_SHA256=/d' "${root}/services/netdata/Dockerfile"
    CI_REPO_ROOT="${root}" run bash "${CI_SH}" version audit
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-WARN-VERSION-0001"* ]]
    [[ "${output}" == *"netdata.sha256_aarch64"* ]]
}

@test "version audit no longer flags the netdata aarch64 orphan on the real repo" {
    # What: Real repo now consumes aarch64 ARG; no warning.
    # Why: Proof consolidation resolved scope gap.
    # From: Issue #1683
    run bash "${CI_SH}" version audit
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"CI-WARN-VERSION-0001"* ]]
}

@test "version audit reports drift but never fails on it" {
    # What: audit is the report-only view of the same drift.
    # Why: verify is the CI gate; audit must stay exit 0.
    # From: Issue #1683 | PR #1858
    local m="${BATS_TEST_TMPDIR}/nd-audit.yml"
    sed 's/version: v2.11.0/version: v2.99.0/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" run bash "${CI_SH}" version audit
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"match=no"* ]]
}

@test "version sync is a byte-identical no-op when already synced" {
    # What: today's real files already match the SOT.
    # Why: sync must never touch a file with nothing to fix.
    # From: Issue #1683 | PR #1858
    local root; root="$(_version_fixture_repo)"
    local before; before="$(sha256sum "${root}/services/netdata/Dockerfile")"
    CI_REPO_ROOT="${root}" run bash "${CI_SH}" version sync
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"changed=0"* ]]
    [[ "${output}" == *"sync=dhclient changed=0"* ]]
    local after; after="$(sha256sum "${root}/services/netdata/Dockerfile")"
    [ "${before}" = "${after}" ]
}

@test "version sync writes a drifted netdata default, then no-ops" {
    # What: SOT moves ahead; sync must repair the file.
    # Why: sync is the only subcommand allowed to mutate.
    # From: Issue #1683 | PR #1858
    local root; root="$(_version_fixture_repo)"
    local m="${BATS_TEST_TMPDIR}/nd-sync.yml"
    sed 's/version: v2.11.0/version: v2.99.0/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" \
        run bash "${CI_SH}" version sync
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"changed=1"* ]]
    grep -qx 'ARG NETDATA_VERSION=v2.99.0' \
        "${root}/services/netdata/Dockerfile"
    local first; first="$(sha256sum "${root}/services/netdata/Dockerfile")"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" \
        run bash "${CI_SH}" version sync
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"changed=0"* ]]
    local second; second="$(sha256sum "${root}/services/netdata/Dockerfile")"
    [ "${first}" = "${second}" ]
}

@test "version sync fails loud on a non-canonical ARG line" {
    # What: Non-canonical ARG shape must fail (lowercase).
    # Why: Write regex must never claim false positive.
    # From: Issue #1683 | PR #1858
    local root; root="$(_version_fixture_repo)"
    sed -i 's/^ARG NETDATA_VERSION=/arg NETDATA_VERSION=/' \
        "${root}/services/netdata/Dockerfile"
    local m="${BATS_TEST_TMPDIR}/nd-noncanon.yml"
    sed 's/version: v2.11.0/version: v2.99.0/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    local before; before="$(sha256sum "${root}/services/netdata/Dockerfile")"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" \
        run bash "${CI_SH}" version sync
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0015"* ]]
    [[ "${output}" != *"changed=1"* ]]
    local after; after="$(sha256sum "${root}/services/netdata/Dockerfile")"
    [ "${before}" = "${after}" ]
}

@test "version sync touches only the three netdata ARG lines" {
    # What: every other Dockerfile line must survive sync.
    # Why: sync owns three values, never a broader rewrite.
    # From: Issue #1683 | PR #1858
    local root; root="$(_version_fixture_repo)"
    local m="${BATS_TEST_TMPDIR}/nd-scope.yml"
    sed 's/version: v2.11.0/version: v2.99.0/' \
        "${CI_MANIFEST_SOURCE}" > "${m}"
    local strip='/^ARG NETDATA_VERSION=/d;/^ARG NETDATA_X86_64_SHA256=/d;/^ARG NETDATA_AARCH64_SHA256=/d'
    local before after
    before="$(sed "${strip}" "${root}/services/netdata/Dockerfile")"
    CI_MANIFEST="${m}" CI_REPO_ROOT="${root}" \
        run bash "${CI_SH}" version sync
    [ "${status}" -eq 0 ]
    after="$(sed "${strip}" "${root}/services/netdata/Dockerfile")"
    [ "${before}" = "${after}" ]
}

@test "unknown version subcommand fails closed" {
    # What: an unrecognized 'version' verb must not succeed.
    # Why: fail-closed dispatch, like every other command.
    # From: Issue #1683 | PR #1858
    run bash "${CI_SH}" version bogus
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0014"* ]]
}

@test "_ci_dockerfile_arg_default reports ABSENT and BARE" {
    # What: a missing name vs. a defaultless declaration.
    # Why: the two must stay distinct, never conflated.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.shapes"
    printf 'FROM alpine\nARG BARE_ONE\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" NOT_THERE
    [ "${status}" -eq 0 ]
    [ "${output}" = "ABSENT" ]
    run _ci_dockerfile_arg_default "${f}" BARE_ONE
    [ "${status}" -eq 0 ]
    [ "${output}" = "BARE" ]
}

@test "_ci_dockerfile_arg_default reads quoted and bare values" {
    # What: unquoted, double- and single-quoted defaults.
    # Why: AG-VAL-036: the real ARG grammar has all three.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.quotes"
    printf 'FROM alpine\nARG A=1.2.3\nARG B="x y"\nARG C='"'"'q v'"'"'\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" A
    [ "${output}" = "FOUND:1.2.3" ]
    run _ci_dockerfile_arg_default "${f}" B
    [ "${output}" = "FOUND:x y" ]
    run _ci_dockerfile_arg_default "${f}" C
    [ "${output}" = "FOUND:q v" ]
}

@test "_ci_dockerfile_arg_default accepts real dhclient re-declares" {
    # What: build-tools re-declares DHCLIENT_VERSION twice.
    # Why: identical bare pre/post-FROM lines are valid.
    # From: Issue #1683 | PR #1858
    run _ci_dockerfile_arg_default \
        "${BATS_TEST_DIRNAME}/../../tools/build-tools/Dockerfile" \
        DHCLIENT_VERSION
    [ "${status}" -eq 0 ]
    [ "${output}" = "BARE" ]
}

@test "_ci_dockerfile_arg_default refuses conflicting re-declares" {
    # What: two ARG lines, one name, different defaults.
    # Why: AG-VAL-036: refuse to guess, escalate instead.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.conflict"
    printf 'FROM alpine\nARG X=1\nARG X=2\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" X
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0002"* ]]
}

@test "_ci_dockerfile_arg_default refuses unsupported shapes" {
    # What: a line-continuation and an unquoted space value.
    # Why: an unreadable shape must fail loud, never skip.
    # From: Issue #1683 | PR #1858
    local f="${BATS_TEST_TMPDIR}/Dockerfile.unsupported"
    printf 'FROM alpine\nARG A=abc\\\nARG B=has space\n' > "${f}"
    run _ci_dockerfile_arg_default "${f}" A
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0003"* ]]
    run _ci_dockerfile_arg_default "${f}" B
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"CI-ERROR-VERSION-0005"* ]]
}

# =========================================================
# HISTORICAL REGRESSIONS
# =========================================================

# What: Load setup.sh's real update-migration functions.
# Why: Test true migrate_env_for_update without sourcing setup.sh.
# From: Issue #1683 | PR #1546
_load_setup_update_helpers() {
    local repo_root="$1"
    local helper_file="${BATS_TEST_TMPDIR}/setup-update-helpers.sh"
    {
        printf '%s\n' 'die() { printf "%s\n" "$*" >&2; return 1; }'
        printf '%s\n' 'print_ok() { :; }'
        printf '%s\n' 'print_step() { :; }'
        printf '%s\n' 'print_warn() { :; }'
        printf '%s\n' 'DEFAULT_UI_SESSION_TTL_SECONDS=86400'
        printf '%s\n' 'MAX_UI_SESSION_TTL_SECONDS=31536000'
        printf 'SCRIPT_DIR=%q\n' "${repo_root}"
        awk '
            /^is_valid_ipv4\(\)/ { capture = 1 }
            /^# Backup\/restore may run on minimal hosts\./ { capture = 0 }
            capture { print }
        ' "${repo_root}/setup.sh"
    } > "${helper_file}"
    # shellcheck source=/dev/null
    source "${helper_file}"
}

# What: A fully-converged install .env, every key backfilled.
# Why: A missing key would fail the no-op test's first run.
# From: Issue #1683 | PR #1546
_write_converged_env_fixture() {
    printf '%s\n' \
        'IP_STANDARD=192.0.2.10' 'IP_SSL=192.0.2.11' 'SSL_ENABLED=1' \
        'DNS_XFR_NOTIFY_TARGETS=dns-ssl:5300' 'UI_SESSION_TTL_SECONDS=86400' \
        'LANCACHE_STATE_DIR=/opt/lancache-ng/state' 'CACHE_DIR=/opt/lancache-ng/cache' \
        'CACHE_MAX_SIZE=50g' 'CACHE_MAX_GB=50' 'CACHE_MEM_MB=512' 'CACHE_SLICE_SIZE=8m' \
        'CACHE_VALID_HIT=365d' 'CACHE_VALID_ANY=1m' 'CACHE_INACTIVE=365d' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' 'PROXY_SECURITY_MODE=lazy' \
        'NGINX_UPSTREAM_RESOLVER=8.8.8.8 8.8.4.4' 'LANCACHE_IMAGE_REGISTRY=ghcr.io' \
        'LANCACHE_IMAGE_PREFIX=wiki-mod/lancache-ng' 'LANCACHE_IMAGE_CHANNEL=pinned' \
        'LANCACHE_IMAGE_TAG=v0.2.0' 'UI_BIND_IP=192.0.2.10' 'DHCP_ENABLED=0' \
        'DHCP_MODE=disabled' 'DHCP_SUBNET=' 'DHCP_GATEWAY=' 'DHCP_RANGE_START=' \
        'DHCP_RANGE_END=' 'DHCP_SUBNET_START=' 'DHCP_DNS_PRIMARY=192.0.2.10' \
        'DHCP_DNS_SECONDARY=192.0.2.11' 'UPSTREAM_DHCP_IP=' 'DHCP_RELAY_LOCAL_ADDR=' \
        'DHCP_PROXY_INTERFACE=' 'DHCP_PROXY_ROUTER=' 'DHCP_NTP_SERVERS=' \
        'DHCP_PROXY_DOMAIN=' 'DHCP_PROXY_BOOT_FILENAME=' 'DHCP_PROXY_BOOT_SERVER=' \
        'DHCP_PROXY_CUSTOM_OPTIONS=' 'DHCP_PROXY_PXE_BOOT_SERVER=' \
        'DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=' 'DHCP_PROXY_PXE_BOOT_FILENAME_UEFI=' \
        'KEA_CTRL_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
        'DDNS_TSIG_KEY=YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYQ==' \
        'PDNS_API_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
        'NETDATA_ALARM_TOKEN=jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj' \
        'NATS_UI_USER=lancache-ui' \
        'NATS_UI_PASSWORD=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
        'NATS_DNS_WRITER_USER=lancache-dns-writer' \
        'NATS_DNS_WRITER_PASSWORD=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
        'NATS_DNS_REPLICA_USER=lancache-dns-replica' \
        'NATS_DNS_REPLICA_PASSWORD=gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg' \
        'NATS_CALLOUT_USER=lancache-nats-callout' \
        'NATS_CALLOUT_PASSWORD=hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh' \
        'NATS_SYS_USER=lancache-nats-sys' \
        'NATS_SYS_PASSWORD=iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii' \
        'SECONDARY_REGISTRATION_TOKEN=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
        'COMPOSE_PROFILES=ssl,logging' 'UI_AUTH_USER=admin' \
        'UI_AUTH_PASSWORD=RealAdminPassword123' 'ALLOW_INSECURE_UI=false' \
        'AUTO_UPDATE_ENABLED=0' 'NTP_ENABLED=0' 'LOGGING_ENABLED=1' \
        > "$1"
}

# What: An old install .env: split cache keys, strict mode.
# Why: Exercises the migration/converge path on first run.
# From: Issue #1683 | PR #1546
_write_legacy_env_fixture() {
    local env_file="$1" ui_auth_user="${2:-}"
    printf '%s\n' \
        'IP_STANDARD=192.0.2.20' 'IP_SSL=' 'CACHE_DIR_STANDARD=/srv/lancache/cache' \
        'CACHE_DIR_SSL=/srv/lancache/cache' 'PROXY_SECURITY_MODE=strict' \
        'PROXY_ALLOWED_CLIENT_CIDRS=' 'LANCACHE_IMAGE_TAG=v0.2.0' \
        "UI_AUTH_USER=${ui_auth_user}" 'UI_AUTH_PASSWORD=' \
        > "$env_file"
}

@test "migrate_env_for_update is a no-op on an already-converged .env" {
    # What: A converged .env stays byte-identical over two runs.
    # Why: AG-OP-006 idempotence; no rewrite on repeat update.
    # From: Issue #1683 | PR #1546
    local repo_root env_file oh h1 h2
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_converged_env_fixture "${env_file}"
    oh="$(sha256sum "${env_file}" | awk '{print $1}')"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    h1="$(sha256sum "${env_file}" | awk '{print $1}')"; [ "${oh}" = "${h1}" ]
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    h2="$(sha256sum "${env_file}" | awk '{print $1}')"; [ "${h1}" = "${h2}" ]
}

@test "migrate_env_for_update runs cleanly under set -u" {
    # What: A quickstart install must not trip nounset.
    # Why: Unset prodsync locals must stay guarded (AG-VAL-002).
    # From: Issue #1683 | PR #1546
    local repo_root env_file
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    set -u
    _write_converged_env_fixture "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
}

@test "migrate_env_for_update converges a legacy .env and is stable on rerun" {
    # What: Legacy keys migrate once, second run changes nothing.
    # Why: AG-OP-007 convergence; secrets must not rotate.
    # From: Issue #1683 | PR #1546
    local repo_root env_file a1 a2 s1 s2
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    run ! grep -q '^CACHE_DIR_STANDARD=' "${env_file}"
    run ! grep -q '^CACHE_DIR_SSL=' "${env_file}"
    grep -qx 'CACHE_DIR=/srv/lancache/cache' "${env_file}"
    grep -qx 'PROXY_SECURITY_MODE=lazy' "${env_file}"
    a1="$(cat "${env_file}")"
    s1="$(grep -E '^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NETDATA_ALARM_TOKEN|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|NATS_SYS_PASSWORD|SECONDARY_REGISTRATION_TOKEN)=' "${env_file}" | sort)"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    a2="$(cat "${env_file}")"
    s2="$(grep -E '^(KEA_CTRL_TOKEN|DDNS_TSIG_KEY|PDNS_API_KEY|NETDATA_ALARM_TOKEN|NATS_UI_PASSWORD|NATS_DNS_WRITER_PASSWORD|NATS_DNS_REPLICA_PASSWORD|NATS_CALLOUT_PASSWORD|NATS_SYS_PASSWORD|SECONDARY_REGISTRATION_TOKEN)=' "${env_file}" | sort)"
    [ "${a1}" = "${a2}" ]; [ "${s1}" = "${s2}" ]
}

@test "migrate_env_for_update generates a UI password once, never rotates it" {
    # What: The conditional UI-password branch runs once only.
    # Why: AG-OP-006 stable secrets on repeat execution.
    # From: Issue #1683 | PR #1546
    local repo_root env_file gp p2
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}" admin
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    grep -qx 'UI_AUTH_USER=admin' "${env_file}"
    gp="$(grep '^UI_AUTH_PASSWORD=' "${env_file}")"
    [ -n "${gp}" ]; [ "${gp}" != "UI_AUTH_PASSWORD=" ]
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    p2="$(grep '^UI_AUTH_PASSWORD=' "${env_file}")"; [ "${gp}" = "${p2}" ]
}

@test "migrate_env_for_update leaves no duplicate key assignments" {
    # What: Two runs must not stack duplicate key lines.
    # Why: set_env_key collapses duplicates (AG-OP-006).
    # From: Issue #1683 | PR #1546
    local repo_root env_file dup
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    dup="$(awk -F= '{print $1}' "${env_file}" | sort | uniq -d)"; [ -z "${dup}" ]
}

@test "migrate_env_for_update preserves a config/prod PXE value across two runs" {
    # What: A prod install backfills from config/prod, not .env.
    # Why: AG-OP-009 preservation; the confirmed #1546 bug.
    # From: Issue #1683 | PR #1546
    local repo_root env_file pd cd cpe
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    pd="${BATS_TEST_TMPDIR}/scratch/deploy/prod"; cd="${BATS_TEST_TMPDIR}/scratch/config/prod"
    mkdir -p "${pd}" "${cd}"; cpe="${cd}/dhcp-proxy.env"; env_file="${pd}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    printf '%s\n' 'DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9' 'DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0' > "${cpe}"
    run migrate_env_for_update "${pd}"; [ "${status}" -eq 0 ]
    grep -qx 'DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9' "${env_file}"
    grep -qx 'DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=real-pxelinux.0' "${env_file}"
    run migrate_env_for_update "${pd}"; [ "${status}" -eq 0 ]
    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "${cpe}"; [ "${output}" = "10.9.9.9" ]
    run get_env_var DHCP_PROXY_PXE_BOOT_FILENAME_BIOS "${cpe}"; [ "${output}" = "real-pxelinux.0" ]
}

@test "migrate_env_for_update preserves a direct config/prod edit after migration" {
    # What: A later config/prod edit wins over a stale .env dup.
    # Why: AG-OP-009 preserve existing operator values.
    # From: Issue #1683 | PR #1546
    local repo_root env_file pd cd cpe
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    pd="${BATS_TEST_TMPDIR}/scratch/deploy/prod"; cd="${BATS_TEST_TMPDIR}/scratch/config/prod"
    mkdir -p "${pd}" "${cd}"; cpe="${cd}/dhcp-proxy.env"; env_file="${pd}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    printf '%s\n' 'DHCP_PROXY_PXE_BOOT_SERVER=10.0.0.1' 'DHCP_PROXY_PXE_BOOT_FILENAME_BIOS=pxelinux.0' > "${cpe}"
    run migrate_env_for_update "${pd}"; [ "${status}" -eq 0 ]
    grep -qx 'DHCP_PROXY_PXE_BOOT_SERVER=10.0.0.1' "${env_file}"
    set_env_key DHCP_PROXY_PXE_BOOT_SERVER "10.0.0.2" "${cpe}"
    run migrate_env_for_update "${pd}"; [ "${status}" -eq 0 ]
    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "${cpe}"; [ "${output}" = "10.0.0.2" ]
}

@test "migrate_env_for_update tolerates an incomplete hand-edited PXE pair" {
    # What: A server value with no filename must not abort update.
    # Why: Hand-edited config/prod is never guaranteed complete.
    # From: Issue #1683 | PR #1546
    local repo_root env_file pd cd cpe
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    pd="${BATS_TEST_TMPDIR}/scratch/deploy/prod"; cd="${BATS_TEST_TMPDIR}/scratch/config/prod"
    mkdir -p "${pd}" "${cd}"; cpe="${cd}/dhcp-proxy.env"; env_file="${pd}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    printf '%s\n' 'DHCP_MODE=dnsmasq-proxy' 'DHCP_SUBNET_START=192.0.2.0' 'DHCP_DNS_PRIMARY=192.0.2.20' 'UPSTREAM_DHCP_IP=192.0.2.1' >> "${env_file}"
    printf '%s\n' 'DHCP_PROXY_PXE_BOOT_SERVER=10.9.9.9' > "${cpe}"
    run migrate_env_for_update "${pd}"; [ "${status}" -eq 0 ]
    run get_env_var DHCP_PROXY_PXE_BOOT_SERVER "${cpe}"; [ "${output}" = "10.9.9.9" ]
}

@test "migrate_env_for_update tolerates an invalid hand-edited value" {
    # What: A malformed value must not abort a working update.
    # Why: Hand-edited files need not satisfy stricter validation.
    # From: Issue #1683 | PR #1546
    local repo_root env_file pd cd cpe
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    pd="${BATS_TEST_TMPDIR}/scratch/deploy/prod"; cd="${BATS_TEST_TMPDIR}/scratch/config/prod"
    mkdir -p "${pd}" "${cd}"; cpe="${cd}/dhcp-proxy.env"; env_file="${pd}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    printf '%s\n' 'DHCP_MODE=dnsmasq-proxy' 'DHCP_SUBNET_START=192.0.2.0' 'DHCP_DNS_PRIMARY=192.0.2.20' 'UPSTREAM_DHCP_IP=192.0.2.1' >> "${env_file}"
    printf '%s\n' 'DHCP_PROXY_ROUTER=not-an-ip-address' > "${cpe}"
    run migrate_env_for_update "${pd}"; [ "${status}" -eq 0 ]
    run get_env_var DHCP_PROXY_ROUTER "${cpe}"; [ "${output}" = "not-an-ip-address" ]
}

@test "migrate_env_for_update preserves all custom per-service state dirs" {
    # What: every custom absolute per-service state dir survives.
    # Why: AG-OP-009 override preservation for all five keys.
    # From: Issue #1683 | PR #1858
    local repo_root env_file k
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_converged_env_fixture "${env_file}"
    for k in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        printf '%s=/custom/%s\n' "${k}" "${k}" >> "${env_file}"
    done
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    for k in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        grep -qx "${k}=/custom/${k}" "${env_file}"
    done
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    for k in PDNS_STANDARD_DIR PDNS_SSL_DIR PDNS_FILTER_STATE_DIR NATS_DATA_DIR NATS_CONF_DIR; do
        grep -qx "${k}=/custom/${k}" "${env_file}"
    done
}

@test "migrate_env_for_update drops a per-service state dir equal to the one-root default" {
    # What: a per-service dir equal to the derived default is dropped.
    # Why: one-root contract keeps LANCACHE_STATE_DIR the single source.
    # From: Issue #1683 | PR #1858
    local repo_root env_file
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_converged_env_fixture "${env_file}"
    printf 'NATS_CONF_DIR=/opt/lancache-ng/state/nats-conf\n' >> "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    run ! grep -q '^NATS_CONF_DIR=' "${env_file}"
}

@test "migrate_env_for_update writes LANCACHE_STATE_DIR on a legacy .env" {
    # What: the one-root key is present after migrating legacy state.
    # Why: LANCACHE_STATE_DIR is the single state-root contract.
    # From: Issue #1683 | PR #1858
    local repo_root env_file
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    env_file="${BATS_TEST_TMPDIR}/.env"
    _load_setup_update_helpers "${repo_root}"
    _write_legacy_env_fixture "${env_file}"
    run ! grep -q '^LANCACHE_STATE_DIR=' "${env_file}"
    run migrate_env_for_update "$(dirname "${env_file}")"; [ "${status}" -eq 0 ]
    grep -q '^LANCACHE_STATE_DIR=/' "${env_file}"
}

@test "production_state_root_default keeps deploy/prod state out of the checkout" {
    # What: a deploy/prod checkout defaults state off the checkout.
    # Why: runtime state must not live inside the git checkout.
    # From: Issue #1683 | PR #1858
    local repo_root root
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_update_helpers "${repo_root}"
    root="$(production_state_root_default /srv/checkout/deploy/prod)"
    [ -n "${root}" ]
    [ "${root}" != "/srv/checkout/deploy/prod" ]
    [ "$(production_state_root_default /var/lib/lancache)" = "/var/lib/lancache" ]
}

@test "runtime_env_file_for_install_dir prefers deploy/prod/.env.local when present" {
    # What: deploy/prod uses .env.local override when it exists.
    # Why: a git pull must not clobber operator prod values.
    # From: Issue #1683 | PR #1858
    local repo_root dp
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_update_helpers "${repo_root}"
    dp="${BATS_TEST_TMPDIR}/deploy/prod"
    mkdir -p "${dp}"
    [ "$(runtime_env_file_for_install_dir "${dp}")" = "${dp}/.env" ]
    : > "${dp}/.env.local"
    [ "$(runtime_env_file_for_install_dir "${dp}")" = "${dp}/.env.local" ]
    [ "$(runtime_env_file_for_install_dir /var/lib/lancache)" = "/var/lib/lancache/.env" ]
}

@test "deploy_prod_repo_input_paths snapshots repo-root runtime inputs for deploy/prod" {
    # What: deploy/prod backup captures ../../ repo-root inputs.
    # Why: rollback must restore the full manual prod config.
    # From: Issue #1683 | PR #1858
    local repo_root rr dp
    repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    _load_setup_update_helpers "${repo_root}"
    rr="${BATS_TEST_TMPDIR}/checkout"
    dp="${rr}/deploy/prod"
    mkdir -p "${dp}" "${rr}/certs" "${rr}/config/prod" "${rr}/services/dns" \
        "${rr}/scripts/untracked" "${rr}/scripts/lib"
    : > "${rr}/services/dns/cdn-domains.txt"
    : > "${rr}/scripts/untracked/docker-socket-proxy.sh"
    : > "${rr}/scripts/lib/shared-secret-bootstrap.sh"
    run deploy_prod_repo_input_paths "${dp}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"/certs"* ]]
    [[ "${output}" == *"/config/prod"* ]]
    [[ "${output}" == *"cdn-domains.txt"* ]]
    [[ "${output}" == *"docker-socket-proxy.sh"* ]]
    [[ "${output}" == *"shared-secret-bootstrap.sh"* ]]
    run deploy_prod_repo_input_paths /var/lib/lancache
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}
