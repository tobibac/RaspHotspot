#!/bin/bash
# -----------------------------------------------------------------------------
# Richtet den offenen WLAN-Hotspot ein.
#
# Zwei Wege, je nachdem was auf dem System läuft:
#   * NetworkManager (Raspberry Pi OS Bookworm und neuer)  -> nmcli-Profil
#   * sonst (Bullseye, Lite-Images ohne NM)                -> hostapd + dnsmasq
# -----------------------------------------------------------------------------
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=../lib/common.sh
. "${LIB_DIR}/common.sh"

need_root
load_config

# --- Interface und Funkfähigkeiten prüfen ------------------------------------
IFACE="$(detect_wifi_iface || true)"
[ -n "$IFACE" ] || die "Kein WLAN-Interface gefunden (WIFI_IFACE in der Konfiguration setzen)."
PHY="$(phy_of_iface "$IFACE" || echo phy0)"
info "WLAN-Interface: ${IFACE} (${PHY})"

# Funkmodul freischalten
if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock wifi 2>/dev/null || true
    rfkill unblock all  2>/dev/null || true
fi

# Funkland setzen – ohne gültiges Land sind 5-GHz-Kanäle gesperrt.
if command -v iw >/dev/null 2>&1; then
    iw reg set "${AP_COUNTRY}" 2>/dev/null || warn "Konnte Funkland ${AP_COUNTRY} nicht setzen."
fi
if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_wifi_country "${AP_COUNTRY}" >/dev/null 2>&1 || true
fi

if command -v iw >/dev/null 2>&1 && ! wifi_supports_ap "$PHY"; then
    die "Das WLAN-Modul ${PHY} unterstützt keinen Access-Point-Modus."
fi

# 5 GHz nur nutzen, wenn wirklich möglich – sonst automatisch auf 2.4 GHz.
BAND="${AP_BAND}"
CHANNEL="${AP_CHANNEL}"
if [ "$BAND" = "a" ] && command -v iw >/dev/null 2>&1; then
    if ! wifi_supports_5ghz "$PHY" "$CHANNEL"; then
        warn "5-GHz-Kanal ${CHANNEL} nicht nutzbar – weiche auf ${AP_FALLBACK_BAND}/Kanal ${AP_FALLBACK_CHANNEL} aus."
        BAND="${AP_FALLBACK_BAND}"
        CHANNEL="${AP_FALLBACK_CHANNEL}"
    fi
fi
info "Band: ${BAND} (Kanal ${CHANNEL}), SSID '${AP_SSID}' – offen, ohne Passwort"

# Das Begrüßungsfenster funktioniert nur, wenn die Geräte den Pi als Gateway
# und DNS bekommen – sonst fragen sie ihn gar nicht erst.
if [ "${PORTAL_ENABLE:-yes}" = "yes" ] && [ "${AP_OFFER_GATEWAY}" != "yes" ]; then
    warn "PORTAL_ENABLE=yes braucht AP_OFFER_GATEWAY=yes – setze das für diesen Lauf."
    AP_OFFER_GATEWAY="yes"
fi

install -d -m 755 "$STATE_DIR"

# =============================================================================
# Variante 1: NetworkManager
# =============================================================================
setup_networkmanager() {
    info "Konfiguriere Hotspot über NetworkManager"

    # DHCP-/DNS-Optionen für den internen dnsmasq von NetworkManager.
    install -d -m 755 /etc/NetworkManager/dnsmasq-shared.d
    {
        echo "# Automatisch erzeugt von RaspHotspot"
        if [ "${PORTAL_ENABLE:-yes}" = "yes" ]; then
            echo "# Alle Namen zeigen auf den Pi, damit die Verbindungstests der"
            echo "# Geräte auf der Begrüßungsseite landen."
            echo "address=/#/${AP_IP}"
        fi
        if [ "${AP_OFFER_GATEWAY}" = "yes" ]; then
            echo "dhcp-option=3,${AP_IP}"
            echo "dhcp-option=6,${AP_IP}"
        else
            echo "# Bewusst kein Gateway und kein DNS: der Hotspot hat kein Internet,"
            echo "# Handys behalten so ihre Mobilfunkverbindung."
            echo "dhcp-option=3"
            echo "dhcp-option=6"
        fi
    } > /etc/NetworkManager/dnsmasq-shared.d/rasphotspot.conf

    if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "${AP_CON_NAME}"; then
        nmcli connection delete "${AP_CON_NAME}" >/dev/null
    fi

    nmcli connection add type wifi ifname "${IFACE}" con-name "${AP_CON_NAME}" \
        autoconnect yes ssid "${AP_SSID}" >/dev/null

    nmcli connection modify "${AP_CON_NAME}" \
        802-11-wireless.mode ap \
        802-11-wireless.band "${BAND}" \
        802-11-wireless.channel "${CHANNEL}" \
        802-11-wireless.powersave 2 \
        ipv4.method shared \
        ipv4.addresses "${AP_IP}/${AP_PREFIX}" \
        ipv6.method disabled \
        connection.autoconnect yes \
        connection.autoconnect-priority 100 >/dev/null

    # Sicherstellen, dass keine Verschlüsselung konfiguriert ist (offenes Netz).
    nmcli connection modify "${AP_CON_NAME}" \
        remove 802-11-wireless-security >/dev/null 2>&1 || true

    nmcli connection up "${AP_CON_NAME}" >/dev/null
    echo "BACKEND=networkmanager" > "${STATE_DIR}/hotspot.state"
}

