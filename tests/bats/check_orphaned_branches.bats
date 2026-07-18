#!/usr/bin/env bats
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
#
# Coverage for scripts/check-orphaned-branches.sh (#990, AG-GH-017's
# automated companion guard). Branch age/exclusion logic is exercised
# against a REAL fixture git repository with controlled commit timestamps
# (via GIT_COMMITTER_DATE/GIT_AUTHOR_DATE), not a mocked git -- git's own
# for-each-ref is cheap, deterministic, and exactly what the script under
# test calls, so there is no reason to fake it. The GitHub API surface
# (pull-request lookup, open-issue listing, issue-comment listing) IS mocked
# via a `curl` stand-in placed ahead of the real one on PATH, following
# tests/bats/check_action_node_versions.bats's established pattern: no live
# call to api.github.com, fully offline and deterministic.
#
# The mock's fixture key is derived from the request's URL path (after
# https://api.github.com/) plus every --data-urlencode value it was given,
# sorted -- mock_curl_response() below computes the identical key so a test
# only has to say "this path with these params returns this status/body"
# without needing to hand-encode a URL.
#
# One thing this suite deliberately does NOT attempt: a live end-to-end run
# against the real wiki-mod/lancache-ng repository and its real remote
# branches/issues/PRs. That was verified manually instead (see this PR's own
# body/closing report) -- a fixture repo cannot stand in for "does this
# correctly flag the real bughunt-* branches that motivated #990 in the first
# place," and a live run isn't reproducible or safe to wire into a bats
# suite that other contributors' CI runs will also execute.

setup() {
    script="$BATS_TEST_DIRNAME/../../scripts/check-orphaned-branches.sh"
    fixture_repo="$BATS_TEST_TMPDIR/fixture-repo"
    mock_bin_dir="$BATS_TEST_TMPDIR/mock-bin"
    mock_fixtures_dir="$BATS_TEST_TMPDIR/mock-curl-fixtures"

    mkdir -p "$fixture_repo" "$mock_bin_dir" "$mock_fixtures_dir"

    git -C "$fixture_repo" init --quiet --initial-branch=master
    git -C "$fixture_repo" config user.email "test@example.invalid"
    git -C "$fixture_repo" config user.name "Test Author"

    # A mock `curl` standing in for the real binary. It recognizes only the
    # -G/--data-urlencode/-o/-w shape this script's curl invocations use,
    # derives a fixture key from the URL path plus sorted data-urlencode
    # values, and serves back whatever mock_curl_response() registered for
    # that key -- or a synthetic 404-shaped empty-array response for
    # anything unregistered, so an unexpected extra page/call fails loudly
    # via an assertion instead of hanging or crashing.
    cat > "$mock_bin_dir/curl" <<'MOCKCURL'
#!/usr/bin/env bash
set -euo pipefail
out_file=""
url=""
data=()
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
        -o) out_file="${args[$((i + 1))]}"; i=$((i + 2)) ;;
        --data-urlencode) data+=("${args[$((i + 1))]}"); i=$((i + 2)) ;;
        -H|-w) i=$((i + 2)) ;;
        -sS|-G) i=$((i + 1)) ;;
        *) url="${args[$i]}"; i=$((i + 1)) ;;
    esac
done
path="${url#https://api.github.com/}"
sorted_data="$(printf '%s\n' "${data[@]:-}" | sort | tr '\n' '_')"
key="$(printf '%s|%s' "$path" "$sorted_data" | tr -c 'A-Za-z0-9' '_')"
fixture_file="${MOCK_CURL_FIXTURES:?MOCK_CURL_FIXTURES not set}/$key"
if [ ! -f "$fixture_file" ]; then
    printf '[]' > "$out_file"
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
    # Unset first so a real CI environment's own GITHUB_TOKEN (routinely
    # present in an Actions job) can never leak into a test that expects a
    # controlled, mocked token -- same precaution
    # check_action_node_versions.bats takes.
    unset GH_TOKEN GITHUB_TOKEN
    export REPO="wiki-mod/lancache-ng"
    export GH_TOKEN="fake-token-for-tests"
    export REF_PREFIX="refs/heads"
    export SLEEP_BETWEEN_CALLS="0"
}

# mock_curl_response <url-path-after-api.github.com/> <data-urlencode-params...> -- <status> <body>
# Registers the canned response for one API call. Params are every
# --data-urlencode value the real script passes (e.g. "state=all"), in any
# order -- this helper sorts them the same way the mock curl does, so a test
# doesn't need to match the script's exact argument order.
mock_curl_response() {
    local path="$1"; shift
    local params=()
    while [ "$1" != "--" ]; do
        params+=("$1")
        shift
    done
    shift # consume --
    local status="$1" body="$2"
    local sorted_data
    sorted_data="$(printf '%s\n' "${params[@]:-}" | sort | tr '\n' '_')"
    local key
    key="$(printf '%s|%s' "$path" "$sorted_data" | tr -c 'A-Za-z0-9' '_')"
    {
        printf '%s\n' "$status"
        printf '%s\n' "$body"
    } > "$mock_fixtures_dir/$key"
}

