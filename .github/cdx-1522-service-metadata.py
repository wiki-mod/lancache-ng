#!/usr/bin/env python3
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later

from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {count}")
    return text.replace(old, new, 1)


# --- build-push.yml ---------------------------------------------------------
build_path = Path('.github/workflows/build-push.yml')
build = build_path.read_text(encoding='utf-8')

build = replace_once(
    build,
    'env:\n  CARGO_BUILD_JOBS: ${{ vars.CARGO_BUILD_JOBS }}\n  DOCKER_METADATA_SHORT_SHA_LENGTH: "7"\n',
    'env:\n  CARGO_BUILD_JOBS: ${{ vars.CARGO_BUILD_JOBS }}\n'
    '  # One runtime list for manifest assembly, promotion, and release loops.\n'
    '  # scripts/check-workflow-service-lists.sh keeps it equal to the build matrix.\n'
    '  CI_BUILD_SERVICES: "proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools"\n'
    '  DOCKER_METADATA_SHORT_SHA_LENGTH: "7"\n',
    'workflow runtime service list',
)

matrix_start = build.index('        include: &normal-build-services\n')
matrix_end = build.index('\n    steps:\n', matrix_start)
matrix = build[matrix_start:matrix_end]

descriptions = {
    'proxy': 'nginx-based lancache-ng caching proxy for standard and TLS-interception cache traffic.',
    'dns': 'PowerDNS recursor, authoritative DNS, and NATS subscriber service for lancache-ng cache routing.',
    'watchdog': 'lancache-ng watchdog helper for runtime health checks and recovery hooks.',
    'dhcp': 'Kea DHCP, control-agent, and DHCP-DDNS service for lancache-ng managed networks.',
    'dhcp-proxy': 'dnsmasq-based DHCP proxy and relay helper for lancache-ng deployments.',
    'ntp': 'chrony-based NTP server for lancache-ng, disciplined against public NTP servers and serving LAN clients on UDP/123.',
    'syslog': 'Combined fluent-bit + syslog-ng first-party central logging service for lancache-ng (issue #1428).',
    'ui': 'lancache-ng Admin UI and control-plane service for cache, DNS, DHCP, and secondary management.',
    'build-tools': 'Prebuilt lancache-ng CI and developer validation toolchain image.',
}

for service, description in descriptions.items():
    old = f'            description: {description}\n'
    new = f'            description: &ci-description-{service} "{description}"\n'
    if matrix.count(old) != 1:
        raise SystemExit(f'matrix description for {service}: expected once, got {matrix.count(old)}')
    matrix = matrix.replace(old, new, 1)

build = build[:matrix_start] + matrix + build[matrix_end:]

full_list = '          services=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools)\n'
full_list_count = build.count(full_list)
if full_list_count != 4:
    raise SystemExit(f'full runtime services arrays: expected 4, got {full_list_count}')
build = build.replace(full_list, '          read -ra services <<< "$CI_BUILD_SERVICES"\n')

trusted_start = build.index('      - name: Create multi-platform manifests\n')
trusted_run = build.index('        run: |\n', trusted_start)
trusted_prefix = build[trusted_start:trusted_run]
needle = '          GHCR_RETRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}\n'
if trusted_prefix.count(needle) != 1:
    raise SystemExit('trusted manifest env insertion point is not unique')
alias_env = ''.join(
    f'          DESCRIPTION_{service.upper().replace("-", "_")}: *ci-description-{service}\n'
    for service in descriptions
)
trusted_prefix = trusted_prefix.replace(needle, needle + alias_env, 1)
build = build[:trusted_start] + trusted_prefix + build[trusted_run:]

map_start = build.index('          # Same wording as this same file\'s build/build-arm64 matrix.description entries --', trusted_run)
map_end = build.index('          # Duplicated rather than factored into a shared script/action:', map_start)
new_map = '''          # These aliases come from the canonical build-matrix description scalars above.\n          declare -A service_descriptions=(\n            [proxy]="$DESCRIPTION_PROXY"\n            [dns]="$DESCRIPTION_DNS"\n            [watchdog]="$DESCRIPTION_WATCHDOG"\n            [dhcp]="$DESCRIPTION_DHCP"\n            [dhcp-proxy]="$DESCRIPTION_DHCP_PROXY"\n            [ntp]="$DESCRIPTION_NTP"\n            [syslog]="$DESCRIPTION_SYSLOG"\n            [ui]="$DESCRIPTION_UI"\n            [build-tools]="$DESCRIPTION_BUILD_TOOLS"\n          )\n\n'''
build = build[:map_start] + new_map + build[map_end:]

