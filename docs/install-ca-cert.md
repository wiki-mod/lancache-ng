# CA-Zertifikat installieren

Der LAN-Cache bricht HTTPS-Verbindungen auf, um den Inhalt cachen zu können.
Dazu muss einmalig ein eigenes CA-Zertifikat auf jedem Gerät installiert werden.

Die Datei `ca.crt` liegt nach dem ersten Start im `certs/`-Verzeichnis des Projekts.

---

## Windows

1. `ca.crt` auf das Gerät kopieren (z.B. per USB oder Netzwerkfreigabe)
2. Doppelklick auf die Datei → „Zertifikat installieren"
3. „Lokaler Computer" → „Weiter"
4. „Zertifikate in folgendem Speicher ablegen" → „Durchsuchen"
5. „Vertrauenswürdige Stammzertifizierungsstellen" → OK → Weiter → Fertig stellen

---

## Linux (Ubuntu / Debian)

```bash
sudo cp ca.crt /usr/local/share/ca-certificates/lancache.crt
sudo update-ca-certificates
```

---

## macOS

1. `ca.crt` doppelklicken → Keychain Access öffnet sich automatisch
2. Zertifikat unter **System** (nicht „Anmeldung") ablegen
3. Im Keychain das Zertifikat suchen → Doppelklick
4. „Vertrauen" aufklappen → „Diese Zertifizierungsstelle immer als vertrauenswürdig einstufen"

---

## Firefox (alle Plattformen)

Firefox hat einen eigenen Zertifikatsspeicher und ignoriert den Systemspeicher:

1. Einstellungen → Datenschutz & Sicherheit → Zertifikate → Zertifikate anzeigen
2. Tab „Zertifizierungsstellen" → „Importieren"
3. `ca.crt` auswählen → „Dieser CA vertrauen, um Webseiten zu identifizieren" ✓

---

## Steam Deck (SteamOS)

Im Desktop-Modus:

```bash
sudo trust anchor --store ca.crt
```

---

## Konsolen (PS5, Xbox, Nintendo)

Konsolen erlauben keine eigenen CA-Zertifikate.
Der DNS-Server leitet ihre CDN-Verbindungen trotzdem zum Cache weiter,
aber der TLS-Handshake schlägt fehl — das Gerät fällt dann automatisch
auf eine direkte Verbindung zurück. Kein Caching, aber volle Funktionalität.
