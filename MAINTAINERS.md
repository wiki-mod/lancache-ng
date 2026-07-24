# Maintainers

This file documents who has access to sensitive project resources and what
their role and responsibilities are, per the OSPS Baseline governance
controls (see `docs/` for the project's other governance documentation).
It is kept up to date whenever repository access or roles change.

## Current maintainers

| GitHub handle | Role | Responsibilities | Access to sensitive resources |
|---|---|---|---|
| [@djdomi](https://github.com/djdomi) | Sole maintainer / owner | Final decision-making on architecture, security posture, release approval, and dependency/tooling choices; reviews and merges all pull requests; triages issues; manages GitHub repository settings | Repository `admin` role (branch protection, security settings, secrets, webhooks); write access to `master`/`current_dev` and all branches; publish rights to the project's GHCR image registry via repository Actions secrets; manages private security advisories and vulnerability disclosure via GitHub Security Advisories |

This list is derived from the repository's actual collaborator permissions
(`GET /repos/wiki-mod/lancache-ng/collaborators`), not from an assumed org
chart, and must be re-verified against that API whenever this file is
updated.

## How contributors relate to this list

lancache-ng accepts external contributions (see `CONTRIBUTING.md`), but
contributors do not receive write access to the repository as part of
having a pull request merged. Write access, admin rights, and secrets are
granted only to the maintainer(s) listed above. AI coding agents (Claude,
Codex, and similar tools) are sometimes used to help implement changes in
this repository, under the direction and review of the maintainer listed
above — an agent's commits and pull requests are not an independent grant
of access and remain subject to the same maintainer review before merge.

## Changes to this list

Adding or removing a maintainer, or changing what sensitive resources they
can access, is a repository governance decision. Open an issue describing
the proposed change before editing this file, so the change itself is
traceable the same way any other governance change is (see `AGENTS.md`'s
"Documentation Drift Is A Defect" section for why stale governance
documentation is treated as a defect, not a stylistic gap).