if build.count('services=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools)') != 0:
    raise SystemExit('duplicate full service array remains in build-push.yml')
if build.count('read -ra services <<< "$CI_BUILD_SERVICES"') != 4:
    raise SystemExit('expected four runtime consumers of CI_BUILD_SERVICES')
for service in descriptions:
    if build.count(f'&ci-description-{service}') != 1:
        raise SystemExit(f'description anchor count for {service} is not one')
    if build.count(f'*ci-description-{service}') != 1:
        raise SystemExit(f'description alias count for {service} is not one')

build_path.write_text(build, encoding='utf-8')

# --- hosted fallback --------------------------------------------------------
fallback_path = Path('.github/workflows/build-push-hosted-fallback.yml')
fallback = fallback_path.read_text(encoding='utf-8')

fallback = replace_once(
    fallback,
    '''          # This overflow workflow carries build-specific metadata in addition\n          # to the canonical service names from release/stack-images.yml. Keep\n          # this table aligned with build-push.yml; scripts/check-workflow-\n          # service-lists.sh verifies the service-set side of that contract.\n          declare -A contexts=(\n''',
    '''          # This separate workflow mirrors build-specific metadata from build-push.yml.\n          # The service-list guard compares the service set and metadata against that matrix.\n          services=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools)\n          declare -A contexts=(\n''',
    'fallback metadata preamble',
)

fallback = replace_once(
    fallback,
    '[ntp]="NTP service for lancache-ng managed networks."',
    '[ntp]="chrony-based NTP server for lancache-ng, disciplined against public NTP servers and serving LAN clients on UDP/123."',
    'fallback ntp description',
)
fallback = replace_once(
    fallback,
    '[syslog]="Syslog collection and forwarding service for lancache-ng deployments."',
    '[syslog]="Combined fluent-bit + syslog-ng first-party central logging service for lancache-ng (issue #1428)."',
    'fallback syslog description',
)
fallback = replace_once(
    fallback,
    '            selected=(proxy dns watchdog dhcp dhcp-proxy ntp syslog ui build-tools)\n',
    '            selected=("${services[@]}")\n',
    'fallback all-services selection',
)
fallback = replace_once(
    fallback,
    '              echo "::error::Unknown service \'$svc\'. Valid services: ${!contexts[*]}."\n',
    '              echo "::error::Unknown service \'$svc\'. Valid services: ${services[*]}."\n',
    'fallback deterministic valid-service message',
)

fallback_path.write_text(fallback, encoding='utf-8')

# --- service-list / metadata guard -----------------------------------------
guard_path = Path('scripts/check-workflow-service-lists.sh')
guard = guard_path.read_text(encoding='utf-8')

header_start = guard.index('# CI guard against')
header_end = guard.index('set -euo pipefail\n')
guard = guard[:header_start] + '''# CI guard for service-set and build-metadata drift.\n# The normal build matrix is canonical. Runtime service loops, Hosted Fallback,\n# GC/backfill helpers, and Full-Setup subsets must stay consistent with it.\n# Deliberate subsets are checked against explicit exclusion sets so dropping a\n# real service cannot pass merely because the shorter list is still a subset.\n''' + guard[header_end:]

guard = replace_once(
    guard,
    '''    extra_files=(\n        "scripts/gc-pr-staging-images.sh"\n        ".github/workflows/backfill-stack-latest.yml"\n        "scripts/ensure-pr-staging-images.sh"\n    )\n''',
    '''    extra_files=(\n        ".github/workflows/build-push-hosted-fallback.yml"\n        "scripts/gc-pr-staging-images.sh"\n        ".github/workflows/backfill-stack-latest.yml"\n        "scripts/ensure-pr-staging-images.sh"\n    )\n''',
    'guard default files',
)

canonical_marker = "canonical_oneline=$(printf '%s' \"$canonical\" | tr '\\n' ' ')\n"
if guard.count(canonical_marker) != 1:
    raise SystemExit('canonical_oneline marker not unique')
