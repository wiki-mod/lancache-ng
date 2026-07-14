set -euo pipefail

grep -n "Set up Docker Buildx for manifest inspection" .github/workflows/build-push.yml >/dev/null || {
  echo "::error::validate-compose must set up Buildx before resolving digest-qualified build-tools images."
  exit 1
}

require_boolean() {
  local name="$1" value="$2"
  case "$value" in
    true|false)
      ;;
    *)
      echo "::error::detect-changes output '$name' must be true or false, got '${value:-<empty>}'."
      exit 1
      ;;
  esac
}

require_success() {
  local name="$1" value="$2"
  if [ "$value" != "success" ]; then
    echo "::error::$name must succeed for this change set, got '$value'."
    exit 1
  fi
}

require_success_or_intentional_skip() {
  local name="$1" value="$2"
  case "$value" in
    success|skipped)
      ;;
    *)
      echo "::error::$name may only be skipped by the PR path filter, got '$value'."
      exit 1
      ;;
  esac
}

if [ "$EVENT_NAME" != "pull_request" ]; then
  require_success "rust-quality (dns/nats-subscriber)" "$DNS_RUST_QUALITY_RESULT"
  require_success "rust-quality (ui)" "$UI_RUST_QUALITY_RESULT"
  require_success "test (dns/nats-subscriber)" "$DNS_TEST_RESULT"
  require_success "test (ui)" "$UI_TEST_RESULT"
  require_success "test (watchdog)" "$WATCHDOG_TEST_RESULT"
  require_success "cargo-audit (dns/nats-subscriber)" "$DNS_CARGO_AUDIT_RESULT"
  require_success "cargo-audit (ui)" "$UI_CARGO_AUDIT_RESULT"
  exit 0
fi

require_success "detect changed paths" "$DETECT_RESULT"

for output in \
  DNS_RUST_CHANGED \
  UI_CHANGED \
  WATCHDOG_CHANGED \
  WORKFLOW_CHANGED \
  DOCS_CHANGED \
  DOCS_ONLY \
  GOVERNANCE_CHANGED \
  SETUP_RUNTIME_CHANGED \
  DEPLOY_CHANGED \
  RELEASE_CONTRACT_CHANGED \
  SCRIPTS_CHANGED
do
  require_boolean "$output" "${!output}"
done

dns_rust_required=false
ui_required=false
watchdog_required=false
if [ "$WORKFLOW_CHANGED" = "true" ]; then
  dns_rust_required=true
  ui_required=true
  watchdog_required=true
fi
if [ "$DNS_RUST_CHANGED" = "true" ]; then
  dns_rust_required=true
fi
if [ "$UI_CHANGED" = "true" ]; then
  ui_required=true
fi
if [ "$WATCHDOG_CHANGED" = "true" ]; then
  watchdog_required=true
fi

if [ "$dns_rust_required" = "true" ]; then
  require_success "rust-quality (dns/nats-subscriber)" "$DNS_RUST_QUALITY_RESULT"
  require_success "test (dns/nats-subscriber)" "$DNS_TEST_RESULT"
  require_success "cargo-audit (dns/nats-subscriber)" "$DNS_CARGO_AUDIT_RESULT"
else
  require_success_or_intentional_skip "rust-quality (dns/nats-subscriber)" "$DNS_RUST_QUALITY_RESULT"
  require_success_or_intentional_skip "test (dns/nats-subscriber)" "$DNS_TEST_RESULT"
  require_success_or_intentional_skip "cargo-audit (dns/nats-subscriber)" "$DNS_CARGO_AUDIT_RESULT"
fi

if [ "$ui_required" = "true" ]; then
  require_success "rust-quality (ui)" "$UI_RUST_QUALITY_RESULT"
  require_success "test (ui)" "$UI_TEST_RESULT"
  require_success "cargo-audit (ui)" "$UI_CARGO_AUDIT_RESULT"
else
  require_success_or_intentional_skip "rust-quality (ui)" "$UI_RUST_QUALITY_RESULT"
  require_success_or_intentional_skip "test (ui)" "$UI_TEST_RESULT"
  require_success_or_intentional_skip "cargo-audit (ui)" "$UI_CARGO_AUDIT_RESULT"
fi

if [ "$watchdog_required" = "true" ]; then
  require_success "test (watchdog)" "$WATCHDOG_TEST_RESULT"
else
  require_success_or_intentional_skip "test (watchdog)" "$WATCHDOG_TEST_RESULT"
fi

if [ "$DOCS_ONLY" = "true" ]; then
  echo "::notice::Docs-only PR: heavy Rust and Docker checks may be skipped, but unconditional policy checks still ran."
fi
if [ "$GOVERNANCE_CHANGED" = "true" ]; then
  echo "::notice::Governance files changed; keep review focused on project rules, not only generated artifacts."
fi
if [ "$SETUP_RUNTIME_CHANGED" = "true" ] || [ "$DEPLOY_CHANGED" = "true" ] || [ "$RELEASE_CONTRACT_CHANGED" = "true" ]; then
  echo "::notice::Runtime/deploy/release contract files changed; validate-compose remains the lightweight project-wide guard."
fi

