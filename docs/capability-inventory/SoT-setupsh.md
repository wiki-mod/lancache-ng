# setup.sh — capability inventory (source of truth, working notes)

Part of the project-wide capability audit tracked in #843. Scope: the
complete `setup.sh` CLI surface (repo root, ~6084 lines on `origin/v0.2.0` at
commit `3f53ac3`). This file is the working draft behind the comment(s)
posted to #843; kept here so progress survives interruptions.

Methodology: read `setup.sh` in full (every `cmd_*` function, the dispatcher,
the interactive `install` main-flow body, and the shared helpers each command
calls), cross-referenced against `.github/AGENTS.md` (AG-OP-006..013,
Convergence/Idempotence Checklist), `scripts/check-idempotence-test-coverage.sh`,
`scripts/setup-cli-simulation.sh`, the other `scripts/*-simulation.sh` files,
every `tests/bats/setup_*.bats` file, and `gh issue` lookups for the issues
named in code comments (#639, #665, #669, #762, #763, #819, #665, #666, #628,
#652, #785, #836, #456).

> **Currency check (2026-07-18):** re-verified against `origin/v0.2.0` @
> `dc8d79c6`; see corrections below. Two substantive updates since this file
> was written against `3f53ac3`:
> - **`secondary`'s generated healthcheck changed** from `rec_control ping` to
>   a real dig-based query/response probe (issue #946 / PRs #976/#916), matching
>   AG-VAL-018. Corrected inline in the `secondary` section below.
> - **The post-update functional health gate now fails closed on a missing
>   probe tool.** `verify_stack_functional_health` was hardened by PR #883 so a
>   missing `dig` no longer silently skips the DNS probe — it calls
>   `require_functional_check_tool dig … || return 1` and `install_missing_tools
>   curl dig` runs before the gate. The `update` section's description of this
>   gate (step 8) is therefore now *more* accurate than when written, not less;
>   noted here for completeness.
>
> Everything else re-verified as still accurate against current code, with one
> caveat: **absolute line numbers have drifted.** `setup.sh` grew from ~6084 to
> 6291 lines since `3f53ac3` (merged `setup.sh`-touching PRs: #869/#876, #883,
> #916/#976, #939, #941, #943, #956, #982, #984, #988), so the specific
> `line N` references throughout this file are offset (roughly +100…+200 in the
> file's latter half). The function names, behaviors, dispatch order,
> test-coverage matrix, and referenced-issue states (#639/#669 CLOSED;
> #785/#836/#456 OPEN — all re-confirmed) remain correct; only the numeric line
> citations are stale.

## Dispatcher / full command list

`case "${1:-install}" in` near the end of the file. Full set, in dispatch order:

| Command | Aliases | Handler |
|---|---|---|
| `install` (default, no arg) | — | inline main-flow body (not a `cmd_*` function) |
| `update` | — | `cmd_update` → `perform_stack_update_flow` |
| `auto-update` | — | `cmd_auto_update` |
| `converge-reconcile` | — | `cmd_converge_reconcile` (internal only, not in `print_usage`/`print_command_help`) |
| `debug` | — | `cmd_debug` |
| `create-logs-for-issue` | — | `cmd_create_logs_for_issue` |
| `backup` | — | `cmd_backup` |
| `restore` | — | `cmd_restore` |
| `secondary` | `--secondary` | `cmd_secondary` |
| `update-ip` | `--reconfigure`, `reconfigure` | `cmd_update_ip` |
| `reset-to-last-known-good-config` | — | `cmd_reset_to_last_known_good_config` |
| `help` | `--help`, `-h` | `print_usage` |

Every command except `converge-reconcile` also handles `<command> --help`/`help`
by calling `print_command_help <command>` (defined ~line 3281) instead of
running the command.

---

## `install` (default)

Not a function — the tail of the script (~line 5136 to EOF) runs linearly
after the dispatcher's `case` falls through (only `install|""` has no
`exit 0`). This is the interactive first-time setup, and also what
`curl … | bash` runs.

**Flow, in order:**
1. Prerequisite checks: must run as root; `assert_prebuilt_image_platform_supported`;
   installs `curl`/`docker`/`docker compose` if missing (`install_curl`,
   `install_docker`, `install_docker_compose` — apt/dnf/yum/pacman dispatch,
   each gated by an explicit operator confirmation before mutating the host).
   If invoked from outside a checkout (`$QUICKSTART_COMPOSE` missing), clones
   `wiki-mod/lancache-ng` to `/opt/lancache-ng` (or syncs an existing checkout
   to the default branch) and re-execs itself there.
2. Network IPs: detects a LAN IPv4/interface, prompts for `IP_STANDARD`,
   optionally enables SSL mode and prompts for `IP_SSL` (offers to
   `ip addr add` it non-persistently).
3. Install directory (`INSTALL_DIR`, default `/opt/lancache-ng`); copies
   quickstart compose assets (`install_quickstart_compose_assets`).
4. Cache configuration: `CACHE_DIR`, cache size in GiB, `CACHE_MEM_MB`.
5. Release channel: prompts `stable`/`edge` UNLESS `LANCACHE_IMAGE_CHANNEL` is
   already set in the environment — that case is respected outright with no
   prompt (documented non-interactive path: `LANCACHE_IMAGE_CHANNEL=edge
   ./setup.sh install`, and `scripts/setup-cli-simulation.sh`'s own
   `LANCACHE_IMAGE_CHANNEL=pinned` + explicit tag for CI's own just-built
   images — comment explicitly calls out both real callers).
6. Scheduled automatic updates prompt → `AUTO_UPDATE_ENABLED` (default `N`).
7. DHCP mode prompt: `disabled` (default) / `kea` / `dnsmasq-proxy` — mutually
   exclusive (`is_valid_dhcp_mode`). `kea` prompts for `KEA_DATA_DIR`,
   `DHCP_SUBNET` (CIDR), gateway, IP pool start/end, and warns to firewall Kea's
   Control Agent port 8000. `dnsmasq-proxy` requires an explicit confirmation
   ("experimental … does not reliably replace DNS options from a normal router
   DHCP server"), prompts for subnet start (`is_dnsmasq_subnet_start`, must end
   in `.0`), primary/secondary DNS options, upstream DHCP IP, and an optional
   block of #450 PXE-scoped extras (interface, router, NTP servers, domain,
   boot filename/server) each with its own validator
   (`is_valid_dhcp_proxy_interface/domain/boot_filename`).
8. Admin-UI access control: prompts to protect with a password (default `Y`);
   generates `UI_AUTH_PASSWORD` (`generate_secret_value … alnum20`) unless an
   existing `.env` already has the same `UI_AUTH_USER` with a usable
   (non-placeholder) password, in which case it's preserved. If the operator
   declines protection, requires an explicit second confirmation to set
   `ALLOW_INSECURE_UI=true`; otherwise `die()`s (AG-SEC-001: fail-closed by
   design, not a bug).
9. Writes `.env` (`write_env_file`): resolves/validates image
   registry/prefix/channel/tag (`resolve_lancache_image_*`,
   `assert_resolved_image_tag_platform_supported` — #665, verifies the
   resolved tag actually publishes an image for this host's architecture
   *before* anything is written), generates-or-preserves every secret via
   `get_or_generate_secret` (`KEA_CTRL_TOKEN` hex32, `DDNS_TSIG_KEY`
   base64_32, `PDNS_API_KEY` hex32, 4 NATS role passwords hex32,
   `SECONDARY_REGISTRATION_TOKEN` hex32), validates every value
   (`validate_env_values_for_initial_write`) before writing anything.
10. Creates cache/Kea directories.
11. Installs systemd units (if `systemctl` present): `lancache.service` (boot
    start, `docker compose up -d`/`down`), `lancache-converge.service` +
    `.timer` (2 min after boot, then every 5 min: runs
    `setup.sh converge-reconcile` — prefixed `-` so its exit code can never
    fail the unit — then `docker compose up -d --remove-orphans` for
    container-drift convergence), and `lancache-auto-update.service` +
    `.timer` (daily + `RandomizedDelaySec=1h`, `Persistent=true`; always
    written, only enabled if `AUTO_UPDATE_ENABLED=1`). The auto-update timer
    intentionally does NOT re-`git pull` itself before running — runs
    whatever `setup.sh` is already on disk at tick time (deliberate, #819,
    to avoid rewriting the running interpreter's own script file mid-exec).
12. Prints a configuration summary, confirms "Start now?", pulls images
    (`assert_prebuilt_image_platform_supported` again, then
    `docker compose pull`), runs `run_kea_dhcp_activation_preflight` (Kea
    mode only: non-invasive `nmap --script broadcast-dhcp-discover` inside
    the dhcp image to detect an existing DHCP server before Kea goes live;
    requires explicit confirmation to proceed if one is found, or if the
    preflight itself couldn't execute), enables+starts the systemd units (or
    falls back to a plain `docker compose up -d` if systemd is unavailable),
    prints Admin-UI URL / CA cert path / DNS IPs / follow-up commands.

**Idempotence**: re-running `install` against an existing `.env` asks
"Overwrite .env? [y/N]" and preserves existing secrets/UI password via
`env_key_has_usable_secret`/`get_or_generate_secret` if answered yes — so it
is not a pure no-op replay path the way `update` is; it's explicitly the
first-time flow, and a second run is an explicit overwrite decision, not a
silent convergence. Directory/systemd-unit writes are idempotent (`mkdir -p`,
overwriting the same unit file content, `daemon-reload`).

**Test coverage**: `scripts/setup-cli-simulation.sh` Phase 1 runs the real
CLI via `expect` end-to-end (fresh install, all prompts, waits for a healthy
running stack, asserts `.env` contains the expected `IP_STANDARD`/
`UI_AUTH_USER`). This is real CLI E2E coverage, not just an extracted
function. `tests/bats/setup_dhcp_mode.bats`, `setup_image_platform_guard.bats`,
`setup_quickstart_assets.bats`, `setup_channel_stable_edge.bats` cover
individual helpers this flow calls, at the function level (no `bash setup.sh`
subprocess). The scheduled channel-install smoke check for the *published*
channels (`dev`/`edge`) is a separate, currently open gap — see issue #785
below (the per-PR gate now installs the PR's own pinned images, so ongoing
channel-pointer-resolution health is no longer implicitly checked by every
PR).

---

## `update` [install-dir]

`cmd_update` (line 3707) → thin wrapper: resolves `install_dir` (default
`/opt/lancache-ng`) and calls `perform_stack_update_flow`.

`perform_stack_update_flow` (line 3642) is the shared engine also used by
`auto-update`. Order (comment: "Reordering can leave a half-migrated stack
running"):
1. `assert_prebuilt_image_platform_supported`; resolve env-file + compose
   files for this install dir (`runtime_env_file_for_install_dir`,
   `compose_file_args_for_install_dir` — the latter auto-detects a NATS
   secondary override compose file, see `nats_secondary_override_active_for_install_dir`).
2. Pause the convergence timer (`pause_lancache_convergence_for_update`) —
   trap-installed BEFORE the call, not after, so a `die()` mid-pause still
   resumes it (see the code comment tracing PR #748 review).
3. `git pull`-sync the repo if `.git` exists (`sync_repo_to_default_branch`).
4. Refresh quickstart compose assets (`install_quickstart_compose_assets`).
5. Pre-update rollback backup: `cmd_backup --config "$install_dir"` — if this
   fails, resumes convergence and dies (no mutation happened yet, so nothing
   to roll back).
6. `migrate_env_for_update "$install_dir"` (see below) then
   `validate_compose_config`.
7. `docker compose pull`; `validate_compose_config` again.
8. `apply_stack_update_ordered`: brings up every non-UI service first,
   `wait_for_stack_health` (per-container Docker healthcheck status if
   declared, else `running` state, AND a real functional probe —
   `verify_stack_functional_health` curls `/healthz` and does a real `dig`
   query, explicitly not `ping`/`ss`, per AG-VAL-018/019/020), only then
   recreates the Admin UI last and re-verifies. A failed health gate at
   either stage calls `rollback_stack_update` (finds the newest
   `lancache-ng-config-*.tar.gz` under `/var/backups/lancache-ng` by
   lexically-sortable UTC timestamp and re-invokes `cmd_restore` against it
   — reuses restore's own already-correct stop/replace/reconverge path
   rather than a second rollback implementation).
9. Resume convergence; done.

**`migrate_env_for_update`** (line 2287) is the real .env-convergence
function, called with `preserve_image_tag=0` from `update` (always
re-resolves the tag against the current channel pointer) vs. `1` from
`restore` (keeps the archived immutable tag — see `restore` below for why).
Resolves/validates image registry/prefix/channel/tag FIRST and calls
`assert_resolved_image_tag_platform_supported` before writing anything else
(#665 — a platform failure here must not leave partial `.env` mutation
behind beyond the images fields). Then: session TTL default/validation,
`IP_SSL`/`SSL_ENABLED` derivation, `AUTO_UPDATE_ENABLED` default (`0`,
matching the interactive picker's own default — migration must never
silently turn this on), `LANCACHE_STATE_DIR` legacy-path resolution, collapses
legacy split `CACHE_DIR_STANDARD`/`CACHE_DIR_SSL` into one `CACHE_DIR` (dies
if they point to two DIFFERENT paths — can't silently pick one), per-service
state dir migrations (PDNS standard/ssl/filter-state, NATS data/conf),
`CACHE_MAX_SIZE`/`CACHE_MEM_MB` defaults,
`migrate_proxy_security_mode_for_update` (legacy `strict`-with-no-allowlist →
`lazy`), and more not fully enumerated here (helper functions between roughly
line 2287-2630) — pattern throughout is `set_env_key_if_empty_or_missing`
(never overwrite an operator's real value) vs. `set_env_key` (always
overwrite — used only for values setup.sh itself fully owns, e.g. the
just-resolved image tag or the now-canonical `CACHE_DIR`).

**Idempotence**: by design — every migration step uses the
"preserve-existing-or-fill-default" pattern above. AG-OP-006/007/011
directly target this function.

**Test coverage — real, layered, and explicitly the strongest in the file:**
- `tests/bats/setup_update_idempotence.bats`: sources the real
  `migrate_env_for_update` function and runs it twice against a legacy
  fixture, diffs the result — the canonical repeat-run fixture test named in
  AGENTS.md's own Convergence/Idempotence Checklist.
- `tests/bats/setup_env_migration.bats`: individual migration helpers
  (`append_env_migrated_assignment_if_missing`,
  `migrate_proxy_security_mode_for_update`, etc.) at the function level.
- `scripts/setup-cli-simulation.sh` Phase 2: real `bash setup.sh update`
  against a seeded legacy `.env` (`PROXY_SECURITY_MODE=strict`), asserts the
  migration fired through the actual CLI, not just the extracted function,
  and the stack comes up healthy.
- Phase 2b: runs the real CLI `update` a SECOND consecutive time with no
  input change, byte-diffs `.env` (excluding the two image-channel/tag keys,
  documented as a deliberately volatile exception) and diffs the 8 stable
  secret keys — this is the AG-OP-011/AG-OP-006 proof at the real-CLI level,
  the strongest test-coverage boundary any subcommand in this file gets.
- Phase 3: forces a platform-preflight failure (fake `LANCACHE_IMAGE_TAG`)
  mid-update, asserts `update` fails closed (`.env` unchanged, a rollback
  backup exists, no partial `docker compose pull`), then restores and
  confirms `update` recovers the stack — the AG-OP-010 "validate before
  restart" proof.
- `tests/bats/setup_nats_secondary_override.bats`: the
  `nats_secondary_override_active_for_install_dir`/
  `compose_file_args_for_install_dir` helpers `cmd_update`'s compose-file
  selection depends on.

**Known gap**: channel *resolution* itself (`resolve_lancache_stack_channel_tag`,
the `channel → stack:<channel> pointer → sha-*` chain against a real,
currently-published GHCR channel) is only exercised end-to-end on
`workflow_dispatch`/fork/Dependabot CI runs since the per-PR gate switched to
each PR's own pinned images — tracked as an open, acknowledged gap in issue
**#785** ("CI: scheduled channel-install smoke check for setup.sh").

---

## `auto-update` [install-dir]

`cmd_auto_update` (line 3744). Scheduled entry point for
`lancache-auto-update.timer` (daily), not meant for interactive use (#819).
Detect-then-act, not unconditional pull-and-restart:
1. Re-checks `AUTO_UPDATE_ENABLED` directly from `.env` (belt-and-braces:
   an operator can flip it to `0` by hand without re-running setup.sh, which
   wouldn't by itself disable an already-enabled systemd timer unit).
2. `resolve_lancache_image_channel` (cheap, local). If enabled and not
   `pinned`, resolves the current channel tag
   (`resolve_lancache_stack_channel_tag` — a real registry round-trip, only
   done once cheaper local checks haven't already ruled the tick out).
3. `lancache_auto_update_should_proceed` (line 3720) — a pure, dependency-free
   decision function deliberately isolated from the docker-dependent
   resolution above specifically so it can be unit-tested without mocking
   docker (see the function's own comment, and #827's own note that two
   different docker/tar-mocking techniques both proved unreliable in this
   project's bats CI environment). Prints a human-readable
   `proceed: …`/`skip: …` reason either way.
4. If proceeding: calls the exact same `perform_stack_update_flow` as manual
   `update` (ordered, health-gated, backup-then-rollback-on-failure).

**Idempotence**: an unchanged channel tick is a true no-op (step 3 above);
when it does act, it inherits `perform_stack_update_flow`'s full idempotent
update path unchanged.

**Test coverage**: `tests/bats/setup_auto_update_gate.bats` covers
`lancache_auto_update_should_proceed` directly and thoroughly (pure function,
no docker) — but that is only the pure gate/decision, not the `cmd_auto_update`
function body itself (the `.env` re-check, the actual channel-tag resolution
call, the dispatch into `perform_stack_update_flow`). No `*-simulation.sh`
script or bats test drives the real `bash setup.sh auto-update` subcommand
end-to-end. Since `perform_stack_update_flow` itself IS the same code path
`setup-cli-simulation.sh` Phases 2/2b/3 exercise via `update`, the actually-
untested surface specific to `auto-update` is narrow (the gate-and-dispatch
wrapper), but it is untested at the real-CLI/real-command level.

---

## `converge-reconcile` [install-dir] (internal only)

`cmd_converge_reconcile` (line 3852). Not documented in `print_usage`/
`print_command_help` and not meant for interactive use — the FIRST
`ExecStart` line of `lancache-converge.service` (prefixed `-`, systemd's own
"never let this fail the unit" syntax), running immediately before the
service's second `ExecStart` (`docker compose up -d --remove-orphans`, the
pre-existing container-drift convergence, unchanged by this feature). Bridges
the Admin UI's release-channel/scheduled-update controls
(`services/ui/src/routes/setup.rs`) onto the host, since that control can
only write into the `ui-data` Docker-managed *named volume* — a plain host
script can't read that as a filesystem path, so it's read through a
throwaway read-only Alpine container (`lancache_read_ui_settings_override`,
same idiom `backup_compose_volumes` already uses). Silently no-ops (`return
0`) if the compose file doesn't exist yet, docker isn't available, or the env
file is missing — this can legitimately fire before the very first install
completes.

Only two keys are ever pulled from the UI's settings file:
`LANCACHE_IMAGE_CHANNEL` (validated by a narrower, silently-no-op-on-
unexpected-value gate, `lancache_ui_channel_override_is_valid` — only
`stable`/`edge`, deliberately narrower than `validate_lancache_image_channel`
which `die()`s and would abort the whole systemd service run) and
`AUTO_UPDATE_ENABLED` (`0`/`1`). If either differs from the current `.env`
value, writes it via `set_env_key`, then unconditionally calls
`reconcile_auto_update_timer_state` (makes the real systemd
enabled/active state of `lancache-auto-update.timer` match .env's CURRENT
`AUTO_UPDATE_ENABLED` — covers a direct manual `.env` edit too, not just the
UI-override path).

**Idempotence**: naturally convergent — re-running with no UI override change
and an already-matching timer state does nothing (`[[ "$ui_channel" !=
"$current_channel" ]]` guards, `systemctl is-enabled --quiet` guards before
enabling/disabling).

**Test coverage**: `tests/bats/setup_ui_channel_override.bats` covers
`lancache_ui_channel_override_is_valid` directly (pure function). No test
covers `lancache_read_ui_settings_override` (the actual Docker-volume read,
via a real or mocked container), `reconcile_auto_update_timer_state` (real
`systemctl` interaction), or `cmd_converge_reconcile` itself end-to-end. No
`*-simulation.sh` script exercises this command. This is a real, currently
uncovered surface — narrower in practice than it looks, since the two things
it writes (`LANCACHE_IMAGE_CHANNEL`, `AUTO_UPDATE_ENABLED`) are individually
simple `set_env_key` calls already proven safe elsewhere, but the volume-read
plumbing and the systemd-timer-state sync are genuinely untested.

---

## `debug` [install-dir]

`cmd_debug` (line 3895). Explicitly read-only diagnostics (comment: "must
not repair, update, or rewrite config"). Prints, in order: `docker compose
ps`; last 30 log lines per service (`proxy dns-standard ui netdata watchdog`,
plus `dns-ssl` if `SSL_ENABLED`); cache directory usage (`du -sh`, handles the
legacy split `CACHE_DIR_STANDARD`/`CACHE_DIR_SSL` case by erroring if they
differ rather than guessing); host LAN IPv4 addresses; and a real
`curl -sf http://<ip>/healthz` check for each configured IP (standard/ssl).

**Idempotence**: trivially yes — pure read, no state written anywhere.

**Test coverage: none found.** No `tests/bats/setup_debug*.bats` file exists
(confirmed via `git ls-tree` against `tests/bats/`), no `*-simulation.sh`
script invokes `setup.sh debug`, and it isn't called from any other tested
codepath either. Coverage is limited to whatever `bash -n`/`shellcheck` catch
syntactically (AG-VAL-007) — the actual runtime behavior of this command
(does `docker compose ps` actually run with the resolved env-file, does the
legacy-cache-path branch actually trigger correctly, does the healthz curl
against a real running stack succeed) has zero test evidence anywhere in the
repo as of this commit.

---

## `create-logs-for-issue` [install-dir] [--dest path]

`cmd_create_logs_for_issue` (line 4159, plus its `logbundle_*` helpers
starting ~line 3986). #762: bundles diagnostic state into one compressed,
secret-redacted archive so a non-programmer operator can attach ONE file to
a GitHub bug report instead of manually running/pasting commands. Read-only,
same as `debug`.

Collects: host facts (Docker/Compose version, kernel, `df -h`);
`docker compose ps`/`config` (the latter re-interpolates every `${VAR}`
reference into plain text, so it needs the same redaction as raw logs, not
"it's just config" — explicit #762 review point); per-service logs
(`--tail=2000`); a redacted copy of `.env`/`.env.local`; and directory-listing-
only (never file content) dumps of every known-good-config-snapshot location
(proxy/dhcp-proxy/pdns as Docker named volumes via a throwaway `alpine`
container; Kea's snapshot dir tries a real host path first, since it's a bind
mount in prod/quickstart but a named volume in dev).

**Redaction is deliberately two-layered** (per #762 review): a name-based
line-level scrub of the `.env` copy (`logbundle_redact_env_file` — every
credential-shaped KEY gets `[REDACTED]` unconditionally, even if already
empty/placeholder, so the archive doesn't incidentally reveal *which* secrets
were still on their default) PLUS a literal-value substitution pass over
EVERY collected artifact (`logbundle_redact_stream`, driven by
`logbundle_collect_secret_values` — gathers every non-placeholder secret
value from both env files, longest-first so no partial-substring corruption,
then does verbatim string replacement, not regex, so base64 punctuation like
`+`/`=` needs no escaping). Credential-shaped keys are matched two ways: an
explicit enumerated list (`logbundle_secret_env_keys` — 9 named keys, kept in
sync by grepping the actual generator call sites per the code comment) PLUS a
broad name-pattern safety net (`logbundle_key_looks_like_secret`: matches
`PASSWORD|SECRET|TOKEN|TSIG|CREDENTIAL|_KEY`) so a future secret-shaped
variable not yet enumerated is still caught (#762: "when in doubt,
over-redact").

**Idempotence**: N/A in the AG-OP sense (it only ever creates a new
timestamped archive, never mutates install state) but is itself
side-effect-free w.r.t. the running stack — pure collection + redaction.

**Test coverage**: `tests/bats/setup_create_logs_for_issue.bats` drives the
real functions (`logbundle_key_looks_like_secret`,
`logbundle_secret_env_keys`, `logbundle_collect_secret_values`,
`logbundle_redact_stream`, `logbundle_redact_env_file`,
`logbundle_select_compressor`, `logbundle_named_volume_listing`, and
`cmd_create_logs_for_issue` itself) with Docker mocked as a shell function
(no real daemon) — real function-level coverage, with redaction specifically
called out as getting the strongest test weight (per the file's own header
comment: "a redaction gap is a credential leak, not a cosmetic bug"). Not
covered: the real end-to-end CLI against a genuinely running Docker stack
(no `*-simulation.sh` script exercises this command against a live install).

---

## `backup` [--config\|--full] [install-dir] [--dest path]

`cmd_backup` (line 2914). Config backups (default) include configuration,
certs, secrets, runtime databases, and Docker named volumes EXCLUDING the
cache volume (`backup_manifest`, `backup_compose_volumes`); `--full` adds
cache directories/volume too and can be very large.

Sequence: validates a stack exists at `install_dir`; installs `tar`/`rsync`
if missing; pauses convergence UNLESS already paused by an enclosing
`cmd_update` call (`UPDATE_CONVERGENCE_PAUSED` guard — a standalone `setup.sh
backup` must pause it itself, or `lancache-converge.timer` could fire
mid-backup and restart the stack this command just stopped for a consistent
copy, #669); records image revisions (`record_image_revisions`, rollback
reference only, never auto-restored, warns rather than fails); stops the
stack (only restarts it afterward if it was ACTUALLY running before, #669);
rsyncs every manifest path into `dest/rootfs/…`; archives Docker volumes;
writes a `README.txt` with the restore command; tars+gzips+chmods 600 the
final archive.

**Idempotence**: each invocation creates a NEW timestamped archive — not a
convergence operation in the AG-OP-006/007 sense, but its cleanup trap
(`backup_cleanup`) is itself safe to run repeatedly / on partial failure
(restarts the stack only if it was running AND this call itself stopped it;
resumes convergence only if this call itself paused it).

**Test coverage**: `tests/bats/setup_backup_restore_safety.bats` drives the
real functions (`compose_project_name`, `compose_cache_volume_name`,
`compose_volume_names`, `backup_compose_volumes`, `compose_stack_running`,
`guard_restore_shared_project_volumes`) with Docker mocked as a shell
function — covers the #669 safety-gap fixes (guard/discovery/gating logic),
not literal `tar`/`rsync` I/O. `scripts/setup-cli-simulation.sh` Phase 3 and
Phase 4a/4b invoke the real `bash setup.sh backup --config …` CLI (not just
the extracted functions) as setup for its rollback-safety and restore-
convergence assertions — so `backup` DOES get real-CLI E2E exercise, just as
a supporting step of those phases rather than a phase with its own name.

---

## `restore` <backup.tar.gz> [install-dir]

`cmd_restore` (line 3072). Restores a backup archive into `install_dir`,
remapping paths when it differs from the archived original (both the
install tree itself and, for `deploy/prod` archives, the separate repo-root
inputs). Reads the project name from the ARCHIVED compose file/env (not the
restore target, which may not exist yet) to run
`guard_restore_shared_project_volumes` (#669 #6 — since the Compose project
name is fixed `lancache-ng` for every install, two installs on the same host
share the same named volumes regardless of install-dir; refuses to proceed
if a running stack elsewhere on this host is still using that project name).
Stops the stack (only restarts afterward if it was running before AND the
restore succeeded — on failure, leaves it stopped with a printed recovery
command using the correct `--env-file`, #669 #4); rsyncs files back
(deliberately WITHOUT `--delete`, so unrelated target-specific files aren't
nuked); handles a stale `.env.local` the archive doesn't account for
(`restore_clear_stale_env_local_if_unarchived` — renames it aside rather than
deleting, since `runtime_env_file_for_install_dir` prefers `.env.local` and
would otherwise silently keep serving the pre-restore override); refreshes
quickstart compose assets (skipped for a `deploy/prod` Git-tracked target);
restores Docker volumes.

**Issue #639 (CLOSED, verified fixed in code)**: after files/volumes are
restored, `cmd_restore` now runs the SAME `.env` convergence path as
`cmd_update` — `migrate_env_for_update "$install_dir" 1` (the `1` =
`preserve_image_tag`: keeps the archived immutable tag rather than
re-resolving against the current channel, since restoring specifically to
roll back a bad channel image must not silently re-pull whatever the channel
currently points to) then `validate_compose_config` (only if Docker/compose
is actually available — a config-only archive on a Docker-less host is an
intentionally supported offline restore path). Runs in a subshell so a
`die()` inside either helper is caught: on failure, `stack_stopped` is
cleared BEFORE `die()` so the already-stopped stack is left stopped (fail
closed per AG-OP-010) rather than started against a config that failed to
converge/validate; whatever partial `.env` writes happened are left on disk
for inspection, with the reported error naming `setup.sh update` as the
recovery path.

**Idempotence**: restoring the SAME already-converged backup twice is a
no-op for `.env` (mirrors AG-OP-011 for `update`). Restoring a legacy-format
backup converges it exactly like `update` would.

**Test coverage — real, and directly proves #639**:
- `tests/bats/setup_restore_stale_env_local.bats`: the stale-`.env.local`
  helper, function-level, fixture-driven.
- `tests/bats/setup_backup_restore_safety.bats`: shared with `backup` above
  (project-name/volume-guard logic, Docker mocked).
- `scripts/setup-cli-simulation.sh` Phase 4a: real CLI — backs up, restores
  the SAME already-converged backup, byte-diffs `.env` (same exclusion list
  as Phase 2b), asserts no-op.
- Phase 4b: real CLI — synthetically rewrites a real backup's embedded `.env`
  into the pre-#456 legacy shape (split cache keys + `PROXY_SECURITY_MODE=
  strict`, same fixture shape `setup_update_idempotence.bats` uses against
  the extracted function), restores it, asserts `CACHE_DIR` collapses
  correctly, the legacy key is gone, `PROXY_SECURITY_MODE` migrated back to
  `lazy`, and the stack comes up healthy — this is real-CLI proof of #639,
  not just the migration function in isolation.
- Phase 3 (rollback-safety) also exercises `restore` indirectly:
  `rollback_stack_update` (called by `perform_stack_update_flow` on a failed
  health gate) calls `cmd_restore` directly, so restore's stop/rsync/
  reconverge path is additionally proven under a real failure-triggered
  rollback, not only under an explicit `setup.sh restore` invocation.

---

## `secondary` --primary <url> --token <token> --name <name> --proxy-ip <ip> [--listen-ip <ip>] [--rotate]

`cmd_secondary` (line 4689). Deliberately separate from primary install: it
consumes credentials returned by the primary's `/api/secondary/register`
route, writes a small standalone DNS-only compose directory (`${name}/`),
and never touches the primary host's own configuration.

Required flags: `--primary`, `--token`, `--name` (`^[a-zA-Z0-9-]+$`),
`--proxy-ip` (valid IPv4). Optional: `--listen-ip` (else auto-detected via
`detect_secondary_listen_ip` — prefers the kernel's real route-to-internet
source address, falls back to the first non-loopback/non-Docker-bridge
address), `--rotate` (reuse an existing secondary dir, refresh credentials).

Before the registration POST, checks for a port-53 conflict on the chosen
listen IP (`secondary_choose_listen_ip` — reports what's bound via
`ss`/`fuser`/`lsof` and offers a suggested alternate; fails closed
non-interactively rather than looping forever) and platform-checks the image
tag EARLY for a `--rotate` run whose registry/prefix/channel/tag can be fully
resolved from local `.env`/env vars alone (so a Buildx/platform failure
surfaces BEFORE the registration POST rotates this secondary's NATS password
on the primary — otherwise there'd be no way to recover except registering
again, since the primary would already expect the new password).

POSTs `{token, name}` to `${primary}/api/secondary/register`, parses the JSON
response with `grep -oP` (no `jq` dependency by design), requires
`nats_url`/`nats_user`/`nats_password`/`consumer_name`/`pdns_api_key` to all
be present. Resolves image registry/prefix/channel/tag with a
precedence chain (explicit env var → existing `.env` on `--rotate` → the
primary's response → hardcoded default) and re-verifies platform support
unless the early preflight above already covered these exact values.
Generates the secondary's own `docker-compose.yml` (a single `dns-secondary`
service, PowerDNS-based, with the #615 known-good-snapshot volume and a real
healthcheck) and `.env`, then `docker compose up -d`. (Corrected 2026-07-18:
this generated healthcheck was `rec_control ping` when this file was written;
issue #946 / PRs #976/#916 replaced it with a real dig-based query/response
probe — `dig @127.0.0.1 steamcontent.com A +short +time=2 +tries=1 | grep -q .`
— explicitly per AG-VAL-018, since `rec_control ping` only proves the process
is up, not that it actually resolves.)

**Idempotence**: `--rotate` explicitly preserves anything not being rotated
(`KEEP_KNOWN_GOOD_CONFIGS` from existing `.env` if not overridden); a
non-`--rotate` run against an existing directory `die()`s rather than
silently overwriting.

**Test coverage — the weakest in the file.** `tests/bats/setup_secondary_docker_compose.bats`
is a REGRESSION TEST FOR A TEXT PATTERN, not a functional test: it locates
the `write_generated_runtime_file "${secondary_dir}/docker-compose.yml"
<<EOF` line in `setup.sh`'s own SOURCE TEXT via `grep -n`, extracts the
following ~100 lines with `sed`, and `grep`s that extracted text for the
literal strings `healthcheck:`, the exact `test: [...]` line, `interval:
30s`, etc. (guards a #652 regression where the healthcheck block was
dropped). It never invokes `cmd_secondary` as a function, never runs `setup.sh
secondary` as a subprocess, and proves nothing about the argument parsing,
JSON-response handling, image-tag resolution precedence chain, or the
`--rotate` logic. `scripts/nats-secondary-auth-callout-simulation.sh` (#583)
IS a real, live, multi-container integration test — but it drives the Admin
UI's HTTP routes directly (`curl … /api/secondary/register`), deliberately
bypassing `setup.sh secondary` entirely, to prove the NATS auth-callout
backend property (unique per-secondary credentials, revocation on delete,
rotation) independent of the CLI. **Net result: `cmd_secondary` itself — the
actual bash command an operator runs — has no test that ever executes it,
at any level**, beyond `bash -n`/shellcheck syntax checking and one grep
against its own source text.

---

## `update-ip` [install-dir] (aliases: `--reconfigure`, `reconfigure`)

`cmd_update_ip` (line 4529). Interactively changes `IP_STANDARD`/`IP_SSL` for
an EXISTING install and restarts its stack. Must run as root. Reads current
values via `resolve_update_ip_config_paths` (#666 fix: this used to be
hardwired to the repo checkout's own `deploy/prod`/`config/prod` paths
regardless of the passed `install_dir` — now correctly resolves a quickstart
install's single `.env` vs. a `deploy/prod` checkout's separate
`config/prod/dns-{standard,ssl}.env` files). Prompts for new IPs (validated,
must differ from each other), then on confirmation: rewrites `IP_STANDARD`/
`IP_SSL` via `sed -i` in the resolved deploy env, ALSO updates `UI_BIND_IP`
and `DHCP_DNS_PRIMARY`/`SECONDARY` — but ONLY if they still equal their
pre-change install-time default (so an operator's explicit override, e.g.
`UI_BIND_IP=127.0.0.1`, is left alone); updates the two `dns-*.env` files'
`PROXY_IP` if present (quickstart has none — `PROXY_IP` there reads straight
from `IP_STANDARD`/`IP_SSL`). Then `docker compose up -d`, with an EXPLICIT
success/failure branch (comment notes `cmd1 && cmd2` as a bare statement is
exempt from `set -e` when not the list's last command — verified directly —
so a silent `if` was needed to make a restart failure actually fatal/visible).

**Idempotence**: re-running with the SAME IPs is effectively a no-op restart
(the conditional `UI_BIND_IP`/DHCP-DNS rewrites only fire if the value still
equals the OLD default, so a second run with unchanged IPs correctly does
nothing there either).

**Test coverage**: `tests/bats/setup_update_ip_install_dir.bats` covers
`resolve_update_ip_config_paths` directly (pure function, no `ask`/docker) —
the #666 path-resolution regression this rewrite fixed. The interactive
prompt flow and the actual `docker compose up -d` restart are NOT driven by
any `*-simulation.sh` script or `expect`-based test — no real-CLI E2E
coverage exists for `update-ip`, unlike `install`/`update`/`backup`/`restore`.

---

## `reset-to-last-known-good-config` <service> [install-dir] [snapshot-id] [--yes]

`cmd_reset_to_last_known_good_config` (line 4329). #763's CLI fallback for
when the Admin UI itself is unreachable but a service's own control surface
still is. Dispatches on `<service>`:
- `kea`/`dhcp` → `reset_kea_to_last_known_good_config`: lists known-good
  `dhcp4.json` snapshots (`list_kea_snapshot_ids`, mirrors
  `services/ui/src/kea_snapshots.rs::list_snapshot_ids` exactly — skips
  `.staging-<id>` dirs, requires a finalized `dhcp4.json`), defaults to the
  newest if no `snapshot-id` given (with a warning), requires confirmation
  unless `--yes`/`-y`, then runs the real three-call Kea Control Agent
  sequence over HTTP Basic auth (`kea_ctrl_post`): `config-test` →
  `config-set` → `config-write` — the exact sequence
  `services/ui/src/routes/dhcp.rs`'s `rollback_kea_snapshot` already runs
  when the UI IS reachable, automated here rather than reinvented. Fails
  closed if `KEA_CTRL_TOKEN` is missing, if `KEA_CONFIG_SNAPSHOT_DIR` was
  overridden to a non-default value this script can't map to a host path, or
  if the Control Agent rejects any of the three calls.
- `dns`/`pdns`/`dns-standard`/`dns-ssl` → explicit `die()` naming issue
  **#628** (PowerDNS zone/record rollback listener) as the blocker — NOT
  silently no-op'd, and not guessed at. **Issue #836** ("complete the
  dns/pdns service target") is the still-open tracking issue for closing
  this gap.
- empty/unknown service → `die()` with usage.

**Idempotence**: re-applying the same snapshot id is idempotent at the Kea
level (config-test/set/write against the same JSON payload). The command
itself does not record a fresh snapshot of the just-restored state (the
Admin UI's own `rollback_kea_snapshot` does, when reached that way) —
explicitly flagged to the operator in the command's own final `print_warn`.

**Test coverage**: `scripts/setup-reset-kea-config-simulation.sh` is a real,
live, multi-container E2E test (#763/#634 topology reuse) — starts a real
Kea container + a real Admin UI container sharing a bind-mounted `kea-data`
dir, creates two known-good snapshots via genuine Admin UI HTTP routes
(reservation A, then A+B), runs the REAL `setup.sh reset-to-last-known-good-config
kea --yes` CLI, then confirms via a fresh `config-get` against the real Kea
server that reservation A is back and B is gone — proof the command
genuinely rolled live config back, not just that the API calls returned
success. This is real-CLI E2E coverage, on par with the `setup-cli-
simulation.sh` phases. Explicitly NOT covered (per that script's own header
comment): the interactive confirmation prompt itself (bypassed via `--yes`),
and the `dns`/`pdns` target (not yet implemented, #628/#836). So: `kea` target
= strong E2E coverage; `dns`/`pdns` target = unimplemented by design, tracked
separately.

---

## `help` / `--help` / `-h`

`print_usage` (line 3241) — deliberately compact top-level list so `curl |
bash` users aren't flooded; per-command detail lives in `print_command_help`
(line 3281), invoked via `<command> --help`/`<command> help` for every
command except `converge-reconcile` (intentionally undocumented/internal).
No functional test needed/expected — pure static text output; would be
caught by `bash -n` if the heredocs were malformed.

---

## Cross-cutting: `scripts/check-idempotence-test-coverage.sh` scope note

This CI guard (per AGENTS.md's Convergence/Idempotence Checklist,
`AG-OP-006`/`007`/`011` enforcement rows) treats **all of `setup.sh` as ONE
writer entry**:

```
"setup.sh|tests/bats/setup_update_idempotence.bats"
```

It only requires ONE evidence file with at least one active `@test` whose
name contains repeat/idempoten/converge. That evidence file
(`setup_update_idempotence.bats`) genuinely does prove `migrate_env_for_update`'s
repeat-run convergence — but the guard's granularity means it makes no claim
whatsoever about `cmd_backup`, `cmd_restore`, `cmd_secondary`, `cmd_update_ip`,
`cmd_auto_update`, `cmd_converge_reconcile`, `cmd_debug`, or
`cmd_create_logs_for_issue` as individually-guarded config-writers — a
regression that removed repeat-run coverage from any of those (while leaving
`setup_update_idempotence.bats` itself untouched) would NOT fail this CI
check. In practice several of them DO have real repeat-run/convergence proof
(restore's Phase 4a/4b in `setup-cli-simulation.sh`, update's Phase 2b) — the
observation here is that this specific automated guard does not know that;
its coverage claim is narrower than the file's actual test suite.

---

## Test-coverage summary matrix

| Subcommand | Real CLI E2E (`*-simulation.sh` / `expect`) | Function-level bats (real function, mocked I/O) | Text/regex-only test | No coverage found |
|---|---|---|---|---|
| `install` | ✅ `setup-cli-simulation.sh` Phase 1 | ✅ (dhcp_mode, image_platform_guard, quickstart_assets, channel_stable_edge) | — | — |
| `update` | ✅ Phase 2, 2b, 3 | ✅ (env_migration, update_idempotence, nats_secondary_override) | — | — |
| `auto-update` | — (only inherits `update`'s coverage via shared `perform_stack_update_flow`) | ✅ (`setup_auto_update_gate.bats`, pure gate function only) | — | partial — the `cmd_auto_update` wrapper itself |
| `converge-reconcile` | — | ✅ (`setup_ui_channel_override.bats`, one helper only) | — | mostly — volume-read + systemd-sync + the command body |
| `debug` | — | — | — | ✅ complete |
| `create-logs-for-issue` | — | ✅ (`setup_create_logs_for_issue.bats`, real functions, mocked docker) | — | — (real Docker E2E not covered, but function coverage is strong) |
| `backup` | ✅ (as setup step in Phase 3/4a/4b) | ✅ (`setup_backup_restore_safety.bats`) | — | — |
| `restore` | ✅ Phase 4a, 4b, + indirectly via rollback in Phase 3 | ✅ (`setup_restore_stale_env_local.bats`, `setup_backup_restore_safety.bats`) | — | — |
| `secondary` | — (NATS backend integration test bypasses the CLI) | — | ✅ (`setup_secondary_docker_compose.bats` greps source text only) | effectively ✅ — `cmd_secondary` itself never executes in any test |
| `update-ip` | — | ✅ (`setup_update_ip_install_dir.bats`, path-resolution only) | — | partial — prompt flow + restart |
| `reset-to-last-known-good-config` | ✅ (`setup-reset-kea-config-simulation.sh`, `kea` target only) | — | — | `dns`/`pdns` target: unimplemented (not a test gap, #628/#836) |
| `help` | N/A (static text) | N/A | N/A | N/A |

## Related GitHub issues referenced in code / cross-checked

- **#639** (CLOSED, verified 2026-07-13) — `setup.sh restore` did not
  re-converge `.env`; fixed, now covered by real-CLI Phase 4a/4b.
- **#665** — image-tag/platform preflight (`assert_resolved_image_tag_
  platform_supported`); threaded through install/update/restore/secondary.
- **#669** (CLOSED) — 6 backup/restore safety gaps (convergence-timer pause,
  stack-state capture, cache-volume exclusion, restore-failure restart
  behavior, shared-project-volume guard); fixed, covered by
  `setup_backup_restore_safety.bats`.
- **#666** — `update-ip` hardwired to the repo's own `deploy/prod` paths
  regardless of `install_dir`; fixed via `resolve_update_ip_config_paths`,
  covered by `setup_update_ip_install_dir.bats` (function-level only).
- **#652** (CLOSED) — secondary's generated compose heredoc dropped its
  healthcheck block; the ONLY regression test for `cmd_secondary` guards
  exactly this and nothing else.
- **#762** — `create-logs-for-issue` (this whole command originates here).
- **#763** — `reset-to-last-known-good-config` (this whole command
  originates here); Kea target implemented + E2E tested, DNS/PDNS target
  explicitly deferred to #628.
- **#628** — PowerDNS zone/record rollback listener; blocks the `dns`/`pdns`
  target of `reset-to-last-known-good-config`.
- **#836** (OPEN) — tracking issue to complete that DNS/PDNS target once #628
  lands.
- **#819** — replaced Watchtower with `auto-update`/`converge-reconcile`
  (health-gated, ordered, rollback-capable update orchestration); introduced
  both of those subcommands plus the systemd timer units.
- **#456** (OPEN) — the project-wide convergence/idempotence audit that
  produced AG-OP-006..013 and the Convergence/Idempotence Checklist this
  whole inventory cross-references.
- **#785** (OPEN) — scheduled channel-install smoke check gap (published
  `dev`/`edge` channel installability no longer implicitly checked by the
  per-PR gate).
- **#843** (this umbrella issue) — project-wide capability inventory.

No open issue currently tracks the `cmd_secondary`/`cmd_debug`/
`converge-reconcile` real-CLI test-coverage gaps identified in this
inventory — these are new observations from this audit, not yet filed.

---

## Shared helper-function inventory (env/secret/systemd/backup helpers, lines ~869-2914)

Every `cmd_*` function above is built on a large shared layer of helpers.
Full pass over every function between `get_env_var` (869) and
`record_image_revisions` (2903, the line before `cmd_backup` starts) —
condensed here; every function was individually checked for purpose,
reads/writes, idempotence, and test coverage.

**`.env` read primitives** (`get_env_var`, `get_env_var_nonempty`,
`get_env_assignment_value_raw[_nonempty]`, `env_key_exists`,
`env_key_has_value`) — pure readers, no isolated `@test` for any of them;
correctness is proven only transitively through every
`migrate_env_for_update` test. A refactor of these primitives alone would
have no dedicated regression coverage.

**Secret classification/generation** (`secret_value_is_placeholder`,
`env_key_has_usable_secret`, `generate_secret_value`, `get_or_generate_secret`)
— `env_key_has_usable_secret` is the idempotence gate every secret-writing
caller relies on (proven via `setup_update_idempotence.bats`).
**`generate_secret_value` itself is NOT idempotent** (each call is a fresh
`openssl rand` draw) — the whole system's secret stability (AG-OP-006)
depends entirely on every caller gating it behind `env_key_has_usable_secret`
first. That is correctly done everywhere today, but it is a single
architectural control point: a future call site that skips the gate would
immediately rotate a secret on every run. `get_or_generate_secret` itself has
no direct test and appears unused in the current `migrate_env_for_update`
call graph (which uses `ensure_secret_env_key` instead) — possibly dead code,
not fully verified since call sites outside this line range weren't checked
by this pass.

**`.env` value validation** (`validate_env_value`, `validate_env_values_for_initial_write`)
— no direct test found for either; exercised only transitively (no isolated
negative test for a rejected character was found in this line range).

**`.env` write primitives** (`set_env_key`, `set_env_assignment`,
`append_env_key_if_missing`, `set_env_key_if_empty_or_missing`,
`append_env_assignment_if_missing`, `append_env_migrated_assignment_if_missing`,
`append_required_env_migrated_assignment_if_empty_or_missing`,
`migrate_proxy_security_mode_for_update`) — all individually idempotent by
design (preserve-existing-or-fill-default pattern); `set_env_key` also
cleans up any pre-existing duplicate key lines on write (self-healing).
`append_env_migrated_assignment_if_missing` and
`migrate_proxy_security_mode_for_update` have DIRECT bats coverage
(`setup_env_migration.bats`); the others are proven only transitively via
`setup_update_idempotence.bats`.
**Gap**: `append_required_env_migrated_assignment_if_empty_or_missing` (the
"never allowed to stay empty" variant) has no isolated test, unlike its
"optional" sibling.

**Legacy path resolution** (`legacy_state_path`, `legacy_state_root_has_known_children`,
`legacy_state_root_or_default`, `legacy_dir_or_default`) — pure readers, no
direct tests, exercised transitively.

**Path-override/removal helpers** (`set_optional_env_path_override_if_needed`,
`remove_env_key`) — idempotent by design (removes an override once it matches
the derived default, converging the "one state root" contract); no direct
test, proven transitively via `migrate_env_for_update` fixtures.

**Install-dir/compose-file resolution** (`production_state_root_default`,
`is_deploy_prod_install_dir`, `runtime_env_file_for_install_dir`,
`nats_secondary_override_active_for_install_dir`,
`compose_file_args_for_install_dir`, `install_quickstart_compose_assets`) —
this group has GOOD direct coverage: `runtime_env_file_for_install_dir` is
tested in 3 separate bats files; `nats_secondary_override_active_for_install_dir`
and `compose_file_args_for_install_dir` have 10 combined tests in
`setup_nats_secondary_override.bats`; `install_quickstart_compose_assets` has
its own dedicated `setup_quickstart_assets.bats` including an explicit
"running install twice on an already-correct install stays idempotent" test.

**Git repo sync** (`git_default_branch_name`, `git_repo_is_clean`,
`sync_repo_to_default_branch`, `deploy_prod_repo_root`,
`deploy_prod_repo_input_paths`, `resolve_update_ip_config_paths`) —
`resolve_update_ip_config_paths` is well tested (4 tests,
`setup_update_ip_install_dir.bats`, the #666 fix). **Gap**:
`sync_repo_to_default_branch` — a destructive `git checkout -B` hard-reset
onto `origin/<default>`, refuses on a dirty tree — has no isolated repeat-run
test anywhere found.

**Atomic file writers** (`write_env_file`, `write_generated_runtime_file`) —
idempotent as a mechanism (temp file + `mv`, preserves owner/mode for
`.env`); no direct test, but exercised by every caller's test.

**Update guards/secret wrapper** (`require_env_value_for_update`,
`ensure_secret_env_key`, `cache_size_gb_from_env`) — `ensure_secret_env_key`
is the AG-OP-006 linchpin, proven via every secret-stability assertion in
`setup_update_idempotence.bats`.

**Platform guards** (`assert_prebuilt_image_platform_supported`,
`host_image_platform`, `assert_resolved_image_tag_platform_supported`) —
well tested: `setup_image_platform_guard.bats` has 2+2+7 tests covering
architecture detection and the #665 resolved-tag-platform check (single-
platform success, multi-platform index fallback, missing buildx, unreachable
registry, missing docker).

**systemd convergence-timer interaction (NOT unit installation)**
(`systemd_unit_exists`, `pause_lancache_convergence_for_update`,
`resume_lancache_convergence_after_update`,
`resume_lancache_convergence_after_failed_update`) — **no test coverage found
for any of these four** (distinct from `watchdog_idempotence.bats`, which
tests a different component, the watchdog service itself, not this
convergence-timer pause/resume logic). **`pause_lancache_convergence_for_update`
is not demonstrably reentrant-safe**: it captures the pre-pause systemd state
into globals on every call; calling it twice without an intervening resume
would read the timer as already-stopped on the second call and overwrite the
"was originally active" flag, so a later resume would incorrectly leave the
timer disabled. Not currently a real bug in the traced call graph (called
once per update from `cmd_update`), but the function itself has no reentrancy
guard and no test proves the single-call assumption holds everywhere it's
used.

**Image tag/channel validation & resolution** (`validate_lancache_image_tag`,
`validate_lancache_image_channel`, `derive_release_archive_image_tag`,
`validate_lancache_image_registry`, `validate_lancache_image_prefix`,
`resolve_lancache_image_registry`, `resolve_lancache_image_prefix`,
`resolve_lancache_image_channel`, `lancache_stack_pointer_channel_for`,
`resolve_lancache_stack_channel_tag`, `resolve_lancache_image_tag`) — mixed:
`validate_lancache_image_channel`/`resolve_lancache_image_channel`/
`lancache_stack_pointer_channel_for`/`derive_release_archive_image_tag`/
`resolve_lancache_image_tag` all have solid direct bats coverage.
**Gaps**: `validate_lancache_image_tag` (accepts only `sha-*`/`pr-<N>-sha-*`/
`vX.Y.Z[-rc.N]`, rejects mutable channel names — a real security-relevant
guard) has NO isolated test found, nor do `validate_lancache_image_registry`,
`validate_lancache_image_prefix`, `resolve_lancache_image_registry`, or
`resolve_lancache_image_prefix`. `resolve_lancache_stack_channel_tag` (the
one function that does a real `docker pull`/`cp`/`tar` against a live
registry to resolve a channel pointer to an immutable `sha-*`) has no bats
test — by design, it needs a real registry, so it's covered instead only by
`scripts/setup-cli-simulation.sh`'s real end-to-end run (subject to the #785
gap noted above: only exercised on non-PR CI events since the per-PR gate
switched to pinned images).

**`migrate_env_for_update` itself (2287-~2604, ~320 lines)** — see the
`update` subcommand section above; this is the single most thoroughly
tested function in the whole file (dedicated bats file + CLI-simulation
phases + explicitly named in the AGENTS.md enforcement matrix as the
concrete evidence for AG-OP-006/007/011).

**Backup/restore support helpers** (`install_missing_tools`,
`backup_manifest`, `path_is_inside`, `compose_stack_available`,
`compose_stack_running`, `compose_stack_stop`, `compose_stack_start`,
`validate_compose_config`, `compose_project_name`,
`compose_cache_volume_name`, `compose_volume_names`,
`backup_compose_volumes`, `restore_compose_volumes`,
`guard_restore_shared_project_volumes`, `record_image_revisions`) — mixed:
`compose_stack_running`, `compose_project_name`, `compose_cache_volume_name`,
`compose_volume_names`, `backup_compose_volumes`, and
`guard_restore_shared_project_volumes` all have direct tests in
`setup_backup_restore_safety.bats`. **Gaps, several notable given how
security/safety-critical this group is**: `backup_manifest` (defines backup
SCOPE — what gets included) has no isolated test; `path_is_inside` (prevents
a backup destination recursively archiving itself) has no test;
`compose_stack_stop` has no direct test; **`compose_stack_start` has no test
of any kind found anywhere** (not even mentioned in a helper file);
**`validate_compose_config`** (the `docker compose config` dry-run that
AG-OP-010 requires to run before any restart/pull) **has no test found** —
notable since this is exactly the kind of "validate before mutate" gate
AGENTS.md calls out as safety-critical; **`restore_compose_volumes`** (the
destructive clean-replace of a named volume's entire contents from an
archive) **has no isolated test** despite being one of the more dangerous
operations in the file; `record_image_revisions` has no test (low risk —
purely informational, never auto-restored).

### Top findings from the helper-layer pass

1. `migrate_env_for_update` is the only area with complete, explicit
   AG-OP-006/007/011 test coverage (repeat-run fixtures, secret-stability
   assertions, hash comparison) — consistent with the AGENTS.md enforcement
   matrix.
2. The foundational `.env` read/write primitives have no isolated unit tests
   of their own; correctness is proven only transitively through
   `migrate_env_for_update`'s tests.
3. Clear test gaps on security-relevant validators:
   `validate_lancache_image_tag`, `validate_lancache_image_registry`,
   `validate_lancache_image_prefix`.
4. Convergence-timer pause/resume (`systemd_unit_exists` through
   `resume_lancache_convergence_after_failed_update`) has zero test coverage,
   and `pause_lancache_convergence_for_update` is not demonstrably safe
   against being called twice without an intervening resume.
5. Several backup/restore core functions have no direct test:
   `backup_manifest`, `path_is_inside`, `compose_stack_stop`,
   `compose_stack_start` (no test anywhere), `validate_compose_config`,
   `restore_compose_volumes`, `record_image_revisions`. Given AG-OP-010
   ("validate before restart/pull") and the destructive nature of volume
   restore, `validate_compose_config` and `restore_compose_volumes` lacking
   direct coverage stand out.
6. `generate_secret_value` is not idempotent by itself (fresh random value on
   every call); the whole system's secret stability depends entirely on
   every call site gating it behind `env_key_has_usable_secret` first. That
   holds correctly everywhere today, but it is a single architectural
   control point rather than a property of the generator itself.
