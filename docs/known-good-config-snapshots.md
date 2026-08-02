# Known-Good Configuration Snapshots

LanCache-NG regenerates several runtime-managed service configurations from
templates, environment variables, and files such as `cdn-domains.txt` every
time a container starts (or, for Kea, whenever the Admin UI pushes a change).
This mechanism keeps a small, validated history of those generated configs so
a bad regeneration — a malformed `cdn-domains.txt` entry, a template bug
introduced by an upgrade, a bad env var — does not either crash-loop the
container or silently run with an invalid config.

This is separate from `setup.sh backup`/`restore` (see
[backup-restore.md](backup-restore.md)), which is a manual, operator-driven
disaster-recovery mechanism covering the whole install. Known-good snapshots
are small, automatic, config-only, and scoped to one service's own generated
runtime config.

Related: issue #415 (parent), #614 (Kea adapter). Related but distinct: the
Kea DHCP mutation path's single-level, in-request rollback added in PR #380
(see "Kea" below).

## Contract

The generic contract (implemented once, documented in
`scripts/lib/known-good-snapshots.sh`, and followed by every file-based
adapter) is:

1. **Validate before snapshotting.** A snapshot is only created after the
   candidate config passes that service's real validation command (`nginx
   -t`, `dnsmasq --test`, Kea `config-test`). Nothing invalid is ever
   snapshotted.
2. **Retention is configurable, default 3.** `KEEP_KNOWN_GOOD_CONFIGS`
   controls how many validated snapshots are kept per service; the oldest
   are pruned automatically whenever a new one is created. The default of 3
   applies if the variable is unset, empty, or not a positive integer.
3. **Snapshots live in a persistent, service-owned volume**, never in the
   ephemeral container layer, so they survive container recreation:

   | Service | Snapshot path (in-container) | Volume |
   |---|---|---|
   | proxy (nginx) | `/var/lib/lancache-proxy/config-snapshots` | `proxy-config-snapshots` |
   | dhcp-proxy (dnsmasq) | `/var/lib/lancache-dhcp-proxy/config-snapshots` | `dhcp-proxy-config-snapshots` |
   | dns-standard, dns-ssl (PowerDNS recursor + auth) | `/var/lib/lancache-dns/config-snapshots/{recursor,auth}` | `pdns-config-snapshots-standard`, `pdns-config-snapshots-ssl` |
   | dns-secondary (remote secondary node, same image/entrypoint) | `/var/lib/lancache-dns/config-snapshots/{recursor,auth}` | `pdns-config-snapshots` |
   | dhcp (Kea) | `/var/lib/kea/config-snapshots` — see "Kea" below | `kea-data` (shared with the `dhcp` service) |

4. **Rollback refuses invalid snapshots.** When a candidate config fails
   validation, the adapter tries every stored snapshot from newest to
   oldest, re-validating each one before applying it. A snapshot that fails
   validation is rejected and logged; it is never applied. If no snapshot
   validates (or none exist), the destination files are left exactly as
   they were before the rollback attempt was made, and the caller treats
   this as fatal (refuses to start rather than run with something unverified).
5. **Every lifecycle event is logged explicitly**, tagged
   `[known-good-snapshot][<service>][<LEVEL>]` with `LEVEL` one of `CREATE`,
   `PRUNE`, `SELECT` (chosen for rollback), or `REJECT`/`FATAL`.

## Incident Runbooks

**Use this section when a service fails to start or crashes in a loop.** Each procedure below covers one adapter and one failure scenario. Start by identifying which service is failing (check `docker compose ps` or the Admin UI Status page), then follow the corresponding procedure. All commands assume you are running `docker compose` from the stack's root directory with `-f deploy/prod/docker-compose.yml` (or use the exact `-f` syntax shown in each procedure if you need to target a specific environment).

### Prerequisites for all procedures

1. SSH or console access to the LanCache-NG host
2. The stack installed at `/opt/lancache-ng` (default; adjust `install-dir` below if different)
3. `docker` and `docker compose` available on your PATH

### nginx / Proxy (`proxy` service) — Configuration validation failure

**Symptoms:**  `proxy` container in `Exited` or `Restarting` state. Log shows error like:
```
[lancache] ERROR: generated nginx config failed validation (nginx -t).
```

**What's happening:** The generated `nginx.conf`, `proxy-params.conf`, or SSL/stream maps failed validation. This usually means a broken `cdn-domains.txt` entry or a bad environment variable substitution.

**Procedure:**

1. Check the container's recent logs:
   ```bash
   cd /opt/lancache-ng
   docker compose -f deploy/prod/docker-compose.yml logs --tail=50 proxy
   ```
   Look for lines like:
   - `[lancache] WARNING: skipping invalid domain entry: …` — a domain in `cdn-domains.txt` is malformed
   - `[lancache] ERROR: generated nginx config failed validation (nginx -t).` — syntax error in generated config
   - `[lancache] ERROR: PROXY_SECURITY_MODE must be lazy or strict…` — env var typo or wrong value

2. If you see `WARNING: skipping invalid domain entry`, fix `services/dns/cdn-domains.txt` (shared by proxy and DNS):
   ```bash
   # Edit the file
   vim /opt/lancache-ng/services/dns/cdn-domains.txt
   
   # Each line should be a plain domain name, one per line (no spaces, no wildcards)
   # Example (correct):
   # steamcontent.com
   # origin.gog.com
   ```

3. If you see `ERROR: PROXY_SECURITY_MODE`, check your `.env`:
   ```bash
   grep PROXY_SECURITY_MODE /opt/lancache-ng/.env
   # Must be one of: lazy, strict
   ```

4. Restart the proxy after any fix:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml up -d proxy
   docker compose -f deploy/prod/docker-compose.yml logs proxy
   ```

5. If the container still exits, the automatic known-good config rollback tried (and the logs should show `[known-good-snapshot][proxy][SELECT]` lines). Verify rollback:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml logs proxy | grep "known-good-snapshot"
   ```

6. **If you see `[known-good-snapshot][proxy][FATAL]`**: all rollback snapshots are exhausted. This means even the previously-working config no longer validates (e.g., an nginx version upgrade in a new image build). See "Exhaustion: no valid snapshots remain" below.

### dnsmasq / DHCP Proxy (`dhcp-proxy` service) — Configuration validation failure

**Symptoms:** `dhcp-proxy` container in `Exited` or `Restarting` state. Log shows error like:
```
[lancache] ERROR: generated dnsmasq config failed validation (dnsmasq --test).
```

**What's happening:** The rendered `dnsmasq.conf` failed validation. This usually means a bad environment variable or an invalid DHCP/relay option configuration.

**Procedure:**

1. Check recent logs:
   ```bash
   cd /opt/lancache-ng
   docker compose -f deploy/prod/docker-compose.yml logs --tail=50 dhcp-proxy
   ```
   Look for lines like:
   - `[lancache] ERROR: generated dnsmasq config failed validation (dnsmasq --test).` — syntax error
   - `Error in config file…` — specific dnsmasq directive is malformed

2. Check the `.env` for DHCP-related variables:
   ```bash
   grep -E "DHCP_|UPSTREAM_DHCP" /opt/lancache-ng/.env
   # Required variables that must be set and valid:
   # DHCP_SUBNET_START=<IP>  (e.g., 192.168.1.100)
   # DHCP_DNS_PRIMARY=<IP>   (e.g., 192.168.1.10)
   # DHCP_DNS_SECONDARY=<IP> (e.g., 192.168.1.11)
   # UPSTREAM_DHCP_IP=<IP>   (IP of real upstream DHCP server, if relaying)
   ```

3. If an IP address looks wrong, fix it in `.env`:
   ```bash
   vim /opt/lancache-ng/.env
   # Edit the line, save
   ```

4. Restart and check logs:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml up -d dhcp-proxy
   docker compose -f deploy/prod/docker-compose.yml logs dhcp-proxy
   ```

