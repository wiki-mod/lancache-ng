# setup.sh — vacuum-first bug-hunt raw findings

Part of the project-wide bug-hunt sweep tracked in #849 (sub-issue of #843).
Component: the complete `setup.sh` CLI surface (repo root, 6084/6085 lines on
`origin/v0.2.0` at commit `3f53ac3`, same commit the capability-inventory SoT
(`docs/capability-inventory/SoT-setupsh.md` on `docs/inventory-setupsh`) was
written against).

Methodology: unscoped, exhaustive, vacuum-first read of the entire file
top-to-bottom (every helper function, every `cmd_*` function, the dispatcher,
and the linear interactive `install` main-flow body at the tail of the file),
cross-checked against `.github/AGENTS.md`, the SoT document, and a live check
of GitHub branch-protection settings via `gh api`. No pre-filtering, no
self-verification during collection — that happens in a later, separate
phase. Findings are listed in the order encountered, not by severity.

---

## 1. `verify_stack_functional_health`'s DNS probe silently no-ops without `dig`

**File/line**: `setup.sh:3482-3513` (`verify_stack_functional_health`), used by
`wait_for_stack_health` (3522) which gates `apply_stack_update_ordered`'s
health decision (whether `update`/`auto-update` keep a new deployment or roll
it back via `rollback_stack_update`).

```bash
test_fqdn="steamcontent.com"
if [[ -n "$ip_standard" ]] && command -v dig >/dev/null 2>&1; then
    resolved=$(dig +time=2 +tries=1 +short @"$ip_standard" A "$test_fqdn" 2>/dev/null)
    if [[ -z "$resolved" ]]; then
        print_error "Functional check failed: DNS did not resolve ${test_fqdn} via ${ip_standard}"
        return 1
    fi
fi
```

`setup.sh` never installs `dig` (confirmed via `grep -n '\bdig\b' setup.sh` —
the only two hits are this comment and this call site; no
`install_missing_tools dig` / `apt-get install dnsutils` anywhere in the
file). If `dig` is not present on the HOST (not inside a container — this
runs directly on the host running `setup.sh update`), the DNS probe is
skipped entirely with **no warning printed at all** — the function just falls
through to `return 0`. `AGENTS.md`'s Runtime Behavior section states: "DNS
health checks must use a real query/response probe such as `dig` or an
equivalent strong check" and explicitly rules out weaker signals. Since the
health gate treats a skipped check as a pass, an update that breaks DNS
resolution (e.g. a botched PowerDNS config after migration) can still pass
the post-update health gate and be kept (not rolled back) purely because
`curl http://$ip_standard/healthz` (an nginx endpoint, unrelated to DNS)
still returns 200 — as long as `dig` happens to be missing on that host.
Debian minimal/cloud images commonly do not ship `dnsutils`/`bind9-dnsutils`
by default, so this is plausibly the common case, not a rare edge case.

Severity assessment: serious — this is exactly the safety-critical
"validate before/after mutate" gate AGENTS.md calls out, and it degrades
silently with no operator-visible warning.

---

## 2. Backup-root is not scoped per install_dir — cross-install rollback collision risk

**File/line**: `cmd_backup` (`setup.sh:2914`, default
`backup_root="/var/backups/lancache-ng"`), `rollback_stack_update`
(`setup.sh:3553-3571`).

```bash
rollback_stack_update() {
    local install_dir="$1"
    local backup_root="/var/backups/lancache-ng"
    local latest_backup
    latest_backup=$(find "$backup_root" -maxdepth 1 -name 'lancache-ng-config-*.tar.gz' -print 2>/dev/null | sort | tail -1)
    ...
    cmd_restore "$latest_backup" "$install_dir"
```

`cmd_backup`'s default destination (`/var/backups/lancache-ng`) is **not**
namespaced by `install_dir`, and the backup archive filename itself
(`lancache-ng-${mode}-${stamp}.tar.gz`) carries no install-dir identity
either — only a UTC timestamp. `rollback_stack_update` (invoked automatically
by `perform_stack_update_flow` whenever the post-update health gate fails)
picks literally "the lexically newest `lancache-ng-config-*.tar.gz` file
under the default backup root," with no cross-check that it actually
belongs to the `install_dir` currently being rolled back.

