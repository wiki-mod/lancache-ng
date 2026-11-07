# Roadmap

This document states what lancache-ng intends to do and does not intend to do
in the next twelve months (OpenSSF Best Practices criterion
`documentation_roadmap`). The live record is the set of GitHub milestones,
issues and pull requests; each item below names its tracking item.

## Contents

1. [Product line](#1-product-line)
2. [Intended work](#2-intended-work)
3. [Not intended or not scheduled](#3-not-intended-or-not-scheduled)
4. [Howto audit this file](#howto-audit-this-file)

## 1. Product line

| Item | State |
| --- | --- |
| Version | Pre-1.0; support window in `SECURITY.md` |
| Stable channel | `latest`, built from `master` |
| Pre-stable channel | `nightly`, built from `current_dev` |
| Development branch | `current_dev` |
| Deployment profile | One profile, `deploy/prod/` (`AG-KD-008`) |

Channel semantics are in `docs/combined-release-and-checklist.md`.

## 2. Intended work

| Topic | Tracking | Milestone |
| --- | --- | --- |
| CI rewrite and its follow-up work | [#1683](https://github.com/wiki-mod/lancache-ng/issues/1683) | none |
| CI infrastructure rework (rebuild, scan, promote, workflow consolidation) | [#1095](https://github.com/wiki-mod/lancache-ng/issues/1095) | Tooling & Checks |
| Check that the `latest` channel can be pulled by tag and started (daily) | [#1986](https://github.com/wiki-mod/lancache-ng/issues/1986) | none |
| CacheHamster: stream-and-discard Steam prefill | [#871](https://github.com/wiki-mod/lancache-ng/issues/871) | LanCache-NG Roadmap |
| Admin UI: unified visual redesign | [#1437](https://github.com/wiki-mod/lancache-ng/issues/1437) | In the Future |

Design documents for planned work: `docs/design-steam-prefill.md`.

## 3. Not intended or not scheduled

| Topic | State | Reference |
| --- | --- | --- |
| IPv6 listener of the PowerDNS recursor | Deferred, low priority | [#851](https://github.com/wiki-mod/lancache-ng/issues/851) |
| A second deployment profile besides `deploy/prod/` | Not intended | `AG-KD-008` |
| Promotion to `1.0.0` | Maintainer decision | `AG-GH-018` |
| WireGuard remote LAN access | Design proposal only, not approved, not scheduled | `docs/design-plannings/design-wireguard-remote-access.md` |

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.

### Special deviation

| Field | Content |
| --- | --- |
| Step | 3 to 6 |
| Reason | The file states plans, not code facts; its evidence is the state of the tracking items |
| Replacement | Every item in sections 2 and 3 has an open tracking issue, a design document or a rule identifier that exists. `gh issue view <number>` and `gh pr view <number>` give the state. An item whose tracking issue is closed is removed from section 2 or moved to section 3 with its reference. An open issue that states intended work and has no row in section 2 is added. |
