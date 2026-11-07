# Governance

Reviewed against `current_dev` at `ef21ed38524fcf6cd6b43e8d800d19c047fe46a9`.

## Contents

1. [Decision authority](#1-decision-authority)
2. [Path of a change](#2-path-of-a-change)
3. [Roles](#3-roles)
4. [Continuity](#4-continuity)
5. [Howto audit this file](#howto-audit-this-file)

## 1. Decision authority

| Item | State | Evidence |
| --- | --- | --- |
| Maintainers | One, [@djdomi](https://github.com/djdomi) | `MAINTAINERS.md` |
| Committees, voting | None | `MAINTAINERS.md` lists no further role |
| Authority | Architecture, security posture, release approval, dependency and tooling choices, repository settings | Maintainer |
| Rulebook for agents and workflows | `AGENTS.md` (`AG-LAW-001`), with `.github/AGENTS.md` and `CLAUDE.md` | Repository root and `.github/` |

## 2. Path of a change

| Step | Rule or location |
| --- | --- |
| Discussion | GitHub issues and pull requests (`CONTRIBUTING.md`) |
| Design text for larger work | `docs/design-plannings/` |
| Integration into `master` | By pull request (`AG-WF-004`) |
| Merge, close, delete | Maintainer authorization (`AG-WF-005`) |
| Change of `AGENTS.md` content | `AG-WF-016` |

Protection of the default branch `master`:

| Mechanism | State | Evidence |
| --- | --- | --- |
| Ruleset `require pull request before merging` | Active, target `~DEFAULT_BRANCH`, no bypass actors, required approvals 0, review thread resolution required | `gh api repos/wiki-mod/lancache-ng/rulesets/19675909` |
| Branch protection of `master` | Required status checks; no required pull request reviews | `gh api repos/wiki-mod/lancache-ng/branches/master/protection` |
| Branch protection of `current_dev` | Required status check `result` | `gh api repos/wiki-mod/lancache-ng/branches/current_dev/protection` |

## 3. Roles

| Role | Holder | Permission |
| --- | --- | --- |
| Maintainer | [@djdomi](https://github.com/djdomi) | `admin`; code owner of all files (`.github/CODEOWNERS`) |
| Contributor | Anyone opening an issue or pull request | None granted by contributing |
| AI coding agent | Tools directed by the maintainer | None; bound by `AGENTS.md` |

## 4. Continuity

| Item | State | Evidence |
| --- | --- | --- |
| Persons with write access besides the maintainer | None | `MAINTAINERS.md` |
| Fork right | AGPL-3.0-or-later, public repository | `LICENSE` |
| Project knowledge | In the repository: `AGENTS.md`, `docs/` | `AG-WF-026`, `AG-DOC-001` |

Naming a second maintainer is a maintainer decision (`AG-GH-018`).

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
