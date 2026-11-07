# Maintainers

Reviewed against `current_dev` at `5f32f9f106949681f8887a8c2e48a467bf7c6dac`.

## Contents

1. [Maintainers](#1-maintainers)
2. [Contributors and AI coding agents](#2-contributors-and-ai-coding-agents)
3. [Changes to this file](#3-changes-to-this-file)
4. [Howto audit this file](#howto-audit-this-file)

## 1. Maintainers

| GitHub handle | Role | Repository permission |
| --- | --- | --- |
| [@djdomi](https://github.com/djdomi) | Owner and sole maintainer | `admin` |

| Item | State | Evidence |
| --- | --- | --- |
| Collaborators with access | One | `gh api repos/wiki-mod/lancache-ng/collaborators` returns `djdomi` with `admin` |
| Code owner of all files | `@djdomi` | `.github/CODEOWNERS` |
| Repository secrets | `CLAUDE_CODE_OAUTH_TOKEN`, `DOCKERHUB_TOKEN`, `DOCKERHUB_USERNAME`, `GHCR_PACKAGE_DELETE_PAT`, `PROJECT_AUTOMATION_PAT`, `SCCACHE_DIST_AUTH_TOKEN`, `SCCACHE_REDIS_URL` | `gh api repos/wiki-mod/lancache-ng/actions/secrets` |
| GHCR login in CI | Workflow token `secrets.GITHUB_TOKEN` | `.github/workflows/ci.yml` (`GHCR_TOKEN`) |
| Security reports | GitHub private security advisories | `SECURITY.md` |

## 2. Contributors and AI coding agents

- Contributors work through issues and pull requests (`CONTRIBUTING.md`).
- A merged pull request grants no repository permission.
- AI coding agents act under the rules of `AGENTS.md` (`AG-WF-004`, `AG-WF-005`). Their commits and pull requests grant no repository permission.

## 3. Changes to this file

A change of the maintainer list or of repository permissions is changed in this file in the same pull request (`AG-DOC-001`). The collaborator list is read again with the command in section 1 at each audit.

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.
