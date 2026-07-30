# Governance

This document describes how lancache-ng makes decisions today: who decides
what, how proposals move from an idea to merged code, and what happens if
the current maintainer becomes unavailable. It exists to satisfy the OpenSSF
Best Practices Badge's Silver-tier `governance` and `roles_responsibilities`
criteria (project #13763, tracked in issue #1130) with a real, accurate
description rather than a template that doesn't match how this project
actually runs.

## Decision-making model

lancache-ng currently has **one human maintainer** ([@djdomi](https://github.com/djdomi))
and no formal steering committee, working group, or voting process. This is
a deliberate reflection of the project's actual current size and contributor
base, not an aspiration to grow a committee before there is a community that
needs one.

- **Final decision-making authority** on architecture, security posture,
  release timing, dependency and tooling choices, and repository settings
  rests with the maintainer. See `MAINTAINERS.md` for the authoritative,
  API-verified list of who currently holds this role and what repository
  access it comes with.
- **Proposals and discussion happen in the open**, via GitHub issues and pull
  request review, per `CONTRIBUTING.md`. Anyone can open an issue or a pull
  request; the maintainer reviews and merges.
- **AI coding agents** (Claude, Codex, and similar tools) are used to help
  implement changes under the maintainer's direction. An agent's commits and
  pull requests carry no independent decision-making authority — they remain
  subject to the same review as any other contribution before merging, and
  the repository's own agent governance (`AGENTS.md`, `.github/AGENTS.md`,
  `CLAUDE.md`) instructs those agents to make ordinary technical decisions
  independently but to escalate anything with real operational impact
  (hardware, cost, network topology, or an irreversible/high-risk change)
  back to the maintainer rather than deciding it unilaterally.

## How a change actually gets decided

1. **Small, well-scoped fixes** can go straight to a pull request; the PR
   itself carries the rationale (see `CONTRIBUTING.md`'s "Before you start").
2. **Larger or ambiguous changes** — new features, behavior changes,
   anything touching security posture or release process — start as a
   GitHub issue so the proposal and its discussion are traceable before code
   exists. `docs/` design documents (e.g. `docs/design-wireguard-remote-access.md`)
   are used for changes that need more written rationale than an issue body
   comfortably holds.
3. **The maintainer reviews and merges** every pull request; nothing lands
   on `current_dev` or `master` without that review, and `master` additionally
   requires a pull request by branch protection (see `AGENTS.md`'s
   `AG-WF-004`/`AG-GOV-004`).
4. **Governance and rule changes themselves** (this file, `AGENTS.md`,
   `CLAUDE.md`, `CODE_OF_CONDUCT.md`, `MAINTAINERS.md`) require the
   maintainer's explicit review before being changed — `AGENTS.md`'s
   `AG-WF-016` specifically forbids silently narrowing or rewriting existing
   governance content without that sign-off.

## Key roles and responsibilities

| Role | Who | Responsibilities |
|---|---|---|
| Maintainer / owner | [@djdomi](https://github.com/djdomi) | Final say on architecture, security posture, and release approval; reviews and merges every pull request; triages issues; manages repository settings, secrets, and security advisories. See `MAINTAINERS.md` for the full, API-verified detail. |
| Contributors | Anyone opening an issue or pull request | Propose changes via issues/PRs following `CONTRIBUTING.md`; do not receive write access, admin rights, or secrets as part of a merged contribution. |
| AI coding agents | Claude, Codex, and similar tools, directed by the maintainer | Implement changes under the governance rules in `AGENTS.md`/`.github/AGENTS.md`/`CLAUDE.md`; make independent technical decisions where the correct answer is determinable from code/docs, escalate the rest. |

## Continuity if the maintainer is unavailable

This project does not yet have a second person with repository write access
(see `MAINTAINERS.md`'s single-row maintainer table) — the Best Practices
Badge's Silver-tier `bus_factor` criterion is tracked as a known, currently
unmet gap in issue #1130 for exactly this reason, and closing it is the
maintainer's decision to make (naming a second trusted maintainer is a real
operational/trust decision, not something an agent can decide on the
maintainer's behalf). Until that happens, continuity relies on:

- The repository being public on GitHub (any interested party can fork it if
  the project is ever abandoned; the AGPL-3.0-or-later license explicitly
  preserves that right — see `LICENSE`).
- All project knowledge — architecture, security posture, release process,
  and historical rationale — being kept in version-controlled, in-repository
  documentation (`AGENTS.md`, `CLAUDE.md`, `docs/`) rather than only in the
  maintainer's head or in chat history, per `AGENTS.md`'s "Documentation
  Drift Is A Defect" and `AG-WF-026` consolidation rules.

## Changing this document

Governance changes are themselves a governance decision: open an issue
describing the proposed change before editing this file or `MAINTAINERS.md`,
the same way `MAINTAINERS.md`'s own "Changes to this list" section already
requires for maintainer-list changes.
