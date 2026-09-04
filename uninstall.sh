#!/bin/bash
# Entfernt RaspHotspot wieder vom System.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${HERE}/lib/common.sh"

KEEP_USER="no"
KEEP_SOURCES="no"
while [ $# -gt 0 ]; do
    case "$1" in
        --keep-user)    KEEP_USER="yes"; shift ;;
        --keep-sources) KEEP_SOURCES="yes"; shift ;;
        -h|--help) echo "sudo ./uninstall.sh [--keep-user] [--keep-sources]"; exit 0 ;;
        *) die "Unbekannte Option: $1" ;;
    esac
done

need_root
load_config

step "Dienste stoppen"
systemctl disable --now rasphotspot-apply.path >/dev/null 2>&1 || true
rm -f /etc/systemd/system/rasphotspot-apply.path /etc/systemd/system/rasphotspot-apply.service

for unit in sonobus-sender aooserver rasphotspot-portal; do
    systemctl disable --now "${unit}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${unit}.service"
done

step "Hotspot zurückbauen"
backend=""
[ -f "${STATE_DIR}/hotspot.state" ] && backend="$(grep -m1 '^BACKEND=' "${STATE_DIR}/hotspot.state" | cut -d= -f2 || true)"

if [ "$backend" = "networkmanager" ] || { [ -z "$backend" ] && command -v nmcli >/dev/null 2>&1; }; then
    nmcli connection delete "${AP_CON_NAME}" >/dev/null 2>&1 || true
    rm -f /etc/NetworkManager/dnsmasq-shared.d/rasphotspot.conf
fi
if [ "$backend" = "hostapd" ] || [ -f /etc/dnsmasq.d/rasphotspot.conf ]; then
    systemctl disable --now rasphotspot-ap-ip.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/rasphotspot-ap-ip.service
    rm -f /etc/dnsmasq.d/rasphotspot.conf
    if [ -f /etc/hostapd/hostapd.conf.vor-rasphotspot ]; then
        mv /etc/hostapd/hostapd.conf.vor-rasphotspot /etc/hostapd/hostapd.conf
    else
        rm -f /etc/hostapd/hostapd.conf
        systemctl disable --now hostapd >/dev/null 2>&1 || true
    fi
    if [ -f /etc/dhcpcd.conf ]; then
        sed -i '/# BEGIN RaspHotspot/,/# END RaspHotspot/d' /etc/dhcpcd.conf
    fi
    systemctl restart dnsmasq >/dev/null 2>&1 || true
fi
systemctl daemon-reload

step "Dateien entfernen"
rm -f "${PREFIX}"/bin/rasphotspot-* "${PREFIX}/bin/aooserver" "${PREFIX}/bin/sonobus"
# Paketquelle von sonobus.net wieder entfernen (das Paket selbst bleibt).
rm -f /etc/apt/sources.list.d/sonobus.list /etc/apt/trusted.gpg.d/sonobus.gpg
rm -rf "${PREFIX}/lib/rasphotspot" "${PREFIX}/share/rasphotspot"
rm -f /etc/udev/rules.d/99-rasphotspot-usb-audio.rules
rm -f /etc/security/limits.d/95-rasphotspot-audio.conf
udevadm control --reload-rules >/dev/null 2>&1 || true

if [ -f /etc/asound.conf ] && grep -q RaspHotspot /etc/asound.conf; then
    if [ -f /etc/asound.conf.vor-rasphotspot ]; then
        mv /etc/asound.conf.vor-rasphotspot /etc/asound.conf
    else
        rm -f /etc/asound.conf
    fi
fi

rm -rf "$CONF_DIR" "$STATE_DIR"
[ "$KEEP_SOURCES" = "yes" ] || rm -rf "$SRC_DIR"

if [ "$KEEP_USER" = "no" ] && id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    userdel -r "${SERVICE_USER}" >/dev/null 2>&1 || userdel "${SERVICE_USER}" >/dev/null 2>&1 || true
    ok "Benutzer ${SERVICE_USER} entfernt"
fi

ok "RaspHotspot entfernt. Installierte apt-Pakete bleiben erhalten."
log "Hinweis: wpa_supplicant wurde ggf. deaktiviert – bei Bedarf wieder aktivieren:"
log "  sudo systemctl enable --now wpa_supplicant"