runtime_check = r'''
# build-push.yml uses one workflow-level runtime list for its shell loops.
# Older/synthetic fixtures may still use services=(...) directly, so the guard
# supports both shapes and fails closed if the runtime list diverges.
workflow_services_requirement="required"
mapfile -t workflow_service_entries < <(grep -nE '^  CI_BUILD_SERVICES:[[:space:]]*' "$workflow" || true)
if [[ ${#workflow_service_entries[@]} -gt 1 ]]; then
    fail "multiple CI_BUILD_SERVICES declarations found in $workflow; expected one maintained runtime list."
elif [[ ${#workflow_service_entries[@]} -eq 1 ]]; then
    entry=${workflow_service_entries[0]}
    content=${entry#*:}
    value=${content#*:}
    value="$(xargs <<<"$value")"
    value=${value#\"}
    value=${value%\"}
    runtime_services=$(printf '%s\n' "$value" | tr ' ' '\n' | sed '/^$/d' | sort -u)
    if [[ "$runtime_services" != "$canonical" ]]; then
        fail "CI_BUILD_SERVICES in $workflow diverges from the build matrix."
        printf "    expected: %s\n" "$canonical_oneline" >&2
        printf "    found:    %s\n" "$(printf '%s' "$runtime_services" | tr '\n' ' ')" >&2
    fi
    workflow_services_requirement="optional"
fi
'''
guard = guard.replace(canonical_marker, canonical_marker + runtime_check, 1)

metadata_functions = r'''
# Extract one field from the anchored normal-build matrix. The matrix values in
# this workflow are scalar strings; description anchors are stripped before
# comparison because the alias name is YAML structure, not metadata content.
extract_matrix_metadata() {
    local field="$1"
    awk -v field="$field" '
        /^[[:space:]]+include: &normal-build-services[[:space:]]*$/ { inside=1; next }
        inside && /^    steps:[[:space:]]*$/ { exit }
        inside && /^[[:space:]]+- service:[[:space:]]*/ {
            line=$0
            sub(/^[[:space:]]+- service:[[:space:]]*/, "", line)
            service=line
            next
        }
        inside && service != "" {
            prefix="^[[:space:]]+" field ":[[:space:]]*"
            if ($0 ~ prefix) {
                line=$0
                sub(prefix, "", line)
                sub(/^&[^[:space:]]+[[:space:]]+/, "", line)
                if (line ~ /^\".*\"$/) {
                    sub(/^\"/, "", line)
                    sub(/\"$/, "", line)
                }
                print service "\t" line
            }
        }
    ' "$workflow" | sort
}

# Extract service-keyed values from one associative array in Hosted Fallback.
extract_fallback_metadata() {
    local file="$1" array_name="$2"
    awk -v array_name="$array_name" '
        $0 ~ "^[[:space:]]*declare -A " array_name "=\\($" { inside=1; next }
        inside && /^[[:space:]]*\)[[:space:]]*$/ { exit }
        inside && /^[[:space:]]*\[[a-z0-9-]+\]=/ {
            line=$0
            sub(/^[[:space:]]*\[/, "", line)
            split_at=index(line, "]=")
            service=substr(line, 1, split_at - 1)
            value=substr(line, split_at + 2)
            sub(/^\"/, "", value)
            sub(/\"$/, "", value)
            print service "\t" value
        }
    ' "$file" | sort
}

check_hosted_fallback_metadata() {
    local file="$1" field array_name expected found
    local -a pairs=(
        "context:contexts"
        "build_contexts:build_contexts"
        "description:descriptions"
    )

    for pair in "${pairs[@]}"; do
        field=${pair%%:*}
        array_name=${pair#*:}
        expected="$(extract_matrix_metadata "$field")"
        found="$(extract_fallback_metadata "$file" "$array_name")"
        if [[ -z "$expected" ]]; then
            fail "could not extract '$field' metadata from the anchored build matrix in $workflow."
            continue
        fi
        if [[ "$found" != "$expected" ]]; then
            fail "$array_name metadata in $file diverges from build-push.yml's normal-build matrix."
        fi
    done
}

'''
metadata_insert = guard.index('# Files where full_setup_services=(...) must equal canonical minus a KNOWN,')
guard = guard[:metadata_insert] + metadata_functions + guard[metadata_insert:]

guard = replace_once(
    guard,
    '''declare -A REQUIRES_SERVICES_ARRAY=(\n    ["gc-pr-staging-images.sh"]=1\n    ["backfill-stack-latest.yml"]=1\n)\n''',
    '''declare -A REQUIRES_SERVICES_ARRAY=(\n    ["build-push-hosted-fallback.yml"]=1\n    ["gc-pr-staging-images.sh"]=1\n    ["backfill-stack-latest.yml"]=1\n)\n''',
    'guard required services files',
)

guard = replace_once(
    guard,
    'check_services_arrays "$workflow" "required"\n',
    'check_services_arrays "$workflow" "$workflow_services_requirement"\n',
    'guard workflow runtime shape',
)

