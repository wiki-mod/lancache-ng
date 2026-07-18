# Release Certification Checklist

This is the **reusable, mandatory gate** a lancache-ng release candidate must pass
before a stable `vX.Y.Z` tag is cut. It is a template: copy the checklist for each
release, fill in the concrete values (commit, host, date), and attach the completed
copy (or a link to the tracking issue where it was run) to the release.

It exists because the per-PR CI (`build-push.yml`, `build-tools.yml`,
`full-setup-*-validate.yml`) proves each change in isolation, but does **not** prove
that the *whole stack, built from the exact release commit, deployed together,
survives running for an hour without a single service bootlooping or restarting*.
That holistic, time-based gate is what this document certifies.

> **Scope note.** This checklist certifies *the stack built from the release
> branch's source at a specific commit*. The images a stable release finally ships
> (`ghcr.io/wiki-mod/lancache-ng/*:vX.Y.Z`) do not exist until the release tag is
> pushed and `build-push.yml` mints them. Whoever confirms the release **must
> additionally verify** the published `vX.Y.Z` digests trace back to the same source
> commit certified here (or that promotion is digest-preserving from the CI build of
> that commit). A green certification of the source does not, by itself, certify a
> different set of bytes published later.

## Definitions — what "certified" means

A release is certified only when **all three gates pass in order**:

1. **Functional** — every service works end-to-end with real probes (not just
   "container is Up"): DNS resolves in both modes, TLS is intercepted in SSL mode and
   passed through in standard mode, HTTP and HTTPS content is actually cached
   (miss→hit), the Admin UI serves, NATS is connected, the watchdog is polling.
2. **Tests** — the project's own suites (`bats`, `shellspec`) pass, run inside the
   pinned build-tools container (the *only* valid verification path, per
   `AGENTS.md` **AG-VAL-016**).
3. **Stability** — the deployed stack runs **60 continuous minutes** with **zero**
   container restarts or restart loops.

If any gate fails, the run **FAILS**. Fix the defect (open a PR, verify, merge under
the normal rules), redeploy, and **restart the failed gate from the beginning** — in
particular, any restart during the stability window resets its 60-minute clock to zero.

---

## Prerequisites

- [ ] Validation runs on the established Linux validation hosts (Windows cannot build
      the Rust services — the linker is broken there). Primary hosts: `lancache-229`,
      `lancache-240`; additional capacity: `lancache-241`, `lancache-243`.
- [ ] **Build host** and **deploy/watch host** are chosen deliberately and are
      *different* machines where possible. The deploy/watch host must be the
      **quietest** available (lowest load, fewest orphaned validation containers) so
      an unrelated CI job scheduled onto it mid-watch cannot OOM-kill a container and
      cause a false stability failure.
- [ ] Record the release commit under certification: `RELEASE_COMMIT=____________`
      (e.g. the tip of the release branch). Every host checkout is verified to be at
      exactly this SHA.
- [ ] `docker`, `dig`, `openssl`, `curl` available on the deploy host; GHCR is
      reachable (for third-party images: `nats`, `netdata`, `docker-socket-proxy`).

## Step 0 — Provenance: pick the right artifact

- [ ] Confirm which commit is being released and whether images exist for it.
      GHCR `:latest` = the *previous* stable release; `:edge` = master-line. **Neither
      is the release candidate** unless the release branch has been merged to master.
      Cross-check with `docker inspect --format '{{index .Config.Labels
      "org.opencontainers.image.revision"}}'` against `RELEASE_COMMIT`.
- [ ] If no published image set matches `RELEASE_COMMIT` (the normal case for a
      release branch ahead of master), **build the stack from source** (Step 1). Do
      **not** substitute `latest`/`edge` — that certifies the wrong code.
- [ ] Do **not** cut a `vX.Y.Z-rc.N` tag merely to force CI to publish images: tagging
      triggers release-promotion automation and is a maintainer/release-stage action,
      outside a verification run's authority. Building from source is the
      side-effect-free faithful equivalent.

## Step 1 — Build the stack from the release source (build host)

- [ ] Fresh checkout at `RELEASE_COMMIT`; verify `git rev-parse HEAD`.
- [ ] Resolve the build-tools image the same way CI does:
      `BUILD_TOOLS_IMAGE=$(BUILD_TOOLS_REQUIRE_PUBLISHED=true bash scripts/select-build-tools-image.sh)`