On a host running two lancache-ng installs at different `install_dir`s
(a scenario the codebase already reasons carefully about elsewhere — see
`guard_restore_shared_project_volumes`'s own comment on the fixed
`lancache-ng` Compose project name, and issue #669 #6) that both use the
default backup destination, a failed update on install A can pick up
install B's most recent config backup and restore it into A.

`guard_restore_shared_project_volumes` (called from `cmd_restore`) mitigates
the case where install B happens to be **actively running** at that exact
moment (it refuses the restore if a running container belonging to the same
fixed `lancache-ng` Compose project has a different `working_dir`). But if
install B is stopped/idle at that moment (e.g. between its own scheduled
backup and its own next start, or simply not currently running), the guard
finds no conflicting running container and the restore proceeds — silently
overwriting install A's `.env`/secrets/state and (since the Compose project
name is fixed) the **same shared named Docker volumes** with install B's
archived content, entirely as an automatic side effect of A's failed update,
with no operator confirmation.

Severity assessment: moderate (real data-clobbering path, but requires the
narrow precondition of two same-host installs sharing the default backup
root and B being stopped at the time A rolls back) — worth an explicit
per-install-dir-scoped backup root/filename rather than relying on the
shared-volume guard to catch every case.

---

## 3. Inconsistent SSL-enabled fallback default across two call sites

**File/line**: `cmd_debug` (`setup.sh:3924`) vs. `verify_stack_functional_health`
(`setup.sh:3494`).

```bash
# cmd_debug:3924
svc_list=(proxy dns-standard ui netdata watchdog)
[[ "${ssl_enabled:-1}" = "1" ]] && svc_list=(proxy dns-standard dns-ssl ui netdata watchdog)
```
```bash
# verify_stack_functional_health:3487,3494
ssl_enabled=$(get_env_var SSL_ENABLED "$_UPDATE_ENV_FILE")
...
if [[ "${ssl_enabled:-0}" = "1" && -n "$ip_ssl" ]] && ! curl -sf "http://$ip_ssl/healthz" >/dev/null; then
```

Both read the same logical value (`SSL_ENABLED` from `.env`) into a locally
named `ssl_enabled` variable, and both use bash's `${var:-default}` to guard
against the value being empty/unset (e.g. on an install whose `.env` predates
`migrate_env_for_update` ever writing `SSL_ENABLED`). But the two call sites
pick **opposite** defaults: `cmd_debug` defaults to `1` (assume SSL enabled)
while `verify_stack_functional_health` defaults to `0` (assume SSL disabled)
for what is meant to be the same "value missing" case. Neither is clearly
"the" correct fail-safe default, and the inconsistency suggests this wasn't a
deliberate per-context choice. Impact is low in both cases today (`cmd_debug`
just tries to tail one extra/one fewer log stream; the health check just
includes/skips one extra curl probe), but it's a real inconsistency in a
"what do we assume when config is incomplete" policy that appears twice in
the same file with different answers.

Severity assessment: minor.

---

## 4. Dead/unreachable branch in `append_env_migrated_assignment_if_missing`

**File/line**: `setup.sh:1170-1188`.

```bash
append_env_migrated_assignment_if_missing() {
    local target_key="$1" source_key="$2" fallback_value="$3" env_file="$4"
    local source_assignment

    if env_key_exists "$target_key" "$env_file"; then
        return 0
    fi

    source_assignment=$(get_env_assignment_value_raw_nonempty "$source_key" "$env_file")
    if [[ -n "$source_assignment" ]]; then
        set_env_assignment "$target_key" "$source_assignment" "$env_file"
    elif env_key_exists "$target_key" "$env_file" || [[ -n "$fallback_value" ]]; then
        set_env_key "$target_key" "$fallback_value" "$env_file"
    fi
}
```