loop_marker = '''    check_full_setup_arrays "$file" "$full_setup_requirement"\ndone\n'''
loop_replacement = '''    check_full_setup_arrays "$file" "$full_setup_requirement"\n\n    if [[ "$file_basename" == "build-push-hosted-fallback.yml" ]]; then\n        check_hosted_fallback_metadata "$file"\n    fi\ndone\n'''
guard = replace_once(guard, loop_marker, loop_replacement, 'fallback metadata guard call')

guard = guard.replace(
    "printf \"%b✗ %d service-list divergence(s) found.%b Keep every services=(...)/full_setup_services=(...) copy in sync with the build matrix; see issue #822.\\n\"",
    "printf \"%b✗ %d service-list/metadata divergence(s) found.%b Keep runtime service metadata in sync with the build matrix.\\n\"",
    1,
)
guard = guard.replace(
    'printf "%b✓ All checked service lists are consistent with the build matrix (%s).%b\\n"',
    'printf "%b✓ All checked service lists and metadata are consistent with the build matrix (%s).%b\\n"',
    1,
)

guard_path.write_text(guard, encoding='utf-8')

# --- bats coverage ----------------------------------------------------------
test_path = Path('tests/bats/check_workflow_service_lists.bats')
tests = test_path.read_text(encoding='utf-8')

comment_start = tests.index('# Coverage for')
comment_end = tests.index('setup() {\n')
tests = tests[:comment_start] + '''# Coverage for scripts/check-workflow-service-lists.sh: canonical matrix, runtime\n# service lists, deliberate subsets, and Hosted Fallback metadata drift. Synthetic\n# fixtures keep failure modes isolated; the final test also checks the real tree.\n''' + tests[comment_end:]

tests = replace_once(
    tests,
    '    ensure_fixture="$BATS_TEST_TMPDIR/ensure-pr-staging-images.sh"\n',
    '    ensure_fixture="$BATS_TEST_TMPDIR/ensure-pr-staging-images.sh"\n'
    '    hosted_fixture="$BATS_TEST_TMPDIR/build-push-hosted-fallback.yml"\n',
    'hosted fixture setup',
)

# Bring the synthetic canonical set up to the real nine-service matrix.
tests = replace_once(
    tests,
    '          - service: ntp\n          - service: ui\n',
    '          - service: ntp\n          - service: syslog\n          - service: ui\n',
    'synthetic syslog matrix row',
)

lines = []
for line in tests.splitlines(keepends=True):
    if 'services=(' in line and 'ntp' in line and 'ui' in line and 'syslog' not in line:
        line = line.replace('ntp ui', 'ntp syslog ui')
    lines.append(line)
tests = ''.join(lines)
tests = tests.replace('all eight real services', 'all nine real services')
tests = tests.replace('full 8-service set', 'full 9-service set')

metadata_tests = r'''

write_metadata_matrix_source() {
    cat <<'EOF'
jobs:
  build:
    strategy:
      matrix:
        include: &normal-build-services
          - service: proxy
            context: services/proxy
            build_contexts: dns-domains=services/dns
            description: &ci-description-proxy "Proxy description."
          - service: ntp
            context: services/ntp
            build_contexts: ""
            description: &ci-description-ntp "NTP description."
    steps: []
          services=(proxy ntp)
EOF
}

write_good_hosted_metadata() {
    cat > "$hosted_fixture" <<'EOF'
services=(proxy ntp)
declare -A contexts=(
  [proxy]=services/proxy
  [ntp]=services/ntp
)
declare -A build_contexts=(
  [proxy]="dns-domains=services/dns"
  [ntp]=""
)
declare -A descriptions=(
  [proxy]="Proxy description."
  [ntp]="NTP description."
)
EOF
}

@test "hosted fallback metadata passes when it matches the anchored build matrix" {
    write_metadata_matrix_source > "$fixture"
    write_good_hosted_metadata

    run bash "$script" "$fixture" "$hosted_fixture"
    [ "$status" -eq 0 ]
    [[ "$output" == *"consistent"* ]]
}

@test "hosted fallback metadata fails when a description drifts from the build matrix" {
    write_metadata_matrix_source > "$fixture"
    write_good_hosted_metadata
    sed -i 's/NTP description\./Drifted NTP description./' "$hosted_fixture"

    run bash "$script" "$fixture" "$hosted_fixture"
    [ "$status" -ne 0 ]
    [[ "$output" == *"descriptions metadata"* ]]
    [[ "$output" == *"diverges"* ]]
}
'''
if 'hosted fallback metadata passes when it matches' in tests:
    raise SystemExit('metadata tests already present unexpectedly')
tests += metadata_tests

test_path.write_text(tests, encoding='utf-8')
