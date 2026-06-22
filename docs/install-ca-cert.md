# Install CA Certificate

The LAN cache intercepts HTTPS connections to cache content.
A custom CA certificate must be installed once on each device.

The file `ca.crt` is located in the `certs/` directory of the project after the first start.

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

Consoles do not allow custom CA certificates.
The DNS server routes their CDN connections to the cache anyway,
but the TLS handshake fails — the device automatically falls back
to a direct connection. No caching, but full functionality.