# =============================================================================
# Variante 2: hostapd + dnsmasq
# =============================================================================
setup_hostapd() {
    info "Konfiguriere Hotspot über hostapd + dnsmasq"

    for pkg in hostapd dnsmasq; do
        command -v "$pkg" >/dev/null 2>&1 || die "${pkg} ist nicht installiert (install.sh erledigt das)."
    done

    # --- hostapd -------------------------------------------------------------
    local hwmode extra=""
    if [ "$BAND" = "a" ]; then
        hwmode="a"
        extra=$'ieee80211ac=1\nht_capab=[HT40+][SHORT-GI-20][SHORT-GI-40]\nvht_oper_chwidth=0'
    else
        hwmode="g"
        extra=$'ht_capab=[HT40+][SHORT-GI-20][DSSS_CCK-40]'
    fi

    install -d -m 755 /etc/hostapd
    [ -f /etc/hostapd/hostapd.conf ] && [ ! -f /etc/hostapd/hostapd.conf.vor-rasphotspot ] && \
        cp -a /etc/hostapd/hostapd.conf /etc/hostapd/hostapd.conf.vor-rasphotspot

    cat > /etc/hostapd/hostapd.conf <<CONF
# Automatisch erzeugt von RaspHotspot
interface=${IFACE}
driver=nl80211

ssid=${AP_SSID}
country_code=${AP_COUNTRY}
ieee80211d=1
hw_mode=${hwmode}
channel=${CHANNEL}
ieee80211n=1
${extra}
wmm_enabled=1

# Offenes Netz: keine Authentifizierung, keine Verschlüsselung
auth_algs=1
wpa=0
macaddr_acl=0
ignore_broadcast_ssid=0
CONF
    chmod 600 /etc/hostapd/hostapd.conf

    if [ -f /etc/default/hostapd ]; then
        sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
        grep -q '^DAEMON_CONF=' /etc/default/hostapd || \
            echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
    fi

    # --- feste IP auf dem WLAN-Interface -------------------------------------
    cat > /etc/systemd/system/rasphotspot-ap-ip.service <<CONF
[Unit]
Description=RaspHotspot: feste IP auf ${IFACE}
Before=hostapd.service dnsmasq.service
Wants=network-pre.target
After=sys-subsystem-net-devices-${IFACE}.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip link set ${IFACE} up
ExecStart=/sbin/ip addr replace ${AP_IP}/${AP_PREFIX} dev ${IFACE}
ExecStop=/sbin/ip addr del ${AP_IP}/${AP_PREFIX} dev ${IFACE}

[Install]
WantedBy=multi-user.target
CONF

    # dhcpcd darf dem Interface nicht dazwischenfunken.
    if [ -f /etc/dhcpcd.conf ]; then
        sed -i '/# BEGIN RaspHotspot/,/# END RaspHotspot/d' /etc/dhcpcd.conf
        cat >> /etc/dhcpcd.conf <<CONF
# BEGIN RaspHotspot
interface ${IFACE}
    static ip_address=${AP_IP}/${AP_PREFIX}
    nohook wpa_supplicant
# END RaspHotspot
CONF
    fi

    # --- dnsmasq -------------------------------------------------------------
    install -d -m 755 /etc/dnsmasq.d
    {
        echo "# Automatisch erzeugt von RaspHotspot"
        echo "interface=${IFACE}"
        echo "bind-interfaces"
        echo "dhcp-range=${AP_DHCP_START},${AP_DHCP_END},255.255.255.0,24h"
        if [ "${PORTAL_ENABLE:-yes}" = "yes" ]; then
            echo "# Alle Namen zeigen auf den Pi, damit die Verbindungstests der"
            echo "# Geräte auf der Begrüßungsseite landen."
            echo "address=/#/${AP_IP}"
        fi
        if [ "${AP_OFFER_GATEWAY}" = "yes" ]; then
            echo "dhcp-option=3,${AP_IP}"
            echo "dhcp-option=6,${AP_IP}"
        else
            echo "# Kein Gateway/DNS: der Hotspot hat kein Internet, Handys sollen"
            echo "# ihre Mobilfunkverbindung weiter nutzen."
            echo "dhcp-option=3"
            echo "dhcp-option=6"
            echo "port=0"
        fi
    } > /etc/dnsmasq.d/rasphotspot.conf

    # --- Dienste -------------------------------------------------------------
    systemctl unmask hostapd >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable rasphotspot-ap-ip.service >/dev/null
    systemctl enable hostapd.service dnsmasq.service >/dev/null

    # wpa_supplicant würde als Client versuchen, sich zu verbinden.
    if systemctl is-enabled wpa_supplicant.service >/dev/null 2>&1; then
        systemctl disable --now wpa_supplicant.service >/dev/null 2>&1 || true
        warn "wpa_supplicant deaktiviert – der Pi verbindet sich nicht mehr mit anderen WLANs."
    fi

    systemctl restart rasphotspot-ap-ip.service
    systemctl restart hostapd.service
    systemctl restart dnsmasq.service

    echo "BACKEND=hostapd" > "${STATE_DIR}/hotspot.state"
}

# --- Auswahl ----------------------------------------------------------------
if systemctl is-active NetworkManager >/dev/null 2>&1 && command -v nmcli >/dev/null 2>&1; then
    setup_networkmanager
else
    setup_hostapd
fi

{
    echo "IFACE=${IFACE}"
    echo "SSID=${AP_SSID}"
    echo "BAND=${BAND}"
    echo "CHANNEL=${CHANNEL}"
    echo "IP=${AP_IP}"
    echo "CONFIGURED_AT=$(date -Is)"
} >> "${STATE_DIR}/hotspot.state"

ok "Hotspot '${AP_SSID}' eingerichtet – ${AP_IP}/${AP_PREFIX} auf ${IFACE}"