# make_branch_at_age <branch> <seconds-old> [message]
# Creates (or updates) a branch in the fixture repo whose tip commit's
# committer/author date is exactly <seconds-old> seconds before "now".
make_branch_at_age() {
    local branch="$1" seconds_old="$2"
    local message="${3:-commit on $branch}"
    local epoch safe_name
    epoch=$(($(date -u +%s) - seconds_old))
    # Branch names in these tests contain slashes (e.g. feat/foo), which are
    # real path separators inside a filename -- sanitize before using the
    # branch name as part of a file path, or e.g. "feat/foo" would require a
    # "file-feat/" directory that doesn't exist.
    safe_name="${branch//\//_}"
    git -C "$fixture_repo" checkout --quiet -B "$branch"
    echo "content for $branch at $seconds_old" > "$fixture_repo/file-$safe_name.txt"
    git -C "$fixture_repo" add "file-$safe_name.txt"
    GIT_COMMITTER_DATE="@$epoch +0000" GIT_AUTHOR_DATE="@$epoch +0000" \
        git -C "$fixture_repo" commit --quiet -m "$message"
}

# mock_no_pr <branch>
# Registers an empty pulls-list result (page 1) for <branch> -- the "NO_PR"
# path used by tests that need to reach the issue-reference check.
mock_no_pr() {
    local branch="$1"
    mock_curl_response "repos/wiki-mod/lancache-ng/pulls" \
        "head=wiki-mod:${branch}" "state=all" "per_page=100" "page=1" \
        -- 200 '[]'
}

# mock_has_pr <branch>
# Registers a non-empty pulls-list result for <branch>.
mock_has_pr() {
    local branch="$1"
    mock_curl_response "repos/wiki-mod/lancache-ng/pulls" \
        "head=wiki-mod:${branch}" "state=all" "per_page=100" "page=1" \
        -- 200 '[{"number": 1, "state": "closed"}]'
}

# mock_open_issues <json-array>
# Registers page 1 of the open-issues listing.
mock_open_issues() {
    mock_curl_response "repos/wiki-mod/lancache-ng/issues" \
        "state=open" "per_page=100" "page=1" \
        -- 200 "$1"
}

# mock_issue_comments <issue-number> <json-array>
mock_issue_comments() {
    local issue_number="$1" body="$2"
    mock_curl_response "repos/wiki-mod/lancache-ng/issues/${issue_number}/comments" \
        "per_page=100" "page=1" \
        -- 200 "$body"
}

@test "excludes master, badges, and release-glob branches regardless of age" {
    make_branch_at_age "master" 7200
    make_branch_at_age "badges" 7200
    make_branch_at_age "v0.2.0" 7200
    make_branch_at_age "feat/genuinely-orphaned" 7200
    mock_no_pr "feat/genuinely-orphaned"
    mock_open_issues '[]'

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" != *"'master'"* ]]
    [[ "$output" != *"'badges'"* ]]
    [[ "$output" != *"'v0.2.0'"* ]]
    [[ "$output" == *"feat/genuinely-orphaned"* ]]
}

@test "excludes a branch younger than the 1-hour default threshold" {
    make_branch_at_age "master" 7200
    make_branch_at_age "feat/too-new" 600

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" != *"feat/too-new"* ]]
}

@test "does not report a branch that has an open, closed, or merged pull request" {
    make_branch_at_age "master" 7200
    make_branch_at_age "feat/has-a-pr" 7200
    mock_has_pr "feat/has-a-pr"

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Orphaned branch detected: 'feat/has-a-pr'"* ]]
}

@test "does not report a branch named in an open issue's body" {
    make_branch_at_age "master" 7200
    make_branch_at_age "feat/named-in-body" 7200
    mock_no_pr "feat/named-in-body"
    mock_open_issues '[{"number": 100, "body": "Tracked under branch feat/named-in-body for follow-up."}]'
    mock_issue_comments 100 '[]'

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Orphaned branch detected: 'feat/named-in-body'"* ]]
}

@test "does not report a branch named only in an issue comment, not the body" {
    make_branch_at_age "master" 7200
    make_branch_at_age "feat/named-in-comment" 7200
    mock_no_pr "feat/named-in-comment"
    mock_open_issues '[{"number": 101, "body": "Unrelated body text."}]'
    mock_issue_comments 101 '[{"body": "Pushed this as feat/named-in-comment, see there."}]'

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Orphaned branch detected: 'feat/named-in-comment'"* ]]
}