The function returns early at the top whenever `target_key` already exists
in the file. By the time the `elif` on the second-to-last line runs,
`target_key` is therefore guaranteed to NOT exist — so
`env_key_exists "$target_key" "$env_file"` in that `elif` condition can never
be true; only the `[[ -n "$fallback_value" ]]` half of the `||` can ever
fire. Behavior is unaffected today (the redundant disjunct is harmless), but
it's dead/misleading code: a future reader could reasonably conclude the
`env_key_exists` check does something here, when it provably cannot.

Severity assessment: minor/info (code-quality, not a behavioral bug).

---

## 5. Missing `local` declarations in `cmd_secondary` leak into global scope

**File/line**: `cmd_secondary` (`setup.sh:4689` onward).

The function declares its locals carefully up front (8 `local` statements
covering ~25 names), but three assignments later in the same function are
never declared local:
- `secondary_env_file` (`setup.sh:5030`: `secondary_env_file="$(realpath -m "${secondary_dir}/.env")"`)
- `missing_fields` (`setup.sh:4874`: `missing_fields=()`, then `+=(...)` four times)
- `cmd` (the `for cmd in curl docker; do ...; done` loop variable at `setup.sh:4762`)

Since `set -euo pipefail` doesn't enforce variable scoping, these three
become plain global shell variables for the remainder of the process. No
observed practical impact today — `cmd_secondary` is the last thing the
dispatcher calls before `exit 0`, so nothing downstream reads them — but it
breaks the otherwise-careful "declare every local up front" convention this
function (and the rest of the file) follows everywhere else, and would
silently leak/collide if any future refactor sourced `setup.sh` and invoked
more than one `cmd_*` function in the same shell (e.g. a test harness, or
`converge-reconcile`'s own systemd-driven reuse pattern).

Severity assessment: info.

---

## 6. Suggested SSL IP can overflow to an invalid octet

**File/line**: `setup.sh:5227` (interactive `install` flow).

```bash
suggested_ssl="${IP_STANDARD%.*}.$((10#${IP_STANDARD##*.} + 1))"
```

If the just-entered `IP_STANDARD`'s last octet is `255` (e.g.
`192.168.1.255`), the computed suggestion becomes `192.168.1.256` — not a
valid IPv4 address. The immediately following `while true; do ask ... ;
is_valid_ipv4 "$IP_SSL" && break; ... done` loop does catch this (the
operator would have to explicitly accept the broken suggestion by pressing
Enter, at which point validation fails and re-prompts), so this cannot
silently produce a bad `.env`. It's a real but low-probability edge case
(`.255` is conventionally a broadcast address, so unlikely to be chosen as
`IP_STANDARD` in the first place) that produces a nonsensical default
suggestion shown to the operator.

Severity assessment: info.

---

## 7. Unverified class: bash's errexit-suspended-inside-a-tested-function-call gotcha

**File/line**: e.g. `apt_docker_compose_is_v2` (`setup.sh:452-457`),
`apt_package_available` (`setup.sh:438-440`), and other helpers whose body is
a bare command substitution assignment, called from `if`/`&&`/`||` contexts
elsewhere in the file.

The file's own comments show the author is well aware of, and has explicitly
worked around, this specific bash behavior in at least two places:
- `set_env_key`'s comment (`setup.sh:1062-1066`): "a caller running this
  inside a subshell whose own exit status is being tested... sits in a bash
  context where errexit is silently ignored for everything inside that
  subshell, so a bare failed append here would otherwise go unnoticed."
- `cmd_update_ip`'s comment (`setup.sh:4663-4668`): "`cmd1 && cmd2` as a bare
  statement is exempt from `set -e`... so a failing `docker compose up -d`
  here would silently fall through."

