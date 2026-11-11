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

## Howto audit this file

The audit procedure of this file is `docs/policy/howto-audit-documentation.md`.

### Special deviation

| Field | Content |
| --- | --- |
| Step | 3 to 6 |
| Reason | The file states plans, not code facts; its evidence is the state of the referenced issues and documents |
| Replacement | Every row in "Intended work" names an issue label or a design document that exists. `gh issue list --label <label>` and `test -e <path>` give the state. A topic that is done is removed; an intended topic without a row is added. |
