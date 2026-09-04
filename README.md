# RaspHotspot – SonoBus-Basisstation auf dem Raspberry Pi

Macht aus einem Raspberry Pi eine autarke Audio-Basisstation:

1. Der Pi spannt ein **offenes WLAN ohne Passwort** auf (Standard-SSID: `ArizonaArizona`).
2. Auf dem Pi läuft der **AOO-Verbindungsserver** (`aooserver`) – das Gegenstück zu
   `aoo.sonobus.net`, nur lokal. Dadurch funktioniert alles **ohne Internet**.
3. **SonoBus läuft headless** auf dem Pi, nimmt das Audio des per USB
   angeschlossenen **Sound Devices MixPre-10T** entgegen und sendet es in die
   Gruppe **`ArizonaArizona`** – auf kürzeste Latenz getrimmt.
4. Wer sich ins WLAN einbucht, bekommt **automatisch eine Anleitungsseite** aufs
   Display (wie im Hotel-WLAN) mit App-Links und den Verbindungsdaten.
5. Alles Einstellbare – WLAN-Name, WLAN-Passwort, Gruppe, Latenz – lässt sich
   im Browser unter `http://10.42.0.1/admin` ändern, ohne SSH.

Alles startet von selbst, sobald der Pi Strom bekommt.

```
   MixPre-10T ──USB──> Raspberry Pi ──WLAN (offen)──> Handys / Laptops
                        ├── aooserver          (Gruppenserver, Port 10998)
                        ├── sonobus --headless (Sender in Gruppe "ArizonaArizona")
                        ├── Begrüßungsseite    (Anleitung auf http://10.42.0.1)
                        └── Einstellungsseite  (http://10.42.0.1/admin)
```

---

## Was du brauchst

