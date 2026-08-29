# Roadmap

This document describes what lancache-ng intends to do, and deliberately does
not intend to do, looking roughly a year out. It exists to satisfy the OpenSSF
Best Practices Badge's Silver-tier `documentation_roadmap` criterion (project
#13763, tracked in issue #1130) with a real, currently-accurate picture rather
than a static aspirational list.

The authoritative, live version of this roadmap is always the project's
GitHub Milestones and the **LanCache-NG Roadmap** project board/milestone —
this file is a periodically-refreshed summary of that real state, not a
replacement for it. If this file and the GitHub milestones disagree, GitHub
is correct (see `AGENTS.md`'s documentation-drift precedence rules) and this
file should be updated to match.

## Where the project is today

- Current stable line: pre-1.0 `v0.x` (see `docs/release-versioning.md` for
  the channel/tagging model). The project is pre-1.0 deliberately — breaking
  changes still bump the minor version, not a major version, until a
  maintainer-decided production-readiness milestone (issue #819).
- Active development branch: `current_dev` (see `docs/release-versioning.md`
  and issues #825/#1141 for the branch/channel model). `master` only receives
  occasional stable-release promotions.
- `v0.3.0` retired the old parallel `deploy/dev/` environment (#766) in favor
  of a single `deploy/prod/` profile used for both developing and deploying,
  distinguished only by which git ref is checked out.

## What the project intends to do (next ~12 months)

Grouped by the GitHub Milestone that actually tracks each item (see the
linked issue numbers for full detail — this file summarizes, it does not
duplicate, their acceptance criteria):

### LanCache-NG Roadmap milestone

- **Security posture / OpenSSF Best Practices Badge** (#1130): keep closing
  real, verified gaps toward the Silver and Gold tiers of the legacy Best
  Practices Badge and toward OSPS Baseline Level 3, rather than only
  improving the reported percentage.
- **Admin UI completeness** (#1078): finish wiring Admin UI capabilities that
  `docs/architecture-ng.md` already documents but the UI doesn't yet expose
  (per `AGENTS.md`'s "Feature Completeness" section — a backend capability
  without UI exposure is treated as delivery debt, not as done).
- **DNS resilience** (#1164): native PowerDNS AXFR/NOTIFY primary/secondary
  replication for `dns-standard`/`dns-ssl`, superseding the earlier #770
  design.
- **DHCP consolidation** (#840): umbrella for scattered Kea/dnsmasq-proxy
  feature and bug work; includes replacing the EOL `dhclient` + `nmap`
  DHCP-probe tooling with a native Rust implementation (#1288).
- **Watchdog coverage** (#842, #1170): the watchdog currently only monitors
  `proxy`/`dns-standard`/`dns-ssl` despite its name implying stack-wide
  coverage; also adding self-healing for a hung `docker-socket-proxy`.
- **Release automation** (#819, #850): move the fully-manual `vX.Y.Z` semver
  bump decision toward automation, once the tag/PR-title mechanics it depends
  on (see `AGENTS.md`'s `AG-GH-018` caveat on `release-please` readiness) are
  in place.
- **Field-testing follow-through** (#1068): work through the setup/docs gaps
  and Admin UI/DHCP/DNS UX issues found during hands-on `v0.2.0` field
  testing; roughly half of that audit's findings remain open.
- **Base image evaluation** (#815, #1287): evaluate migrating DNS/DHCP and
  proxy/ntp/watchdog/ui services to Alpine base images for fresher packages.
- **Undocumented-vs-real-capability audits** (#843, #871): reconcile
  documentation that describes capabilities against what actually exists in
  the codebase today — e.g. the Cache Warmer, whose mechanism is now decided
  (stream-and-discard prefill, not steamcmd, per #871) but not yet built.
- **CI/tooling health**: several open `ci`/`tooling`-labeled issues (e.g.
  #1014 consolidating workflow files, #1065's runner-pool saturation,
  #1253/#1290 narrowing build-tools rebuild triggers) reduce CI cost and
  fragility without changing product behavior.

### v0.3.0 milestone (in-flight release line)

Nineteen open issues track the remaining work for the current `v0.3.0` line,
spanning setup-flow refactors (#1263), CI trigger-coverage gaps (#1245,
#1176), and the items above that are also tagged for this specific release.
See the milestone itself for the current exact set, since it changes as
issues close.

## What the project deliberately does not intend to do (or has deferred)

- **IPv6 for the PowerDNS Recursor** (#851): deliberately deferred as low
  priority; full dual-stack support already exists elsewhere in the stack
  (see `AGENTS.md`'s `## CDN Domains, First-time Setup, IPv6` section — **corrected
  2026-08-05, issue #1391 doc-sweep audit**: this used to point at `CLAUDE.md`'s IPv6
  notes, which moved into `AGENTS.md` on 2026-07-31 per `CLAUDE.md`'s own current
  text), but the recursor's own IPv6 listener is not currently planned work.
- **A parallel `deploy/dev/` environment**: deliberately retired (#766, v0.3.0)
  and not coming back — see `AGENTS.md`'s `AG-KD-008` (**corrected 2026-08-05, issue
  #1391 doc-sweep audit**: this used to point at `CLAUDE.md`'s "No Separate Dev
  Environment" section, which also moved into `AGENTS.md` on 2026-07-31) for why an
  earlier version of this project's own tooling mistakenly grew one and why that was
  undone.
- **A major-version (`1.0.0`) bump**: `AGENTS.md`'s `AG-GH-018` is explicit
  that this stays a deliberate, manual maintainer decision, never an
  automatic side effect of any automation this roadmap's release-automation
  item might add.
- **Mandatory two-person code review** and other Gold-tier Best Practices
  Badge process controls that would change how contributions are reviewed:
  these are real maintainer decisions with ongoing process cost, tracked as
  open questions in issue #1130 rather than committed roadmap items.

## Keeping this current

Whoever last works through the `LanCache-NG Roadmap` milestone in a given
quarter should re-check this file against the real milestone/issue state and
correct drift, the same way `docs/threat-model.md` is re-audited per release
(see that document's own "How to re-audit this document" section for the
pattern this follows).
