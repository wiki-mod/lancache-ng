#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Drift guard (issue #1091) for the three compose `dhcp` service healthchecks'
# KEA_CTRL_TOKEN placeholder detection. Each healthcheck must decide "is the
# compose-injected KEA_CTRL_TOKEN still a placeholder that the entrypoint would
# have discarded in favour of the shared-secret file?" using the SAME rule the
# entrypoint actually applies (services/dhcp/entrypoint.sh's KEA_CTRL_TOKEN
# resolution: secret_is_placeholder()'s lowercase + "-"/"_" normalization, plus
# the three exact legacy literals). Before #1091 the three healthchecks each
# hand-rolled a different, weaker case pattern, so an operator whose placeholder
# value was case/dash-varied got a permanently `unhealthy` container while Kea
# ran fine on the real, shared-secret-resolved token. This test fails loudly if
# the three ever diverge again or drift from secret_is_placeholder's verdict --
# the same class of guard tests/bats/shared_secret_bootstrap_sync.bats provides
# for the bash-side embedded copies.

setup() {
    repo_root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    compose_files=(
        "$repo_root/deploy/dev/docker-compose.yml"
        "$repo_root/deploy/prod/docker-compose.yml"
        "$repo_root/deploy/quickstart/docker-compose.yml"
    )
    fixture="$repo_root/tests/fixtures/placeholder-detection-cases.txt"
}

# extract_detection <compose-file>
# Prints the dhcp healthcheck's placeholder-detection statements: the lines from
# the KEA_CTRL_TOKEN assignment through the legacy-literal case (everything that
# can empty $token), with leading whitespace stripped and compose's `$$`
# unescaped to a single `$` for a real shell. The shared-secret-file read line
# is deliberately excluded so classification depends only on the detection, not
# on the presence of a filesystem path.
extract_detection() {
    awk '
        /token="\$\$\{KEA_CTRL_TOKEN/ { capture = 1 }
        capture { sub(/^[[:space:]]+/, ""); gsub(/\$\$/, "$"); print }
        /lancache-dhcp-prod-secret/ { capture = 0 }
    ' "$1"
}

# classify <detection-snippet> <token-value>
# Runs the extracted detection with KEA_CTRL_TOKEN set to the given value and
# reports whether it emptied $token ("placeholder") or left it intact ("real").
classify() {
    local snippet="$1" value="$2" token
    token="$(KEA_CTRL_TOKEN="$value" sh -c "$snippet"$'\nprintf "%s" "${token:-}"')"
    if [ -z "$token" ]; then printf placeholder; else printf real; fi
}

# The three healthchecks must be byte-identical in their detection logic --
# divergence between them is exactly the #1091 bug.
@test "all three dhcp healthchecks share an identical placeholder-detection fragment" {
    reference="$(extract_detection "${compose_files[0]}")"
    [ -n "$reference" ]
    for f in "${compose_files[@]}"; do
        run extract_detection "$f"
        [ "$output" = "$reference" ]
    done
}

# The extracted, real healthcheck fragment must agree with secret_is_placeholder
# (the fixture's first verdict column) on every case this project tracks --
# proving the healthcheck normalizes the same way the entrypoint does. The
# fixture contains no dhcp legacy literals, so healthcheck verdict == column 1
# for every row here.
@test "healthcheck detection matches secret_is_placeholder over the shared fixture" {
    snippet="$(extract_detection "${compose_files[0]}")"
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        value="$(printf '%s\n' "$line" | awk '{print $1}')"
        expected="$(printf '%s\n' "$line" | awk '{print $2}')"
        got="$(classify "$snippet" "$value")"
        [ "$got" = "$expected" ] || {
            echo "value=$value healthcheck=$got secret_is_placeholder=$expected"
            false
        }
    done < "$fixture"
}

# The three legacy KEA_CTRL_TOKEN literals are a dhcp-specific extra the
# entrypoint discards (they are not part of secret_is_placeholder's pattern set
# and so are not in the fixture), so they get their own assertion.
@test "healthcheck detects the three legacy KEA_CTRL_TOKEN literals as placeholders" {
    snippet="$(extract_detection "${compose_files[0]}")"
    for lit in lancache-dhcp-secret lancache-dhcp-dev-secret lancache-dhcp-prod-secret; do
        [ "$(classify "$snippet" "$lit")" = placeholder ]
    done
}

# deploy/dev/.env ships a real, intentional dev secret whose "-change-me"
# INFIX must not be mistaken for a "change_me" PREFIX -- exactly the case
# secret_is_placeholder() is documented to keep as real, and which the fixed
# healthcheck must also keep as real.
@test "healthcheck keeps dev's real KEA_CTRL_TOKEN value real" {
    snippet="$(extract_detection "${compose_files[0]}")"
    [ "$(classify "$snippet" "lancache-dev-kea-control-token-change-me")" = real ]
}
