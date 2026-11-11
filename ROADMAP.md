# Roadmap

What lancache-ng intends to do and does not intend to do in the next twelve
months. The state of single items is in the GitHub issues and milestones.

## Product line

| Item | State |
| --- | --- |
| Version | Before `1.0.0`; support window in `SECURITY.md` |
| Stable channel | `latest`, built from `master` |
| Experimental channel | `nightly`, built from `current_dev` |
| Development branch | `current_dev` |
| Deployment profile | One profile, `deploy/prod/` |

Channels: `docs/combined-release-and-checklist.md`.

## Intended work

| Topic | Reference |
| --- | --- |
| Find and fix bugs | issues with the label `bug` |
| WireGuard remote LAN access | `docs/design-plannings/design-wireguard-remote-access.md` |

## Not intended

| Topic | State |
| --- | --- |
| IPv6 listener of the PowerDNS recursor | Not planned |
| A second deployment profile besides `deploy/prod/` | Not intended |
| Release `1.0.0` | Maintainer decision, no date |

## Audit

Procedure: `docs/policy/howto-audit-documentation.md`. This file states plans,
not code facts; it is checked against the open issues and the referenced
design document.
