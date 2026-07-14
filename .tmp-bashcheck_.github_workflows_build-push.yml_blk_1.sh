set -euo pipefail

: "${BASE_SHA:?pull request base SHA is required}"
: "${GITHUB_SHA:?GitHub checkout SHA is required}"

# BASE_SHA is the base branch's CURRENT tip at run time, not the
# commit this PR branch actually forked from. A plain two-dot
# `git diff BASE_SHA GITHUB_SHA` between two independently-moved
# branches shows the union of everything different between those
# two snapshots -- including files an unrelated, already-merged PR
# changed on the base branch after this branch forked, which then
# gets misattributed as "this PR changed it" and defeats path
# scoping for every job below (confirmed real occurrence: #536).
# Diffing from the actual merge-base instead of BASE_SHA directly
# fixes that; actions/checkout above already runs with
# fetch-depth: 0, so merge-base has the full history it needs.
merge_base="$(git merge-base "$BASE_SHA" "$GITHUB_SHA")"
changed_files="$(mktemp)"
git diff --name-only "$merge_base" "$GITHUB_SHA" > "$changed_files"
printf 'Changed files:\n'
cat "$changed_files"

touches_prefix() {
  local prefix="$1" path
  while IFS= read -r path; do
    [[ "$path" == "$prefix"* ]] && return 0
  done < "$changed_files"
  return 1
}

touches_exact() {
  local expected="$1" path
  while IFS= read -r path; do
    [[ "$path" == "$expected" ]] && return 0
  done < "$changed_files"
  return 1
}

touches_docs() {
  local path
  while IFS= read -r path; do
    case "$path" in
      *.md|docs/*)
        return 0
        ;;
    esac
  done < "$changed_files"
  return 1
}

docs_only=true
any_changed=false
while IFS= read -r path; do
  any_changed=true
  case "$path" in
    *.md|docs/*)
      ;;
    *)
      docs_only=false
      ;;
  esac
done < "$changed_files"
if [ "$any_changed" = "false" ]; then
  docs_only=false
fi

output_bool() {
  local name="$1"
  shift
  if "$@"; then
    printf '%s=true\n' "$name"
  else
    printf '%s=false\n' "$name"
  fi
}

{
  output_bool "dns_rust" touches_prefix "services/dns/nats-subscriber/"
  output_bool "dns_image" touches_prefix "services/dns/"
  output_bool "ui" touches_prefix "services/ui/"
  output_bool "watchdog" touches_prefix "services/watchdog/"
  output_bool "dhcp" touches_prefix "services/dhcp/"
  output_bool "dhcp_proxy" touches_prefix "services/dhcp-proxy/"
  # services/proxy/Dockerfile COPYs services/dns/cdn-domains.txt
  # into the image at build time (the dns-domains named build
  # context), so a domain-list-only change must also rebuild the
  # proxy image or its baked-in /etc/nginx/cdn-domains.txt goes
  # stale until some unrelated services/proxy/ change next fires
  # (#771). Added in addition to (not instead of) the
  # services/proxy/ prefix check in the first condition below, and
  # the separate dns_image rule just above.
  if touches_prefix "services/proxy/" \
    || touches_exact "services/dns/cdn-domains.txt"; then
    echo "proxy=true"
  else
    echo "proxy=false"
  fi
  output_bool "build_tools" touches_prefix "tools/build-tools/"
  if touches_exact ".github/workflows/build-push.yml" \
    || touches_exact ".github/workflows/build-tools.yml" \
    || touches_prefix ".github/actions/"; then
    echo "workflow=true"
  else
    echo "workflow=false"
  fi
  output_bool "docs" touches_docs
  printf 'docs_only=%s\n' "$docs_only"
  if touches_exact "AGENTS.md" || touches_exact ".github/AGENTS.md"; then
    echo "governance=true"
  else
    echo "governance=false"
  fi
  if touches_exact "setup.sh" || touches_prefix "scripts/"; then
    echo "setup_runtime=true"
  else
    echo "setup_runtime=false"
  fi
  output_bool "deploy" touches_prefix "deploy/"
  if touches_prefix "release/" || touches_exact ".github/workflows/backfill-stack-latest.yml"; then
    echo "release_contract=true"
  else
    echo "release_contract=false"
  fi
  output_bool "scripts" touches_prefix "scripts/"
} >> "$GITHUB_OUTPUT"

