# RaspHotspot – SonoBus-Basisstation auf dem Raspberry Pi

Macht aus einem Raspberry Pi eine autarke Audio-Basisstation:

1. Der Pi spannt ein **offenes WLAN ohne Passwort** auf (Standard-SSID: `ArizonaArizona`).
2. Auf dem Pi läuft der **AOO-Verbindungsserver** (`aooserver`) – das Gegenstück zu
   `aoo.sonobus.net`, nur lokal. Dadurch funktioniert alles **ohne Internet**.
3. **SonoBus läuft headless** auf dem Pi, nimmt das Audio des per USB
   angeschlossenen **Sound Devices MixPre-10T** entgegen und sendet es in die
   Gruppe **`ArizonaArizona`**.

Alle im WLAN eingebuchten Geräte starten einfach SonoBus, tragen den Pi als
Verbindungsserver ein, betreten die Gruppe – und hören den MixPre.

```
   MixPre-10T ──USB──> Raspberry Pi ──WLAN (offen)──> Handys / Laptops
                        ├── aooserver        (Gruppenserver, Port 10998)
                        └── sonobus --headless (Sender in Gruppe "ArizonaArizona")
```

---

## Was du brauchst

| | |
|---|---|
| Raspberry Pi | 4 oder 5 empfohlen (2 GB RAM+). Pi 3B+ funktioniert, baut aber langsamer. |
| Betriebssystem | Raspberry Pi OS **Bookworm** (Lite reicht), 64-bit empfohlen |
| Audio | Sound Devices MixPre-10T (oder ein anderes USB-Audio-Interface) |
| Karte | ≥ 8 GB, Netzteil mit ordentlich Strom (USB-Audio zieht mit) |
| Zeit | Der SonoBus-Build dauert auf einem Pi 4 etwa 30–60 Minuten |

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
4. Hilfsskripte nach `/usr/local/bin` installieren
5. `aooserver` und `sonobus` aus den Quellen bauen ← **das dauert**
6. systemd-Dienste `aooserver.service` und `sonobus-sender.service` einrichten
7. Den offenen Hotspot einrichten
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
sudo ./install.sh --skip-build                          # nur neu konfigurieren
sudo ./install.sh --force-build                         # Binaries neu bauen
sudo ./install.sh --skip-hotspot                        # WLAN unangetastet lassen
sudo ./install.sh --reset-config                        # Konfiguration neu anlegen
```

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
2. SonoBus öffnen (kostenlos für iOS, Android, macOS, Windows, Linux von
   [sonobus.net](https://sonobus.net)).
3. Im Verbindungsfenster **nicht** den voreingestellten Server
   `aoo.sonobus.net` lassen, sondern eintragen:

   | Feld | Wert |
   |---|---|
   | Verbindungsserver | `10.42.0.1` |
   | Port | `10998` |
   | Gruppe | `ArizonaArizona` |
   | Passwort | *(leer)* |

4. Gruppe betreten – der Pi ist als **`MixPre-10T`** schon drin.

Alternativ gibt es einen Link, den SonoBus direkt versteht (kopieren, dann in
SonoBus „Verbindungsinfo einfügen"):

```
sonobus://10.42.0.1:10998/?g=ArizonaArizona
```

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
| `AP_SSID` | Name des offenen WLANs | `ArizonaArizona` |
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

`SB_BUFFER_SIZE` erhöhen (z. B. `512` oder `1024`), auf 5 GHz wechseln, den
Abstand verringern und in SonoBus auf den Client-Geräten die Jitter-Puffer auf
„Auto" lassen.

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

**Bauen schlägt fehl (Speicher)**

Swap vergrößern und neu bauen:

```bash
sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
sudo systemctl restart dphys-swapfile
sudo ./install.sh --force-build
```

---

## Was wo liegt

| Pfad | Inhalt |
|---|---|
| `/etc/rasphotspot/rasphotspot.conf` | die eine Konfigurationsdatei |
| `/etc/rasphotspot/connect-info.txt` | Anschlussinfos für die Zuhörer |
| `/etc/asound.conf` | erzeugte ALSA-Gerätenamen (`rasphotspot_in/out`) |
| `/var/lib/sonobus/.config/sonobus/SonoBus.settings` | erzeugte SonoBus-Audioeinstellungen |
| `/usr/local/bin/aooserver`, `/usr/local/bin/sonobus` | gebaute Programme |
| `/usr/local/bin/rasphotspot-*` | Hilfsskripte (Status, Audio-Setup, Starter) |
| `/usr/local/src/rasphotspot/` | Quellen für spätere Neubauten |
| `/var/log/rasphotspot/` | Logdateien des Verbindungsservers |

### Die Dienste

* **`aooserver.service`** – startet `aooserver --port=10998`, unabhängig vom Audio.
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

Die Hilfsfunktionen (Kartenerkennung, Kanalmasken, Verbindungslink, Erzeugen der
Konfiguration, Format der Kommandozeilenoptionen) haben eine kleine Testsuite –
sie braucht kein root und fasst das System nicht an:

```bash
./tests/run-tests.sh
```

## Hinweise

* SonoBus überträgt **unverschlüsselt**, und das WLAN ist **offen** – wer in
  Funkreichweite ist, kann mithören. Für vertrauliche Inhalte ein Gruppenpasswort
  setzen (`SB_GROUP_PASSWORD`) und/oder das WLAN nicht offen betreiben.
* SonoBus (GPLv3) und aooserver stammen von Jesse Chappell / Sonosaurus, die
  AOO-Bibliothek von Christof Ressi. Dieses Projekt baut und konfiguriert diese
  Programme lediglich.
* Der Pi verbindet sich auf Systemen ohne NetworkManager nach der Installation
  nicht mehr selbst mit anderen WLANs (`wpa_supplicant` wird deaktiviert) –
  für die Fernwartung dann LAN-Kabel oder Bildschirm/Tastatur nutzen.
