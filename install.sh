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
  --sonobus-deb Q    fertiges SonoBus-Paket statt Selbstbau (Datei oder URL).
                     Spart auf langsamen Pis Stunden – Pakete gibt es auf
                     sonobus.net/linux.html
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
for f in "${HERE}"/bin/*; do
    install -m 755 "$f" "${PREFIX}/bin/$(basename "$f")"
done
install -d -m 755 "${PREFIX}/share/rasphotspot"
install -m 644 "${HERE}/portal/portal.html" "${PREFIX}/share/rasphotspot/portal.html"
install -m 644 "${HERE}/udev/99-rasphotspot-usb-audio.rules" \
        /etc/udev/rules.d/99-rasphotspot-usb-audio.rules
udevadm control --reload-rules >/dev/null 2>&1 || true
ok "Skripte nach ${PREFIX}/bin installiert"

# =============================================================================
step "5/8  aooserver und SonoBus bauen"
# =============================================================================
if [ "$SKIP_BUILD" = "yes" ]; then
    warn "Build übersprungen (--skip-build)"
    command -v aooserver >/dev/null 2>&1 || die "aooserver fehlt – ohne --skip-build installieren."
    command -v sonobus   >/dev/null 2>&1 || die "sonobus fehlt – ohne --skip-build installieren."
else
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
    elif [ -x "${PREFIX}/bin/sonobus" ] && [ "$FORCE_BUILD" = "no" ]; then
        ok "sonobus ist bereits installiert (--force-build erzwingt Neubau)"
    elif command -v sonobus >/dev/null 2>&1 && [ "$FORCE_BUILD" = "no" ]; then
        ok "sonobus ist bereits vorhanden ($(command -v sonobus))"
    else
        info "Jetzt wird SonoBus gebaut. Das dauert – Zeit für einen Kaffee."
        info "Reicht der Arbeitsspeicher nicht, wird für den Build automatisch"
        info "eine Auslagerungsdatei angelegt und hinterher wieder entfernt."
        "${HERE}/scripts/build-sonobus.sh"
    fi
fi

# Kennt das gebaute SonoBus den Headless-Modus? (rein informativ)
sb_help="$(timeout 30 "$(command -v sonobus || echo "${PREFIX}/bin/sonobus")" --help 2>&1 || true)"
if ! printf '%s' "$sb_help" | grep -q -- "--headless"; then
    warn "Konnte den Headless-Modus nicht bestaetigen (sonobus --help ohne Ergebnis)."
    warn "Falls sonobus-sender nicht startet: SB_USE_XVFB=\"yes\" in ${CONF_FILE} setzen."
else
    ok "SonoBus mit Headless-Modus gebaut"
fi

# =============================================================================
step "6/8  systemd-Dienste einrichten"
# =============================================================================
UNITS=(aooserver sonobus-sender)
[ "${PORTAL_ENABLE:-yes}" = "yes" ] && UNITS+=(rasphotspot-portal)

for unit in "${UNITS[@]}"; do
    sed -e "s|@SERVICE_USER@|${SERVICE_USER}|g" \
        -e "s|@SERVICE_HOME@|${SERVICE_HOME}|g" \
        -e "s|@LOG_DIR@|${SB_SERVER_LOGDIR:-/var/log/rasphotspot}|g" \
        "${HERE}/systemd/${unit}.service" > "/etc/systemd/system/${unit}.service"
    chmod 644 "/etc/systemd/system/${unit}.service"
done
systemctl daemon-reload
for unit in "${UNITS[@]}"; do
    systemctl enable "${unit}.service" >/dev/null
    ok "${unit}.service eingerichtet und für den Autostart aktiviert"
done

if [ "${PORTAL_ENABLE:-yes}" != "yes" ]; then
    systemctl disable --now rasphotspot-portal.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/rasphotspot-portal.service
    systemctl daemon-reload
fi

# =============================================================================
step "7/8  WLAN-Hotspot einrichten"
# =============================================================================
if [ "$SKIP_HOTSPOT" = "yes" ]; then
    warn "Hotspot übersprungen (--skip-hotspot)"
else
    "${HERE}/scripts/setup-hotspot.sh"
fi

# =============================================================================
step "8/8  Dienste starten"
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

1. Mit dem offenen WLAN "${AP_SSID}" verbinden (kein Passwort).
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
log "${C_GRN}${C_BLD}Fertig.${C_RST}"
log ""
log "  WLAN            : ${C_BLD}${AP_SSID}${C_RST} (offen, ohne Passwort)"
log "  Verbindungsserver: ${C_BLD}${AP_IP}:${SB_SERVER_PORT}${C_RST}"
log "  Gruppe          : ${C_BLD}${SB_GROUP}${C_RST}"
log "  Link            : ${LINK}"
log ""
log "  Begrüßungsseite : http://${AP_IP}/ (öffnet sich beim Einbuchen von selbst)"
log "  Latenz          : ${SB_SEND_FORMAT}, Puffer ${SB_BUFFER_SIZE} Samples, Jitterpuffer ${SB_JITTER_MS} ms"
log ""
log "  Zustand prüfen  : rasphotspot-status"
log "  Diese Infos     : ${CONF_DIR}/connect-info.txt"
log ""
log "  Am MixPre-10T muss USB-Audio aktiv sein (Menü: System > USB > Audio Interface)."
log "  Alles startet ab jetzt automatisch, sobald der Pi Strom bekommt."
log "  Zum Prüfen einmal neu starten: sudo reboot"
log ""