Both of those specific call sites were hardened with an explicit `die()`/
`if` branch as a result. It is not established (and was not proven during
this vacuum-first pass — this needs the separate verification phase, not
speculative assertion here) whether every OTHER helper function whose only
content is a command substitution and that is itself invoked from an
`if cond; then` / `cond1 && cond2` / `cond1 || cond2` context elsewhere in
the file received the same audit. `apt_docker_compose_is_v2` and
`apt_package_available` are two concrete candidates to check first (both are
called as the direct condition of `if`/`&&` in `apt_compose_package`), but
this is flagged as a **class** to verify, not as a confirmed bug — I did not
confirm `apt-cache policy`/`apt-cache show` actually exit non-zero for an
unknown/absent package on a real Debian host, which is the precondition for
this class to matter in practice.

Severity assessment: info (unverified class, flagged for the verification
phase — do not treat as a proven live bug without further evidence).

---

## 8. CI enforcement gap: the only real setup.sh CLI E2E gate is not a required check, and the actual base branch has no branch protection at all

**File/line**: `.github/workflows/full-setup-deep-validate.yml` header
comment (lines 27-35): "BRANCH PROTECTION NOTE: making this a REQUIRED check
is a repository branch-protection setting, which lives in GitHub's settings
and not in any file in this repo... A maintainer must add the... aggregate
below... to the branch protection required-status-checks list for
v0.2.0/master."

This was verified live (not just read from the comment) via:

```
$ gh api repos/wiki-mod/lancache-ng/branches/master/protection
"required_status_checks":{"contexts":["shellcheck","validate-compose"], ...}

$ gh api repos/wiki-mod/lancache-ng/branches/v0.2.0/protection
{"message":"Branch not protected", ... "status":404}
```

Two concrete findings from this:

1. **`master`** has branch protection, but its required status checks are
   only `shellcheck` and `validate-compose` — the "Full-Setup Deep Validate"
   aggregate job (the only workflow that runs `scripts/setup-cli-simulation.sh`,
   the sole real end-to-end exerciser of `setup.sh install`/`update`/`restore`
   against a live stack, per the SoT's own test-coverage matrix) is **not**
   in that list. A PR could merge into `master` even if that workflow failed,
   was cancelled, or never ran.
2. **`v0.2.0`** — the branch this bug-hunt sweep itself is based on, and
   (per project convention/CLAUDE.md's Dev-Ordner-retirement notes) the
   actual current working/target branch for PRs — has **no branch protection
   configured at all** (`404 Branch not protected`). None of `setup.sh`'s CI
   gates (`shellcheck`, the `setup_*.bats` suite, `full-setup-deep-validate`)
   are enforced as a merge requirement on it today; a PR could be merged into
   `v0.2.0` with every check red, or with no checks having run.

Severity assessment: moderate — this is a governance/process gap rather than
a bug in `setup.sh`'s own logic, but it directly determines whether every
other finding in this document (and every existing test in the SoT's
test-coverage matrix) actually blocks a bad merge in practice. Flagging for
the maintainer to confirm intent (this may already be a known, accepted gap
while v0.2.0 is pre-stable) rather than asserting it is unintentional.

---

## 9. Vacuous assertion in `setup_update_idempotence.bats` — `run !` result is never checked

**File/line**: `tests/bats/setup_update_idempotence.bats:158-159`.

```bash
run ! grep -q '^CACHE_DIR_STANDARD=' "$env_file"
run ! grep -q '^CACHE_DIR_SSL=' "$env_file"
grep -qx 'CACHE_DIR=/srv/lancache/cache' "$env_file"
grep -qx 'PROXY_SECURITY_MODE=lazy' "$env_file"
```

Bats' `run` helper captures a command's exit status/output into `$status`/
`$output` and always itself returns 0, specifically so a failing command
under test doesn't abort the whole test via bats' own errexit-like behavior
— the caller is expected to assert on `$status` afterward. Lines 158-159
never do that (no `[ "$status" -eq 0 ]`/`-eq 1` follows either `run` call,
and no other line reads `$status` before it gets overwritten by whatever
`run` call comes next). This means the two lines intended to prove
"`migrate_env_for_update` actually removed the legacy `CACHE_DIR_STANDARD`/
`CACHE_DIR_SSL` keys" (visible from the surrounding code and the file's own
header-comment framing: "split cache keys collapse") execute but assert
**nothing** — a regression that stopped removing those legacy keys after
migration would not be caught by this test. This is independent of whatever
bats' `run ! <cmd>` idiom is specifically documented to mean; the defect is
simply that no assertion follows the `run` call at all, which is true
regardless of that idiom's semantics. Lines 160-161 (bare `grep -qx`, not
wrapped in `run`) are correctly enforcing in the normal bats sense (an
unguarded failing command does fail the test) — only the two `run !` lines
are affected.

