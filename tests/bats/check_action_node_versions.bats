#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-action-node-versions.sh (#801): the CI guard
# that fails a build if any pinned GitHub Action -- local composite or
# external, resolved via the GitHub Contents API -- declares a deprecated
# Node runtime in its own action.yml/action.yaml.
#
# This builds a small fixture repo (a fake .github/workflows + .github/actions
# tree) and a mock `curl` binary placed ahead of the real one on PATH, so
# every scenario runs fully offline and deterministically -- no live call to
# api.github.com, and no dependency on what any real action currently
# declares. The mock maps a request URL to a canned (HTTP status, body) pair
# read from a small per-test fixtures directory; see mock_curl_response()
# below for how a test registers one.
#
# One scenario (the "would this have caught #799" one) deliberately uses the
# real owner/repo/ref/action.yml content #799 involved
# (actions/upload-artifact@834a144ee995460fba8ed112a2fc961b36a5ec5a's actual
# pre-fix `runs.using: node20`, confirmed live against the GitHub API while
# building this guard) -- not a synthetic node20 example -- so this test
# suite itself is the permanent regression check that the guard would have
# caught the exact problem #799 reported, without needing a one-off manual
# verification step that leaves no trace once this PR merges.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-action-node-versions.sh"
    fixture_root="$BATS_TEST_TMPDIR/fixture-repo"
    mock_bin_dir="$BATS_TEST_TMPDIR/mock-bin"
    mock_fixtures_dir="$BATS_TEST_TMPDIR/mock-curl-fixtures"

    mkdir -p "$fixture_root/.github/workflows"
    mkdir -p "$mock_bin_dir"
    mkdir -p "$mock_fixtures_dir"

    # A mock `curl` standing in for the real binary: it recognizes only the
    # GitHub Contents API shape this script generates (a `-o <file>` output
    # target, an `Accept` header, and a trailing URL), maps the URL to a
    # canned response registered by mock_curl_response() below, writes the
    # canned body to the `-o` target, and prints the canned status code to
    # stdout the same way `curl -w '%{http_code}'` would.
    cat > "$mock_bin_dir/curl" <<'MOCKCURL'
#!/usr/bin/env bash
set -euo pipefail
out_file=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = "-o" ]; then
        out_file="${args[$((i + 1))]}"
    fi
done
url="${args[-1]}"
key=$(printf '%s' "$url" | sed -E 's#^https://api\.github\.com/repos/##' | tr '/?&=' '____')
fixture_file="${MOCK_CURL_FIXTURES:?MOCK_CURL_FIXTURES not set}/$key"
if [ ! -f "$fixture_file" ]; then
    printf '000'
    exit 0
fi
status_line=$(head -n1 "$fixture_file")
tail -n +2 "$fixture_file" > "$out_file"
printf '%s' "$status_line"
MOCKCURL
    chmod +x "$mock_bin_dir/curl"

    export PATH="$mock_bin_dir:$PATH"
    export MOCK_CURL_FIXTURES="$mock_fixtures_dir"
    unset GH_TOKEN GITHUB_TOKEN
}

# mock_curl_response <owner/repo> <ref> <subpath-or-empty> <file> <status> <body>
# Registers the canned response for one action.yml/action.yaml lookup,
# keyed exactly the way the mock curl above derives its lookup key from the
# real script's generated URL -- kept as a single helper so the URL-shape
# knowledge lives in one place instead of being hand-duplicated per test.
mock_curl_response() {
    local owner_repo="$1" ref="$2" subpath="$3" file="$4" status="$5" body="$6"
    local key="${owner_repo}_contents_${subpath:+${subpath}_}${file}_ref_${ref}"
    key="${key//\//_}"
    {
        printf '%s\n' "$status"
        printf '%s\n' "$body"
    } > "$mock_fixtures_dir/$key"
}

write_workflow() {
    cat > "$fixture_root/.github/workflows/ci.yml"
}

@test "passes when every pinned action (local and external) reports a current Node runtime" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
      - uses: ./.github/actions/my-composite
EOF
    mkdir -p "$fixture_root/.github/actions/my-composite"
    cat > "$fixture_root/.github/actions/my-composite/action.yml" <<'EOF'
name: My composite
runs:
  using: composite
  steps:
    - run: echo hi
      shell: bash
EOF
    mock_curl_response "actions/checkout" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "" "action.yml" 200 \
"name: Checkout
runs:
  using: 'node24'
  main: 'dist/index.js'"

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "fails on the exact pre-#800 actions/upload-artifact@834a144... pin (the #799 regression)" {
    # Real owner/repo/ref/content from before PR #800's fix -- this is the
    # permanent proof that this guard would have caught #799.
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: actions/upload-artifact@834a144ee995460fba8ed112a2fc961b36a5ec5a # v4.3.6
EOF
    mock_curl_response "actions/upload-artifact" "834a144ee995460fba8ed112a2fc961b36a5ec5a" "" "action.yml" 200 \
"name: 'Upload a Build Artifact'
runs:
  using: 'node20'
  main: 'dist/upload/index.js'"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"actions/upload-artifact@834a144ee995460fba8ed112a2fc961b36a5ec5a"* ]]
    [[ "$output" == *"node20"* ]]
}

