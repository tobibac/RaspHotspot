#!/bin/bash
# =============================================================================
# RaspHotspot – Installation
#
# Macht aus einem Raspberry Pi eine SonoBus-Basisstation:
#   * offener WLAN-Hotspot (ohne Passwort)
#   * aooserver  – der Verbindungsserver, über den sich die Gruppe findet
#   * SonoBus headless – schickt das Audio des per USB angeschlossenen
#     Sound Devices MixPre-10T in die Gruppe
#
# Aufruf:  sudo ./install.sh [Optionen]
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"

SONOBUS_DEB=""
SONOBUS_SOURCE="repo"     # repo = fertiges Paket bevorzugen, build = selbst bauen
SKIP_BUILD="no"
SKIP_HOTSPOT="no"
FORCE_BUILD="no"
KEEP_CONFIG="yes"
EXTRA_CONFIG=""
CLI_SSID=""
CLI_GROUP=""

usage() {
    cat <<USAGE
RaspHotspot – Installation

  sudo ./install.sh [Optionen]

Optionen:
  --group NAME       SonoBus-Gruppenname (Standard: ArizonaArizona)
  --ssid NAME        Name des offenen WLANs (Standard: ArizonaArizona)
  --config DATEI     zusätzliche Konfigurationsdatei einlesen
  --reset-config     vorhandene /etc/rasphotspot/rasphotspot.conf überschreiben
  --sonobus-deb Q    bestimmtes SonoBus-Paket verwenden (Datei oder URL)
  --build-sonobus    SonoBus aus den Quellen bauen statt das fertige Paket
                     von pkg.sonobus.net zu nehmen (dauert Stunden)
  --skip-build       aooserver/SonoBus nicht neu bauen (nutzt vorhandene Binaries)
  --force-build      auch dann bauen, wenn die Binaries schon existieren
  --skip-hotspot     WLAN-Hotspot nicht anfassen
  -h, --help         diese Hilfe

Nach der Installation:
  rasphotspot-status         Zustand aller Teile anzeigen
  sudo ./uninstall.sh        alles wieder entfernen
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --group)        CLI_GROUP="${2:-}"; shift 2 ;;
        --ssid)         CLI_SSID="${2:-}"; shift 2 ;;
        --config)       EXTRA_CONFIG="${2:-}"; shift 2 ;;
        --reset-config) KEEP_CONFIG="no"; shift ;;
        --sonobus-deb)  SONOBUS_DEB="${2:-}"; shift 2 ;;
        --build-sonobus) SONOBUS_SOURCE="build"; shift ;;
        --skip-build)   SKIP_BUILD="yes"; shift ;;
        --force-build)  FORCE_BUILD="yes"; shift ;;
        --skip-hotspot) SKIP_HOTSPOT="yes"; shift ;;
        -h|--help)      usage; exit 0 ;;
        *) die "Unbekannte Option: $1 (--help für die Übersicht)" ;;
    esac
done

need_root
command -v apt-get >/dev/null 2>&1 || die "Dieses Skript setzt ein Debian-/Raspberry-Pi-OS-System voraus."

# Vorhandene Installation behalten, sofern nicht --reset-config
if [ "$KEEP_CONFIG" = "no" ] && [ -f "$CONF_FILE" ]; then
    mv "$CONF_FILE" "${CONF_FILE}.alt"
    warn "Alte Konfiguration nach ${CONF_FILE}.alt verschoben."
fi

load_config "$EXTRA_CONFIG"
[ -n "$CLI_GROUP" ] && SB_GROUP="$CLI_GROUP"
[ -n "$CLI_SSID" ]  && AP_SSID="$CLI_SSID"

log ""
log "${C_BLD}RaspHotspot${C_RST} – SonoBus-Basisstation für den Raspberry Pi"
log "  WLAN (offen) : ${AP_SSID}"
log "  Gruppe       : ${SB_GROUP}"
log "  Audioquelle  : ${AUDIO_CARD_MATCH} (USB)"
log "  Dienstbenutzer: ${SERVICE_USER}"