- [ ] Build each service, mirroring the CI matrix (context = `services/<svc>`):
  - [ ] `proxy` — needs `--build-context dns-domains=services/dns`
  - [ ] `dns` — Rust; `--build-arg BUILD_TOOLS_IMAGE=$BUILD_TOOLS_IMAGE`
  - [ ] `ui` — Rust; `--build-arg BUILD_TOOLS_IMAGE=$BUILD_TOOLS_IMAGE`
  - [ ] `watchdog`
  - [ ] `dhcp`, `dhcp-proxy` (needed only if certifying the DHCP profile / lease-flow sim)
  - Tag every image `ghcr.io/wiki-mod/lancache-ng/<svc>:<LOCAL_TAG>` (e.g. a
    `cert-<version>-<shortsha>` tag that cannot collide with a published channel).
- [ ] Transfer images to the deploy/watch host without a registry:
      `docker save <images> | gzip -1 | ssh <deploy-host> 'gunzip | docker load'`.

## Step 2 — Deploy the stack (deploy/watch host)

- [ ] Fresh checkout at `RELEASE_COMMIT` on the deploy host.
- [ ] Generate the CA: `bash certs/generate-ca.sh` (creates `certs/ca.crt` + `ca.key`).
- [ ] Produce a real secret set. Either run `setup.sh` (its interactive installer also
      touches host networking/packages — avoid on a shared build slave), or reproduce
      its secret contract exactly with `openssl` into `deploy/prod/.env.local`:
  - [ ] `DDNS_TSIG_KEY` = `openssl rand -base64 32`
  - [ ] `PDNS_API_KEY`, `KEA_CTRL_TOKEN`, `SECONDARY_REGISTRATION_TOKEN`, and every
        `NATS_*_PASSWORD` = `openssl rand -hex 32`
  - [ ] `UI_AUTH_USER` + `UI_AUTH_PASSWORD` (or `ALLOW_INSECURE_UI=true` only for an
        explicitly unauthenticated UI)
  - [ ] `LANCACHE_IMAGE_TAG=<LOCAL_TAG>`, `LANCACHE_STATE_DIR=<writable dir>`
  - [ ] `IP_STANDARD` / `IP_SSL` = two host-reachable addresses (add non-colliding
        addresses on a `dummy` interface if the host has no spare LAN IPs).
- [ ] **Sync the DNS spoof target.** `config/prod/dns-standard.env` and
      `config/prod/dns-ssl.env` carry `PROXY_IP=` independently of `.env` (setup.sh
      normally syncs them). Set them to the matching `IP_STANDARD` / `IP_SSL`, or the
      DNS zones will spoof CDN names to the template default `192.168.234.x` and no
      client can reach the proxy.
- [ ] `docker compose -f deploy/prod/docker-compose.yml --env-file deploy/prod/.env.local config`
      resolves cleanly and every `image:` shows `<LOCAL_TAG>`.
- [ ] `docker compose ... up -d`; after boot, `docker compose ps` shows every service
      `healthy` (or `running` for the no-healthcheck helpers). If you edit any
      `config/prod/*.env` after first boot, `up -d --force-recreate <svc>` — a plain
      `restart` does **not** re-read env files.

## Step 3 — Gate 1: Functional verification (real probes)

Use a real, fetchable CDN entry from `services/dns/cdn-domains.txt` (e.g.
`deb.debian.org`, which serves plain `curl` requests — most game CDNs need signed URLs).

- [ ] **DNS standard mode**: `dig @<IP_STANDARD> <cdn> +short` → `<IP_STANDARD>`
- [ ] **DNS ssl mode**: `dig @<IP_SSL> <cdn> +short` → `<IP_SSL>`
- [ ] **SSL MITM cert**: `openssl s_client -connect <IP_SSL>:443 -servername <cdn>`
      presents a cert issued by `CN=LanCache-NG CA`; a client trusting `certs/ca.crt`
      completes the handshake **without** `-k`.
- [ ] **Standard passthrough cert**: `openssl s_client -connect <IP_STANDARD>:443
      -servername <cdn>` presents the **real upstream** CDN cert (no interception).