| | |
|---|---|
| Raspberry Pi | 4 oder 5 empfohlen. Ein Pi 3B geht auch – siehe [Pi 3B](#hinweise-zum-pi-3b) |
| Betriebssystem | Raspberry Pi OS **Bookworm** (Lite reicht), 64-bit empfohlen |
| Audio | Sound Devices MixPre-10T (oder ein anderes USB-Audio-Interface) |
| Karte | ≥ 16 GB (der Build braucht Platz für Quellen und Auslagerungsdatei) |
| Strom | Ordentliches Netzteil – USB-Audio zieht mit |
| Zeit | SonoBus bauen: Pi 5 ~20 min, Pi 4 ~30–60 min, Pi 3B mehrere Stunden |

Für die Installation braucht der Pi **einmalig Internet** (LAN-Kabel oder WLAN),
um die Quellen zu laden und zu bauen. Danach läuft alles offline.

---

## Installation

```bash
# auf dem Pi, mit Internetverbindung:
sudo apt update && sudo apt install -y git
git clone https://github.com/tobibac/RaspHotspot.git
cd RaspHotspot
sudo ./install.sh
```

Das Skript erledigt der Reihe nach:

1. Pakete installieren (Compiler, ALSA, X11-Bibliotheken, ggf. hostapd/dnsmasq)
2. Dienstbenutzer `sonobus` und Verzeichnisse anlegen
3. Konfiguration nach `/etc/rasphotspot/rasphotspot.conf` schreiben
4. Hilfsskripte und Begrüßungsseite nach `/usr/local` installieren
5. SonoBus aus der offiziellen Paketquelle `pkg.sonobus.net` installieren
   (dort gibt es ARM-Pakete) und den kleinen `aooserver` selbst bauen.
   Klappt die Paketquelle nicht, baut das Skript SonoBus aus den Quellen –
   dann dauert es deutlich länger.
6. systemd-Dienste einrichten und für den Autostart aktivieren
   (`aooserver`, `sonobus-sender`, `rasphotspot-portal`)
7. Den offenen Hotspot samt Begrüßungsseite einrichten
8. Alles starten

Danach einmal neu starten:

```bash
sudo reboot
```

Kontrolle:

```bash
rasphotspot-status
```

### Nützliche Optionen

```bash
sudo ./install.sh --group MeineGruppe --ssid MeinWLAN   # andere Namen
sudo ./install.sh --build-sonobus                       # SonoBus selbst bauen
sudo ./install.sh --skip-build                          # nur neu konfigurieren
sudo ./install.sh --force-build                         # Binaries neu bauen
sudo ./install.sh --skip-hotspot                        # WLAN unangetastet lassen
sudo ./install.sh --reset-config                        # Konfiguration neu anlegen
```

### Woher SonoBus kommt

Standardmäßig aus der Paketquelle von sonobus.net – das ist der offiziell
unterstützte Weg und dauert Sekunden statt Stunden:

```
deb http://pkg.sonobus.net/apt stable main
```

Der Installer trägt sie ein, holt den Signaturschlüssel und installiert
`sonobus`. Gibt es dort kein Paket für die Architektur des Pi
(`dpkg --print-architecture`), fällt er automatisch auf den Selbstbau zurück.
Erzwingen lässt sich beides:

```bash
sudo ./install.sh --build-sonobus              # unbedingt selbst bauen
sudo ./install.sh --sonobus-deb ./sonobus.deb  # bestimmtes Paket nehmen
```

`aooserver` gibt es nirgends fertig, der wird immer gebaut – er ist klein und
in wenigen Minuten durch. Gefunden werden beide später über den `PATH`, egal ob
sie in `/usr/bin` (Paket) oder `/usr/local/bin` (Selbstbau) liegen.

---

## Hinweise zum Pi 3B

Ein Pi 3B reicht für den Betrieb, hat aber drei Eigenheiten:

**Nimm das fertige Paket.** Der Selbstbau von SonoBus dauert auf einem 3B
mehrere Stunden: 1 GB RAM, und JUCE braucht beim Übersetzen einzelner Dateien
über ein Gigabyte. Der Installer nimmt deshalb von sich aus die Paketquelle von
sonobus.net. Muss doch gebaut werden, legt er automatisch eine
Auslagerungsdatei an (und entfernt sie hinterher) und baut mit einem Job –
das läuft dann am besten über Nacht.

**Nur 2,4 GHz.** Das WLAN-Modul des 3B kann kein 5 GHz (erst der 3B+ kann das).
Die Installation merkt das selbst und schaltet auf 2,4 GHz um – in der Ausgabe
steht dann „5-GHz-Kanal 36 nicht nutzbar". Nichts zu tun, aber es heißt: weniger
Bandbreite und mehr Störungen durch Nachbar-WLANs.

**Zuhörerzahl im Blick behalten.** SonoBus schickt jedem Teilnehmer seinen
eigenen Datenstrom. Unkomprimiert (`pcm16`) sind das rund 1,5 Mbit/s pro
Zuhörer – auf 2,4 GHz sind damit etwa eine Handvoll Geräte realistisch. Wenn es
mehr werden sollen oder es hakt:

```ini
SB_SEND_FORMAT="opus96"     # ~0,2 Mbit/s pro Zuhörer, kostet ~2,5 ms
```

danach `sudo systemctl restart sonobus-sender`. Der Unterschied in der Latenz
ist klein, der in der Funklast riesig.

---

## Am MixPre-10T einstellen

1. **Menu → System → USB → USB Audio** (bzw. „Audio Interface") aktivieren.
   Das MixPre meldet sich dann als USB-Audio-Gerät mit 12 Ein- und 4 Ausgängen an.
2. Samplerate auf **48 kHz** stellen (Menu → Record → Sample Rate).
3. USB-C an den Pi (am besten an einen USB-3-Port, blau).

Über USB liefert das MixPre die **Stereo-Mischung auf Kanal 1+2** und darunter
die ISO-Spuren ab Kanal 3. Standardmäßig sendet der Pi genau diese Stereo-Mischung.

Möchtest du stattdessen z. B. die ISO-Spuren 3+4 senden, in
`/etc/rasphotspot/rasphotspot.conf`:

```ini
SB_INPUT_FIRST_CHANNEL="3"
SB_INPUT_CHANNELS="2"
```

und danach `sudo systemctl restart sonobus-sender`.

---

## So verbinden sich die Zuhörer

1. Mit dem offenen WLAN **`ArizonaArizona`** verbinden – kein Passwort.
   Auf den meisten Geräten **öffnet sich die Anleitungsseite von selbst**
   (bei iPhones sofort, bei Android als Benachrichtigung „Anmelden"). Sonst im
   Browser `http://10.42.0.1` aufrufen.
2. Die Seite führt durch beides: App installieren und verbinden.
3. Im Verbindungsfenster **nicht** den voreingestellten Server
   `aoo.sonobus.net` lassen, sondern eintragen:

   | Feld | Wert |
   |---|---|
   | Verbindungsserver | `10.42.0.1` |
   | Port | `10998` |
   | Gruppe | `ArizonaArizona` |
   | Passwort | *(leer)* |

4. Gruppe betreten – der Pi ist als **`MixPre-10T`** schon drin.

Schneller geht es über den Link. Die Anleitungsseite hat dafür einen Knopf
„Verbindungslink kopieren":

```
sonobus://10.42.0.1:10998/?g=ArizonaArizona
```

SonoBus schaut beim Start in die Zwischenablage: liegt so ein Link dort, füllt
die App die Gruppendaten selbst aus – man muss nur noch auf *Verbinden* tippen.
Das ist der zuverlässigste Weg, weil die Android-App das `sonobus://`-Schema
nicht direkt registriert; auf iPhone, Mac und PC funktioniert auch der direkte
Klick auf den Link.

Die fertigen Anschlussinfos stehen nach der Installation auch auf dem Pi:
`/etc/rasphotspot/connect-info.txt`

> **Warum ein eigener Server?** Der Hotspot hat kein Internet. SonoBus überträgt
> das Audio zwar direkt zwischen den Geräten, aber ein Verbindungsserver muss die
> Teilnehmer einer Gruppe zusammenbringen. Deshalb läuft `aooserver` lokal auf
> dem Pi.

> **Kein Internet trotz WLAN?** Genau so ist es gedacht: Der Pi verteilt per
> DHCP absichtlich **kein** Standard-Gateway und keinen DNS-Server, damit Handys
> parallel ihre Mobilfunkverbindung behalten. Wer das anders will, setzt
> `AP_OFFER_GATEWAY="yes"`.

---

---

## Die Begrüßungsseite

Bucht sich ein Gerät ins WLAN ein, prüft es automatisch, ob es Internet hat –
iPhones fragen `captive.apple.com`, Android `connectivitycheck.gstatic.com`,
Windows `msftconnecttest.com`. Der dnsmasq des Hotspots beantwortet **alle**
Namen mit der Adresse des Pi, und der kleine Webserver auf dem Pi liefert statt
der erwarteten Erfolgsmeldung die Anleitungsseite. Genau daran erkennen die
Geräte ein „Anmelde-WLAN" und zeigen die Seite von selbst an.

Die Seite erklärt in zwei Schritten:

1. **App installieren** – mit Links zu Play Store, App Store und sonobus.net
   und dem deutlichen Hinweis, dass man dafür das WLAN kurz verlassen muss
   (mobile Daten oder anderes WLAN), weil dieser Hotspot kein Internet hat.
2. **Verbinden** – Knopf „Verbindungslink kopieren", dazu Server, Port und
   Gruppe zum Abtippen und ein paar Tipps (Kopfhörer, eigenes Mikro stumm).

Anpassen lässt sich das über `PORTAL_TITLE` und `PORTAL_NOTE`
(z. B. `PORTAL_NOTE="Heute: Soundcheck ab 18 Uhr"`); die Seite selbst liegt
als `/usr/local/share/rasphotspot/portal.html` und ist eine ganz normale
HTML-Datei. Nach Änderungen:

```bash
sudo systemctl reload rasphotspot-portal    # Texte neu einlesen
```

Ganz abschalten: `PORTAL_ENABLE="no"` setzen und `sudo ./install.sh --skip-build`
laufen lassen.

> Das Begrüßungsfenster braucht `AP_OFFER_GATEWAY="yes"`, denn nur dann fragen
> die Geräte den Pi überhaupt nach ihren Verbindungstests. Nebeneffekt: Android
> meldet „WLAN ohne Internet" – die mobile Datenverbindung bleibt aber aktiv,
> Apps nutzen weiter LTE.

---

## Latenz

Voreingestellt ist der kürzeste Weg, Tonqualität ist dabei zweitrangig:

| Stellschraube | Wert | Warum |
|---|---|---|
| `SB_BUFFER_SIZE` | `128` | Audiopuffer, bei 48 kHz rund **2,7 ms** je Richtung |
| `SB_SEND_FORMAT` | `pcm16` | unkomprimiert – **kein Codec rechnet**, also keine Encoder-Verzögerung. Opus würde je nach Bitrate 2,5–20 ms zusätzlich kosten (1,5 Mbit/s statt ~200 kbit/s sind im lokalen WLAN kein Problem) |
| `SB_JITTER_MS` | `5` | Startwert des Jitterpuffers |
| `SB_JITTER_MODE` | `auto-full` | wächst bei Aussetzern, **schrumpft auch wieder** – die Verbindung pendelt sich auf den kürzesten stabilen Wert ein |
| `AP_BAND` | `a` (5 GHz) | mehr Bandbreite, weniger Störungen als 2,4 GHz |

Noch kürzer geht `SB_BUFFER_SIZE="64"` (1,3 ms). Wenn es knackst, ist der Weg
zurück `128` → `256`. Bei Funkproblemen hilft eher näher rangehen als ein
größerer Puffer.

Diese Werte schreibt `rasphotspot-audio-setup` bei jedem Start in die
SonoBus-Einstellungen (`defsendqual`, `defnetbuf`, `defnetauto`).
**Wichtig:** Den Jitterpuffer auf der Empfangsseite bestimmt jedes Gerät selbst.
Wer dort auf Nummer sicher gehen will, stellt in SonoBus beim Teilnehmer
*MixPre-10T* den Puffer ebenfalls auf *Auto*.

---

## Autostart

Nach der Installation braucht der Pi weder Bildschirm noch Anmeldung: Strom
dran, ~30 Sekunden warten, fertig. Dafür sorgen

* `aooserver.service`, `sonobus-sender.service` und `rasphotspot-portal.service`
  – alle mit `systemctl enable` für den Boot aktiviert, alle mit
  `Restart=always` und ohne Neustart-Bremse (`StartLimitIntervalSec=0`), sodass
  sie sich auch nach wiederholten Fehlern immer wieder selbst starten;
* der Hotspot – als NetworkManager-Profil mit `autoconnect yes`
  bzw. über die aktivierten Dienste `hostapd` und `dnsmasq`;
* eine udev-Regel, die den Sender neu startet, sobald das MixPre eingeschaltet
  bzw. eingesteckt wird – die Reihenfolge beim Einschalten ist also egal;
* `rasphotspot-sonobus-run`, das beim Start bis zu zwei Minuten auf
  Audiointerface und Verbindungsserver wartet, statt aufzugeben.

Prüfen lässt sich das mit einem Neustart:

```bash
sudo reboot
# nach dem Hochfahren:
rasphotspot-status
```

> Zieh den Stecker möglichst nicht mitten im Betrieb – wie bei jedem
> Linux-Rechner kann das auf Dauer die SD-Karte beschädigen. Für den
> Dauereinsatz lohnt sich ein `sudo raspi-config` → *Performance* → Overlay-FS,
> dann ist das Dateisystem schreibgeschützt und Stromausfälle sind egal.

---

## Einstellungen im Browser

Unter **`http://10.42.0.1/admin`** liegt eine Seite, auf der sich alles ändern
lässt, ohne sich per SSH anzumelden:

* **WLAN** – Name, Passwort (leer = offen, sonst WPA2), Funkland, Band, Kanal,
  Adresse des Pi
* **SonoBus-Gruppe** – Gruppenname, Gruppenpasswort, Anzeigename, Serverport
* **Ton und Latenz** – Sendeformat, Audiopuffer, Samplerate, Jitterpuffer,
  Eingangskanäle, Rückweg, Audiogerät
* **Begrüßungsseite** – an/aus, Überschrift, Zusatzhinweis

Angemeldet wird sich mit dem Benutzer `admin` und dem Passwort, das die
Installation einmalig auswürfelt und am Ende anzeigt. Neu setzen:

```bash
sudo rasphotspot-admin-password           # fragt nach einem eigenen Passwort
sudo rasphotspot-admin-password --random  # würfelt eins und zeigt es an
```

Nach dem Speichern startet der Pi genau das neu, was von der Änderung betroffen
ist: bei Tonänderungen die SonoBus-Dienste, bei Netzwerkänderungen den Hotspot.
**Änderst du WLAN-Name oder -Passwort, fliegst du dabei selbst aus dem Netz** –
das ist normal, einfach neu verbinden.

### Wie das abgesichert ist

Der Webserver läuft als unprivilegierter Dienst und darf die Konfiguration
**nicht** selbst schreiben. Er legt Änderungen nur als Vorschlag unter
`/var/lib/rasphotspot/staged.json` ab. Eine systemd-Path-Unit bemerkt die Datei
und startet `rasphotspot-apply` als root – und das prüft **jeden Wert noch
einmal komplett neu**, bevor irgendetwas geschrieben wird.

Diese doppelte Prüfung ist kein Selbstzweck: Die Konfigurationsdatei wird von
Root-Skripten mit `source` eingelesen und von systemd als `EnvironmentFile`
benutzt. Ein Wert mit Anführungszeichen oder `$` darin wäre damit
Befehlsausführung als root. Deshalb kommen nur Werte durch, die einem engen
Muster entsprechen, und nur Schlüssel aus einer festen Liste – ein per Formular
untergeschobenes `SERVICE_USER=root` landet wortlos im Papierkorb.

> Trotzdem: In einem **offenen** WLAN kann jeder in Funkreichweite die
> Anmeldeseite erreichen, und HTTP-Basic-Auth überträgt das Passwort
> ungeschützt. Wenn dir das zu locker ist, vergib ein WLAN-Passwort (dann ist
> der Funkverkehr verschlüsselt) oder schalte die Seite mit
> `ADMIN_ENABLE="no"` ganz ab.

---

## Konfiguration

Alle Einstellungen stehen in **`/etc/rasphotspot/rasphotspot.conf`**
(Vorlage mit Kommentaren: `config.env.example`). Nach Änderungen:

```bash
sudo systemctl restart aooserver sonobus-sender   # Gruppe/Audio übernehmen
sudo rasphotspot-audio-setup                      # nur das Audiogerät neu schreiben
sudo ./scripts/setup-hotspot.sh                   # WLAN neu einrichten
```

Die wichtigsten Schrauben:

| Schlüssel | Bedeutung | Standard |
|---|---|---|
| `AP_SSID` | Name des WLANs | `ArizonaArizona` |
| `AP_PASSWORD` | WLAN-Passwort; leer = offenes Netz, sonst WPA2 | *(leer)* |
| `AP_BAND` / `AP_CHANNEL` | `a` = 5 GHz (empfohlen), `bg` = 2.4 GHz | `a` / `36` |
| `AP_COUNTRY` | Funkland – ohne das sind 5-GHz-Kanäle gesperrt | `DE` |
| `AP_IP` | Adresse des Pi im Hotspot-Netz | `10.42.0.1` |
| `AP_OFFER_GATEWAY` | Pi als Gateway/DNS anbieten | `no` |
| `SB_GROUP` | SonoBus-Gruppe | `ArizonaArizona` |
| `SB_GROUP_PASSWORD` | optionales Gruppenpasswort | *(leer)* |
| `SB_USERNAME` | Anzeigename des Pi in der Gruppe | `MixPre-10T` |
| `SB_SERVER_PORT` | Port des Verbindungsservers (TCP+UDP) | `10998` |
| `SB_SAMPLE_RATE` / `SB_BUFFER_SIZE` | Audioformat | `48000` / `256` |
| `SB_INPUT_FIRST_CHANNEL` / `SB_INPUT_CHANNELS` | welche MixPre-Kanäle gesendet werden | `1` / `2` |
| `SB_ENABLE_OUTPUT` | Rückweg auf die USB-Returns des MixPre | `yes` |
| `AUDIO_CARD_MATCH` | Suchmuster für die Soundkarte | `MixPre` |
| `AUDIO_PCM_TYPE` | `hw` (direkt) oder `plug` (mit Umwandlung) | `hw` |
| `SB_SEND_FORMAT` | Sendeformat, `pcm16` = niedrigste Latenz | `pcm16` |
| `SB_JITTER_MS` / `SB_JITTER_MODE` | Start und Regelung des Jitterpuffers | `5` / `auto-full` |
| `PORTAL_ENABLE` | Begrüßungsseite beim Einbuchen | `yes` |
| `PORTAL_TITLE` / `PORTAL_NOTE` | Überschrift und Zusatzhinweis auf der Seite | `Live-Ton` / – |
| `ADMIN_ENABLE` / `ADMIN_USER` | Einstellungsseite und ihr Benutzername | `yes` / `admin` |

5 GHz ist für mehrere Zuhörer klar besser (mehr Bandbreite, weniger Störungen),
2.4 GHz hat mehr Reichweite. Kann der Pi den gewünschten 5-GHz-Kanal nicht als
Access Point nutzen, schaltet die Installation automatisch auf 2.4 GHz um.

---

## Wenn etwas nicht läuft

```bash
rasphotspot-status                    # Übersicht: WLAN, Audio, Dienste
journalctl -u sonobus-sender -f       # Sender live mitlesen
journalctl -u aooserver -f            # Verbindungsserver live mitlesen
```

**Das MixPre wird nicht gefunden**

```bash
cat /proc/asound/cards                # taucht es hier auf?
arecord -l
```
Wenn nicht: am MixPre USB-Audio aktivieren, anderes Kabel/Port probieren. Sobald
es eingeschaltet wird, startet der Sender per udev-Regel automatisch neu.
Heißt die Karte anders, `AUDIO_CARD_MATCH` anpassen.

**Der Sender startet nicht / stürzt ab**

Bei X11-Fehlern in den Logs in der Konfiguration `SB_USE_XVFB="yes"` setzen und
`sudo systemctl restart sonobus-sender` – dann läuft SonoBus hinter einem
virtuellen Framebuffer.

Bei Fehlern beim Öffnen des Audiogeräts `AUDIO_PCM_TYPE="plug"` setzen: dann
übernimmt ALSA Format- und Ratenumwandlung (dafür sind nur die ersten Kanäle
erreichbar).

**Aussetzer / Knacksen**

`SB_BUFFER_SIZE` von `128` auf `256` erhöhen, auf 5 GHz wechseln, den Abstand
verringern und in SonoBus auf den Client-Geräten den Jitterpuffer auf „Auto"
lassen. Hilft das nicht, `SB_SEND_FORMAT="opus96"` probieren – das braucht
deutlich weniger Funkbandbreite und kostet nur wenige Millisekunden.

**Die Begrüßungsseite erscheint nicht von selbst**

```bash
systemctl status rasphotspot-portal
curl -I http://10.42.0.1/          # vom Pi aus
```
Die Seite ist immer unter `http://10.42.0.1` erreichbar – auch wenn das
automatische Aufpoppen ausbleibt. Voraussetzung fürs Aufpoppen ist
`AP_OFFER_GATEWAY="yes"` und ein dnsmasq, der alle Namen auf den Pi auflöst
(`address=/#/10.42.0.1`). Auf Systemen mit NetworkManager steht das in
`/etc/NetworkManager/dnsmasq-shared.d/rasphotspot.conf`, sonst in
`/etc/dnsmasq.d/rasphotspot.conf`. Manche Android-Versionen zeigen statt der
Seite nur eine Benachrichtigung – die muss man einmal antippen.

**Passwort für die Einstellungsseite vergessen**

```bash
sudo rasphotspot-admin-password --random    # neues würfeln und anzeigen
```

**Gespeicherte Änderungen werden nicht übernommen**

```bash
systemctl status rasphotspot-apply.path     # muss aktiv sein
journalctl -u rasphotspot-apply -n 30       # was beim Übernehmen passiert ist
```
Die Path-Unit ist die Schleuse zwischen Webseite und System. Ist sie inaktiv,
bleibt der Vorschlag in `/var/lib/rasphotspot/staged.json` liegen. Anwerfen mit
`sudo systemctl enable --now rasphotspot-apply.path`.

**Der Knopf „Verbindungslink kopieren" tut nichts**

Captive-Portal-Browser sind eingeschränkt. Dann die Seite in Safari/Chrome unter
`http://10.42.0.1` öffnen oder Server, Port und Gruppe von Hand eintippen –
beides steht auf der Seite.

**Kein WLAN sichtbar**

```bash
sudo iw reg get                       # Funkland gesetzt?
nmcli connection show                 # Profil "rasphotspot" vorhanden/aktiv?
sudo systemctl status hostapd         # (auf Systemen ohne NetworkManager)
```
Auf 5 GHz muss das Funkland stimmen (`AP_COUNTRY`), sonst sind die Kanäle
gesperrt.

**Bauen schlägt fehl: `jack/jack.h` fehlt**

SonoBus wird mit `JUCE_JACK=1` gebaut und braucht die JACK-Header:

```bash
sudo apt install libjack-jackd2-dev
```

Auf Desktop-Images kann apt dabei `pipewire-jack` ersetzen wollen. Auf einem
Lite-Image (Empfehlung für diese Basisstation) ist das kein Thema.

**Bauen bricht ab mit `Killed signal terminated program cc1plus`**

Das ist der Kernel, der dem Compiler den Speicher entzieht. Auslöser ist
JUCEs Hilfsprogramm `juceaide`: JUCE baut es fest als Debug-Version, und die
Sammeldatei `juce_gui_basics.cpp` braucht dabei über ein Gigabyte.

Der Installer legt inzwischen selbst eine Auslagerungsdatei an
(`/var/cache/rasphotspot-build-swap`), bis RAM + Swap zusammen 4 GB ergeben,
und räumt sie nach dem Build wieder weg. Einfach nochmal starten:

```bash
sudo ./install.sh
```

Meldet er zu wenig Plattenplatz, entweder aufräumen (`sudo apt clean`) oder den
Swap dauerhaft vergrößern:

```bash
sudo dphys-swapfile swapoff
sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
sudo dphys-swapfile setup && sudo dphys-swapfile swapon
```

Wer nicht warten will, nimmt das fertige Paket:
`sudo ./install.sh --sonobus-deb <URL oder Datei>`.

---

## Was wo liegt

| Pfad | Inhalt |
|---|---|
| `/etc/rasphotspot/rasphotspot.conf` | die eine Konfigurationsdatei |
| `/etc/rasphotspot/connect-info.txt` | Anschlussinfos für die Zuhörer |
| `/etc/asound.conf` | erzeugte ALSA-Gerätenamen (`rasphotspot_in/out`) |
| `/var/lib/sonobus/.config/sonobus/SonoBus.settings` | erzeugte SonoBus-Audioeinstellungen |
| `/usr/local/bin/aooserver`, `/usr/local/bin/sonobus` | gebaute Programme |
| `/usr/local/bin/rasphotspot-*` | Hilfsskripte (Status, Audio-Setup, Starter, Portal) |
| `/usr/local/share/rasphotspot/portal.html` | die Begrüßungsseite |
| `/usr/local/share/rasphotspot/admin.html` | die Einstellungsseite |
| `/etc/rasphotspot/admin.secret` | Passwort-Hash der Einstellungsseite |
| `/var/lib/rasphotspot/staged.json` | Vorschlag aus dem Formular, wird sofort abgeholt |
| `/usr/local/src/rasphotspot/` | Quellen für spätere Neubauten |
| `/var/cache/rasphotspot-build-swap` | Auslagerungsdatei, nur während des Builds |
| `/var/log/rasphotspot/` | Logdateien des Verbindungsservers |

### Die Dienste

* **`aooserver.service`** – startet `aooserver --port=10998`, unabhängig vom Audio.
* **`rasphotspot-portal.service`** – Begrüßungs- und Einstellungsseite auf Port 80.
* **`rasphotspot-apply.path` / `.service`** – die Schleuse, die Änderungen aus
  dem Formular als root prüft und übernimmt.
* **`sonobus-sender.service`** – erkennt vor jedem Start das Audiointerface neu
  (`rasphotspot-audio-setup`), wartet auf Interface und Serverport und startet
  dann `sonobus --headless --group=ArizonaArizona --connectionserver=127.0.0.1:10998`.
  Beide starten bei Fehlern automatisch neu.

---

## Deinstallation

```bash
sudo ./uninstall.sh
```

Entfernt Dienste, Skripte, Konfiguration, Hotspot-Einstellungen und den
Dienstbenutzer. Installierte apt-Pakete bleiben erhalten.

---

## Tests

Die Hilfsfunktionen haben eine Testsuite – sie braucht kein root und fasst das
System nicht an:

```bash
./tests/run-tests.sh        # alles: Bash-Helfer, Portal, Einstellungsseite
python3 tests/test_config.py # nur die Prüfregeln der Konfiguration
```

Geprüft werden unter anderem: Kartenerkennung, Kanalmasken, Verbindungslink,
das Format der Kommandozeilenoptionen (SonoBus nimmt nur `--option=wert`), die
Antworten der Begrüßungsseite auf die Verbindungstests von iOS/Android/Windows,
die Anmeldung an der Einstellungsseite und – am wichtigsten – dass sich über das
Formular keine Befehle in die Konfiguration schmuggeln lassen.

## Hinweise

* SonoBus überträgt **unverschlüsselt**, und das WLAN ist ab Werk **offen** –
  wer in Funkreichweite ist, kann mithören. Für vertrauliche Inhalte ein
  WLAN-Passwort vergeben (`AP_PASSWORD` oder gleich auf der Einstellungsseite,
  dann ist der Funkverkehr WPA2-verschlüsselt) und/oder ein Gruppenpasswort
  setzen (`SB_GROUP_PASSWORD`; die Begrüßungsseite zeigt es dann an – wer das
  nicht will, setzt zusätzlich `PORTAL_ENABLE="no"`).
* SonoBus (GPLv3) und aooserver stammen von Jesse Chappell / Sonosaurus, die
  AOO-Bibliothek von Christof Ressi. Dieses Projekt baut und konfiguriert diese
  Programme lediglich.
* Der Pi verbindet sich auf Systemen ohne NetworkManager nach der Installation
  nicht mehr selbst mit anderen WLANs (`wpa_supplicant` wird deaktiviert) –
  für die Fernwartung dann LAN-Kabel oder Bildschirm/Tastatur nutzen.