# =============================================================================
step "1/8  Pakete installieren"
# =============================================================================
REQUIRED_PKGS=(
    git build-essential cmake pkg-config
    libasound2-dev libopus-dev
    libfreetype6-dev
    libx11-dev libxext-dev libxinerama-dev libxrandr-dev libxcursor-dev
    libgl-dev
    alsa-utils iw rfkill
    curl ca-certificates
)
OPTIONAL_PKGS=(opus-tools xvfb)

# JACK-Header: SonoBus baut mit JUCE_JACK=1, ohne jack/jack.h bricht der Build ab.
if apt-cache show libjack-jackd2-dev >/dev/null 2>&1; then
    REQUIRED_PKGS+=(libjack-jackd2-dev)
else
    REQUIRED_PKGS+=(libjack-dev)
fi

# libcurl: je nach Distribution openssl- oder gnutls-Variante
if apt-cache show libcurl4-openssl-dev >/dev/null 2>&1; then
    REQUIRED_PKGS+=(libcurl4-openssl-dev)
else
    REQUIRED_PKGS+=(libcurl4-gnutls-dev)
fi
# libfreetype heißt je nach Version anders
if ! apt-cache show libfreetype6-dev >/dev/null 2>&1; then
    REQUIRED_PKGS=("${REQUIRED_PKGS[@]/libfreetype6-dev/libfreetype-dev}")
fi

USE_NM="no"
if systemctl is-active NetworkManager >/dev/null 2>&1 && command -v nmcli >/dev/null 2>&1; then
    USE_NM="yes"
    info "NetworkManager erkannt – der Hotspot wird darüber eingerichtet."
else
    info "Kein aktiver NetworkManager – hostapd/dnsmasq werden installiert."
    REQUIRED_PKGS+=(hostapd dnsmasq)
fi

info "apt-get update"
DEBIAN_FRONTEND=noninteractive apt-get update -qq

info "Installiere: ${REQUIRED_PKGS[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${REQUIRED_PKGS[@]}"

for p in "${OPTIONAL_PKGS[@]}"; do
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
        || warn "Optionales Paket '${p}' konnte nicht installiert werden – kein Problem."
done
ok "Pakete bereit"

# =============================================================================
step "2/8  Dienstbenutzer und Verzeichnisse"
# =============================================================================
SERVICE_HOME="/var/lib/${SERVICE_USER}"
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$SERVICE_HOME" \
            --shell /usr/sbin/nologin --comment "RaspHotspot SonoBus" "$SERVICE_USER"
    ok "Benutzer '${SERVICE_USER}' angelegt"
else
    ok "Benutzer '${SERVICE_USER}' existiert bereits"
fi
usermod -aG audio "$SERVICE_USER"

install -d -m 755 "$SERVICE_HOME" && chown "$SERVICE_USER":"$SERVICE_USER" "$SERVICE_HOME"
install -d -m 755 "$CONF_DIR" "$STATE_DIR" "$SRC_DIR"
install -d -m 755 "${SB_SERVER_LOGDIR:-/var/log/rasphotspot}"
chown "$SERVICE_USER":"$SERVICE_USER" "${SB_SERVER_LOGDIR:-/var/log/rasphotspot}"

# Echtzeitrechte für Audio (greift bei Login-Sessions, systemd setzt eigene Limits)
if [ -d /etc/security/limits.d ]; then
    cat > /etc/security/limits.d/95-rasphotspot-audio.conf <<LIM
@audio   -  rtprio     95
@audio   -  memlock    unlimited
LIM
fi
# Passwort für die Einstellungsseite – nur beim ersten Mal erzeugen.
ADMIN_PASSWORD_NEW=""
if [ "${ADMIN_ENABLE:-yes}" = "yes" ] && [ ! -f "${CONF_DIR}/admin.secret" ]; then
    ADMIN_PASSWORD_NEW="$(RASPHOTSPOT_SERVICE_USER="${SERVICE_USER}" \
        "${HERE}/bin/rasphotspot-admin-password" --random | sed 's/.*: //')"
    log ""
    log "  ${C_BLD}Passwort für die Einstellungsseite: ${ADMIN_PASSWORD_NEW}${C_RST}"
    log "  ${C_YEL}Jetzt notieren.${C_RST} Neues setzen: sudo rasphotspot-admin-password"
    log ""
