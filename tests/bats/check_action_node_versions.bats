#!/usr/bin/env bats
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Coverage for scripts/tracked/check-action-node-versions.sh (#801): the CI guard
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
    script="$BATS_TEST_DIRNAME/../../scripts/tracked/check-action-node-versions.sh"
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
    # Single attempt, no backoff: this test asserts the eventual-give-up
    # warning path, not the retry loop itself (see the dedicated retry test
    # below) -- keep it fast and independent of the real retry count/timing.
    export GHCR_RETRY_MAX_ATTEMPTS=1

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

@test "retries a transient rate-limit/infra response and recovers on a later attempt" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: someorg/flaky-then-ok-action@ffffffffffffffffffffffffffffffffffffffff # v1
EOF
    # A call-counting mock curl: first call for this exact URL returns 403,
    # every call after that returns 200 with a real action.yml body -- proves
    # the retry loop actually re-issues the request (not just re-reads a
    # static fixture) and recovers instead of giving up on the first
    # transient failure, per AG-CI-013.
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
counter_file="${MOCK_CURL_CALL_COUNTS:?MOCK_CURL_CALL_COUNTS not set}/$key"
count=0
[ -f "$counter_file" ] && count=$(cat "$counter_file")
count=$((count + 1))
printf '%s' "$count" > "$counter_file"
if [ "$count" -eq 1 ]; then
    printf '' > "$out_file"
    printf '403'
else
    printf 'runs:\n  using: node24\n' > "$out_file"
    printf '200'
fi
MOCKCURL
    chmod +x "$mock_bin_dir/curl"
    mkdir -p "$BATS_TEST_TMPDIR/mock-curl-call-counts"
    export MOCK_CURL_CALL_COUNTS="$BATS_TEST_TMPDIR/mock-curl-call-counts"
    export GHCR_RETRY_MAX_ATTEMPTS=3
    export GHCR_RETRY_BACKOFF_SECONDS=0

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" != *"infrastructure hiccup"* ]]
    [[ "$output" != *"Could not find action.yml or action.yaml"* ]]
}

@test "does not retry a permanent 401/400/422 response, even with retries available" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: someorg/bad-token-action@1111111111111111111111111111111111111111 # v1
EOF
    # A call-counting mock curl always returning 401: proves the permanent-
    # failure classification stops ghcr_retry immediately (GHCR_RETRY_MAX_ATTEMPTS
    # set well above 1) instead of burning the whole retry budget on a token
    # that will never suddenly start working -- the actual regression this
    # AGENTS.md (AG-CI-013) finding was about.
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
counter_file="${MOCK_CURL_CALL_COUNTS:?MOCK_CURL_CALL_COUNTS not set}/$key"
count=0
[ -f "$counter_file" ] && count=$(cat "$counter_file")
count=$((count + 1))
printf '%s' "$count" > "$counter_file"
printf '' > "$out_file"
printf '401'
MOCKCURL
    chmod +x "$mock_bin_dir/curl"
    mkdir -p "$BATS_TEST_TMPDIR/mock-curl-call-counts"
    export MOCK_CURL_CALL_COUNTS="$BATS_TEST_TMPDIR/mock-curl-call-counts"
    export GHCR_RETRY_MAX_ATTEMPTS=5
    export GHCR_RETRY_BACKOFF_SECONDS=0

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"infrastructure hiccup"* ]]
    [[ "$output" == *"HTTP 401"* ]]

    local_key="someorg_bad-token-action_contents_action.yml_ref_1111111111111111111111111111111111111111"
    call_count=$(cat "$BATS_TEST_TMPDIR/mock-curl-call-counts/$local_key")
    [ "$call_count" -eq 1 ]
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