- [ ] **HTTP cache**: `curl --resolve <cdn>:80:<IP_STANDARD> http://<cdn>/<path>`
      twice → `X-Cache-Status: MISS` then `HIT`; `X-Served-By: lancache-ng`.
- [ ] **HTTPS (MITM) cache**: `curl --cacert certs/ca.crt --resolve
      <cdn>:443:<IP_SSL> https://<cdn>/<other-path>` twice → `MISS` then `HIT` over
      trusted TLS. (Use a *different* path than the HTTP test — the cache key is
      `$host$uri`, shared across HTTP/HTTPS.)
- [ ] **Admin UI**: unauthenticated → `401`; authenticated → `200`; `/health` → `200`;
      dashboard renders (`<title>LanCache-NG Admin …`).
- [ ] **NATS**: server `healthy`; each DNS container logs `Connected to NATS` and
      `Created durable subscriber`.
- [ ] **Watchdog**: `status.json` is updating with a recent timestamp, all monitored
      services green, `failures: 0`.
- [ ] **DHCP** (profile-gated; `DHCP_MODE` defaults to `disabled` in the prod
      profile): run `scripts/dhcp-kea-lease-flow-simulation.sh` (it **builds from
      source** — pass `DHCP_LEASE_FLOW_CLIENT_IMAGE=$BUILD_TOOLS_IMAGE`) for a real
      Kea DISCOVER→OFFER→REQUEST→ACK lease flow, or bring up the `dhcp-kea` profile.
- [ ] **IPv6**: on a dual-stack host, repeat the DNS (`AAAA`) and cache probes over
      IPv6. On an IPv4-only harness, record this as *not verified here* rather than
      silently skipping.

> The repo's simulation scripts encode much of this. Note which **build** from source
> (e.g. `dhcp-kea-lease-flow-simulation.sh`) vs. **pull** published images (e.g.
> `ssl-mitm-cache-simulation.sh` pulls `edge`). Pull-based sims test master-line code,
> **not** an unpublished release candidate — for those, reproduce the assertions
> directly against the source-built deployment (as above).

## Step 4 — Gate 2: Test suites (pinned build-tools container)

Mirror CI (`build-tools.yml`) exactly; do **not** fall back to host tools (AG-VAL-016).

- [ ] `docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work
      "$BUILD_TOOLS_IMAGE" bash -lc 'set -euo pipefail; bats tests/bats'` → 0 failures.
- [ ] `docker run --rm ... "$BUILD_TOOLS_IMAGE" bash -lc 'shellspec --shell bash
      tests/shellspec'` → 0 failures.

## Step 5 — Gate 3: 60-minute stability watch

Watch the **deployed prod stack** (not an ephemeral sim). Keep the host quiet.

- [ ] Record each container's restart count at t=0:
      `docker inspect -f '{{.Name}} {{.RestartCount}}' $(docker compose ps -q)`.
- [ ] Start a backgrounded event capture for the whole window so a restart *between*
      samples is still caught:
      `docker events --filter event=restart --filter event=die --filter event=oom
      --format '{{.Time}} {{.Actor.Attributes.name}} {{.Status}}' > events.log &`
- [ ] Sample `docker compose ps` periodically across the full hour (not just start and
      end). Post progress at least every 15 minutes.
- [ ] At t=60m: restart counts unchanged from t=0, `events.log` shows **no**
      `restart`/`die`/`oom` for any stack container, every service still `healthy`.
- [ ] **Any** restart or bootloop in the window ⇒ FAIL: diagnose, fix, redeploy, and
      restart this 60-minute clock from zero.

## Sign-off

- [ ] Gate 1 (functional): PASS / FAIL
- [ ] Gate 2 (tests): PASS / FAIL
- [ ] Gate 3 (60-min stability): PASS / FAIL — window `HH:MM`–`HH:MM`, 0 restarts
- [ ] Provenance note recorded (commit certified; downstream must match published digests)
- [ ] Overall: **CERTIFIED / NOT CERTIFIED**

Record: `RELEASE_COMMIT`, build host, deploy/watch host, `LOCAL_TAG`, build-tools
digest, date, and a link to the tracking issue where the run was documented.
