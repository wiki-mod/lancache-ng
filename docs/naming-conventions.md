# Naming Conventions

This document is the single, authoritative naming contract for every
runtime object lancache-ng creates: Compose project/service names, Docker
container names, Docker volumes, host bind-mount directories, GHCR
image/package names, environment variables that refer to services or
containers, the Docker socket proxy's security allowlist, and backup/restore
paths. It exists because those names are declared in many independent
places (three Compose files, two service source trees, several shell
scripts, several env-file templates) with no single owner, and a silent
mismatch between any two of them is a security or availability bug, not a
cosmetic one — see "Why this document exists" below.

If you add a new service, volume, environment variable, or allowlist entry,
follow the rule for its category below, and update every place listed under
"Where each name actually lives" for that category. `scripts/tracked/check-naming-consistency.sh`
(wired into CI, see "CI guard" below) checks the parts of this contract that
are mechanically checkable; it does not replace reading this document.

## Why this document exists

This came out of issue #454, itself a follow-up from hardening the Docker
socket proxy in #377. The socket proxy's HAProxy allowlist (the
`docker-socket-proxy-allowlist` config in `deploy/prod/docker-compose.yml`)
only allows Docker API calls against a
fixed list of container names. Every other layer that talks about "the proxy
container" or "the DNS-standard container" — the Admin UI's Docker API
client, the watchdog's health-check loop, each Compose file's
`container_name:` — has to agree on the *exact same strings* for that
allowlist to mean anything. Before this document, that agreement was
de-facto (everything happened to line up) rather than contract-enforced
(nothing said it had to, and nothing would fail CI if it stopped). A drift
here is not cosmetic: if the Admin UI's container-name literal for "restart
the proxy" drifted from the allowlist's literal, the restart button would
silently start failing closed (safe, but broken) or — if the drift went the
other way (allowlist tightened past what the code sends) — the specific
failure mode security review already assumed, not a novel one.

## Two separate name namespaces — do not conflate them

There are two genuinely different kinds of "name a service" in this stack,
and they intentionally use different literal values:

1. **Compose service name** (e.g. `proxy`, `dns-standard`, `dns-ssl`,
   `nats`). This is the DNS alias Docker's embedded resolver gives every
   container on a Compose network. Code that builds an HTTP URL to reach
   another container in the same stack (e.g. the Admin UI calling
   `http://dns-standard:8081`) uses this name.
2. **Container name** (e.g. `lancache-proxy`, `lancache-dns-standard`).
   This is the literal Docker Engine object name, used wherever code talks
   to the **Docker Engine API** — `GET /containers/<name>/json`,
   `POST /containers/<name>/restart`, etc. The Docker Engine API has no
   concept of a Compose service name; it only knows container names/IDs.
   The Admin UI's Docker socket calls (`services/ui/src/main.rs`),
   the watchdog's health/restart loop (`services/watchdog/src/`), and
   the socket proxy's allowlist (`scripts/untracked/docker-socket-proxy.sh`) all
   operate in this namespace.

**Do not "fix" the difference between these two by unifying them.** Making
`PROXY_SERVICE` equal `lancache-proxy` would break Docker DNS resolution
(compose networks do not add `lancache-`-prefixed aliases automatically);
making `CONTAINER_PROXY` equal `proxy` would break the Docker Engine API
calls (a bare `proxy` is not that container's actual Docker name unless
`container_name:` is also changed to match, which would then break the
socket-proxy allowlist regex on every other Compose file). The two
namespaces are related by a fixed rule (see below) but are not
interchangeable strings.

## Category rules

### Compose project name

Rule: the one deployment profile, `deploy/prod` (AG-KD-008), declares
`name: lancache-ng` at the top
of its `docker-compose.yml`. This fixes the Compose project name so
generated resource names (`lancache-ng-<service>-1` for anything without an
explicit `container_name:`, network names, the implicit default network)
are stable and predictable across `docker compose up`/`down`/`restart`
invocations, regardless of the checkout directory name.

Documented exceptions:

- `deploy/full-setup/docker-compose.yml` uses `name: lancache-ng-validation`
  deliberately — it is a CI-only harness with dummy images
  (`docs/release-versioning.md`), never a real
  deployment, and must never collide with a real `lancache-ng` project on
  the same Docker host/runner.