fi

ok "Verzeichnisse angelegt"

# =============================================================================
step "3/8  Konfiguration schreiben"
# =============================================================================
# Die Vorlage Zeile fuer Zeile durchgehen und jeden Schluessel durch den aktuell
# gueltigen Wert ersetzen - Kommentare bleiben dabei erhalten.
render_config "${HERE}/config.env.example" "$CONF_FILE"
ok "geschrieben: ${CONF_FILE}"

# =============================================================================
step "4/8  Skripte installieren"
# =============================================================================
install -d -m 755 "${PREFIX}/lib/rasphotspot"
install -m 644 "${HERE}/lib/common.sh" "${PREFIX}/lib/rasphotspot/common.sh"
install -m 644 "${HERE}/lib/rasphotspot_config.py" "${PREFIX}/lib/rasphotspot/rasphotspot_config.py"
for f in "${HERE}"/bin/*; do
    install -m 755 "$f" "${PREFIX}/bin/$(basename "$f")"
done
install -d -m 755 "${PREFIX}/share/rasphotspot"
install -m 644 "${HERE}/portal/portal.html" "${PREFIX}/share/rasphotspot/portal.html"
install -m 644 "${HERE}/portal/admin.html" "${PREFIX}/share/rasphotspot/admin.html"
# Vorlage für die Konfiguration – rasphotspot-apply schreibt damit die Datei
# neu und behält dabei alle Kommentare.
install -m 644 "${HERE}/config.env.example" "${PREFIX}/share/rasphotspot/config.env.example"
# Damit die Einstellungsseite das WLAN neu aufsetzen kann.
install -m 755 "${HERE}/scripts/setup-hotspot.sh" "${PREFIX}/bin/rasphotspot-setup-hotspot"
install -m 644 "${HERE}/udev/99-rasphotspot-usb-audio.rules" \
        /etc/udev/rules.d/99-rasphotspot-usb-audio.rules
udevadm control --reload-rules >/dev/null 2>&1 || true
ok "Skripte nach ${PREFIX}/bin installiert"

# =============================================================================
step "5/8  aooserver und SonoBus installieren"
# =============================================================================
# SonoBus aus der offiziellen Paketquelle von sonobus.net installieren.
# Das ist der schnelle Weg – gerade auf kleinen Pis, wo der Selbstbau Stunden
# dauert. Es gibt dort ARM-Pakete in 32 und 64 Bit.
sonobus_from_apt_repo() {
    local key="/etc/apt/trusted.gpg.d/sonobus.gpg"
    local list="/etc/apt/sources.list.d/sonobus.list"

    info "Richte die SonoBus-Paketquelle ein (pkg.sonobus.net)"
    echo "deb http://pkg.sonobus.net/apt stable main" > "$list"

    if ! curl -fsSL -o "${key}.tmp" "https://pkg.sonobus.net/apt/keyring.gpg"; then
        rm -f "${key}.tmp" "$list"
        warn "Schlüssel der Paketquelle nicht erreichbar."
        return 1
    fi
    mv "${key}.tmp" "$key"
    chmod 644 "$key"

    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        warn "apt-get update mit der neuen Paketquelle fehlgeschlagen."
        rm -f "$list" "$key"
        return 1
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y sonobus; then
        warn "Für diese Architektur ($(dpkg --print-architecture)) gibt es dort kein Paket."
        return 1
    fi

    command -v sonobus >/dev/null 2>&1
}

# Taugt das installierte SonoBus für den Betrieb ohne Bildschirm?
sonobus_has_headless() {
    local bin
    bin="$(command -v sonobus 2>/dev/null || echo "${PREFIX}/bin/sonobus")"
    [ -x "$bin" ] || return 1
    timeout 30 "$bin" --help 2>&1 | grep -q -- "--headless"
}

if [ "$SKIP_BUILD" = "yes" ]; then
    warn "Installation von aooserver/SonoBus übersprungen (--skip-build)"
    command -v aooserver >/dev/null 2>&1 || die "aooserver fehlt – ohne --skip-build installieren."
    command -v sonobus   >/dev/null 2>&1 || die "sonobus fehlt – ohne --skip-build installieren."
else
    # aooserver gibt es nirgends fertig – der muss gebaut werden. Er ist aber
    # klein und in ein paar Minuten durch.
    if [ -x "${PREFIX}/bin/aooserver" ] && [ "$FORCE_BUILD" = "no" ]; then
        ok "aooserver ist bereits installiert (--force-build erzwingt Neubau)"
    else
        "${HERE}/scripts/build-aooserver.sh"
    fi

    if [ -n "$SONOBUS_DEB" ]; then
        info "Installiere SonoBus aus dem Paket ${SONOBUS_DEB}"
        deb_file="$SONOBUS_DEB"
        if [[ "$SONOBUS_DEB" =~ ^https?:// ]]; then
            deb_file="$(mktemp -d)/sonobus.deb"
            curl -fL --progress-bar -o "$deb_file" "$SONOBUS_DEB" \
                || die "Download fehlgeschlagen: ${SONOBUS_DEB}"
        fi
        [ -f "$deb_file" ] || die "Paketdatei nicht gefunden: ${deb_file}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_file" \
            || die "Paket ließ sich nicht installieren."
        command -v sonobus >/dev/null 2>&1 \
            || die "Nach der Paketinstallation ist kein 'sonobus' im PATH."
        ok "SonoBus aus Paket installiert: $(command -v sonobus)"

    elif command -v sonobus >/dev/null 2>&1 && [ "$FORCE_BUILD" = "no" ]; then
        ok "SonoBus ist bereits vorhanden ($(command -v sonobus))"

    elif [ "$SONOBUS_SOURCE" = "build" ]; then
        info "SonoBus wird aus den Quellen gebaut (--build-sonobus)."
        "${HERE}/scripts/build-sonobus.sh"

    elif sonobus_from_apt_repo; then
        ok "SonoBus aus der Paketquelle installiert ($(command -v sonobus))"
        if ! sonobus_has_headless; then
            warn "Das Paket kennt keinen --headless-Modus – baue doch aus den Quellen."
            "${HERE}/scripts/build-sonobus.sh"
        fi

    else
        warn "Paketquelle nicht nutzbar – SonoBus wird aus den Quellen gebaut."
        info "Das dauert; reicht der Arbeitsspeicher nicht, legt der Build"
        info "automatisch eine Auslagerungsdatei an und entfernt sie hinterher."
        "${HERE}/scripts/build-sonobus.sh"
    fi
fi

if sonobus_has_headless; then
    ok "SonoBus läuft ohne Bildschirm (--headless vorhanden)"
else
    warn "Konnte den Headless-Modus nicht bestätigen."
    warn "Falls sonobus-sender nicht startet: SB_USE_XVFB=\"yes\" in ${CONF_FILE} setzen."
fi

# =============================================================================
step "6/8  systemd-Dienste einrichten"
# =============================================================================
UNITS=(aooserver sonobus-sender)
[ "${PORTAL_ENABLE:-yes}" = "yes" ] && UNITS+=(rasphotspot-portal)

# Die Übernahme-Schleuse: eine Path-Unit bemerkt den Vorschlag der
# Einstellungsseite und startet den Dienst, der ihn als root prüft.
if [ "${ADMIN_ENABLE:-yes}" = "yes" ] && [ "${PORTAL_ENABLE:-yes}" = "yes" ]; then
    UNITS+=(rasphotspot-apply.path)
    install -m 644 "${HERE}/systemd/rasphotspot-apply.service" \
            /etc/systemd/system/rasphotspot-apply.service
    install -m 644 "${HERE}/systemd/rasphotspot-apply.path" \
            /etc/systemd/system/rasphotspot-apply.path
fi

for unit in "${UNITS[@]}"; do
    case "$unit" in *.path) continue ;; esac
    sed -e "s|@SERVICE_USER@|${SERVICE_USER}|g" \
        -e "s|@SERVICE_HOME@|${SERVICE_HOME}|g" \
        -e "s|@LOG_DIR@|${SB_SERVER_LOGDIR:-/var/log/rasphotspot}|g" \
        "${HERE}/systemd/${unit}.service" > "/etc/systemd/system/${unit}.service"
    chmod 644 "/etc/systemd/system/${unit}.service"
done
systemctl daemon-reload
for unit in "${UNITS[@]}"; do
    case "$unit" in
        *.path) systemctl enable "${unit}" >/dev/null; systemctl restart "${unit}" >/dev/null
                ok "${unit} eingerichtet (Schleuse für die Einstellungsseite)" ;;
        *)      systemctl enable "${unit}.service" >/dev/null
                ok "${unit}.service eingerichtet und für den Autostart aktiviert" ;;
    esac
done

if [ "${PORTAL_ENABLE:-yes}" != "yes" ]; then
    systemctl disable --now rasphotspot-portal.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/rasphotspot-portal.service
    systemctl daemon-reload
fi

# =============================================================================
step "7/8  Dienste starten"
# =============================================================================
systemctl restart aooserver.service
ok "aooserver gestartet"

if [ "${PORTAL_ENABLE:-yes}" = "yes" ]; then
    if systemctl restart rasphotspot-portal.service; then
        ok "Begrüßungsseite gestartet (http://${AP_IP}/)"
    else
        warn "Begrüßungsseite konnte nicht starten – Logs: journalctl -u rasphotspot-portal -n 30"
    fi
fi

if systemctl restart sonobus-sender.service; then
    ok "sonobus-sender gestartet"
else
    warn "sonobus-sender konnte nicht starten – meist fehlt nur das Audiointerface."
    warn "Logs: journalctl -u sonobus-sender -n 50"
fi

# --- Verbindungsinfo ---------------------------------------------------------
LINK="$(sonobus_link "${AP_IP}")"
cat > "${CONF_DIR}/connect-info.txt" <<INFO
SonoBus-Gruppe "${SB_GROUP}" auf diesem Raspberry Pi
=====================================================

1. Mit dem WLAN "${AP_SSID}" verbinden${AP_PASSWORD:+ (Passwort: ${AP_PASSWORD})}${AP_PASSWORD:-  – es ist offen, kein Passwort nötig}.
   Auf den meisten Geräten öffnet sich die Anleitungsseite dann von selbst.
   Sonst im Browser aufrufen: http://${AP_IP}/

2. SonoBus öffnen (sonobus.net) und im Verbindungsfenster eintragen:

     Verbindungsserver : ${AP_IP}
     Port              : ${SB_SERVER_PORT}
     Gruppe            : ${SB_GROUP}
     Passwort          : ${SB_GROUP_PASSWORD:-(keins)}

   Wichtig: Der voreingestellte Server "aoo.sonobus.net" funktioniert hier
   nicht – der Hotspot hat keinen Internetzugang.

3. Alternativ diesen Link in die Zwischenablage kopieren, SonoBus erkennt ihn
   beim Start bzw. über "Verbindungsinfo einfügen":

     ${LINK}

Der Pi selbst ist als "${SB_USERNAME}" in der Gruppe und sendet die Kanäle
${SB_INPUT_FIRST_CHANNEL}-$(( SB_INPUT_FIRST_CHANNEL + SB_INPUT_CHANNELS - 1 )) des MixPre-10T.
INFO

log ""
log "${C_BLD}Das ist eingerichtet:${C_RST}"
log ""
if [ -n "${AP_PASSWORD:-}" ]; then
log "  WLAN            : ${C_BLD}${AP_SSID}${C_RST} (WPA2, Passwort gesetzt)"
else
log "  WLAN            : ${C_BLD}${AP_SSID}${C_RST} (offen, ohne Passwort)"
fi
log "  Verbindungsserver: ${C_BLD}${AP_IP}:${SB_SERVER_PORT}${C_RST}"
log "  Gruppe          : ${C_BLD}${SB_GROUP}${C_RST}"
log "  Link            : ${LINK}"
log ""
log "  Begrüßungsseite : http://${AP_IP}/ (öffnet sich beim Einbuchen von selbst)"
if [ "${ADMIN_ENABLE:-yes}" = "yes" ]; then
log "  Einstellungen   : ${C_BLD}http://${AP_IP}/admin${C_RST} (Benutzer ${ADMIN_USER:-admin})"
if [ -n "$ADMIN_PASSWORD_NEW" ]; then
log "  Passwort dafür  : ${C_BLD}${ADMIN_PASSWORD_NEW}${C_RST}  ${C_YEL}(jetzt notieren!)${C_RST}"
log "                    ändern mit: sudo rasphotspot-admin-password"
fi
fi
log "  Latenz          : ${SB_SEND_FORMAT}, Puffer ${SB_BUFFER_SIZE} Samples, Jitterpuffer ${SB_JITTER_MS} ms"
log ""
log "  Zustand prüfen  : rasphotspot-status"
log "  Diese Infos     : ${CONF_DIR}/connect-info.txt"
log ""
# =============================================================================
step "8/8  WLAN-Hotspot einrichten"
# =============================================================================
# Ganz zum Schluss, und zwar mit Absicht: Sobald das WLAN-Modul vom Client- in
# den Access-Point-Betrieb wechselt, bricht jede SSH-Verbindung ab, die über
# genau dieses WLAN läuft. Alles Wichtige ist bis hierher erledigt und
# ausgegeben; der Hotspot selbst wird zusätzlich losgelöst von dieser Sitzung
# gestartet, damit er auch dann fertig wird, wenn die Verbindung wegbricht.
if [ "$SKIP_HOTSPOT" = "yes" ]; then
    warn "Hotspot übersprungen (--skip-hotspot)"
    log "  Später nachholen mit: sudo rasphotspot-setup-hotspot"
else
    HOTSPOT_IFACE="$(detect_wifi_iface || true)"
    RISKY="no"
    if [ -n "$HOTSPOT_IFACE" ] && ssh_over_iface "$HOTSPOT_IFACE"; then
        RISKY="yes"
        log ""
        warn "Du bist über ${HOTSPOT_IFACE} per SSH verbunden – genau dieses"
        warn "Interface wird jetzt zum Access Point. Deine Verbindung bricht"
        warn "dabei ab. Das ist normal und kein Fehler:"
        log  "    • Der Hotspot läuft danach trotzdem weiter."
        log  "    • Zurück kommst du über das WLAN '${AP_SSID}' und"
        log  "      dann  ssh ${SUDO_USER:-pi}@${AP_IP}"
        log  "    • Oder per LAN-Kabel bzw. Bildschirm und Tastatur."
        log ""
        info "Weiter in 8 Sekunden – mit Strg+C abbrechen (Hotspot dann später"
        info "mit 'sudo rasphotspot-setup-hotspot' einrichten)."
        sleep 8
    fi

    if [ "$RISKY" = "yes" ] && command -v systemd-run >/dev/null 2>&1; then
        # Losgelöst von dieser Sitzung starten, damit ein Verbindungsabbruch
        # die Einrichtung nicht mittendrin abwürgt.
        systemctl reset-failed rasphotspot-hotspot-setup.service 2>/dev/null || true
        systemd-run --unit=rasphotspot-hotspot-setup --collect --quiet \
            "${PREFIX}/bin/rasphotspot-setup-hotspot"
        info "Einrichtung läuft im Hintergrund (rasphotspot-hotspot-setup)."

        for _ in $(seq 1 60); do
            systemctl is-active --quiet rasphotspot-hotspot-setup.service || break
            sleep 1
        done

        if systemctl is-failed --quiet rasphotspot-hotspot-setup.service; then
            err "Hotspot-Einrichtung fehlgeschlagen:"
            journalctl -u rasphotspot-hotspot-setup -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
        else
            ok "Hotspot '${AP_SSID}' eingerichtet"
        fi
    else
        "${PREFIX}/bin/rasphotspot-setup-hotspot"
    fi
fi

log ""
log "${C_GRN}${C_BLD}Fertig.${C_RST}"
log ""
log "  Am MixPre-10T muss USB-Audio aktiv sein (Menü: System > USB > Audio Interface)."
log "  Zurück auf den Pi kommst du über das WLAN '${AP_SSID}': ssh ${SUDO_USER:-pi}@${AP_IP}"
log "  Alles startet ab jetzt automatisch, sobald der Pi Strom bekommt."
log "  Zum Prüfen einmal neu starten: sudo reboot"
log ""
