set -euo pipefail

mkdir -p coverage-badge
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -v "$PWD:/work:ro" \
  -v "$PWD/coverage-badge:/coverage-badge" \
  -w /work \
  "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" \
  bash -c 'set -euo pipefail

    # Extract coverage percentages from JSON reports inside the
    # selected build-tools image, not from incidental host binaries.
    dns_coverage=$(jq -r ".coverage" coverage-dns/tarpaulin-report.json 2>/dev/null || echo "0")
    ui_coverage=$(jq -r ".coverage" coverage-ui/tarpaulin-report.json 2>/dev/null || echo "0")

    echo "DNS coverage: ${dns_coverage}%"
    echo "UI coverage: ${ui_coverage}%"

    # Per-crate thresholds, not a shared minimum: the two crates'"'"' real
    # coverage differs by an order of magnitude (measured on CI:
    # ui ~38.6%, nats-subscriber ~0%, since nats-subscriber'"'"'s 4 tests
    # only cover its data model, not its subscribe/forward logic --
    # tracked in #504). A single shared "minimum" threshold would
    # either block ui'"'"'s real coverage from ever mattering (if set low
    # enough for nats-subscriber to pass) or permanently fail
    # nats-subscriber (if set for ui'"'"'s level). Each crate'"'"'s threshold
    # is raised independently as that crate gains real tests.
    ui_threshold=35
    dns_threshold=0

    echo "UI threshold: ${ui_threshold}%"
    echo "DNS threshold: ${dns_threshold}% (tracked gap: #504)"

    failed=0
    if (( $(echo "$ui_coverage < $ui_threshold" | bc -l) )); then
      echo "::error::UI coverage ${ui_coverage}% is below threshold of ${ui_threshold}%"
      failed=1
    fi
    if (( $(echo "$dns_coverage < $dns_threshold" | bc -l) )); then
      echo "::error::DNS coverage ${dns_coverage}% is below threshold of ${dns_threshold}%"
      failed=1
    fi

    if [[ "$failed" -eq 1 ]]; then
      exit 1
    fi

    # Badge generation reuses this same containerized jq instead of
    # assuming a host-installed jq, matching why the coverage
    # extraction above already runs in here (issue #566).
    ui_coverage_display="$(printf "%.2f" "$ui_coverage")"
    dns_coverage_display="$(printf "%.2f" "$dns_coverage")"
    badge_message="ui ${ui_coverage_display}% / dns ${dns_coverage_display}%"
    badge_color=yellow
    if awk -v ui="$ui_coverage" -v dns="$dns_coverage" "BEGIN { exit !(ui >= 80 && dns >= 80) }"; then
      badge_color=brightgreen
    fi

    jq -n \
      --arg message "$badge_message" \
      --arg color "$badge_color" \
      "{schemaVersion: 1, label: \"rust coverage\", message: \$message, color: \$color}" \
      > /coverage-badge/rust.json

    {
      printf "ui=%s\n" "$ui_coverage_display"
      printf "dns=%s\n" "$dns_coverage_display"
      printf "message=%s\n" "$badge_message"
    } > /coverage-badge/output.env

    echo "Coverage check passed"'

cat coverage-badge/output.env >> "$GITHUB_OUTPUT"