@test "ignores an issues-endpoint entry that is actually an open PR (carries pull_request key)" {
    make_branch_at_age "master" 7200
    make_branch_at_age "feat/only-mentioned-in-a-pr" 7200
    mock_no_pr "feat/only-mentioned-in-a-pr"
    # The /issues endpoint returns PRs too; an entry with a pull_request key
    # must be filtered out of the reference corpus even though its body
    # mentions the branch -- otherwise an open PR unrelated to AG-GH-017's
    # "issue comment" traceability requirement would incorrectly save an
    # actually-untracked branch from being reported.
    mock_open_issues '[{"number": 102, "body": "See feat/only-mentioned-in-a-pr", "pull_request": {"url": "https://api.github.com/repos/wiki-mod/lancache-ng/pulls/102"}}]'

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Orphaned branch detected: 'feat/only-mentioned-in-a-pr'"* ]]
}

@test "reports a genuinely orphaned branch with its last-commit date and author" {
    make_branch_at_age "master" 7200
    make_branch_at_age "bughunt-example" 7200
    mock_no_pr "bughunt-example"
    mock_open_issues '[]'

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" == *"::warning::"* ]]
    [[ "$output" == *"Orphaned branch detected: 'bughunt-example'"* ]]
    [[ "$output" == *"Test Author"* ]]
    [[ "$output" == *"::notice::"*"1 orphaned branch"* ]]
}

@test "treats an unresolvable pull-request lookup as unverifiable, not orphaned" {
    make_branch_at_age "master" 7200
    make_branch_at_age "feat/rate-limited-lookup" 7200
    mock_curl_response "repos/wiki-mod/lancache-ng/pulls" \
        "head=wiki-mod:feat/rate-limited-lookup" "state=all" "per_page=100" "page=1" \
        -- 403 '{"message": "API rate limit exceeded"}'

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Orphaned branch detected: 'feat/rate-limited-lookup'"* ]]
    [[ "$output" == *"could not determine whether branch 'feat/rate-limited-lookup' has a pull request"* ]]
}

@test "suppresses all orphan reporting when the open-issues listing itself fails" {
    make_branch_at_age "master" 7200
    make_branch_at_age "feat/would-be-orphaned" 7200
    mock_no_pr "feat/would-be-orphaned"
    mock_curl_response "repos/wiki-mod/lancache-ng/issues" \
        "state=open" "per_page=100" "page=1" \
        -- 500 '{"message": "Internal Server Error"}'

    run bash "$script" "$fixture_repo"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Orphaned branch detected:"* ]]
    [[ "$output" == *"could not list open issues"* ]]
    [[ "$output" == *"incomplete run"* ]]
}

@test "fails closed when REPO is not set" {
    unset REPO
    make_branch_at_age "master" 7200

    run bash "$script" "$fixture_repo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REPO is required"* ]]
}

@test "fails closed when no GitHub token is available" {
    unset GH_TOKEN GITHUB_TOKEN
    make_branch_at_age "master" 7200

    run bash "$script" "$fixture_repo"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GH_TOKEN or GITHUB_TOKEN is required"* ]]
}

@test "skips a remote's symbolic HEAD ref instead of treating it as a phantom branch" {
    # refs/remotes/origin/HEAD only exists for an actual remote-tracking
    # setup, not a plain refs/heads fixture -- build a real bare "remote" and
    # clone it so git itself creates the symref, exactly as a real CI
    # checkout would after `git fetch origin '+refs/heads/*:refs/remotes/origin/*'`.
    local bare_remote="$BATS_TEST_TMPDIR/bare-remote.git"
    local clone_dir="$BATS_TEST_TMPDIR/clone-repo"
    git init --quiet --bare --initial-branch=master "$bare_remote"
    git -C "$fixture_repo" remote add temp-origin "$bare_remote" 2>/dev/null || true

    make_branch_at_age "master" 7200
    make_branch_at_age "bughunt-via-remote" 7200
    git -C "$fixture_repo" push --quiet temp-origin master bughunt-via-remote

    git clone --quiet "$bare_remote" "$clone_dir"

    REF_PREFIX="refs/remotes/origin" REMOTE_NAME="origin"
    export REF_PREFIX REMOTE_NAME
    mock_no_pr "bughunt-via-remote"
    mock_open_issues '[]'
    # Deliberately NOT mocking a pulls-lookup response for "origin" (the
    # phantom name this script would derive from refs/remotes/origin/HEAD if
    # the HEAD-skip check failed to catch it -- see this script's own header
    # comment on Step 1 for why %(refname:short) alone is not a safe check).
    # If the skip regresses, the unmocked call falls through the mock
    # curl's default (status 000) into a LOOKUP_FAILED warning naming
    # "origin" -- asserted against explicitly below, not left to chance.

    run bash "$script" "$clone_dir"
    [ "$status" -eq 0 ]
    [[ "$output" != *"'HEAD'"* ]]
    [[ "$output" != *"'origin'"* ]]
    [[ "$output" == *"Orphaned branch detected: 'bughunt-via-remote'"* ]]
    # Exactly master + bughunt-via-remote were scanned -- if the HEAD symref
    # slipped through as a phantom third branch, this count would be 3.
    [[ "$output" == *"(2 total remote branch(es) scanned)"* ]]
}
