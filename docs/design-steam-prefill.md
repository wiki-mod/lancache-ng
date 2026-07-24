# Steam Prefill (Proactive Cache Warming) — Design Plan

**Status: design proposal only, not committed, not scheduled.** Nothing in
this document is approved for implementation. This is the written design
plan issue [#816](https://github.com/wiki-mod/lancache-ng/issues/816) asked
for, produced for maintainer review before any code is written. Most of the
research below was already captured directly in #816's own issue body and
its 2026-07-14 self-correction comment; this document consolidates that
research into a single reviewable place and adds one piece of net-new
analysis that wasn't in the issue: an explicit overlap check against
[#871](https://github.com/wiki-mod/lancache-ng/issues/871) (see
["Overlap with #871"](#overlap-with-871-cache-warmer) below), which the
maintainer specifically asked this pass to resolve.

## Goal

Add a "Steam prefill" capability for v0.3.0: proactively trigger Steam depot
downloads through lancache-ng so the proxy's own cache observes and stores
the traffic ahead of time, without anyone playing/downloading live first.

## Non-negotiable requirement

**The prefill tool must never persist downloaded game content to its own
local disk.** Its only legitimate job is to make bytes flow through
lancache-ng's proxy so *the proxy* caches them. The prefill process must
stream each HTTP response and discard it (conceptually "pipe to /dev/null")
— never buffer a full chunk/depot file or write one to disk.

In Rust this is a solved problem, not a research gap: `reqwest`'s streaming
body API (`Response::bytes_stream()`), or draining an `AsyncRead` into
`tokio::io::sink()` via `tokio::io::copy`, both read-and-drop each chunk
without ever writing to a file or holding the whole body in memory. The
open question is only which Steam-protocol layer lets us intercept the HTTP
GET and read the body ourselves, rather than forcing us through its own
"download to file" helper — see below.

## Reference tool: `tpill90/steam-lancache-prefill` (C#/.NET, MIT license)

- **Disk-write claim — confirmed, not assumed.** Its README states directly
  that game downloads write no data to disk. Good prior art, but its
  protocol layer (SteamKit2/DepotDownloader-adjacent) is GPL-licensed in
  places — do not port that code directly; re-verify the exact license of
  anything actually touched before copying.
- Requires a real Steam account login (Steam Guard + Mobile Authenticator
  supported). Anonymous login exists in the protocol but only works for
  free-to-play/tools apps (e.g. Spacewar, AppID 480) — most users' actual
  libraries need a real account.
- The same author maintains `epic-lancache-prefill` and
  `battlenet-lancache-prefill` with the same overall shape — useful
  precedent for a future generalized multi-CDN prefill design, not a v0.3.0
  commitment.

## Rust crate landscape

- **`steam-vent`** (<https://codeberg.org/steam-vent/steam-vent>) — mature
  (created 2023-08, ~9.5k downloads, v0.5.0). Handles the Steam
  **network/auth** layer (login, Steam Guard, licenses). The hard,
  security-sensitive part, and the one crate here with a real track record.
- **`steamroom` / `steamroom-client`**
  (<https://github.com/landaire/steamroom>) — a cleanroom Rust
  reimplementation of DepotDownloader's depot/manifest/CDN logic, built
  specifically to avoid GPL issues. Covers manifest parsing, chunk
  decrypt/decompress/checksum, CDN server pooling, and anonymous logon for
  free apps. Very young (created 2026-04-12, ~7 GitHub stars, ~164
  downloads, v0.2.0) — promising exact fit, but unproven. Its high-level
  client defaults to writing chunks directly to files, which conflicts with
  the no-disk-write requirement — the design uses only its lower-level
  depot/CDN types, not its download orchestration.
- Ruled out: `steamworks` (game-integration SDK bindings, not CDN),
  `steam-rs` (Web API bindings only), `steam-client-rs`/`steam-kit`
  (general Steam-network clients, not depot-focused).

**Recommendation**: split the problem across three planes so the
no-disk-write guarantee lives in code this project controls, not in a
dependency's behavior:

- **Control plane** (login, Steam Guard 2FA, license/manifest access) →
  `steam-vent`.
- **Depot/manifest layer** (parsing manifest format, listing chunk hashes)
  → `steamroom`'s lower-level types, pinned carefully as an evolving
  dependency, with a minimal from-scratch reimplementation as a fallback if
  it proves too unstable.
- **Data plane** (fetching each chunk's bytes) → plain `reqwest` GET against
  the resolved CDN URL, streamed straight to a discard sink.

One nuance to confirm during implementation rather than assume here: modern
Steam may require an authenticated "manifest request code" even for
otherwise-anonymous depots — if so, real per-operator Steam credentials will
likely be needed for anything beyond free-to-play test apps (see open
decisions below).

## HTTP vs HTTPS, and why this deploys via standard mode

Steam depot/chunk/manifest downloads are served over **plain HTTP**
(`http://<cdn-host>/depot/<depot-id>/chunk/<hash>` across Valve's own CDN
nodes and third-party CDNs). Only the Steam-network control-plane
connection (login, licenses, manifest metadata) uses Steam's own encrypted
binary protocol, which is not cacheable content and irrelevant to lancache
either way.

The strongest evidence: `tpill90`'s Steam/Epic/Battle.net prefill tools
already work against real lancache/lancachenet deployments today, and
lancachenet only caches HTTP.

**Implication for this project**: prefill traffic lands in cache via
**standard mode** (SNI-passthrough proxy path) — no CA cert trust needed on
whatever host runs the prefill tool, exactly like a real Steam client
today. SSL mode would also work (it's a superset for HTTP) but standard
mode is sufficient and simpler to require.

**Wiring check, verified against this repo's actual code as of this
writeup**: `services/dns/cdn-domains.txt` already lists the depot/content
hostnames (`steamcontent.com`, `content1-5.steampowered.com`,
`cs.steampowered.com`).

### The `lancache.steamcontent.com` sentinel

The Steam client does an explicit DNS lookup for a sentinel hostname, and
if it resolves, switches into a dedicated "SteamCache" download mode (max
connections per cache IP goes from 4 to 32; the client stops using Valve's
CDN-broker feature, which can otherwise route downloads to third-party CDN
nodes in ways that break simple HTTP caching). This is specifically about
the **official Steam client's** behavior, not about whether depot bytes are
fetchable/cacheable at all — a custom prefill tool built on
`steam-vent`/`steamroom` talks to the CDN directly, isn't the Steam client,
and isn't gated by this detection logic either way. It matters for real
Steam clients elsewhere on the LAN (so prefilled content is actually served
to them at good performance), not as a precondition for the prefill tool
itself.

The sentinel hostname is `lancache.steamcontent.com`, confirmed via
LanCache.NET's own 2020 announcement post and the community-maintained
`uklans/cache-domains` hostname list.

**No DNS change is needed.** `services/dns/entrypoint.sh` generates the RPZ
zone from `cdn-domains.txt` by emitting both an exact match and a
wildcard record per line. Since `steamcontent.com` is already a line in the
file (re-verified directly against `services/dns/cdn-domains.txt` while
writing this document), the generated zone already includes
`*.steamcontent.com → PROXY_IP`, which matches `lancache.steamcontent.com`
as a subdomain.

### How other storefronts handle the same problem (context, not a mandate)

This "special sentinel hostname" mechanism appears Steam-specific. The
Blizzard domain list has no `lancache.*`-style sentinel — DNS-overriding
its real CDN hostnames is sufficient. Origin and Riot clients are reported
to instead require the *resolved* cache IP itself to be an RFC1918 private
address before trusting a redirected download source — a different
mechanism (address-range validation), same underlying goal. This project's
proxy IPs are already LAN/RFC1918 addresses, so that check is already
satisfied for any future non-Steam prefill work. Net takeaway: no single
generic detection pattern across CDNs; each storefront's client has its own
quirk.

## Overlap with #871 (Cache Warmer)

**These two issues are not distinct features — they are two different
proposed mechanisms for the same underlying need, and the mechanisms
actively conflict.**

[#871](https://github.com/wiki-mod/lancache-ng/issues/871) found that
`docs/architecture-ng.md` documents an entire "Cache Warmer" subsystem
(top-of-file service table plus a `## Cache Warming` section) that does not
exist in the codebase anywhere. As currently documented, that subsystem is:

- a separate `services/warmer` container running **`steamcmd`**
- the operator enters a Steam app ID
- `steamcmd` fetches the depot manifest and chunk URLs through the local
  proxy (so lancache-ng's cache does observe and store the traffic — same
  end goal as this issue)
- live progress shown in the Admin UI (total chunks / completed / MB/s)
- optional Steam account credentials via `STEAM_USER`/`STEAM_PASS` env vars
- app-ID-to-URL tracking as a basis for targeted cache purging

That is a real, coherent design for the same "proactive Steam cache
warming" goal this issue (#816) addresses — but it is built on `steamcmd`,
and `steamcmd` **installs the game**: it downloads, verifies, decompresses,
and writes the full depot content to a local app directory on whatever host
runs it. That is precisely what this issue's non-negotiable requirement
forbids. `steamcmd`'s own normal operation is not a "download to a
throwaway buffer and discard" step — it is a real install, with real
disk-space and SSD-wear cost on the warmer host, which is exactly the
downside `tpill90`'s C# reference tool (and this issue's whole design)
exists to avoid. The two documents are not "two options for the same easy
thing" — they trade off real operational costs against each other:

| | #871 (steamcmd container) | #816 (this document) |
|---|---|---|
| Depot bytes touch local disk on the warmer host | Yes (real install) | No (streamed + discarded by design) |
| Disk/SSD footprint on warmer host | Full library size, repeatedly | None |
| Implementation effort | Wraps an existing, mature Valve tool | Custom Rust control/depot/data-plane split across two young-to-mature crates |
| Admin UI integration (progress, app-ID input) | Already specified in the doc | Not designed here; would need its own work |
| Targeted-purge tracking (app ID → CDN URLs) | Already specified in the doc | Not designed here; would need its own work |
| Credential handling | Documented (env vars) | Explicitly flagged as an open decision (see below) |

**This is a maintainer reconciliation call, not something to resolve by
picking a side unilaterally.** Two honest framings are possible, and both
are legitimate:

1. **#816 supersedes #871.** If the no-disk-write requirement is a hard
   product requirement (as #816 states), then the `steamcmd`-based design
   `architecture-ng.md` currently describes is simply the wrong mechanism
   and should be retired from the doc in favor of this design once it is
   approved. Under this framing, #871's real value is the parts #816
   doesn't cover yet — Admin UI progress reporting and app-ID → URL
   tracking for targeted purging — which could be adopted as UI/tracking
   requirements for whichever engine actually gets built, without adopting
   `steamcmd` itself.
2. **Both stay, serving different operators.** An operator who doesn't
   mind the disk/SSD cost and wants the simplicity and maturity of
   wrapping Valve's own official tool might prefer a `steamcmd`-based
   warmer; an operator who cares about warmer-host disk wear wants this
   issue's approach. This would mean building and maintaining two separate
   engines for the same job, which is real ongoing cost the project should
   only take on deliberately, not by default.

This document does not pick between (1) and (2) — that is exactly the kind
of decision `AGENTS.md`'s Agent Autonomy rule reserves for the maintainer
(real product/scope tradeoff, not a fact determinable from code alone).
Whichever way it resolves, neither issue should be closed until that
decision is made and reflected in both issues.

## Open decisions for the maintainer

1. **Credential strategy**: dedicated/throwaway Steam account for prefill
   vs. the owner's main account; where credentials are stored (env var /
   secret file, never committed). Real consequences (account, blast radius
   if the prefill host is compromised) — not decided here.
2. **In-repo vs. separate binary/repo**: package as a new Rust binary in
   its own crate under this repo (following the `tools/build-tools`
   convention), or as a standalone companion tool in a separate repo.
3. **#871 reconciliation** (see above): supersede, adopt partial ideas from
   #871's UI/tracking scope, or maintain both engines.

## Proposed ordered plan (pending the decisions above)

1. Confirm credential strategy (decision 1).
2. Prototype control-plane login with `steam-vent` against a free app
   (e.g. Spacewar, AppID 480) using anonymous logon, to validate the login
   → license → manifest-request flow end-to-end before touching real
   games.
3. Add depot/manifest parsing (via `steamroom`'s lower-level APIs, pinned
   version, or a minimal reimplementation if it proves too unstable) to
   enumerate chunk hashes for a given AppID/depot.
4. Implement the data-plane fetch: plain `reqwest` GET per chunk URL, body
   streamed via `bytes_stream()`/`tokio::io::copy(..., tokio::io::sink())`,
   never written to a file. Verify end-to-end against a running dev
   `docker compose` stack in **standard mode**: first request MISS through
   lancache, second identical request HIT — confirming the proxy (not the
   prefill tool) holds the cached bytes.
5. Extend to real-account login once decision 1 is made, plus a
   configurable list of AppIDs to prefill.
6. Package per decision 2.
7. Document operator usage: point the prefill host's DNS at the
   standard-mode IP, no CA cert install required, expected AppID config
   format. No DNS changes are needed for the `lancache.steamcontent.com`
   sentinel (see above).
8. Future/stretch, not v0.3.0 scope: generalize the "data-plane
   discard-download" core so it's CDN-agnostic, following the precedent
   that `tpill90` built near-identical sibling tools for Epic and
   Battle.net.

## Requirement compliance recap

This design satisfies the no-disk-write requirement by construction: the
only place bytes are read is the data-plane HTTP GET (step 4 above), and
that path is explicitly a streamed drain to a sink, never a file write. The
Steam-protocol crates are scoped to control-plane/manifest metadata only
(small JSON/binary structures, not depot content), so even their own
internal behavior never touches the multi-GB depot payloads.
