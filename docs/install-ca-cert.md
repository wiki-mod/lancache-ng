# Install CA Certificate

The LAN cache intercepts HTTPS connections to cache content.
A custom CA certificate must be installed once on each device.

The file `ca.crt` is located in the `certs/` directory of the project after the
first start (for a standard `/opt/lancache-ng` install:
`/opt/lancache-ng/certs/ca.crt`). See
[Getting the `ca.crt` onto client devices](#getting-the-cacrt-onto-client-devices)
for how to distribute it to every device without server access.

---

## Windows

1. Copy `ca.crt` to the device (e.g. via USB or network share)
2. Double-click the file → "Install certificate"
3. "Local machine" → "Next"
4. "Place all certificates in the following store" → "Browse"
5. "Trusted root certification authorities" → OK → Next → Finish

---

## Linux (Ubuntu / Debian)

```bash
sudo cp ca.crt /usr/local/share/ca-certificates/lancache.crt
sudo update-ca-certificates
```

---

## macOS

1. Double-click `ca.crt` → Keychain Access opens automatically
2. Place certificate under **System** (not "Login")
3. Find the certificate in Keychain → Double-click
4. Expand "Trust" → "Always trust this certificate authority"

---

## Firefox (all platforms)

Firefox has its own certificate store and ignores the system store:

1. Settings → Privacy & Security → Certificates → View certificates
2. "Authorities" tab → "Import"
3. Select `ca.crt` → "Trust this CA to identify websites" ✓

---

## Steam Deck (SteamOS)

In desktop mode:

```bash
sudo trust anchor --store ca.crt
```

---

## Consoles (PS5, Xbox, Nintendo)

Consoles (PS5, Xbox, Nintendo Switch) have no way to install a custom CA
certificate — the capability simply does not exist on those platforms. So they
can never trust the LAN cache's CA, and SSL-mode interception can never work for
them.

**You do not need to do anything, and you should not point consoles somewhere
else.** A console can keep using the LanCache NG DNS server exactly like any
other device, with no restriction. Here is the causal chain, so it is
unambiguous:

1. Because consoles cannot install the CA, their download CDN domains are
   **deliberately left out** of the DNS spoofing list (`cdn-domains.txt`).
2. Since those domains are not spoofed, the LanCache NG DNS server resolves them
   **normally, to the real CDN IPs** — the console's own DNS request is answered
   truthfully instead of being redirected to the proxy.
3. The console therefore connects **directly to the real CDN** and downloads work
   completely normally. There is no failed TLS handshake and nothing to break.

The only consequence is that console downloads are **not cached** (no bandwidth
savings for them). Everything else the console resolves through LanCache NG still
works, and any *other* (non-console) domains that *are* on the spoof list are
still cached as usual. In short: leave consoles pointed at the LanCache NG DNS —
they get full functionality, just without the caching benefit.

> If you run a LAN with **no** consoles and want to cache Xbox-on-PC (Game Pass
> for PC) downloads, you can opt in by adding the Xbox CDN domains manually — see
> the note at the bottom of `services/dns/cdn-domains.txt`. Do **not** do this if
> any real Xbox console shares the network, or that console's downloads will
> break.

---

## Getting the `ca.crt` onto client devices

`ca.crt` is a **public** certificate (only the matching `ca.key` is secret, and
that never leaves the server). For a standard production install under
`/opt/lancache-ng`, the file lives on the host at:

```
/opt/lancache-ng/certs/ca.crt
```

`setup.sh` prints this exact path after the first start. The open question this
section addresses is how to get that file onto **every** client device — phones,
laptops, Steam Decks — without SSH-ing into the server for each one.

> **Status: proposal pending maintainer decision.** The mechanisms below are
> options with trade-offs, not all implemented yet. The recommendation is Option
> A; the alternatives are listed so the trade-offs are explicit.

### Option A (recommended): serve `ca.crt` over plain HTTP from the proxy

Expose the certificate at a fixed, documented URL on the proxy's port 80, e.g.:

```
http://<lancache-lan-ip>/ca.crt
```

Any device on the LAN could then fetch and install it from a browser, with zero
server access. This is the only option that reaches arbitrary client devices
directly.

- **Why it is acceptable security-wise:** `ca.crt` is public by design — serving
  it leaks nothing (the secret is `ca.key`, which stays on the server with
  restrictive permissions). Anyone on the LAN can already read all cached
  content; trusting local devices is already the core assumption of this
  appliance (see `docs/threat-model.md`).
- **Trade-off to accept:** the endpoint is intentionally **not** behind the Admin
  UI's auth gate, so it is reachable by any LAN device. That is the point, but it
  should be a conscious decision.
- **Open implementation questions for the maintainer** (this is why it is a
  proposal, not yet shipped):
  - It needs a small `location = /ca.crt` block in `services/proxy/conf.d/http.conf`
    that serves the file from where it is mounted (`/etc/nginx/ssl/ca/ca.crt`),
    taking priority over the catch-all `location /` that proxies to origins.
  - **File readability must be verified first:** the entrypoint's `chmod 0644`
    loop targets the per-domain cert dir, not the CA dir, so the nginx worker's
    read access to `ca.crt` is not currently guaranteed and would need confirming.
  - Decide the response `Content-Type` (`application/x-x509-ca-cert` is widely
    accepted) and whether to gate the route on `SSL_ENABLED=1` (it is only
    meaningful in SSL mode).

### Option B (no code change): admin-run one-liner

The admin serves the file ad hoc from the install directory, e.g.:

```bash
cd /opt/lancache-ng/certs && python3 -m http.server 8000
# clients then browse to http://<lancache-lan-ip>:8000/ca.crt, then Ctrl-C when done
```

or copies it off with `scp`:

```bash
scp user@<lancache-lan-ip>:/opt/lancache-ng/certs/ca.crt .
```

- **Pro:** zero code, works today.
- **Con:** manual and temporary; `python3` is not guaranteed on the host; `scp`
  still needs per-device handling. A stop-gap, not a real distribution path.

### Option C (complementary): "Download CA certificate" button in the Admin UI

Add a link/route in the Admin UI (which the operator already logs into) that
downloads `ca.crt`.

- **Pro:** smallest trust question — it only reaches operators who already pass
  the UI's auth gate.
- **Con:** it only helps the **operator's own** machine. It does **not** solve the
  "every device on the network" problem, because end-user client devices do not
  log into the Admin UI. Best treated as a convenience on top of Option A, not a
  replacement.

### Recommendation

Ship **Option A** as the primary mechanism (it is the only one that reaches
arbitrary client devices unattended), optionally add **Option C** for operator
convenience, and document **Option B** as the immediate no-code workaround until
A lands. The maintainer may weigh the "unauthenticated LAN endpoint" trade-off
differently and prefer C-only or B-only; that decision is intentionally left
open here.
