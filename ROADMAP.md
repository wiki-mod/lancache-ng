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
| DNS proxy dnsdist on port 53 in the dns image: client, authoritative, NOTIFY and AXFR traffic on one port; the real client IP reaches recursor and pdns by proxy protocol | `services/dns/Dockerfile` |
| Downloads per device: amount from the cache (HIT) and from the internet (MISS) | nginx access log of the proxy |
| Device names instead of IP addresses in these views | DHCP leases, PTR records |
| Devices that hold a DHCP lease but never query the lancache DNS | DHCP leases, recursor query log |
| HTTP or HTTPS mode per device, with TLS errors that point to a missing CA certificate | recursor query log on `IP_HTTPS`, nginx error log |
| DNS queries per device | recursor query log |
| CacheHamster: prefill over HTTPS for HTTPS caching | `services/cachehamster/` |
| CacheHamster: platforms besides Steam | `services/cachehamster/` |

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
| Replacement | Every row in "Intended work" names an issue label, a design document or file, or the data source the topic builds on. `gh issue list --label <label>` and `test -e <path>` give the state. A topic that is done is removed; an intended topic without a row is added. |
