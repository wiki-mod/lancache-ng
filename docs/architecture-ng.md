# LanCache-NG Architecture

## Services

| Service | Default | Replaces | Notes |
|---|---|---|---|
| nginx (proxy) | on | — | Mainline von nginx.org, Debian 13 Base |
| BIND9 | on | dnsmasq | Chroot im Container |
| Kea DHCP | off | — | Benötigt BIND9 (DDNS) |
| Watchdog | on | — | Health-Checks, Auto-Restart, Purge-Cron |
| syslog-ng | on | — | Zentrales Logging aller Container |
| Admin UI | on | — | Axum/Rust, Tera, Tailwind, eigener Port |
| Cache Warmer | off | — | steamcmd, auf Anfrage startbar |

## nginx

Mainline von nginx.org (nicht Debian-Paket). Basis: `debian:13-slim`.

**Performance-Konfiguration:**

```nginx
worker_processes      auto;
worker_rlimit_nofile  65535;
thread_pool default   threads=32 max_queue=65536;

events {
    worker_connections  4096;
    use epoll;
    multi_accept on;
}

sendfile    on;
tcp_nopush  on;
tcp_nodelay on;
aio         threads=default;
directio    4m;
```

**Cache-Konfiguration (alle Werte als Env-Var + im Admin-UI konfigurierbar):**

| Variable | Default | Beschreibung |
|---|---|---|
| `CACHE_MAX_SIZE` | `500g` | Max. Cachegröße — UI prüft gegen verfügbaren Disk-Platz |
| `CACHE_MEM_MB` | `200` | keys_zone Größe (1MB ≈ 8.000 Keys) |
| `CACHE_SLICE_SIZE` | `8m` | Slice-Größe: `4m/8m/16m/32m/64m/128m/256m/512m` |
| `CACHE_VALID_HIT` | `365d` | Gültigkeitsdauer für 200/206/301/302 |
| `CACHE_VALID_ANY` | `1m` | Gültigkeitsdauer für alles andere |
| `CACHE_INACTIVE` | `365d` | Entfernen wenn X Tage nicht zugegriffen |

**Slice Module** (für Range Requests bei Game-Downloads):
```nginx
slice               $CACHE_SLICE_SIZE;
proxy_cache_key     "$host$uri$slice_range";
proxy_set_header    Range $slice_range;
proxy_cache_valid   206 $CACHE_VALID_HIT;
```

**Hinweis:** `max_size` ist kein hartes Limit — bei abgestürzten Workern kann der Cache drüber wachsen. Watchdog überwacht den echten Disk-Stand.

## BIND9

- Chroot unter `/var/lib/named` im Container
- RPZ ersetzt `cdn-domains.txt` / `cdn-ssl-domains.txt`
- IPv4 + IPv6 überall (dual-stack)

**Zonen:**

| Zone | Typ | Zweck |
|---|---|---|
| `lan` | primary | TLD für das LAN |
| `local.lan` | primary | LAN-Hosts (via Admin-UI verwaltbar) |
| `10.in-addr.arpa` | primary | Reverse 10/8 |
| `168.192.in-addr.arpa` | primary | Reverse 192.168/16 |
| `16–31.172.in-addr.arpa` | primary | Reverse 172.16/12 |
| `ip6.arpa` (ULA) | primary | IPv6 Reverse |

**Optionale Features (Env-Variablen):**

| Variable | Default | Bedeutung |
|---|---|---|
| `ENABLE_ROOT_MIRROR` | `false` | Root Zone Mirror (AXFR von Root-Servern) |
| `FILTER_AAAA_V4` | `false` | AAAA-Records für IPv4-Clients filtern |
| `FILTER_AAAA_V6` | `false` | AAAA-Records für IPv6-Clients filtern |
| `ENABLE_SECONDARY` | `false` | Secondary Zones aktivieren |
| `SECONDARY_MASTERS` | — | IP des Primary-DNS |
| `SECONDARY_ZONES` | — | Kommagetrennte Zonenliste |

**allow-query / allow-recursion:** offen für alle RFC-1918 + IPv6 ULA per Default

**nsupdate (RFC 2136):** TSIG-gesicherter Kanal für Admin-UI → BIND9

## Kea DHCP

- DHCPv4 + DHCPv6 (dual-stack)
- IP-Bereiche als Start–End (keine CIDR-Pflicht)
- Feste Zuweisungen: MAC → IP, editierbar über UI
- DDNS → BIND9: Lease = automatisch A + PTR in `local.lan`
- REST API (Kea Control Agent) für Admin-UI

## Watchdog

Eigener leichtgewichtiger Container mit Docker-Socket-Zugriff (restart-Berechtigung).

**Health-Checks:**
- nginx: HTTP-Request auf `/health`
- BIND9: DNS-Query-Test
- Kea: REST API Ping
- syslog-ng: Prozess-Check

**Auto-Restart:** X fehlgeschlagene Checks → `docker restart <container>`

**Scheduled Purge (Cron, täglich):**
- Entfernt Cache-Einträge älter als `CACHE_VALID_HIT` (`find -mtime`)
- Ergänzt nginx `inactive` (die nach Zugriffszeit arbeitet)

