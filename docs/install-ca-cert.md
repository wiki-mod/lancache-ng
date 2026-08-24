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

### Manual distribution

The admin serves the file ad hoc — but **never** point `python3 -m http.server`
at the `certs/` directory itself: it serves the entire current directory, and
`certs/` also holds `ca.key`, the private CA key. Copy just `ca.crt` into a
freshly created throwaway directory first, then serve *that*:

```bash
( serve_dir="$(mktemp -d)" && trap 'rm -rf "$serve_dir"' EXIT && cp /opt/lancache-ng/certs/ca.crt "$serve_dir/" && cd "$serve_dir" && python3 -m http.server 8000 )
# clients then browse to http://<lancache-lan-ip>:8000/ca.crt, then Ctrl-C when done --
# the throwaway directory is removed automatically, no separate cleanup step needed
```

Use `mktemp -d`, not a fixed path like `mkdir -p /tmp/lancache-ca-serve`: `mktemp
-d` only succeeds by creating a directory that did not exist a moment ago, so
there is no path for this command to silently follow a pre-existing directory
or symlink left at a predictable name — `mkdir -p` on an existing path is a
silent no-op, so a stale or planted path there would go unnoticed. The whole
command is wrapped in `( ... )` with a `trap ... EXIT` inside it, so the
throwaway directory is removed the moment the subshell exits — whether
`python3` is stopped with `Ctrl-C`, exits on its own, or the command fails
partway through — rather than depending on the admin remembering a separate
cleanup step. Because only `ca.crt` was copied in, `ca.key` is never inside
the directory being served — there is no window, however brief, in which it
is reachable.

The `trap` cannot run if the shell is killed outright (`kill -9`, an
out-of-memory kill, a host power loss) — this project supports too wide a
range of host operating systems (see `CONTRIBUTING.md`: "do not assume every
operator runs the same ... host OS") to promise any specific OS-level temp
cleanup will catch that case. The realistic worst case if it happens is a
leftover copy of the public `ca.crt` sitting under `/tmp` until it's removed
by hand or by whatever temp-cleaning policy (if any) the host itself runs —
not a secret, so this is a tidiness gap, not a security one.

or copies it off with `scp`:

```bash
scp user@<lancache-lan-ip>:/opt/lancache-ng/certs/ca.crt .
```

- **Pro:** zero code, works today.
- **Con:** manual and temporary; `python3` is not guaranteed on the host; `scp`
  still needs per-device handling. A stop-gap, not a real distribution path.
- **Warning:** while the one-liner's server is running, `http://<lancache-lan-ip>:8000/ca.crt`
  is reachable by any device on the LAN with no authentication. That is fine —
  `ca.crt` is public — but don't leave it running longer than needed; `Ctrl-C`
  it and remove the throwaway directory once every client device has fetched
  the file.

### Possible future convenience: "Download CA certificate" button in the Admin UI

Add a link/route in the Admin UI (which the operator already logs into) that
downloads `ca.crt`.

- **Pro:** smallest trust question — it only reaches operators who already pass
  the UI's auth gate.
- **Con:** it only helps the **operator's own** machine. It does **not** solve the
  "every device on the network" problem, because end-user client devices do not
  log into the Admin UI. Best treated as a convenience on top of manual distribution, not a
  replacement.

### Recommendation

Treat the **manual distribution** path above as the current documented solution.
An Admin-UI download is optional future convenience only. Separately, the
project still needs a safe documented workflow for issuing a **new** CA after
compromise, replacing the server-side CA files, and re-distributing that new
CA to clients.
