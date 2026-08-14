#!/usr/bin/env bash
# LanCache-NG (https://github.com/wiki-mod/lancache-ng)
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# AG-VAL-029 standing check for issue #1535: aquasecurity/trivy-action must
# only ever be invoked from inside .github/actions/trivy-scan-retry/action.yml
# (the AG-CI-013 retry + GHCR-first-DB-mirror + authenticated-pull wrapper),
# never directly from a workflow or a different composite action. A direct
# call site bypasses that wrapper's retry/auth/mirror-ordering fix entirely
# and silently reintroduces the exact zero-retry gap that caused two real CI
# failures (PR #1503, PR #1500) before this wrapper existed. A point fix
# alone would not have prevented the *next* direct call site from making the
# same mistake, so this exists as a repeatable guard rather than only a
# one-time cleanup (AG-VAL-029).
#
# Accepts an optional repo_root argument (defaults to this script's own
# repo) so a bats test can point it at a throwaway fixture tree instead of
# mutating or depending on the real repository.
set -euo pipefail

if [ "$#" -gt 0 ]; then
    repo_root=$(cd "$1" && pwd)
else
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    repo_root=$(cd "$script_dir/.." && pwd)
fi
cd "$repo_root"

# The one legitimate call site: the wrapper action's own four attempt steps.
allowed_file=".github/actions/trivy-scan-retry/action.yml"

violations=0
while IFS=: read -r file _rest; do
    [ -n "$file" ] || continue
    if [ "$file" = "$allowed_file" ]; then
        continue
    fi
    echo "::error::check-trivy-action-direct-usage: $file calls aquasecurity/trivy-action directly -- use ./.github/actions/trivy-scan-retry instead (issue #1535, AG-CI-013)" >&2
    violations=$((violations + 1))
done < <(grep -rn --include='*.yml' --include='*.yaml' 'uses: *aquasecurity/trivy-action@' .github/workflows .github/actions 2>/dev/null || true)

if [ "$violations" -gt 0 ]; then
    echo "::error::check-trivy-action-direct-usage: found $violations direct aquasecurity/trivy-action call site(s) outside the retry wrapper" >&2
    exit 1
fi

echo "check-trivy-action-direct-usage: no direct aquasecurity/trivy-action call sites outside .github/actions/trivy-scan-retry/action.yml"