Severity assessment: minor/moderate (test-quality defect: the two assertions
are silently inert, weakening this test's proof of one part of the #456
legacy-cache-key-collapse migration, though the same collapse is still
proven at the real-CLI level by `scripts/setup-cli-simulation.sh` Phase 4b's
`grep -q '^CACHE_DIR_STANDARD=' "$install_dir/.env" && { echo error; exit 1;
}` check, which correctly uses the bare/unwrapped form).

---

## 10. Stale doc-comment references a deleted script as existing test coverage

**File/line**: `tests/bats/setup_channel_stable_edge.bats:18-21` (header comment).

```
Testing the pure mapping function directly is both simpler and strictly
more reliable ... the actual registry pull path stays covered by the real
end-to-end CI simulations (scripts/setup-cli-simulation.sh,
scripts/watchtower-update-simulation.sh) instead of an in-bats mock.
```

`scripts/watchtower-update-simulation.sh` no longer exists — confirmed via
`git log --all --oneline -- scripts/watchtower-update-simulation.sh`, whose
most recent entry is commit `dd0fd66`, "feat(setup): remove Watchtower, add
scheduled-update opt-in in its place (#829)": Watchtower (and its dedicated
simulation script) was deleted as part of the #819 rework this same
`setup.sh` region documents extensively (`cmd_auto_update`/
`perform_stack_update_flow` replacing it). The comment still claims this
deleted script as one of the two things providing real end-to-end coverage
of the channel-resolution registry pull path. This is exactly the kind of
stale claim AGENTS.md's Comment Style section warns about ("a stale
[claim]... sitting next to code that no longer does it... actively misleads
the next reader"), and it directly reinforces the SoT's own already-flagged
issue #785 gap (scheduled channel-install smoke check for the published
channels) by making a reader believe there is more real coverage of that
path than currently exists.

Severity assessment: minor (documentation-only, but actively misleading
about test-coverage scope in exactly the area #785 already tracks as a gap).

---

## Scope note on what this pass did and did not (yet) do

- Read `setup.sh` in full, sequentially, top to bottom (all ~6085 lines),
  including every helper function, every `cmd_*` function, the dispatcher,
  and the entire linear `install` main-flow body.
- Cross-checked every finding against `.github/AGENTS.md`'s explicit rules
  (Setup/Update/Migration Semantics, Runtime Behavior, Required Validation).
- Read the capability-inventory SoT (`docs/capability-inventory/SoT-setupsh.md`
  on `docs/inventory-setupsh`) in full as a starting point, not a boundary —
  every finding above is new relative to that document (the SoT's own
  test-coverage gaps are not re-listed here; see that document directly).
- Verified the CI branch-protection finding (#8) live via `gh api`, since
  that is directly checkable without needing a runner.
- Also did a full read of all 14 `tests/bats/setup_*.bats` files (the 15th,
  `detect_full_setup_changes.bats`, is not `setup.sh`-specific) plus both
  `scripts/setup-cli-simulation.sh` and
  `scripts/setup-reset-kea-config-simulation.sh` in full for test-quality
  bugs (vacuous assertions, wrong fixtures, stale doc claims). That pass
  found findings #9 and #10 above; every other file/script read clean (every
  `run` call is followed by a real `$status`/`$output` assertion, fixtures
  match the behavior under test).
- Did not use a live runner (.228/.229/.240) for this pass — no runner
  resources were created or need cleanup for this component's bug hunt.