- `deploy/secondary/docker-compose.yml` sets no project name. It is
  copied as-is by `setup.sh secondary` onto a remote host that runs nothing
  else from this project, is a single-service file, and is never reachable
  through the Docker socket proxy trust boundary described below — a fixed
  project name has no correctness benefit there. If a secondary node is
  ever colocated with another lancache-ng deployment, revisit this
  exception.

### Compose service names

Rule: lowercase, hyphen-separated, one word per logical responsibility —
`proxy`, `dns-standard`, `dns-ssl`, `dhcp`, `dhcp-proxy`, `dhcp-probe`,
`ntp`, `nats`, `docker-socket-proxy`, `watchdog`, `ui`, `netdata`, `syslog`,
`cachehamster`.
This list never carried a separate `syslog-ng` entry even while a real
`syslog-ng` Compose service existed (issue #453/#633 through the
syslog+fluent-bit consolidation PR) -- a pre-existing documentation gap this
project never revisited, not a deliberate decision. The consolidation
merging `syslog` (fluent-bit) and `syslog-ng` into one combined-container
`syslog` service genuinely closes that gap rather than papering over it:
this list is now accurate again by construction, since there is only one
logical central-logging service left to name. These names are also the DNS aliases used for
service-to-service HTTP calls inside a Compose network (see "Two separate
name namespaces" above). They must stay identical everywhere the same
logical service is named — a service must not be called `dns-standard` in
one file and `dns_standard` or `standard-dns` in another.

### Container names (`container_name:`)

Rule: every service defined in `deploy/prod` gets an explicit
`container_name: lancache-<service>`
(the Compose service name, prefixed with `lancache-`; `dns-standard`
becomes `lancache-dns-standard`, not `lancache-dnsstandard` or
`lancache_dns_standard`). Do not leave `container_name:` unset and rely on
Compose's auto-generated `<project>-<service>-<n>` name.

Two reasons this must be explicit for **every** service, not only the ones
the Docker socket proxy currently allowlists:

1. **Docker socket proxy allowlist targets.** Any container the Admin UI or
   watchdog can start/stop/restart/inspect through
   `scripts/untracked/docker-socket-proxy.sh` must have a name that exactly matches
   the allowlist regex, or the request is denied (fails closed, but that's
   still a bug). Today that set is `lancache-proxy`,
   `lancache-dns-standard`, `lancache-dns-ssl`, `lancache-dhcp`,
   `lancache-dhcp-proxy`, `lancache-dhcp-probe`, `lancache-nats` — all of
   which already had explicit `container_name:` values before this change.
2. **Operator-visible consistency.** At the time this rule was written,
   `docker-socket-proxy`, `watchdog`, `ui`, and `netdata` were not allowlist
   targets (nothing called the Docker API to manage them by name) -- this
   is **no longer true for `ui`/`netdata`**: issue #842/#849 (2026-08-05)
   added both, plus `syslog` (at the time, two separate services/containers,
   `syslog` and `syslog-ng`, each added individually; the syslog+fluent-bit
   consolidation PR merged concurrently reduced that to the one `syslog`
   name that remains), to `safe_container_inspect`/
   `lancache_container` (inspect-only, for watchdog's Rust rewrite's
   alert-only monitoring -- see `docs/architecture-ng.md`'s "Auto-restart"
   section for the full list and reasoning). **Corrected 2026-08-19 (issue
   #1486): `ui` is no longer inspect-only.** It additionally gained its own
   narrow `safe_ui_restart` grant (restart-only, never start/stop) for the
   Admin UI's own operator-initiated self-restart control -- `netdata` and
   `syslog` remain inspect-only exactly as before. `docker-socket-proxy` and
   `watchdog` remain the only two of this original four still deliberately
   absent from the allowlist (a service never needs Docker-API access to
   itself). Before this section's original change, none of the four had a
   `container_name:` either, so `docker ps` showed them as
   `lancache-ng-ui-1`, `lancache-ng-watchdog-1`, etc. — a project name plus
   an implementation detail (the numeric Compose replica suffix) an
   operator has to mentally parse, and a naming rule with silent,
   unexplained exceptions. This PR adds explicit `container_name:` values
   for these four (`lancache-docker-socket-proxy`, `lancache-watchdog`,
   `lancache-ui`, `lancache-netdata`) and for the `syslog` service (Compose-
   profile-gated; on by default since issue #1343 for `setup.sh`-managed
   installs, not "optional" in the off-by-default sense the original wording
   implied -- a from-scratch manual `deploy/prod` install still starts with
   it off, matching its `dhcp-kea`/`dhcp-proxy`/`ntp` sibling profiles) where
   present (and,
   at the time, the since-removed `watchtower` service --
   see #819), so "every lancache-ng service has a stable, predictable name"
   is a rule without exceptions instead of a rule with four undocumented
   ones. See "Migration impact" below — this is a
   one-time container recreation, not a data migration.

`netdata` additionally sets `hostname: lancache-netdata` (the in-container
`/etc/hostname` value, unrelated to the Docker-level container name) — this
predates this change and is now consistent with its new `container_name:`.

### Docker volumes

Rule for new volumes: lowercase, hyphen-separated, named for what they hold,
no service prefix required when the volume is already scoped inside a
service-named block in the Compose file (e.g. `proxy-cache`,
`proxy-config-snapshots`, `dhcp-proxy-config-snapshots`, `watchdog-status`,
`ui-data`, `pdns-filter-state`).

Documented exception (grandfathered, not changing here): the three Netdata
volumes — `netdataconfig`, `netdatalib`, `netdatacache` — are missing the
hyphen this convention otherwise uses everywhere else
(`netdata-config`/`netdata-lib`/`netdata-cache` would match the pattern).
These are **not** renamed by this change: Docker named volumes carry real
persisted state, and renaming a volume means either data loss or a
migration step in `setup.sh`, which is a deliberate, human-approved
decision outside the scope of a naming-documentation pass. This exception
is permanent rather than a placeholder awaiting a fix, unless a future,
explicitly scoped change adds the volume migration logic.

### Host bind-mount directories

Rule: everything under the shared `LANCACHE_STATE_DIR` (default
`/opt/lancache-ng`) uses lowercase, hyphen-separated subdirectory names that
match the service that owns them: `cache`, `pdns-standard`, `pdns-ssl`,
`pdns-filter-state`, `nats`, `nats-conf`, `kea`, `ntp`. See `docs/backup-restore.md`
and `docs/how-to-change-ip.md` for the full `LANCACHE_STATE_DIR` contract
and its override variables (`PDNS_STANDARD_DIR`, `PDNS_SSL_DIR`,
`PDNS_FILTER_STATE_DIR`, `NATS_DATA_DIR`, `NATS_CONF_DIR`, `KEA_DATA_DIR`,
`NTP_DATA_DIR`).
This document does not duplicate that contract; it only asserts that new
state directories must follow the same naming shape.

### GHCR image/package names

Rule: `ghcr.io/wiki-mod/lancache-ng/<service>` for every first-party image,
where `<service>` is the same lowercase-hyphenated name as the Compose
service and its key in the `services:` block of
`.github/yaml/build-manifest.yml` (plus `build-tools`). This is already
fully governed by `.github/yaml/build-manifest.yml` (the machine-readable
inventory) and `docs/release-versioning.md` — this document does not duplicate that
contract, it only asserts that the image name always matches the service
name it packages. `LANCACHE_IMAGE_REGISTRY`, `LANCACHE_IMAGE_PREFIX`,
`LANCACHE_IMAGE_TAG`, and `LANCACHE_IMAGE_CHANNEL` are the fixed
environment variable names every service/script uses to assemble an image
reference; do not introduce a second set of image-location variables.

### Environment variables that refer to services or containers

Rule: no environment variable names a service or a container. The ui has
no Docker access: it writes settings, marker and request files, and the
supervisor in the owning container restarts its own program when a
watched file changes. Only the watchdog in `services` talks to Docker,
and it finds the stack by its compose project label, not by a name list.

### Backup/restore paths that depend on these names

Rule: `setup.sh`'s `compose_volume_names()`/`backup_compose_volumes()`/
`restore_compose_volumes()` (see `docs/backup-restore.md`) discover Docker
volumes generically by inspecting the running containers, so they do not
hardcode volume names — a new volume that follows the naming rule above is
automatically included without a `setup.sh` change. The one place names are
hardcoded is the `deploy_prod_repo_input_paths()` allowlist of repo-root
paths reached via `../../` from `deploy/prod` (certs, `config/prod`,
`services/dns/cdn-domains.txt`, `scripts/untracked/docker-socket-proxy.sh`) — any new
repo-root file a production Compose service reads via a relative bind mount
must be added there too, or a config-mode backup/restore silently misses
it.

## Where each name actually lives

| Category | Canonical source | Also appears in |
|---|---|---|
| Compose project name | `deploy/prod/docker-compose.yml` `name:` | — |
| Compose service names | `deploy/prod/docker-compose.yml` service keys | `services/ui/src/main.rs` (reads the required `*_SERVICE` variables), `deploy/prod/docker-compose.yml` env values that build internal URLs |
| Container names | `deploy/prod/docker-compose.yml` `container_name:` | `scripts/untracked/docker-socket-proxy.sh` (allowlist), `services/ui/src/main.rs` (`container_name_for_service`), `services/common/config.rs` (`CONTAINER_*` defaults), `services/watchdog/src/main.rs` (override guard), `config/prod/watchdog.env` (`CONTAINER_*` overrides) |
| Docker volumes | `deploy/prod/docker-compose.yml` `volumes:` top-level block | Service-level `volumes:` mount lists in the same file |
| Host bind-mount directories | `docs/backup-restore.md`, `docs/how-to-change-ip.md` | `deploy/prod/docker-compose.yml`, `setup.sh` |
| GHCR image/package names | `.github/yaml/build-manifest.yml` (`services:`) | `docs/release-versioning.md`, the `image:` lines of `deploy/prod` and `deploy/secondary` |
| Service-referring env vars | See table above | `services/ui/src/main.rs`, `services/common/config.rs`, `config/prod/*.env` |
| Socket proxy allowlist | `scripts/untracked/docker-socket-proxy.sh` | (mounted read-only, unchanged, into the `docker-socket-proxy` service of `deploy/prod`) |

## CI guard

`ci.sh check naming-consistency` runs inside `ci.sh check all` and checks
the parts of this contract that are mechanically verifiable:

- `deploy/prod/docker-compose.yml` declares `name: lancache-ng`.
- Every allowlist container name in `scripts/untracked/docker-socket-proxy.sh`
  has a matching `container_name:` in `deploy/prod`.
- Every container-name literal `services/ui/src/main.rs` can
  resolve to is a subset of that same allowlist.
- Every `lancache-*` container-name constant in
  `services/common/config.rs` is a subset of that same allowlist.
- The allowlist never names the watchdog container in an `acl` or
  `http-request` line and grants no lifecycle action (start, stop,
  restart, wait) to the watchdog or syslog containers (issue #1486).
- The `*_SERVICE` values the ui requires (set in compose) match a real
  Compose service name (not a container name) in
  `deploy/prod/docker-compose.yml`.

It does not (and cannot) verify the human-judgment parts of this document —
whether a *new* category of name follows the rule is a code-review
question, not a script's job.

## Migration impact

This change is a documentation-and-consistency pass, not a data migration.
Nothing that persists state (volume names, bind-mount paths, `LANCACHE_STATE_DIR`
layout, backup archive format) changes.

The one runtime-visible effect: `docker-socket-proxy`, `watchdog`, `ui`, and
`netdata` (and `syslog` where present) now have an explicit
`container_name:` where they previously had none. On the next
`docker compose up -d` after upgrading, Compose recreates exactly these
containers (new fixed name assigned) because their config changed — this is
the same kind of one-time recreation any `container_name:`/image-tag change
already causes, not a new class of behavior. No named volume is renamed,
removed, or recreated; a container recreation does not touch volume
contents. Expect a few seconds of downtime for these four/six containers
during the update, same as any other rolling update. `proxy`, `dns-standard`,
`dns-ssl`, `dhcp`, `dhcp-proxy`, `dhcp-probe`, and `nats` already had
explicit `container_name:` values and are unaffected by this change.

The deleted `x-docker-socket-proxy-command` YAML anchors were dead
(unreferenced) content with no runtime effect — removing them changes
nothing at deploy time.
