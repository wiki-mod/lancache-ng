# Naming Conventions

This document is the naming contract for all project-defined names and
identifiers (see [AG-CODE-014]). Runtime objects are covered first: the Compose project and service names, Docker container names,
Docker volumes, host bind-mount directories, GHCR image and package names,
environment variables that refer to services or containers, and
backup/restore paths. Code identifiers are covered in "Code Naming
Conventions" below. `ci.sh check naming-consistency` (part of `ci.sh check
all`, see "CI guard" below) checks the parts that a script can check; it
does not replace reading this document.

If you add a new service, volume or environment variable, follow the rule
for its category below and update every place listed under "Where each name
actually lives".

## Why this document exists

A name is read in more than one place. Two examples:
- The container name is the Docker `syslog` tag (`tag: "{{.Name}}"` in
  `x-logging` of `deploy/prod/docker-compose.yml`), so it is the syslog-ng
  program name and the log store directory (`LanCache-NG-proxy/`, see the
  logging matrix in `docs/architecture-ng.md`). The per-service logging
  switches name the container through its SOT key (`LOG_SWITCHES` in
  `services/common/config.rs`: `LOGGING_PROXY_ENABLED` to
  `CONTAINER_NAME_PROXY`, and so on).
- The watchdog keys `status.json` by the Compose service label of each
  container (`com.docker.compose.service`), and the Admin UI dashboard shows
  those keys.

A drift between two places silently breaks a log switch, a log directory or
a dashboard row.

## Two separate name namespaces; do not conflate them

1. **Compose service name** (`services`, `proxy`, `dns`, `dhcp`, `ui`). It
   is the key under `services:` in the Compose file and the DNS alias that
   Docker's embedded resolver gives the container on a Compose network.
2. **Container name** (`LanCache-NG-proxy`, `LanCache-NG-dns`, and so on).
   It is the Docker Engine object name: the name `docker ps` shows, the
   syslog tag, and the name the Docker Engine API uses. The watchdog finds
   the stack's containers by the compose project label of its own container,
   not by a list of names (`own_project` and `project_containers` in
   `services/watchdog/src/main.rs`).

The two are related by a fixed rule (see below) but are not the same string.

## Category rules

### Compose project name

Rule: `deploy/prod/docker-compose.yml`, the one deployment profile
(AG-KD-008), declares `name: lancache-ng`. This fixes the project label, the
network names and the names of the named volumes across `docker compose
up`, `down` and `restart`, whatever the checkout directory is called.

Documented exception: `deploy/secondary/docker-compose.yml` sets no project
name. `setup.sh secondary` writes it onto a remote host that runs nothing
else from this project; it has one service (`dns`).

### Compose service names

Rule: lowercase, one word per container: `services`, `proxy`, `dns`,
`dhcp`, `ui` in `deploy/prod`, and `dns` in `deploy/secondary`. A service
keeps the same name in every file; it must not be `dns` in one file and
`dns_server` in another.

### Container names (`container_name:`)

Rule: every service sets `container_name: ${SOT_CONTAINER_NAME_<SERVICE>}`.
The SOT (`.github/yaml/build-manifest.yml`) owns the values:
`CONTAINER_NAME_PREFIX=LanCache-NG` and
`CONTAINER_NAME_<SERVICE>=@CONTAINER_NAME_PREFIX@-<service>`, so `dns`
becomes `LanCache-NG-dns`. Do not leave `container_name:` unset and rely on
Compose's generated `<project>-<service>-<n>` name, and do not write a name
literal into a Compose file or into code.

### Docker volumes

Rule for new volumes: lowercase, hyphen-separated, named for what they hold
(for example `proxy-cache`, `proxy-config-snapshots`, `watchdog-status`,
`retention-state`, `ui-data`, `shared-secrets`).

### Host bind-mount directories

Rule: each host directory is set by one operator variable that
`deploy/prod/docker-compose.yml` requires (`CACHE_DIR`, `CA_DIR`,
`PDNS_DIR`, `PDNS_FILTER_STATE_DIR`,
`KEA_DATA_DIR`, `NTP_DATA_DIR`, `CACHEHAMSTER_DATA_DIR`,
`SYSLOG_NG_LOG_DIR`). A new state directory gets its own variable of the
same shape and a lowercase, hyphen-separated directory name. See
`docs/README.md` for the
`LANCACHE_STATE_DIR` contract; this document does not repeat it.

### GHCR image/package names

Rule: `ghcr.io/wiki-mod/lancache-ng/<service>` for every first-party image,
where `<service>` is the same lowercase-hyphenated name as the Compose
service and its key in the `services:` block of
`.github/yaml/build-manifest.yml` (plus `build-tools`). This is already
fully governed by `.github/yaml/build-manifest.yml` (the machine-readable
inventory) and `docs/combined-release-and-checklist.md` — this document does not duplicate that
contract, it only asserts that the image name always matches the service
name it packages. `LANCACHE_IMAGE_REGISTRY`, `LANCACHE_IMAGE_PREFIX`,
`LANCACHE_IMAGE_TAG`, and `LANCACHE_IMAGE_CHANNEL` are the fixed
environment variable names every service/script uses to assemble an image
reference; do not introduce a second set of image-location variables.

### GHCR image tags

Rule: the prefix `sha-` names a commit and nothing else. A per-commit tag is
`sha-<full 40-hex commit SHA>` (AG-REL-015, `docs/combined-release-and-checklist.md`).
A tag that names a build identity (the 64-hex hash of a service's build
inputs, `docs/ci-2.0-architecture.md`) is
`<release.tag_identity_prefix><build identity>-<arch>`, with the prefix
`identity-` owned by `.github/yaml/build-manifest.yml` (`release:`) and
written and read only through `_ci_image_tag` in `.github/scripts/ci.sh`.
An identity tag never starts with `sha-`, so no commit-tag reader, pin
check or retention rank can mistake it for a commit.

### Environment variables that refer to services or containers

Rule: no operator environment variable names a service or a container. The
ui and the watchdog in `services` talk to Docker: the ui renders the
configs and wakes the owner containers, the watchdog checks health and
restarts containers. Both find the stack by its compose project label, not
by a name list. The
SOT `CONTAINER_NAME_*` keys are the one place a container name is written.

### Backup/restore paths that depend on these names

Rule: `setup.sh`'s `compose_volume_names()`, `backup_compose_volumes()` and
`restore_compose_volumes()` (see `docs/README.md`) discover Docker
volumes by inspecting the running containers, so a new volume that follows
the rule above is included without a `setup.sh` change. Repo files that a
Compose service mounts through `../../` are found the same way:
`deploy_prod_repo_input_paths()` in `setup.sh` reads every `../../` path from
the Compose files and keeps the ones that exist in the checkout (today
`services/dns/cdn-domains.txt`). There is no hand-kept list.

## Where each name actually lives

| Category | Canonical source | Also appears in |
|---|---|---|
| Compose project name | `deploy/prod/docker-compose.yml` `name:` | the compose project label the watchdog reads |
| Compose service names | `deploy/prod/docker-compose.yml` and `deploy/secondary/docker-compose.yml` service keys | the `status.json` keys the watchdog writes |
| Container names | `.github/yaml/build-manifest.yml` (`CONTAINER_NAME_PREFIX`, `CONTAINER_NAME_*`) | `container_name:` of both Compose files, `LOG_SWITCHES` in `services/common/config.rs` |
| Docker volumes | `deploy/prod/docker-compose.yml` top-level `volumes:` block | the service `volumes:` lists in the same file |
| Host bind-mount directories | the required variables of `deploy/prod/docker-compose.yml` | `docs/README.md`, `setup.sh` |
| GHCR image/package names | `.github/yaml/build-manifest.yml` (`services:`) | `docs/combined-release-and-checklist.md`, the `image:` lines of `deploy/prod` and `deploy/secondary` |

## CI guard

`ci.sh check naming-consistency` (`_ci_check_naming_consistency` in
`.github/scripts/ci.sh`) renders `deploy/prod/docker-compose.yml` and fails
when:
- a service has no `container_name:`;
- a `container_name:` does not end in `-<service>`;
- the services use more than one container name prefix;
- the prefix is not the Compose project name (compared without case).

It does not (and cannot) verify the human-judgment parts of this document —
whether a *new* category of name follows the rule is a code-review
question, not a script's job.

## Code Naming Conventions

### Scope

These conventions MUST apply to all first-party implementation code,
including Rust, Shell, tests, internal APIs, public APIs, data structures,
and generated interfaces. Language-specific native naming conventions MUST
be respected.

### External identifiers

Identifiers mandated by an external format, protocol or program
(for example Kea `option-data`, PowerDNS settings, nginx directives,
Docker labels) keep their external spelling. They are not project-defined.
The project-side name that wraps or refers to them MUST follow this
document. This section records the binding external specifications
referred to in [AG-CODE-014]. A more specific AG rule that
requires a name takes precedence; it MUST be referenced here
and MUST NOT become a second, separately maintained convention.

### Case

| Element | Convention | Example |
| --- | --- | --- |
| Functions, methods, variables, fields, modules, files | `snake_case` | `restart_container()` |
| Structs, enums, enum variants, traits | `PascalCase` | `DnsServer` |
| Constants, statics, environment variables | `SCREAMING_SNAKE_CASE` | `MAX_RETRIES` |
| API paths | lowercase, consistent | `/api/v1/containers` |
| JSON properties (own formats) | `snake_case` | `desired_state` |

Acronyms follow Rust style: `DnsServer`, `HttpClient`, `SnmpAgent`.

### Function verbs

Each prefix has one binding meaning. The verbs are not interchangeable.

| Prefix | Meaning | Example |
| --- | --- | --- |
| `read_` | read local data, no change | `read_config()` |
| `fetch_` | get data from a remote service | `fetch_zone()` |
| `load_` | load stored state or configuration | `load_snapshot()` |
| `save_` | store state permanently | `save_config()` |
| `parse_` | turn input into a structure | `parse_dns_record()` |
| `validate_` | check data, never modify it | `validate_zone()` |
| `render_` | build a representation from data | `render_nginx_config()` |
| `create_` | create a new resource | `create_snapshot()` |
| `ensure_` | make a state exist; idempotent | `ensure_directory()` |
| `apply_` | actually apply a change | `apply_config()` |
| `reconcile_` | align actual with desired state | `reconcile_process_state()` |
| `reload_` | take config without full restart | `reload_nginx()` |
| `restart_` | restart a resource | `restart_process()` |
| `stop_` | stop a running process or service | `stop_container()` |
| `delete_` | remove a resource permanently | `delete_snapshot()` |
| `handle_` | handle an event or request | `handle_process_exit()` |
| `is_` / `has_` / `can_` | boolean state, presence, permission | `is_healthy()` |

Simple getters follow Rust style (`status()`, not `get_status()`).
Conversions follow `as_`, `to_`, `into_`, `From` and `TryFrom`.

### Naming rules

1. Function names MUST describe observable purpose, behavior, and relevant side effects.
2. Equivalent operations MUST use the same terminology across the repository.
3. Naming MUST NOT introduce competing implementations, owners, or duplicate abstractions.
4. Names MUST NOT conceal state changes, file writes, network calls, or process control.
5. `validate_*` MUST NOT modify the validated resource.
6. `reload_*` MUST NOT silently substitute a full restart unless documented.
7. `ensure_*` MUST keep the intended state when repeated with unchanged inputs.
8. Names MUST NOT use suffixes such as `_new`, `_v2`, `_old`, `_helper`, `_impl` or `_async` to tell implementations apart.
9. Names MUST NOT repeat context already given by the owning module or type.
10. Ambiguous names (`do_work()`, `run_task()`, `handle_data()`) MUST NOT be used without clear domain context; abbreviations only where locally unambiguous.
11. Existing canonical names MUST be reused; a second name for an existing capability needs a documented semantic distinction.
12. Public API operations, fields, and their Rust implementations MUST share one terminology.
13. Code identifiers MUST be English, except identifiers mandated by external formats or protocols (for example Kea `option-data`).
14. Naming MUST NOT override ownership, reuse, or consolidation under [AG-CODE-011] and [AG-CODE-013].
15. Naming MUST NOT substitute for comments, test documentation, or verification under [AG-LAW-001].
16. Correct names MUST NOT be changed for cosmetic reasons only.

### Enforcement

Mechanical violations are checked by language tooling (rustc lints,
clippy) and the existing naming guard. Semantic violations are judged
against actual behavior, side effects, ownership and API contracts.
Passing a naming check does not establish overall compliance. A rename
needs a concrete reason and MUST keep all callers, contracts,
serialization formats and external integrations working.

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