**Disk-Monitoring:**
- Warnung im UI bei 85% Füllstand (gelb)
- Alarm bei 95% (rot)
- Prüft echten Disk-Stand, nicht nur nginx `max_size`

**Status:** wird als Ampelleiste im Admin-UI angezeigt (grün/gelb/rot pro Service)

## syslog-ng

Zentrales Logging aller Container. Alle Services senden an syslog-ng.

- Speicher selbstverwaltend: max. Dateigröße + automatische Rotation
- Retention konfigurierbar (Default: 30 Tage)
- **Log-Level pro Service im Admin-UI konfigurierbar:**

| Service | Level-Optionen |
|---|---|
| nginx | `emerg / error / warn / info / debug` |
| BIND9 | `critical / error / warning / notice / info / dynamic` |
| Kea | `fatal / error / warn / info / debug` |
| Watchdog | `error / info / debug` |

- **Weiterleitung:** Ziel-IP + Port + Protokoll (UDP/TCP/TLS, RFC 5424 oder 3164) im Admin-UI konfigurierbar
- Änderung im UI → schreibt Konfig → `syslog-ng-ctl reload`

## Cache Warming

Eigener Container (`services/warmer`) mit `steamcmd`.

**Ablauf:**
1. User gibt Steam App-ID ein
2. `steamcmd` holt Depot-Manifest (anonym für F2P, optional mit Account für Paid Games)
3. Chunk-URLs werden über den lokalen Proxy gefetcht → landen im Cache
4. Fortschritt live im Admin-UI (Chunks gesamt / erledigt / MB/s)

**Steam Account:** optional per Env-Var (`STEAM_USER`, `STEAM_PASS`) — nie im Repo, nie im Image.

**Tracking:** welche App-IDs wurden gewärmt + welche CDN-URLs gehören dazu → Basis für gezieltes Purging.

Epic / GOG: nicht unterstützt.

## Cache Retention & Bereinigung

**Drei Mechanismen zusammen:**

| Mechanismus | Trigger | Grundlage |
|---|---|---|
| nginx `inactive` | automatisch, laufend | nicht zugegriffen seit `CACHE_INACTIVE` |
| Watchdog Purge-Cron | täglich automatisch | Datei älter als `CACHE_VALID_HIT` |
| Manuelles Purge | Admin-UI on-demand | frei wählbar |

**Manuelles Purging im Admin-UI:**

| Aktion | Granularität |
|---|---|
| Gesamten Cache leeren | Alles |
| Nach Alter bereinigen | Älter als X Tage — Vorschau "~X GB frei" vor Bestätigung |
| Nach Zugriff bereinigen | Nicht zugegriffen seit X Tagen |
| Einzelnen Titel löschen | Alle Chunks einer gewärmten App-ID |
| Pinning | App-ID vor LRU + automatischem Purge schützen |

**Größenvalidierung:** Admin-UI prüft verfügbaren Disk-Platz beim Speichern von `CACHE_MAX_SIZE`. Warnung > 90% des verfügbaren Platzes, Fehler bei Überschreitung.

## Monitoring (Admin-UI)

- Netdata integriert (Proxy via `/api/netdata`)
- Statistiken: CPU, RAM, Netzwerk MB/s (Echtzeit + Verlauf), Disk I/O
- Dashboard: Cache-Füllstand, Hit/Miss-Rate, aktive Verbindungen
- Watchdog-Ampelleiste: ein Indikator pro Service, persistent sichtbar

## Admin UI

Läuft auf eigenem Axum-Webserver (Port 8080) — unabhängig von nginx. Wenn nginx down ist, ist das UI noch erreichbar und zeigt den Fehler.

- Zwei Modi: **Anfänger** (geführt, kein Jargon) / **Experte** (technisch direkt)
- DNS: Zonen anlegen, Host-Einträge, PTR-Haken bei LAN-IPs
- Kea: Lease-Übersicht, feste Zuweisungen anlegen/editieren
- Cache: Warming starten, Fortschritt, Purging, Retention + Slice/Size-Einstellungen
- Logs: gefiltert nach Service, Level wählbar
- Erweiterte Optionen (Root Mirror, Filter AAAA, Secondary, syslog-Weiterleitung) unter "Erweitert"

## IPv6

- BIND9: dual-stack Listener, AAAA-Records, IPv6 Reverse Zonen
- Kea: DHCPv6 parallel zu DHCPv4
- nginx: bereits IPv6-fähig
- Docker: IPv6 auf Linux-Host via `"ipv6": true` in `daemon.json`

## Sicherheit

- Alle generierten Secrets (TSIG-Keys, Kea API Token) werden beim Container-Start auto-generiert, nie im Repo
- Docker-Socket im Watchdog: nur restart-Berechtigung, kein full admin
- Repo ist public: keine echten IPs, Passwörter oder Keys in Konfig-Dateien

## Implementierungsreihenfolge

1. nginx (Slice Module + Optimierungen)
2. BIND9
3. Kea DHCP
4. Watchdog
5. syslog-ng
6. Cache Warmer
7. Admin UI