@test "skips a job-level reusable-workflow reference instead of treating it as a missing local action" {
    # A `uses: ./.github/workflows/<wf>.yml` at job level is a reusable-workflow
    # call, not a composite action: it points at a workflow FILE, not a
    # directory holding an action.yml, and has no runs.using to check. The
    # reusable workflow file itself is scanned directly (it lives under
    # .github/workflows), so skipping the reference loses no coverage. Before
    # this was handled, the script misread the `./`-prefixed value as a local
    # action and failed on a missing action.yml -- issue #1014 introduced the
    # repo's first local reusable workflow and surfaced exactly that.
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  call-reusable:
    uses: ./.github/workflows/reusable.yml
EOF
    # The referenced reusable workflow must exist as a real file so the scan of
    # workflow_files includes it; it declares no external `uses:` of its own.
    cat > "$fixture_root/.github/workflows/reusable.yml" <<'EOF'
name: Reusable
on:
  workflow_call:
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
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

@test "fails when one file repeats the exact same third-party action ref literally" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
EOF
    mock_curl_response "actions/checkout" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "" "action.yml" 200 \
"runs:
  using: 'node24'"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"repeats third-party action ref"* ]]
    [[ "$output" == *"actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]]
}

@test "fails when one third-party action key drifts to multiple refs across .github" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
      - uses: actions/checkout@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # v7.0.1
EOF
    mock_curl_response "actions/checkout" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "" "action.yml" 200 \
"runs:
  using: 'node24'"
    mock_curl_response "actions/checkout" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "" "action.yml" 200 \
"runs:
  using: 'node24'"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is pinned to multiple refs across .github/**"* ]]
    [[ "$output" == *"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]]
    [[ "$output" == *"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"* ]]
}

@test "passes when one file centralizes a repeated third-party ref via YAML anchor and alias" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: &checkout_centraliced_versioning actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
      - uses: *checkout_centraliced_versioning # v7.0.0
EOF
    mock_curl_response "actions/checkout" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "" "action.yml" 200 \
"runs:
  using: 'node24'"

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "passes when a composite action.yml repeats the same literal third-party ref (anchors don't load there, Issue #1095 F-24)" {
    # Confirmed live (F-24, PR #1665): the Actions Runner's composite-action
    # loader hard-fails on a YAML anchor/alias inside action.yml -- unlike a
    # workflow file, where the previous test above proves the collapse is
    # both possible and required. A repeated literal ref inside a composite
    # action.yml is therefore the correct, GitHub-imposed shape, not a
    # duplication violation, and must not fail this check the way the
    # equivalent workflow-file case above correctly does.
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: ./.github/actions/retry-wrapper
EOF
    mkdir -p "$fixture_root/.github/actions/retry-wrapper"
    cat > "$fixture_root/.github/actions/retry-wrapper/action.yml" <<'EOF'
name: Retry wrapper
runs:
  using: composite
  steps:
    - id: attempt1
      uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
      continue-on-error: true
    - id: attempt2
      if: steps.attempt1.outcome == 'failure'
      uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
EOF
    mock_curl_response "actions/checkout" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "" "action.yml" 200 \
"runs:
  using: 'node24'"

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" != *"repeats third-party action ref"* ]]
}

@test "fails on the exact #1095 literal-expression-in-description bug (folded block scalar)" {
    # Verbatim reproduction of the real broken description: body that failed
    # every build/build-arm64 job with "Unrecognized named-value: 'github'".
    # The manifest template validator evaluates a description: body even when
    # it is pure documentation prose, so this must fail the guard rather than
    # be waved through as harmless text. Folded (>-) block scalar specifically:
    # that is the shape the real incident used, and a naive same-line-only
    # scan would miss it entirely.
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: ./.github/actions/trivy-centralized
EOF
    mkdir -p "$fixture_root/.github/actions/trivy-centralized"
    cat > "$fixture_root/.github/actions/trivy-centralized/action.yml" <<'EOF'
name: Centralized trivy
inputs:
  trivy-config:
    description: >-
      Absolute path to a trivy-config.yaml. Must be computed by the caller
      as ${{ github.action_path }}/trivy-config.yaml against the CALLER's
      own action_path.
    required: false
    default: ""
runs:
  using: composite
  steps:
    - run: echo hi
      shell: bash
EOF

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"description: field contains GitHub Actions expression syntax"* ]]
}

@test "passes on prose-only description text, and ignores expressions in YAML comments and runs: steps" {
    # The valid-case half of the guard: the post-fix wording must not trip it,
    # and neither may the two places a literal expression is genuinely correct.
    # A YAML '#' comment is never template-evaluated, so it is the recommended
    # home for a note that needs to show the real syntax -- a guard that
    # flagged it would push authors away from the one safe place to explain
    # this. Expressions under runs: are ordinary required interpolation.
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: ./.github/actions/trivy-centralized
EOF
    mkdir -p "$fixture_root/.github/actions/trivy-centralized"
    cat > "$fixture_root/.github/actions/trivy-centralized/action.yml" <<'EOF'
name: Centralized trivy
# Callers pass ${{ github.action_path }}/trivy-config.yaml from their own
# action_path; safe to write literally here because comments are not
# template-evaluated.
inputs:
  trivy-config:
    description: >-
      Absolute path to a trivy-config.yaml. Must be computed by the caller
      as its own github dot action_path joined with trivy-config.yaml.
    required: false
    default: ""
  scan-type:
    description: Scan type passed straight through to trivy-action.
    required: false
    default: ""
runs:
  using: composite
  steps:
    - run: echo "${{ inputs.trivy-config }} ${{ inputs.scan-type }}"
      shell: bash
EOF

    run "$script" "$fixture_root"
    [ "$status" -eq 0 ]
    [[ "$output" != *"description: field contains"* ]]
}

# What: an unresolved alias isn't a pinned-action failure.
# Why: the summary must not conflate the two failure kinds.
# From: Issue #1095 | PR #1734
@test "an extraction-only failure (unresolved alias) is not mislabeled as a pinned-action failure" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: *never_defined_anchor
      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa # v7.0.0
EOF
    mock_curl_response "actions/checkout" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "" "action.yml" 200 \
"runs:
  using: 'node24'"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 extraction problem(s)"* ]]
    [[ "$output" != *"pinned action(s)"* ]]
}

@test "a mixed run counts extraction and pinned-action failures separately, not combined" {
    write_workflow <<'EOF'
name: CI
on: push
jobs:
  build:
    steps:
      - uses: *never_defined_anchor
      - uses: actions/upload-artifact@ffffffffffffffffffffffffffffffffffffffff # v4.3.0
EOF
    mock_curl_response "actions/upload-artifact" "ffffffffffffffffffffffffffffffffffffffff" "" "action.yml" 200 \
"runs:
  using: 'node20'"

    run "$script" "$fixture_root"
    [ "$status" -ne 0 ]
    [[ "$output" == *"1 pinned action(s) or manifest field(s) failed"* ]]
    [[ "$output" == *"1 extraction problem(s)"* ]]
}