5. Verify rollback:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml logs dhcp-proxy | grep "known-good-snapshot"
   ```

6. **If you see `[known-good-snapshot][dhcp-proxy][FATAL]`**: all rollback snapshots are exhausted. See "Exhaustion: no valid snapshots remain" below.

### Kea DHCP Server (`dhcp` service) — Configuration validation failure

**Symptoms:** `dhcp` container in `Exited` or `Restarting` state (if using the DHCP profile), or running but reporting `unhealthy` from `docker compose ps`. Admin UI DHCP page shows errors.

**What's happening:** Kea's configuration validation failed during startup, OR the Admin UI tried to apply a new config and it failed to validate.

**Procedure:**

1. Check container status:
   ```bash
   cd /opt/lancache-ng
   docker compose -f deploy/prod/docker-compose.yml ps dhcp
   # If the container is not running at all, skip to step 3 below.
   # If it's running but unhealthy, Kea Control Agent may still be reachable.
   ```

2. **If the container is running (even if unhealthy), try the Admin UI first:**
   - Open the Admin UI in your browser and navigate to the **DHCP** page
   - The page lists known-good Kea config snapshots (newest first)
   - Click **Rollback** on the newest snapshot that you remember being valid
   - Admin UI logs the rollback; check `docker compose logs ui` for status

3. **If the container is not running, or Admin UI is unreachable, use the CLI fallback:**
   ```bash
   ./setup.sh reset-to-last-known-good-config kea [--yes]
   ```
   
   This command:
   - Lists known-good `dhcp4.json` snapshots stored on disk (newest first, with UTC timestamps)
   - Prompts you to confirm which snapshot to restore (or use `--yes` to restore the newest without prompting)
   - Applies the snapshot via Kea's Control Agent API (the same sequence the Admin UI uses)
   - Persists the config to disk

4. Check logs after rollback:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml logs dhcp
   ```

5. **If the container still fails to start or stays unhealthy after rollback**, or if `setup.sh reset-to-last-known-good-config kea` reports no snapshots exist: the snapshot history is exhausted. See "Exhaustion: no valid snapshots remain" below.

### PowerDNS — Static config (`dns-standard`, `dns-ssl` services) — Configuration validation failure

**Symptoms:** `dns-standard` or `dns-ssl` container exits with a log like:
```
[lancache-dns] ERROR: generated recursor.conf/pdns.conf failed validation.
[lancache-dns] ERROR: attempting rollback to the newest known-good snapshot instead.
```

**What's happening:** The generated `recursor.conf` (PowerDNS Recursor) or `pdns.conf` (Authoritative server) failed validation. This usually means a bad `PDNS_API_KEY`, `DDNS_ALLOW_FROM`, or `DDNS_TSIG_KEY` value.

**Procedure:**

1. Identify which file failed by checking logs:
   ```bash
   cd /opt/lancache-ng
   docker compose -f deploy/prod/docker-compose.yml logs --tail=50 dns-standard
   # or: docker compose -f deploy/prod/docker-compose.yml logs --tail=50 dns-ssl
   ```
   
   Look for which validation failed:
   - `pdns_recursor --config=check` → recursor.conf validation failed
   - `pdns_server --config=check` → pdns.conf (authoritative) validation failed

2. Check environment variables used in config template:
   ```bash
   grep -E "PDNS_API_KEY|DDNS_ALLOW_FROM|DDNS_TSIG_KEY|LOG_QUERIES" /opt/lancache-ng/.env
   ```
   These variables are baked into the config. Common issues:
   - `PDNS_API_KEY` is empty or contains invalid characters
   - `DDNS_ALLOW_FROM` is set to a malformed CIDR/IP list

3. Fix the variable in `.env`:
   ```bash
   vim /opt/lancache-ng/.env
   # Edit and save
   ```

4. Restart the DNS container:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml up -d dns-standard
   # or dns-ssl, or both
   docker compose -f deploy/prod/docker-compose.yml logs dns-standard
   ```

5. Verify rollback happened:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml logs dns-standard | grep "\[known-good-snapshot\]"
   # Look for [SELECT] lines showing a snapshot was chosen
   ```

6. **If you see `[known-good-snapshot][dns][FATAL]`**: all static-config snapshots are exhausted. See "Exhaustion: no valid snapshots remain" below.

**Note for secondary DNS nodes:** If running a secondary DNS node (from `setup.sh secondary`), it uses the same `dns` image and entrypoint, so the same procedure applies. Secondary nodes have their own independent `pdns-config-snapshots` volume.

### PowerDNS — Zone/record rollback (`dns-standard`, `dns-ssl` services) — Incorrect zone data

**Symptoms:** DNS queries return wrong answers, or zones contain stale/incorrect records. You did NOT recently change the zone manually — this is data corruption or an erroneous NATS message.

**What's happening:** The zone data in `pdns.sqlite3` (stored in `lan.`, `local.lan.`, or a private reverse zone) is incorrect. This can happen due to a bug in Kea's DDNS updates, a bad Admin UI publish, or corrupted NATS messages.

**Procedure:**

