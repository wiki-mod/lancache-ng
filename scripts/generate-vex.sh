#!/usr/bin/env bash
# lancache-ng (https://github.com/wiki-mod/lancache-ng)
# Generates an OpenVEX (https://openvex.dev) JSON document from the accepted-
# vulnerability records in .trivyignore.yaml, so that downstream consumers get
# a standard, portable VEX statement for every vulnerability this project has
# assessed and deliberately suppressed in its own scanning -- rather than only
# the Trivy-specific ignore-list format, which non-Trivy tooling cannot parse
# (OSPS-VM-04.02).
#
# WHY OpenVEX (not CycloneDX VEX): OpenVEX is a self-contained, standalone JSON
# document that references CVEs directly and needs no surrounding CycloneDX BOM
# to be valid, which makes it both trivially assembled here with jq and
# trivially consumed downstream (e.g. `trivy --vex`, `vexctl`). CycloneDX VEX
# would have to be embedded in or cross-referenced against a CycloneDX BOM,
# which is more machinery for no gain for this small, controlled ignore list.
#
# WHY status "affected" (not "not_affected"): each .trivyignore.yaml entry is a
# record that a vulnerable component IS present and the finding is being
# accepted/deferred (typically because no fixed upstream version exists to bump
# to yet), NOT a claim that the vulnerable code is unreachable. The honest
# OpenVEX mapping for "present, accepted, awaiting a fix" is `affected` with an
# `action_statement`, never `not_affected` (which would require a real
# non-exploitability justification the ignore-list entries do not assert). If a
# future entry genuinely represents non-exploitability, its VEX status mapping
# must be revisited here rather than blanket-applied.
#
# Parsing approach mirrors scripts/validate-stack-images.sh: a targeted awk
# reader for this project's own small, controlled YAML schema (no yq/PyYAML
# dependency), with jq doing all JSON assembly and escaping. Output is written
# to stdout.
#
# Determinism: the document timestamp comes from $VEX_TIMESTAMP when set, else
# the current UTC time. The committed vex.openvex.json and its CI drift check
# (scripts/check-vex-drift.sh) rely on $VEX_TIMESTAMP to reproduce a byte-stable
# document, so the only thing that changes the document is a real change to
# .trivyignore.yaml, never the wall clock.
set -euo pipefail

trivyignore="${1:-.trivyignore.yaml}"

# Product identifier for the OpenVEX statements. The .trivyignore.yaml entries
# bind a CVE to file paths, not to a specific first-party image, so the honest
# granularity is the project's released-image namespace as the product, with
# the reported file paths recorded as subcomponents.
product_id="pkg:github/wiki-mod/lancache-ng"
vex_author="lancache-ng release automation (https://github.com/wiki-mod/lancache-ng)"
vex_context="https://openvex.dev/ns/v0.2.0"

timestamp="${VEX_TIMESTAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

if [ ! -f "$trivyignore" ]; then
  echo "error: '$trivyignore' not found" >&2
  exit 1
fi

# awk emits one TAB-delimited record per accepted-vulnerability entry:
#   <id> \t <expired_at> \t <statement> \t <path1>|<path2>|...
# The folded '>-' statement scalar is reassembled by joining its continuation
# lines with single spaces (reproducing YAML folded-scalar semantics). Paths
# and ids never contain a TAB or '|', so those delimiters are safe here.
parsed="$(
  awk '
    function flush() {
      if (have_entry) {
        gsub(/^ +| +$/, "", stmt)
        printf "%s\t%s\t%s\t%s\n", id, expiry, stmt, paths
      }
      have_entry=0; id=""; expiry=""; stmt=""; paths=""; mode=""
    }
    {
      match($0, /^ */); indent=RLENGTH
      rest=substr($0, indent+1)
    }
    rest == "" { next }
    rest ~ /^#/ { next }
    indent == 0 { next }
    # New entry: "  - id: <cve>"
    indent == 2 && rest ~ /^- id:/ {
      flush()
      have_entry=1
      v=rest; sub(/^- id:[ \t]*/, "", v); id=v
      mode=""
      next
    }
    indent == 4 && rest ~ /^paths:/ { mode="paths"; next }
    indent == 4 && rest ~ /^statement:/ {
      mode="statement"
      v=rest; sub(/^statement:[ \t]*/, "", v)
      # Drop a folded/literal block indicator (">", ">-", "|", "|-", ...); keep
      # a genuine inline scalar value if one was given on the same line.
      if (v ~ /^[>|][+-]?[ \t]*$/) { v="" }
      stmt=v
      next
    }
    indent == 4 && rest ~ /^expired_at:/ {
      v=rest; sub(/^expired_at:[ \t]*/, "", v)
      gsub(/^"|"$/, "", v); expiry=v; mode=""
      next
    }
    mode == "paths" && indent == 6 && rest ~ /^- / {
      v=rest; sub(/^-[ \t]*/, "", v)
      gsub(/^"|"$/, "", v)
      if (paths == "") { paths=v } else { paths=paths "|" v }
      next
    }
    mode == "statement" && indent >= 6 {
      if (stmt == "") { stmt=rest } else { stmt=stmt " " rest }
      next
    }
    END { flush() }
  ' "$trivyignore"
)"

statements="[]"
while IFS=$'\t' read -r id exp stmt paths_joined; do
  [ -n "$id" ] || continue

  if [ -n "$paths_joined" ]; then
    subcomponents="$(
      printf '%s\n' "$paths_joined" \
        | tr '|' '\n' \
        | jq -R 'select(length > 0) | {"@id": .}' \
        | jq -s '.'
    )"
  else
    subcomponents='[]'
  fi

  # An `affected` OpenVEX statement requires an action_statement; fold the
  # accepted-vulnerability rationale and its mandatory re-review date (there is
  # no native OpenVEX field for an expiry, so it is stated in the text) into it.
  action_statement="$stmt"
  if [ -n "$exp" ]; then
    action_statement="${stmt} (Accepted, tracked risk recorded in .trivyignore.yaml; this disposition expires ${exp} and must be re-reviewed on or before that date.)"
  fi

  statement_json="$(
    jq -n \
      --arg cve "$id" \
      --arg product "$product_id" \
      --argjson subcomponents "$subcomponents" \
      --arg action "$action_statement" \
      --arg ts "$timestamp" \
      '{
        vulnerability: { name: $cve },
        timestamp: $ts,
        products: [ { "@id": $product, subcomponents: $subcomponents } ],
        status: "affected",
        action_statement: $action
      }'
  )"

  statements="$(jq --argjson s "$statement_json" '. + [$s]' <<<"$statements")"
done <<<"$parsed"

jq -n \
  --arg context "$vex_context" \
  --arg id "https://github.com/wiki-mod/lancache-ng/vex/lancache-ng-${timestamp}" \
  --arg author "$vex_author" \
  --arg ts "$timestamp" \
  --argjson statements "$statements" \
  '{
    "@context": $context,
    "@id": $id,
    author: $author,
    timestamp: $ts,
    version: 1,
    statements: $statements
  }'