@test "passes on the real #800/#802 replacement pins (v7.0.1/v8.0.1, both node24)" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
EOF
    mock_curl_response "actions/upload-artifact" "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a" "" "action.yml" 200 \
"runs:
  using: 'node24'"
    mock_curl_response "actions/download-artifact" "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c" "" "action.yml" 200 \
"runs:
  using: 'node24'"

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
}

@test "resolves a subpath action (github/codeql-action/analyze) against the right nested action.yml" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: github/codeql-action/analyze@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v4
EOF
    mock_curl_response "github/codeql-action" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "analyze" "action.yml" 200 \
"runs:
  using: 'node16'"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"github/codeql-action/analyze@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"* ]]
    [[ "$output" == *"node16"* ]]
}

@test "falls back to action.yaml when action.yml 404s" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: someorg/some-action@cccccccccccccccccccccccccccccccccccccccc # v1
EOF
    mock_curl_response "someorg/some-action" "cccccccccccccccccccccccccccccccccccccccc" "" "action.yml" 404 ""
    mock_curl_response "someorg/some-action" "cccccccccccccccccccccccccccccccccccccccc" "" "action.yaml" 200 \
"runs:
  using: 'node20'"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"someorg/some-action@cccccccccccccccccccccccccccccccccccccccc"* ]]
    [[ "$output" == *"node20"* ]]
}

@test "fails closed when both action.yml and action.yaml are genuinely 404" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: someorg/broken-action@dddddddddddddddddddddddddddddddddddddddd # v1
EOF
    mock_curl_response "someorg/broken-action" "dddddddddddddddddddddddddddddddddddddddd" "" "action.yml" 404 ""
    mock_curl_response "someorg/broken-action" "dddddddddddddddddddddddddddddddddddddddd" "" "action.yaml" 404 ""

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not find action.yml or action.yaml"* ]]
}

@test "warns (does not fail) on a rate-limit/infra response instead of a definitive 404" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: someorg/rate-limited-action@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee # v1
EOF
    mock_curl_response "someorg/rate-limited-action" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" "" "action.yml" 403 ""

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"infrastructure hiccup"* ]]
    # Regression check: the HTTP status must actually reach the warning
    # message. An earlier version of fetch_external_action_yaml tried to
    # report it via a global variable set from inside a function that is
    # only ever invoked through command substitution (a subshell) -- the
    # variable never made it back to the caller, so the message printed an
    # empty status every time. Asserting the real status code here would
    # have caught that.
    [[ "$output" == *"HTTP 403"* ]]
}

@test "fails when a local composite action is referenced but has no action.yml/action.yaml" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: ./.github/actions/missing-composite
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"./.github/actions/missing-composite"* ]]
    [[ "$output" == *"has no action.yml/action.yaml"* ]]
}

@test "fails when a local action declares a deprecated Node runtime" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: ./.github/actions/legacy-js-action
EOF
    mkdir -p "$fixture_root/.github/actions/legacy-js-action"
    cat > "$fixture_root/.github/actions/legacy-js-action/action.yml" <<'EOF'
name: Legacy
runs:
  using: node12
  main: index.js
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"./.github/actions/legacy-js-action"* ]]
    [[ "$output" == *"node12"* ]]
}

@test "reports every bad pin in one run, not just the first" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: actions/upload-artifact@834a144ee995460fba8ed112a2fc961b36a5ec5a # v4.3.6
      - uses: actions/download-artifact@ffffffffffffffffffffffffffffffffffffffff # v4.3.0
EOF
    mock_curl_response "actions/upload-artifact" "834a144ee995460fba8ed112a2fc961b36a5ec5a" "" "action.yml" 200 \
"runs:
  using: 'node20'"
    mock_curl_response "actions/download-artifact" "ffffffffffffffffffffffffffffffffffffffff" "" "action.yml" 200 \
"runs:
  using: 'node20'"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"actions/upload-artifact@834a144ee995460fba8ed112a2fc961b36a5ec5a"* ]]
    [[ "$output" == *"actions/download-artifact@ffffffffffffffffffffffffffffffffffffffff"* ]]
    [[ "$output" == *"2 pinned action(s)"* ]]
}

@test "does not mistake an embedded 'uses:' string inside a run: shell block for a real step" {
    # build-push.yml's own CI-scope-policy guard greps for the literal text
    # 'uses: ./.github/actions/rust-acceleration-preflight' as part of an
    # unrelated check -- that occurrence must not be misparsed as a real
    # step directive by this script.
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
      - name: Embedded guard
        run: |
          grep -F 'uses: ./.github/actions/rust-acceleration-preflight' some-workflow.yml
EOF
    mock_curl_response "actions/checkout" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "" "action.yml" 200 \
"runs:
  using: 'node24'"

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" != *"rust-acceleration-preflight"* ]]
}