1. **If the Admin UI is reachable, use it first:**
   - Open the Admin UI, navigate to **DNS** > **Zones**
   - Click on the affected zone name (e.g., `lan.`)
   - Scroll to "Known-good zone snapshots" and see the list
   - Click **Rollback** on a snapshot you remember being correct (usually the newest, unless you suspect it's also bad)

2. **If the Admin UI is unreachable, use the CLI fallback:**
   ```bash
   ./setup.sh reset-to-last-known-good-config dns /opt/lancache-ng lan [--yes]
   # Replace "/opt/lancache-ng" with your install directory if different -- this
   # argument is REQUIRED here even if you're using the default, because the
   # zone argument that follows it is positional (there is no way to skip it)
   # Replace "dns" with "dns-standard" or "dns-ssl" to target a specific container
   # Replace "lan" with the zone you want to fix (with or without a trailing dot -- both work)
   ```
   
   This command:
   - Lists known-good snapshots for that zone (newest first, with UTC timestamps)
   - Applies the chosen snapshot (or the newest with `--yes`)
   - Re-publishes the restored records to secondary DNS nodes (if applicable)
   - Flushes PowerDNS Recursor caches so clients see the fix immediately

3. Verify the zone is fixed:
   ```bash
   # From inside the dns-standard container, check one record:
   docker compose -f deploy/prod/docker-compose.yml exec dns-standard sh -c \
     'dig @127.0.0.1 <hostname>.<zone> +short'
   # Example: dig @127.0.0.1 mydevice.lan +short
   ```

4. Check logs:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml logs dns-standard | grep -E "\[known-good-snapshot\]|rollback"
   ```

5. **If the rollback command fails because no snapshots exist for that zone**: zone snapshots have never been taken (the zone has no NATS-driven updates yet, or automatic snapshotting is not enabled). Manual fixes in this case require direct database inspection; see "Exhaustion: no valid snapshots remain" below.

### Exhaustion: no valid snapshots remain

**Symptoms:** A service exits with `[known-good-snapshot][<service>][FATAL]` after trying all stored snapshots, or `./setup.sh reset-to-last-known-good-config` reports no snapshots exist.

**What's happening:** The service's generated config failed validation, every previously-stored snapshot also fails validation (e.g., an nginx/dnsmasq version upgrade), and there is no further automatic recovery. This is exactly the scenario rescue mode (issue #763 part 1) is meant to address.

**Procedure:**

1. Identify the root cause. Check the logs for the *first* validation error (before the rollback attempts):
   ```bash
   cd /opt/lancache-ng
   docker compose -f deploy/prod/docker-compose.yml logs <service> 2>&1 | head -100
   # Example for proxy: docker compose -f deploy/prod/docker-compose.yml logs proxy 2>&1 | head -100
   ```
   The error message before the "attempting rollback" line tells you what was wrong with the config.

2. **Fix the root cause:**
   - If it's a `cdn-domains.txt` malformed entry, edit `services/dns/cdn-domains.txt`
   - If it's an env var, edit `.env`
   - If it's a template bug (rare), this requires a code fix or downgrade (consult project documentation)

3. **Once you've fixed the input**, check if rescue mode is enabled for this service:
   ```bash
   # Rescue mode means the container is still running even though the service failed to start.
   # Check if the container is up but unhealthy:
   docker compose -f deploy/prod/docker-compose.yml ps <service>
   ```
   
   If the container is running, you may be able to `docker exec` into it for inspection:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml exec <service> sh
   # Inside: check logs, inspect config files, etc.
   exit
   ```

4. Once the underlying issue is fixed, restart the container fresh:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml restart <service>
   docker compose -f deploy/prod/docker-compose.yml logs <service>
   ```

5. **If the container does NOT come up**, and you haven't enabled rescue mode, you must either:
   - Fix the config from outside the container (as above) and restart
   - OR inspect the snapshot files directly on disk to understand why they're failing:
     ```bash
     # List snapshot directories per service:
     # nginx/proxy: docker run --rm -v proxy-config-snapshots:/data busybox ls -la /data
     # dnsmasq: docker run --rm -v dhcp-proxy-config-snapshots:/data busybox ls -la /data
     # PowerDNS: docker run --rm -v pdns-config-snapshots-standard:/data busybox ls -la /data/recursor
     # Kea: docker run --rm -v kea-data:/data busybox ls -la /data/config-snapshots
     ```

6. **Critical: if the issue is persistent and you cannot fix it**, contact project maintainers with:
   - The exact error message from `docker compose logs`
   - The content of the bad config file (if safe to share)
   - The `.env` values for any variables involved
   - Whether this happened after an image upgrade

### Admin UI unreachable

**Symptoms:** You cannot open the Admin UI in your browser, or the IP/port it should be on does not respond.

**What's happening:** The `ui` service may have crashed, or there's a network/port binding issue.

**Procedure:**

1. Check if the container is running:
   ```bash
   cd /opt/lancache-ng
   docker compose -f deploy/prod/docker-compose.yml ps ui
   # If it shows "Exited" or "Restarting", the UI itself crashed
   # If it's running, check step 2
   ```

2. Check recent UI logs:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml logs --tail=100 ui
   ```
   Look for errors like:
   - `Connection refused` — the Admin UI process started but cannot reach another service
   - `Panic` or `thread panicked` — UI code crashed
   - `Port X already in use` — another process owns the port

3. If the UI container crashed, restart it:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml up -d ui
   docker compose -f deploy/prod/docker-compose.yml logs ui
   ```

4. Check that core services are running:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml ps
   # Required for UI to work: proxy, dns-standard (or dns-ssl), nats, ui
   # (dhcp/dhcp-proxy/ntp only required if their profiles are enabled)
   ```

5. If core services are down (Exited), fix them first using the procedures above, then restart UI:
   ```bash
   docker compose -f deploy/prod/docker-compose.yml up -d
   ```

6. Once the UI container is healthy (`docker compose ps ui` shows `(healthy)`), try accessing it:
   - On a production host, open `http://<IP_STANDARD>:8080/admin/` in your browser
   - On a dev host, open `http://localhost:3000/admin/`

7. **If the UI still doesn't respond** after the container is healthy, check:
   - Network connectivity: `ping <IP_STANDARD>` from your client
   - Firewall rules: check if port 8080 (or 3000 for dev) is blocked
   - Proxy/nginx health: `docker compose ps proxy` and `docker compose logs proxy`

---

### Why the contract is one document but several files per adapter, not one shared file

`scripts/lib/known-good-snapshots.sh` is the canonical, tested reference
implementation. It is not baked into the `proxy`, `dhcp-proxy`, or `dns`
container images via a shared Docker build context, because each of those
Dockerfiles builds from its own isolated service directory
(`services/proxy/`, `services/dhcp-proxy/`, `services/dns/`) with no
shared-file context wired up for any of them — unlike `cdn-domains.txt`,
which already uses a named `dns-domains` additional build context for the
`proxy` image only. Extending that pattern to a second shared context for
every image would require `build-push.yml`'s image build matrix to support
multiple `--build-context` values per image, which it does not today
(`build_contexts` is treated as one `name=path` pair). Given the mechanism
itself is genuinely small (roughly 150 lines of straightforward bash), each
entrypoint embeds a byte-identical copy of the same functions instead,
marked with `# BEGIN known-good-snapshot library` /
`# END known-good-snapshot library` comments.
`tests/bats/known_good_snapshots_sync.bats` fails if any embedded copy ever
drifts from `scripts/lib/known-good-snapshots.sh`, so "generic" here means
one documented, behaviorally-verified contract that happens to exist as
four physically-identical copies (the canonical file plus one embedded copy
each in proxy, dhcp-proxy, and dns), not literal single-file reuse at
runtime.

## nginx / proxy

`services/proxy/entrypoint.sh` regenerates `nginx.conf`, `proxy-params.conf`,
the SSL/security maps (`00-ssl-map.conf`), and the stream target map
(`00-stream-targets.conf`) on every start from templates, env vars, and
`cdn-domains.txt`. After generation:

- `nginx -t` validates the live config in place (there is no way to validate
  an isolated copy in a temp location, because `nginx.conf` includes
  `/etc/nginx/conf.d/*.conf` and `/etc/nginx/stream.d/*.conf` via fixed
  absolute paths, not relative ones — validation always checks the real,
  currently-generated files).
- If valid: the four generated files are snapshotted, oldest pruned beyond
  `KEEP_KNOWN_GOOD_CONFIGS` (default 3), and nginx starts normally.
- If invalid: the entrypoint tries every stored snapshot, newest to oldest,
  copying each one's files onto the live config paths and re-running
  `nginx -t` after each copy. The first snapshot that validates is kept in
  place and nginx starts from it. If none validate (including "no snapshots
  exist yet"), the container exits non-zero rather than starting nginx with
  a config that failed validation.

Static, non-templated files (`conf.d/http.conf`, `conf.d/https.conf`,
`public_suffix_list.dat`) are not snapshotted; they are not runtime-managed
and are already covered by the image build.

**Operational risk to know about:** if the fallback path is ever taken, nginx
keeps running on a *stale* known-good config while the newly generated one —
whatever an operator most recently changed (a `cdn-domains.txt` edit,
`PROXY_SECURITY_MODE`, an env var) — was rejected. If the underlying source
of the bad generation is not fixed, every subsequent restart regenerates the
same broken candidate and falls back again, silently running on
increasingly stale config. The `WARNING`/`ERROR` log lines at fallback time
are the only current signal of this; there is no separate health/status
indicator. Watch container logs after any config change that requires a
proxy restart.

## dnsmasq / dhcp-proxy

`services/dhcp-proxy/entrypoint.sh` renders `/etc/dnsmasq.conf` from
`dnsmasq.conf.template` (via envsubst, for the four required env vars
`DHCP_SUBNET_START`, `DHCP_DNS_PRIMARY`, `DHCP_DNS_SECONDARY`,
`UPSTREAM_DHCP_IP`) plus the issue #450 optional dnsmasq relay/proxy options
(router/NTP/domain/PXE-boot/custom options, appended conditionally by
`_dhcp_proxy_render_optional_directives` rather than templated, since an
unset optional value must produce no line at all -- see
`docs/dhcp-modes.md`) on every start. This mode has no live/UI-driven config
mutation, so, like nginx, the only meaningful trigger for rollback is "the
config this container is about to start with is invalid":

- `dnsmasq --test -C /etc/dnsmasq.conf` validates the generated config
  before dnsmasq actually starts.
- If valid: the config is snapshotted and pruned to `KEEP_KNOWN_GOOD_CONFIGS`
  (default 3).
- If invalid: same newest-to-oldest rollback search as nginx, validating each
  snapshot with the same `dnsmasq --test` command before accepting it. If
  none validate, the container exits non-zero instead of starting dnsmasq
  with an invalid config.

Same operational risk as nginx applies: a persistently broken input
(`UPSTREAM_DHCP_IP` typo, etc.) falls back to the same stale snapshot on
every restart until the input is fixed.

## Kea

Kea already has a real, working, single-level safety net from PR #380:
`kea_config_modify()` in `services/ui/src/routes/dhcp.rs` retains the config
from `config-get`, applies the candidate via `config-test` → `config-set`,
and — if the follow-up `config-write` (persist to disk) fails in a confirmed
way — rolls back to the retained old config via another `config-set`. That
protects one request's mutation from leaving the running and persisted
config diverged, but on its own it is in-memory and scoped to a single
request: it kept no multi-generation history on disk, and had no
`KEEP_KNOWN_GOOD_CONFIGS`-style retention or rollback-to-an-older-snapshot
capability for Kea.

#614 adds that persisted layer on top, without replacing PR #380's
single-request safety net. Unlike the nginx/dnsmasq/PowerDNS adapters, Kea's
config is mutated live through this Admin UI's own Rust HTTP client against
the Kea Control Agent, not regenerated from a shell template at container
startup — so this adapter is not a byte-identical embedded shell library
copy like the other three. It is a Rust reimplementation of the same
documented contract, in `services/ui/src/kea_snapshots.rs`:

- **Snapshot creation is a side effect of `kea_config_modify()`'s existing
  chain**, not a separate step: every one of the DHCP mutation routes
  (subnet/reservation add/update/remove, DHCP option add/remove) already
  goes through `config-get` → modify → `config-test` → `config-set` →
  `config-write`. On a confirmed `config-write` success, the exact validated
  and applied config is snapshotted into `/var/lib/kea/config-snapshots`
  (the persistent `kea-data` volume, shared with the `dhcp` service), then
  pruned to `KEEP_KNOWN_GOOD_CONFIGS` (default 3, same variable and default
  as the other adapters). This satisfies "validate before snapshotting"
  without a redundant second `config-test`: the existing chain already
  gates it.
- Snapshot creation is best-effort and non-fatal, matching the nginx
  adapter's own treatment of a failed `kgs_snapshot_create`: if writing the
  snapshot fails (e.g. the shared volume is unexpectedly unwritable), the
  mutation itself still succeeds (it was already applied and persisted by
  Kea), and a `WARNING` is logged that rollback protection is degraded until
  it succeeds again.
- **Rollback is operator-selected, not automatic.** The nginx/dnsmasq/
  PowerDNS adapters search their stored snapshots newest-to-oldest
  automatically, because "the config this container is about to start with
  is invalid" is their only rollback trigger, at a single well-defined
  moment (container startup). Kea has no equivalent moment — its config
  only ever changes through this Admin UI, live. So the `/dhcp` page lists
  known-good snapshots (newest first) and an operator picks one explicitly;
  only that snapshot is validated (via `config-test`, logging `REJECT` and
  refusing the rollback if it fails) and applied (via the same
  `kea_config_modify()` chain, which also verifies persisted state through
  its existing `config-write` confirmation and records a fresh snapshot of
  the restored config).
- `KEA_CONFIG_SNAPSHOT_DIR` (default `/var/lib/kea/config-snapshots`) and
  `KEEP_KNOWN_GOOD_CONFIGS` (default 3, same variable name as the shell
  adapters) configure this adapter; both are read by the Admin UI process,
  not a shell entrypoint.
- The `dhcp` (Kea) container's `services/dhcp/entrypoint.sh` chowns
  `config-snapshots/` to the Admin UI's fixed UID/GID (10001) on every
  start, since that container runs as root and the Admin UI runs as a fixed
  non-root user — the same pattern already used to keep the shared
  `nats.conf` writable by the Admin UI after a NATS restart (see
  `deploy/*/docker-compose.yml`'s `nats` service).
- `tests/bats/known_good_snapshots_sync.bats` does not (and should not)
  cover this adapter: there is no embedded shell copy to drift, since none
  of this lives in a shell entrypoint. Coverage lives in
  `services/ui/src/kea_snapshots.rs`'s and `services/ui/src/routes/dhcp.rs`'s
  own `cargo test` suites instead.
- **`kea-ctrl-agent.conf` and `kea-dhcp-ddns.conf` are outside this
  mechanism entirely and are not user-editable.** Unlike `kea-dhcp4.conf`
  (mutated live by the Admin UI, so `entrypoint.sh` merges narrowly to
  preserve that state — see `migrate_dhcp4_config()`), these two files have
  no UI-mutated state to protect, so `entrypoint.sh` fully regenerates each
  from its template on every start and overwrites the persisted copy
  whenever the rendered output differs (a full-file `cmp`, not a
  field-level merge). This is deliberate: it lets a future template change
  reach already-deployed installs on upgrade, the same reasoning that
  motivated regenerating `kea-ctrl-agent.conf` on `KEA_CTRL_TOKEN`/
  `KEA_CTRL_HOST` changes in the first place. The tradeoff is that any
  manual edit made directly to either persisted file (e.g. added TLS
  settings or an extra authenticated client in `kea-ctrl-agent.conf`) is
  silently discarded on the next container start. Do not hand-edit these
  files (#651).

## PowerDNS

PowerDNS's state splits into two very different categories, and only the
first reuses the generic file-snapshot mechanism (#615). The second needs
its own mechanism, described in its own terms below; see "Zones, records,
and TSIG/DDNS metadata" below.

### Static service config — `pdns.conf` / `recursor.conf` (implemented, #615)

`services/dns/entrypoint.sh` regenerates `recursor.conf` and
`pdns.conf` on every start from templates and env vars (`PDNS_API_KEY`,
`DDNS_ALLOW_FROM`, `LOG_QUERIES`) via `render_template_atomic()`. This is the
same shape of problem as nginx/dnsmasq — file-based, deterministically
regenerated — and reuses the exact same generic contract, but the two files
belong to two independent daemons (the recursor and the authoritative
server) with two independently-generated configs, so each is validated,
snapshotted, and rolled back **separately**: a broken `recursor.conf` does
not block a still-good `pdns.conf` from starting, and vice versa, *as long
as rollback succeeds* — i.e. a known-good snapshot exists for the failing
side. The entrypoint validates the recursor first
(`_dns_recursor_validate_snapshot_or_rollback ... || exit 1`) and, on a fresh
install or once snapshot history is exhausted, that call returns 1 and the
container exits before ever reaching `pdns.conf` generation/validation — so
on those two occasions a broken `recursor.conf` genuinely does prevent the
authoritative server from starting too. Both live
under one persistent volume per `dns-standard`/`dns-ssl` container
(`pdns-config-snapshots-standard`, `pdns-config-snapshots-ssl`, mounted at
`/var/lib/lancache-dns`), in separate `recursor/` and `auth/` subdirectories
so the two independent snapshot histories never collide. A remote secondary
DNS node (`setup.sh secondary`, `deploy/secondary/docker-compose.yml`) runs
the same `dns` image and entrypoint, so it gets the identical
`/var/lib/lancache-dns/config-snapshots/{recursor,auth}` layout too — its own
persistent volume there is named `pdns-config-snapshots` (one node, so no
`-standard`/`-ssl` suffix is needed).

**recursor.conf: pure pre-start check, like `nginx -t`.** Debian Trixie's
`pdns-recursor` package (5.2.x) ships a genuine, side-effect-free check-only
invocation: `pdns_recursor --config=check --config-dir=<dir>`. Verified
empirically against the real packaged binary (not assumed from
documentation) before writing the adapter: it parses and validates the YAML
config and exits non-zero on error — both on a YAML syntax error and on a
semantically-invalid-but-syntactically-fine config (an unrecognized
top-level key) — without binding any sockets or starting the recursor. This
is exactly the pure pre-start validator the other two adapters use, so
`_dns_recursor_validate_snapshot_or_rollback()` in
`services/dns/entrypoint.sh` follows the identical
validate-then-snapshot-or-rollback shape as
`_proxy_validate_snapshot_or_rollback()` /
`_dhcp_proxy_validate_snapshot_or_rollback()`, just with
`pdns_recursor --config=check` as the validator command.

**pdns.conf: also a pure pre-start check, once verified live.** An earlier
draft of this adapter assumed `pdns_server` had no check-only flag, because
its `--help` output doesn't spell out "check" as a value the way
`pdns_recursor`'s `--help` explicitly does ("You can use --config=check to
test the config file...") — `pdns_server --help` only documents `--config`
as "Provide configuration file on standard output" and `--no-config` as
"Don't parse configuration file", with no mention of a check mode. That
draft built a start-then-verify probe instead: start `pdns_server` in the
foreground, poll the control socket with `pdns_control rping`, then tear
the probe down either way. Before merging, `--config=check` was tried
directly against the real Debian Trixie `pdns-server` package (4.9.x) on a
self-hosted runner anyway (rather than trusting the absence of documentation)
and turned out to work exactly like `pdns_recursor --config=check`: it
parses the config, attempts to load the configured `launch=` backend
module, and exits non-zero on error — confirmed against an unloadable
backend module and an unknown/malformed setting (the realistic failure mode
here, since a broken `PDNS_API_KEY`/`DDNS_ALLOW_FROM` template substitution
produces exactly that) — all without ever binding a port or leaving a
process running. `_dns_auth_validate_snapshot_or_rollback()` in
`services/dns/entrypoint.sh` therefore uses
`pdns_server --config=check --config-dir=<dir>` directly, the same
validate-then-snapshot-or-rollback shape as every other adapter here,
instead of the more complex probe — no `_dns_auth_probe()` function exists
in the merged version of this adapter.

One real limitation carries over either way: neither `--config=check` nor
a full running daemon validates semantic values such as CIDR syntax in
`allow-dnsupdate-from` — confirmed empirically (starting a real
`pdns_server` with a garbage `allow-dnsupdate-from` value still binds its
port and answers `pdns_control rping` normally). This is a pre-existing
PowerDNS behavior, not a gap introduced by preferring the simpler
check-only flag over a full start.

The same "`--config=check` doesn't validate bind-ability" limitation applies
to `local-address` (issue #706): `pdns.conf.template` bakes in this
container's own dynamically-detected, non-loopback IPv4 address
(`$PDNS_LOCAL_ADDRESS`, needed so DNS UPDATE packets from the separate
`dhcp` container/host can actually reach this daemon), which means every
snapshot also captures whichever bridge IP the container happened to have
at that moment. If pdns.conf is later rolled back to an older snapshot, its
`local-address` line would otherwise still hold that stale address — valid
syntax, so `--config=check` passes it, but not necessarily bindable if this
container was recreated with a different address since. To avoid a rollback
that "succeeds" on paper but then restart-loops `pdns_server` on a dead
bind address, `_dns_auth_validate_snapshot_or_rollback()` re-stamps the
restored file's `local-address` line with the current session's
`$PDNS_LOCAL_ADDRESS` immediately after a successful rollback, without
re-running `--config=check` (safe precisely because that check already
ignores this value either way).

Ordering matters here in a way it does not for nginx/dnsmasq: pdns.conf
validation/rollback runs *before* any `pdnsutil` call in the entrypoint
(zone creation, TSIG import), because those calls also read `pdns.conf` via
`--config-dir` — if pdns.conf is rolled back to a known-good snapshot,
every subsequent `pdnsutil` call in that same startup must see the rolled-
back config, not the rejected candidate. It's kept positioned after the
SQLite database file exists and before zone creation / `configure_ddns_tsig`
for that reason, even though `--config=check` itself doesn't actually
require the database file to exist (confirmed empirically — it still exits
0 with a nonexistent `gsqlite3-database=` path, since it does not open the
backend the way a full start does).

**Operational risk to know about:** same shape as nginx/dnsmasq — if the
fallback path is taken, PowerDNS keeps running on a stale known-good config
while the newly generated one (whatever `PDNS_API_KEY`/`DDNS_ALLOW_FROM`/
`LOG_QUERIES` change an operator most recently made) was rejected, and every
restart re-generates and re-rejects the same broken candidate until the
underlying input is fixed. The `WARNING`/`ERROR` `[lancache-dns]` log lines
at fallback time are the only current signal.

### Zones, records, and TSIG/DDNS metadata

Authoritative over `pdns.sqlite3` and mutated live via `pdnsutil`, the
Admin UI's DDNS/NATS sync path, and dynamic DNS updates from Kea. This is
API/database-backed state, not a config file, so it cannot reuse the
generic file-snapshot contract (#615) as-is: a blind file-level
snapshot/restore of `pdns.sqlite3` while the daemon is live risks capturing
an inconsistent database file, and "rolling back" zone/record data has
completely different implications than rolling back a static config file —
it can silently undo legitimate client DHCP leases, DDNS-driven hostname
records, or secondary-node reconciliation state that changed after the
snapshot was taken. Issue #628 implemented this design; everything below
describes running behavior (`services/dns/nats-subscriber/src/
zone_snapshots.rs`, `rollback_listener.rs`, `services/ui/src/routes/
dns_snapshots.rs`), not a proposal for a future implementation PR.

**Scope decision.** Looking at what `services/dns/entrypoint.sh` actually
does on every start narrows the problem a lot:

- The RPZ zone (`rpz.`) is fully regenerated from `cdn-domains.txt` on
  every start (see "Generate RPZ Zone from cdn-domains.txt" in the
  entrypoint) and is never mutated any other way. It needs no snapshot at
  all — restoring `cdn-domains.txt` (already covered by
  `setup.sh backup`/`restore`, see
  [backup-restore.md](backup-restore.md)) is sufficient to reproduce it
  exactly.
- TSIG key material and the `TSIG-ALLOW-DNSUPDATE` zone metadata are also
  fully reproducible **when `DDNS_TSIG_KEY` is set**: `configure_ddns_tsig()`
  runs unconditionally on every start, re-importing the key from
  `DDNS_TSIG_KEY`/`DDNS_TSIG_NAME`/`DDNS_TSIG_ALGORITHM` and re-setting the
  metadata on every zone in `DDNS_UPDATE_ZONES`. There is nothing here that a
  restart doesn't already reconstruct from environment variables, so this
  metadata needs no snapshot of its own in that case. That guarantee does
  not hold if `DDNS_TSIG_KEY` is later blanked: `configure_ddns_tsig()`
  returns immediately when it is empty (`services/dns/entrypoint.sh`,
  `configure_ddns_tsig()`'s `""` case) without clearing any
  `TSIG-ALLOW-DNSUPDATE` metadata or key rows a previous start already wrote,
  so a host that had DDNS enabled and then has the key removed or blanked
  (migration, config edit) can retain stale TSIG authorization that no
  restart converges away. This snapshot/rollback design does not cover that
  case; it is a pre-existing gap in `configure_ddns_tsig()` itself, tracked
  as a follow-up rather than solved here since it is about TSIG metadata
  hygiene, not zone/record rollback.
- `lan.` / `local.lan.` and the private reverse zones (`PRIVATE_REVERSE_ZONES`
  in the entrypoint) are created idempotently (`create-zone ... || true`)
  but never repopulated — their *record* contents come entirely from
  DDNS updates (Kea leases, hostname registrations) applied directly to the
  primary's PowerDNS instance. **Correction on NATS coverage:** only the
  `lan.` zone has any NATS-driven path today — the Admin UI's record
  mutation routes (`services/ui/src/routes/domains.rs`) publish with a
  hardcoded `"zone": "lan"`, and `nats-subscriber`'s `reconciler()` only
  polls/republishes `/zones/lan` (`services/dns/nats-subscriber/src/main.rs`).
  `local.lan.` and the private reverse zones have no NATS reconciliation
  path at all: Kea's `forward-ddns`/`reverse-ddns` config
  (`services/dhcp/kea-dhcp-ddns.conf`) sends DDNS updates only to the
  primary `dns-standard`/`dns-ssl` instances' own DDNS ports, never to
  `dns-secondary` nodes and never through NATS. So today, a `dns-secondary`
  node never receives `local.lan.`/reverse-zone records at all, regardless
  of rollback — this is a pre-existing replication gap this design does not
  create and cannot fix on its own; see "Secondary nodes and NATS
  replication" below for how the implementation documents (rather than
  silently papers over) it.

So the only state that genuinely needs a snapshot/rollback story is the
**dynamic record data inside `lan.`, `local.lan.`, and the private reverse
zones** — not the zone list, not TSIG, not RPZ.

**Execution path: PowerDNS's HTTP API, not `pdnsutil` from a container that
can't reach it.** An earlier draft of this design routed every step through
`pdnsutil list-zone` / `check-zone` / `load-zone`. That does not work as a
whole: `pdnsutil` operates directly on the local `pdns.sqlite3` backend, so
every one of those commands can only run *inside* the `dns-standard`/
`dns-ssl` container, with `--config-dir=/etc/pdns/auth` (the config
directory the authoritative server is actually generated into by
`services/dns/entrypoint.sh` — the default `/etc/pdns` is empty in this
image; every existing `pdnsutil` call in the entrypoint, e.g.
`configure_ddns_tsig()`'s `import-tsig-key`/`set-meta` calls, already passes
this flag). The Admin UI, which the design assigns the operator-facing
rollback action to, cannot do that: `services/ui/Dockerfile` doesn't install
`pdnsutil` and doesn't mount the `pdns-config-snapshots-{standard,ssl}`
volumes, and even if it did, running `pdnsutil` from a second container
against a `pdns.sqlite3` file that a live `pdns_server` in another container
already has open is not a safe way to read or mutate it.

What the Admin UI *does* already reach is PowerDNS's Authoritative HTTP API
on port 8081 (`services/ui/src/config.rs`'s `pdns_auth_url`, default
`http://dns-standard:8081`) — the same API `services/dns/nats-subscriber`
already uses for `GET`/`PATCH /zones/lan` (`handle_dns_record`, the
`reconciler`) and the same API family whose recursor sibling on 8082 the UI
already calls for cache flushes (`flush_recursor_cache` in
`services/ui/src/routes/domains.rs`). This design therefore routes zone
snapshot capture and rollback through that API instead of `pdnsutil`:

- **Snapshot mechanism.** The canonical, rollback-usable snapshot artifact is
  the same JSON `GET /api/v1/servers/localhost/zones/<zone>` response
  `nats-subscriber` already parses elsewhere in this same process — the
  `ZoneInfo`/`rrsets` shape `reconciler()` already deserializes, and the
  same shape `handle_dns_record`'s `dns_record_to_zone_update` already
  builds `REPLACE`/`DELETE` operations from — not the `/export` endpoint.
  This matters because `/export` returns AXFR/zone-file *text*, while
  PowerDNS's `PATCH /zones/{zone}` consumes JSON `rrsets`; storing the AXFR
  text as "the snapshot" would leave rollback with no defined way to turn it
  back into `rrsets` JSON without writing and maintaining a zone-file parser
  that does not exist anywhere in this codebase today. Storing the same
  JSON shape the reconciler and `handle_dns_record` already speak avoids
  that problem entirely and keeps one rrset representation across the whole
  adapter. `services/dns/nats-subscriber` — which already runs inside the
  `dns-standard`/`dns-ssl` container and already speaks this API — issues
  this call and writes the result under
  `${DNS_CONFIG_SNAPSHOT_DIR}/zones/<zone>`, one `snapshot_root` per zone,
  applying the same `KEEP_KNOWN_GOOD_CONFIGS` retention default as every
  other adapter. This implementation does not additionally store the
  `/export` AXFR text alongside the JSON (an option this section originally
  left open, purely as a human-readable artifact for manual inspection, see
  "Manual recovery" below) — only the JSON `rrsets` snapshot exists on disk;
  a future PR could add the AXFR text as a second, read-only artifact
  without changing the rollback path itself, which would still only ever
  diff/patch from the JSON. Because `nats-subscriber` is
  a compiled Rust binary in its own process (`services/dns/Dockerfile` copies it to
  `/usr/local/bin/nats-subscriber` and the entrypoint execs it as a separate
  process at the bottom of the file), it cannot call the `kgs_*` shell
  functions embedded in `services/dns/entrypoint.sh` — a child process
  cannot invoke its parent shell's functions, and
  `scripts/lib/known-good-snapshots.sh` is not even copied into this image
  (`services/dns/Dockerfile` has no such `COPY`). This adapter therefore
  needs its own Rust reimplementation of the retention primitives (create/
  list/prune), the same decision already made for Kea's
  `services/ui/src/kea_snapshots.rs` — not a fourth embedded shell copy, and
  not a cross-process call into `entrypoint.sh`.
- **Trigger point.** `nats-subscriber`'s `handle_dns_record` (the NATS-driven
  apply path) is one trigger, but not the only in-scope write path: Kea's
  DDNS updates (`services/dhcp/kea-dhcp-ddns.conf`'s `forward-ddns`/
  `reverse-ddns` `dns-servers`) go straight to PowerDNS over TSIG-
  authenticated DNS UPDATE, bypassing NATS and `nats-subscriber` entirely.
  A design that only snapshots after a NATS-applied write would silently
  stop covering DHCP-driven lease/PTR record changes, which this section
  claims are in scope. Two triggers exist:
  1. `handle_dns_record`'s post-`PATCH` hook (`main.rs`'s `maybe_snapshot_
     zone`, called right after a successful PATCH) covers the NATS-applied
     path.
  2. `zone_snapshot_watcher` (`main.rs`) is the periodic export-and-diff
     trigger for DDNS-originated changes: it polls every zone in
     `zone_snapshots::ROLLBACK_ZONES` every 60 seconds (the same interval
     shape as the existing `reconciler`) and runs unconditionally on every
     node, since it is not gated on NATS reconciliation being enabled — the
     alternative considered (a PowerDNS primary-notify-style hook) would
     need a webhook/notify receiver this codebase has no equivalent of
     anywhere else, whereas polling reuses the exact API call and diff
     helpers the post-PATCH trigger already needs.
  Both triggers cover all of `ROLLBACK_ZONES` (`lan.`, `local.lan.`, and the
  private reverse zones), not just the two zones with no NATS path: `lan.`
  itself also receives direct DDNS writes for DHCP lease hostnames
  alongside its separate NATS-applied path, so it needs the periodic
  trigger too, not only the post-PATCH one.
  Two further requirements apply to both triggers:
  - **Skip no-op applies.** The existing `reconciler` (services/dns/nats-
    subscriber/src/main.rs:442-541) polls `/zones/lan` every 60 seconds and
    republishes every non-SOA/NS rrset unconditionally, regardless of
    whether anything changed; JetStream's default ~120s duplicate-message
    window only partially absorbs this. A trigger that snapshots on every
    confirmed apply without comparing content would let these periodic
    republishes burn through the default retention of 3 snapshots within
    minutes, pushing out genuinely different history. Both triggers compare
    the freshly exported zone against the most recently stored snapshot
    before creating a new one (`zone_snapshots::matches_latest_snapshot`):
    rather than hashing serialized bytes (order-sensitive), both sides are
    canonicalized -- the rrsets array sorted by (name, type), each rrset's
    own `records` array sorted by content -- and compared with plain `==`,
    so PowerDNS returning the same content in a different order never reads
    as a change.
  - **Snapshot failures are best-effort, never fatal to message
    acknowledgment.** `nats-subscriber`'s consumer loop only calls
    `msg.ack().await` when `handle_message` returns `true`; on `false` it
    lets JetStream redeliver
    (services/dns/nats-subscriber/src/main.rs:187-200). If a post-apply
    snapshot/export failure were folded into that same return value, an
    already-applied and already-confirmed PATCH would be redelivered and
    reapplied indefinitely whenever the snapshot volume or helper is
    unavailable — stalling this consumer even though PowerDNS already has
    the correct data. `handle_dns_record`/the DDNS-side trigger must log
    (`[known-good-snapshot][dns][...]`) and otherwise treat a snapshot
    failure as non-fatal: still return `true`/ack the already-applied write.
- **Validation.** Snapshot creation is validated by construction: a
  snapshot is only captured from a `GET .../zones/<zone>` (the JSON `rrsets`
  form described above) immediately after a `PATCH .../zones/<zone>` call
  PowerDNS itself already accepted (a 2xx response), so there is no
  separate pre-snapshot check to run — unlike
  nginx/dnsmasq/pdns.conf/recursor.conf, there is no free-standing candidate
  file to validate before it exists; the API's own acceptance of the PATCH
  *is* the validation gate. This replaces an earlier draft's `pdnsutil
  check-zone <zone>` step here, which was not actually possible as
  described: `check-zone` validates the zone already loaded into the
  backend, not an arbitrary file, so it cannot pre-validate an export before
  accepting it as a snapshot. `pdnsutil check-zone --config-dir=/etc/pdns/auth
  <zone>` (run locally by `nats-subscriber` inside the `dns-standard`/
  `dns-ssl` container, where `pdnsutil` and the live backend both already
  exist) remains useful as a *secondary structural sanity check* — SOA
  serial sanity, dangling CNAME targets, delegation consistency, none of
  which the API's per-RR validation catches — but only as a check against
  the zone's current live state (before snapshotting, or after a rollback
  has already been applied), never as a way to pre-validate a candidate file
  in isolation.
- **Applying a rollback stays operator-selected, never automatic.** Because
  no structural check can judge semantic correctness (whether a zone's
  contents are consistent with Kea's current DHCP leases or NATS's current
  reconciliation state right now), and because restoring an older zone
  snapshot can undo real client leases or hostnames created since that
  snapshot, this follows the same pattern already documented above for Kea:
  an operator picks a specific timestamped snapshot for a specific zone.
  Execution needs a DNS-side path the Admin UI can actually reach, since (as
  established above) the UI cannot run `pdnsutil` itself: `nats-subscriber`
  — already resident in the `dns-standard`/`dns-ssl` container, already
  holding the snapshot files it wrote, and already speaking the PowerDNS API
  — is the natural place for a small local HTTP listener (a new port,
  alongside PowerDNS's own 8081/8082) that the Admin UI calls to list
  snapshots for a zone and to trigger a rollback. On a rollback request,
  `nats-subscriber` diffs the snapshot's rrsets against the zone's current
  rrsets (`GET .../zones/<zone>`, which it already knows how to call) and
  issues the equivalent `PATCH .../zones/<zone>` — `REPLACE` for every rrset
  present in the snapshot, `DELETE` for every current rrset absent from it
  — mirroring the `dns_record_to_zone_update` shape `handle_dns_record`
  already implements, then re-runs the `check-zone` structural sanity check
  from the point above as a post-apply confirmation. No automatic
  startup-time rollback is ever attempted for zone data, unlike the
  nginx/dnsmasq/PowerDNS static-config adapters above.
- **The rollback listener must require authentication.** A local HTTP
  listener that can list zone snapshots and trigger a `PATCH`-based rollback
  is a control-plane endpoint, not a read-only status page, and this
  project never treats Docker Compose network reachability alone as a trust
  boundary for anything comparable: PowerDNS's own Authoritative HTTP API on
  port 8081 is reachable by every container on the same network this new
  listener would be, and it still requires the `X-API-Key` header
  (`PDNS_API_KEY`) on every call (`services/dns/nats-subscriber/src/main.rs`,
  `services/ui/src/routes/domains.rs`); NATS itself went further and moved
  from a single shared credential to individually-revocable per-secondary
  identities via an auth callout (`services/ui/src/nats_auth_callout.rs`,
  #583) rather than relying on network placement alone. A rollback listener
  with no equivalent check would let anything else reachable on the same
  Compose network — not just the Admin UI — list and roll back zone
  snapshots, silently bypassing whatever authentication the Admin UI itself
  enforces on the operator. This listener (`services/dns/nats-subscriber/
  src/rollback_listener.rs`) gates every request the same way this project
  already gates every comparable internal surface: a constant-time
  comparison of the `X-API-Key` header against `PDNS_API_KEY`, checked
  before the request body is even parsed. It binds `0.0.0.0:8083`, not
  `127.0.0.1` -- a literal loopback bind would make it unreachable from the
  Admin UI's own container (containers have separate network namespaces);
  "container-local" here instead means not published to the host/LAN via
  docker-compose `ports:`, only `expose:`, the same treatment PowerDNS's own
  8081/8082 already get. That network placement is defense-in-depth on top
  of the `X-API-Key` check, never a substitute for it -- any container on
  the same Compose network could still reach the port and would be rejected
  by the header check alone.
- **Flush recursor caches after a rollback.** A `load`/`PATCH`-style
  rollback can change or delete many names in one operation, but
  `flush_recursor_cache` (`services/ui/src/routes/domains.rs:264-289`)
  documents that PowerDNS Recursor's flush endpoint only clears an exact
  name — even `?domain=lan.` leaves an already-changed leaf record cached —
  and the recursor's packet cache keeps successful answers for 3600 seconds
  by default (`services/dns/recursor.conf.template`'s `packetcache.ttl`).
  Re-running `check-zone` after a rollback confirms the authoritative data
  is structurally sound, but says nothing about what recursors are still
  serving from cache. The rollback path must enumerate every name whose
  rrset changed (available directly from the diff computed in the point
  above) and flush each one against every recursor instance (both
  `dns-standard` and `dns-ssl`, matching the two-mode/two-IP architecture),
  not rely on a single whole-zone or root flush call.
  - **NATS permission dependency (#867).** This flush is a
    `lancache.dns.flush` JetStream publish sent under whichever
    container's own identity runs `rollback_handler` (`NATS_DNS_WRITER_USER`
    on `dns-standard`, `NATS_DNS_REPLICA_USER` on `dns-ssl`) -- it only
    works if that identity's `publish` allow-list in `nats.conf` (and the
    byte-identical generators in `deploy/prod` and
    `deploy/quickstart/docker-compose.yml`) actually includes that subject.
    It shipped without it: every rollback correctly patched PowerDNS but
    the flush was silently denied server-side, and the `POST /rollback`
    response had no field reflecting that. Both identities now carry the
    permission, and any per-name flush publish/ack failure is surfaced in
    the response body as `flush_ok`/`flush_failed_names` rather than only
    logged, so a future permission regression (or a genuinely down
    recursor) is visible to whatever calls this endpoint instead of
    silently swallowed.

**Secondary nodes and NATS replication.** Every DNS node (primary and each
remote secondary from `setup.sh secondary`) runs its own
`nats-subscriber` consuming the same JetStream stream and applying updates
to its own local PowerDNS instance independently — record data is
replicated through NATS messages, not through file or database copying
between nodes, **but only for the `lan.` zone today** (see the correction
under "Scope decision" above: the reconciler and the Admin UI's publish
path are both hardcoded to `zone: "lan"`, and `local.lan.`/reverse-zone
DDNS updates go straight to the primary, never through NATS). Two separate
things follow from that:

- For `lan.`, a rollback re-publishes the restored state onto the NATS
  stream so secondaries converge, rather than leaving the primary and its
  secondaries silently holding different data for the rolled-back zone.
  `rollback_listener.rs`'s `publish_rollback_records` (called only when
  `zone == "lan."`) re-publishes every REPLACE/DELETE entry from the
  applied rollback patch onto `lancache.dns.record`, reusing the same
  message shape `nats_publish::publish_dns_record` already provides to the
  existing `reconciler`. Each entry gets a fresh, rollback-specific message
  id (`rollback-<batch timestamp>-<name>-<type>`) rather than reusing the
  reconciler's stable `reconcile-lan-<name>-<type>` id, so JetStream's
  ~120s duplicate-message window can never silently absorb this explicit
  republish if the periodic reconciler happened to publish an identical id
  moments earlier. The existing 60-second reconciler is a backstop on top
  of this, not a replacement for it: even without the explicit republish,
  it would eventually converge secondaries on its own, just with up to a
  60-second delay.
  - **NATS permission dependency (#906, follow-up to #867's flush-permission
    fix above).** Like the flush, this republish is a `lancache.dns.record`
    JetStream publish sent under whichever container's own identity runs
    `rollback_handler` (`NATS_DNS_WRITER_USER` on `dns-standard`,
    `NATS_DNS_REPLICA_USER` on `dns-ssl`) -- it only works if that
    identity's `publish` allow-list actually includes that subject. The
    writer identity already held it (it needs it for the reconciler too);
    the replica identity did not, and was silently denied when publishing
    would have been attempted. Not reachable on the default
    `DNS_ROLLBACK_URL` (`dns-standard:8083` everywhere), but the identity's
    permissions must be correct independent of which URL an operator
    configures. Fixed by granting `NATS_DNS_REPLICA_USER` `publish` on
    `lancache.dns.record` too, accepting a real security-surface tradeoff:
    a compromised dns-ssl NATS credential can now forge or replicate `lan.`
    DNS records, not just signal a cache-flush. The alternative considered
    was making the rollback listener itself detect and reject a
    permission-denied record republish for `lan.` (fail loud instead of
    silently no-op'ing); the maintainer chose the permission grant instead.
- For `local.lan.` and the private reverse zones, there is no existing NATS
  replication to preserve or break in the first place — a rollback on the
  primary for these zones only ever affects that one node, exactly like
  every DDNS write to them already does today. This implementation takes
  the simpler of the two options this section originally posed: it does
  NOT extend NATS coverage to these zones (that would be real scope creep
  beyond this issue -- a second, separately-scoped change to Kea's
  DDNS-update path and to `nats-subscriber`'s consumer, not a rollback
  concern). Instead, this paragraph documents the gap explicitly:
  `dns-secondary` nodes do not carry `local.lan.`/
  reverse-zone records and will not converge after a rollback either. Either
  way, this design does not silently assume replication that does not
  exist.

**Container reachability during crash-loops:** Everything described above — the Admin UI listing zone snapshots, an
operator picking one, `nats-subscriber`'s local admin listener applying the
diffed `PATCH` inside the `dns-standard`/`dns-ssl` container — depends on an
operator (or the Admin UI acting on their behalf) actually being able to
reach that container's listener. This assumption is most at risk in exactly
the scenario this mechanism exists for: if PowerDNS is crash-looping because
its own zone/record data is broken, the container may never stay up long
enough to be reached, and the rollback tool becomes unreachable during the
very crash-loop it exists to resolve. The Admin UI CLI fallback
(`./setup.sh reset-to-last-known-good-config dns …`) mitigates this by
executing the rollback from *inside* the container via `docker compose
exec`, so it works as long as the container can be exec'd into — which
includes the rescue-mode scenario where the container is running but its
main service (PowerDNS) is not. For the complete incident-response story
(including what to do when rescue mode itself is needed), see "Incident
Runbooks" near the beginning of this document.

## Manual recovery and exhaustion

If a service ever exhausts its known-good snapshots (fresh install with no
prior successful start, or every snapshot also fails validation — e.g. after
a `dnsmasq`/`nginx` version upgrade that rejects previously-valid syntax),
the container refuses to start and logs `[known-good-snapshot][…][FATAL]`
lines. **For step-by-step recovery procedures covering all services and
failure scenarios**, see "Incident Runbooks" near the beginning of this
document — it includes identifying the root cause, applying fixes, and
deciding whether rescue mode is needed. The snapshot directories are plain
files under the volumes listed in the "Contract" section above and can be
inspected directly with `docker compose exec` or
`docker run --rm -v <volume>:/data busybox ls -la /data` for manual
inspection if needed.

Kea has no equivalent exhaustion state, since it never rolls back
automatically: an operator picks a snapshot from the `/dhcp` page's list, and
if none there look right, `kea-dhcp4.conf` on disk is untouched by a failed
rollback attempt (`kea_config_modify()`'s existing PR #380 behavior). If the
Admin UI itself is unreachable, the snapshot JSON files under
`kea-data`'s `config-snapshots/` (mounted at `/var/lib/kea/config-snapshots`
in both the `ui` and `dhcp` containers) can be inspected the same way, and a
chosen one applied manually against the Kea Control Agent API
(`config-test` → `config-set` → `config-write`, the same three-call
sequence the Admin UI itself uses) -- or, since #794, automated with
`./setup.sh reset-to-last-known-good-config kea [install-dir] [snapshot-id]
[--yes]`, which does exactly that.

**Update (#836): the PowerDNS zone/record adapter now has this same CLI
fallback too.** The gap this section used to describe here -- "no equivalent
manual-CLI fallback documented here yet" -- is closed:
`./setup.sh reset-to-last-known-good-config dns [install-dir] <zone>
[snapshot-id] [--yes]` (aliases: `pdns`; `dns-standard`/`dns-ssl` select an
explicit target container, defaulting to `dns-standard` to match the Admin
UI's own current single-primary scope) lists this install's known-good
snapshots for the given zone and applies one via nats-subscriber's real
rollback listener -- the same list/diff/PATCH/check-zone/flush/republish
chain `services/ui/src/routes/dns_snapshots.rs` already forwards to when the
Admin UI IS reachable. Unlike Kea (one `dhcp4.json`, one snapshot history),
PowerDNS tracks snapshots per zone (`lan.`, `local.lan.`, and the private
reverse zones), so `<zone>` is a required argument for this target; omitting
it lists which zones currently have at least one snapshot instead of
guessing one, since silently defaulting the zone itself (unlike defaulting
the *snapshot id* to the newest within an already-chosen zone) risks
mutating the wrong zone's data.

This command reaches the rollback listener (port 8083) by running
`docker compose exec` into the target `dns-standard`/`dns-ssl` container and
calling `curl` from inside it, rather than calling the listener directly from
the host: unlike Kea's Control Agent (reachable via `network_mode: host`),
the rollback listener's port is deliberately only `expose`d to the Compose
network, never published to the host (see "The rollback listener must
require authentication" above). The `X-API-Key` value is resolved *inside*
that container -- reading `PDNS_API_KEY` from its own environment if usable,
else the `pdns-api-key` file on the shared-secrets volume it already mounts
at `/var/lib/lancache-secrets` -- rather than read from this host's `.env`
and passed in, so the #858 shared-secrets first-writer-wins bootstrap (a
fresh install's `.env`-configured `PDNS_API_KEY` can legitimately be blank
until a container generates it) cannot leave this command sending a stale or
empty key. This still depends on the target container itself being
reachable, the same latent gap Kea's own fallback has and #763 is meant to
close -- see "Known gap: this rollback path assumes the container is
reachable" above.
