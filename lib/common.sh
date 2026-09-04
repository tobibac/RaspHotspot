#!/bin/bash
# Gemeinsame Hilfsfunktionen für alle RaspHotspot-Skripte.

CONF_DIR="/etc/rasphotspot"
CONF_FILE="${CONF_DIR}/rasphotspot.conf"
STATE_DIR="/var/lib/rasphotspot"
SRC_DIR="/usr/local/src/rasphotspot"
PREFIX="/usr/local"
# Wurzel der ALSA-Statusdateien – nur für Tests umbiegbar.
ASOUND_DIR="${ASOUND_DIR:-/proc/asound}"

# --- Ausgabe ---------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s  !%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()   { printf '%s  ✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_RST"; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Bitte mit sudo bzw. als root ausführen."
}

# --- Konfiguration ---------------------------------------------------------
# Lädt die Konfiguration: erst die Vorlage (für Defaults), dann die
# installierte Datei, dann eine explizit übergebene Datei.
load_config() {
    local extra="${1:-}"
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    [ -f "${here}/config.env.example" ] && . "${here}/config.env.example"
    [ -f "${here}/config.env" ]         && . "${here}/config.env"
    [ -f "$CONF_FILE" ]                 && . "$CONF_FILE"
    if [ -n "$extra" ]; then
        [ -f "$extra" ] || die "Konfigurationsdatei nicht gefunden: $extra"
        . "$extra"
    fi
    return 0
}

# --- Netzwerk --------------------------------------------------------------
# Erstes WLAN-Interface ermitteln.
detect_wifi_iface() {
    local i
    if [ -n "${WIFI_IFACE:-}" ]; then
        printf '%s' "$WIFI_IFACE"; return 0
    fi
    for i in /sys/class/net/*/wireless; do
        [ -e "$i" ] || continue
        basename "$(dirname "$i")"
        return 0
    done
    return 1
}

# phy-Name zu einem Interface.
phy_of_iface() {
    local iface="$1"
    if [ -f "/sys/class/net/${iface}/phy80211/name" ]; then
        cat "/sys/class/net/${iface}/phy80211/name"
        return 0
    fi
    return 1
}

# Kann dieses Gerät als Access Point arbeiten?
wifi_supports_ap() {
    local phy="$1"
    iw phy "$phy" info 2>/dev/null | sed -n '/Supported interface modes/,/^\t[A-Za-z]/p' \
        | grep -qE '^\s+\*\s+AP$'
}

# Ist der 5-GHz-Kanal wirklich nutzbar (vorhanden, nicht gesperrt)?
wifi_supports_5ghz() {
    local phy="$1" chan="${2:-36}" freq line
    freq=$((5000 + chan * 5))
    line="$(iw phy "$phy" info 2>/dev/null | grep -E "^\s+\* ${freq} MHz" | head -1)"
    [ -n "$line" ] || return 1
    case "$line" in
        *disabled*|*"no IR"*|*"radar detection"*) return 1 ;;
    esac
    return 0
}

# Läuft die aktuelle SSH-Sitzung über dieses Interface? Wenn ja, bricht sie
# ab, sobald daraus ein Access Point wird.
ssh_over_iface() {
    local iface="$1" addr
    command -v ss >/dev/null 2>&1 || return 1
    while read -r addr; do
        [ -n "$addr" ] || continue
        if ss -tn state established 2>/dev/null \
             | awk '{print $3}' | grep -q "^${addr}:22$"; then
            return 0
        fi
    done < <(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    return 1
}

# --- Audio -----------------------------------------------------------------
# Sucht die Soundkarte und gibt "index<TAB>id<TAB>beschreibung" zurück.
# 1. nach AUDIO_CARD_MATCH, 2. erste USB-Karte mit Aufnahme-Gerät.
detect_audio_card() {
    local match="${1:-}" idx id desc
    local -a usb_fallback=()

    while read -r idx id desc; do
        [ -n "$idx" ] || continue
        if [ -n "$match" ] && printf '%s %s' "$id" "$desc" | grep -qi -- "$match"; then
            printf '%s\t%s\t%s\n' "$idx" "$id" "$desc"
            return 0
        fi
        if [ -e "${ASOUND_DIR}/card${idx}/usbid" ] && \
           compgen -G "${ASOUND_DIR}/card${idx}/pcm*c" >/dev/null; then
            usb_fallback=("$idx" "$id" "$desc")
        fi
    done < <(list_audio_cards)

    if [ ${#usb_fallback[@]} -eq 3 ]; then
        printf '%s\t%s\t%s\n' "${usb_fallback[0]}" "${usb_fallback[1]}" "${usb_fallback[2]}"
        return 0
    fi
    return 1
}

# Alle Karten als "index id beschreibung" ausgeben.
list_audio_cards() {
    [ -f "${ASOUND_DIR}/cards" ] || return 0
    # Zeilenformat: " 1 [MixPre10T      ]: USB-Audio - MixPre-10T"
    awk -F'[][]' '/^[[:space:]]*[0-9]+[[:space:]]*\[/ {
            idx = $1 + 0
            id = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
            desc = $3; sub(/^[[:space:]]*:[[:space:]]*/, "", desc)
            print idx, id, desc
        }' "${ASOUND_DIR}/cards"
}

# Bitmaske für JUCE (audioDeviceInChans / audioDeviceOutChans):
# count Einsen ab Kanal first (1-basiert), als Binärstring MSB-first.
channel_bitmask() {
    local first="${1:-1}" count="${2:-2}" i out=""
    for ((i = 0; i < count; i++)); do out="1${out}"; done
    for ((i = 1; i < first; i++)); do out="${out}0"; done
    printf '%s' "$out"
}

# --- Latenz -----------------------------------------------------------------
# SonoBus-Sendeformat -> Index in der Formatliste des Programms.
# PCM ist unkomprimiert und damit ohne Encoder-Verzögerung; Opus spart
# Bandbreite, kostet je nach Bitrate 2,5 bis 20 ms.
send_format_index() {
    case "${1:-pcm16}" in
        opus16)  printf '0'  ;;
        opus24)  printf '1'  ;;
        opus48)  printf '2'  ;;
        opus64)  printf '3'  ;;
        opus96)  printf '4'  ;;
        opus128) printf '5'  ;;
        opus160) printf '6'  ;;
        opus256) printf '7'  ;;
        pcm16)   printf '8'  ;;
        pcm24)   printf '9'  ;;
        pcm32)   printf '10' ;;
        *)       printf '8'; return 1 ;;
    esac
}

# Regelverhalten des Jitterpuffers -> Index des SonoBus-Parameters.
jitter_mode_index() {
    case "${1:-auto-full}" in
        off)       printf '0' ;;
        auto-up)   printf '1' ;;
        auto-full) printf '2' ;;
        initial)   printf '3' ;;
        *)         printf '2'; return 1 ;;
    esac
}

# --- Konfiguration schreiben ------------------------------------------------
# Erzeugt aus der Vorlage eine Konfigurationsdatei, in der jeder Schlüssel durch
# den aktuell gültigen Wert ersetzt ist. Kommentare bleiben erhalten.
render_config() {
    local template="$1" target="$2" line key val
    [ -f "$template" ] || die "Vorlage nicht gefunden: $template"
    : > "${target}.tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]]; then
            key="${BASH_REMATCH[1]}"
            val="${!key-}"
            printf '%s="%s"\n' "$key" "$val" >> "${target}.tmp"
        else
            printf '%s\n' "$line" >> "${target}.tmp"
        fi
    done < "$template"
    mv "${target}.tmp" "$target"
    chmod 644 "$target"
}

# --- Speicher für den Build -------------------------------------------------
# JUCE baut sein Hilfsprogramm juceaide als Debug-Build (das schreibt JUCE
# selbst so vor, Flags von außen greifen dort nicht). Die große Sammeldatei
# juce_gui_basics.cpp braucht dabei deutlich über ein Gigabyte – auf einem Pi
# mit 1–2 GB RAM killt der Kernel den Compiler:
#   "c++: fatal error: Killed signal terminated program cc1plus"
# Dagegen hilft nur mehr Speicher. Wir legen für die Dauer des Builds eine
# Auslagerungsdatei an und räumen sie hinterher wieder weg.

BUILD_SWAPFILE="/var/cache/rasphotspot-build-swap"

ram_mb()  { awk '/^MemTotal:/  { printf "%d", $2 / 1024 }' /proc/meminfo; }
swap_mb() { awk '/^SwapTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo; }

# Wieviel Auslagerungsdatei fehlt noch? (vorhanden, gewünscht) -> MB, 0 = genug.
# Wird auf volle 256 MB aufgerundet, Minimum 512 MB.
swap_needed_mb() {
    local have="$1" want="$2" missing
    if [ "$have" -ge "$want" ]; then printf '0'; return 0; fi
    missing=$(( want - have ))
    missing=$(( (missing + 255) / 256 * 256 ))
    [ "$missing" -lt 512 ] && missing=512
    printf '%s' "$missing"
}

# Freier Platz in MB auf dem Dateisystem, auf dem ein Pfad liegt.
free_disk_mb() {
    df -Pm "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Sorgt dafür, dass RAM + Swap mindestens <want_mb> ergeben.
ensure_build_memory() {
    local want="${1:-4096}" have need free
    have=$(( $(ram_mb) + $(swap_mb) ))
    info "Speicher: $(ram_mb) MB RAM + $(swap_mb) MB Swap = ${have} MB"

    need="$(swap_needed_mb "$have" "$want")"
    if [ "$need" = "0" ]; then
        ok "Genug Speicher für den Build"
        return 0
    fi

    if [ -e "$BUILD_SWAPFILE" ]; then
        warn "Alte Auslagerungsdatei ${BUILD_SWAPFILE} gefunden – räume sie weg."
        swapoff "$BUILD_SWAPFILE" 2>/dev/null || true
        rm -f "$BUILD_SWAPFILE"
    fi

    install -d -m 755 "$(dirname "$BUILD_SWAPFILE")"
    free="$(free_disk_mb "$(dirname "$BUILD_SWAPFILE")")"
    if [ -n "$free" ] && [ "$free" -lt $(( need + 1024 )) ]; then
        err "Zu wenig Platz: ${need} MB Auslagerungsdatei gewünscht, nur ${free} MB frei."
        err "Platz schaffen (z. B. 'sudo apt clean') oder Swap von Hand vergrößern:"
        err "  sudo dphys-swapfile swapoff"
        err "  sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile"
        err "  sudo dphys-swapfile setup && sudo dphys-swapfile swapon"
        return 1
    fi

    info "Lege ${need} MB Auslagerungsdatei an (${BUILD_SWAPFILE}) – nur für den Build"
    if ! fallocate -l "${need}M" "$BUILD_SWAPFILE" 2>/dev/null; then
        dd if=/dev/zero of="$BUILD_SWAPFILE" bs=1M count="$need" status=none || {
            err "Konnte ${BUILD_SWAPFILE} nicht anlegen."
            return 1
        }
    fi
    chmod 600 "$BUILD_SWAPFILE"

    if ! mkswap "$BUILD_SWAPFILE" >/dev/null 2>&1 || ! swapon "$BUILD_SWAPFILE" 2>/dev/null; then
        rm -f "$BUILD_SWAPFILE"
        err "Auslagerungsdatei ließ sich nicht aktivieren (Dateisystem unterstützt das nicht?)."
        err "Bitte den Swap von Hand vergrößern:"
        err "  sudo dphys-swapfile swapoff"
        err "  sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile"
        err "  sudo dphys-swapfile setup && sudo dphys-swapfile swapon"
        return 1
    fi

    ok "Jetzt $(( $(ram_mb) + $(swap_mb) )) MB Speicher verfügbar"
    warn "Auslagern auf SD-Karte ist langsam – der Build dauert dadurch länger."
    return 0
}

# Auslagerungsdatei wieder abbauen (per trap am Ende des Builds).
release_build_memory() {
    if [ -e "$BUILD_SWAPFILE" ]; then
        swapoff "$BUILD_SWAPFILE" 2>/dev/null || true
        rm -f "$BUILD_SWAPFILE"
        info "Auslagerungsdatei wieder entfernt"
    fi
}

# --- Diverses --------------------------------------------------------------
# Sinnvolle Anzahl paralleler Compiler-Jobs.
# Die Sammeldateien von JUCE brauchen beim Übersetzen gut 1,5 GB pro Job –
# deshalb richtet sich die Parallelität nach dem echten RAM, nicht nach der
# Kernzahl. Die Auslagerungsdatei ist Reserve für Spitzen, keine Grundlage für
# mehr Jobs: Auslagern auf SD-Karte ist um Größenordnungen langsamer.
build_jobs() {
    local cpus mem_mb by_mem
    cpus="$(nproc 2>/dev/null || echo 2)"
    mem_mb="$(ram_mb)"
    by_mem=$(( mem_mb / 1500 ))
    [ "$by_mem" -lt 1 ] && by_mem=1
    if [ "$by_mem" -lt "$cpus" ]; then printf '%s' "$by_mem"; else printf '%s' "$cpus"; fi
}

# Wartet, bis ein TCP-Port erreichbar ist.
wait_for_port() {
    local host="$1" port="$2" timeout="${3:-60}" i
    for ((i = 0; i < timeout * 2; i++)); do
        if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
            exec 3<&- 2>/dev/null || true
            exec 3>&- 2>/dev/null || true
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# XML-Sonderzeichen maskieren.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# URL-Parameter maskieren (für den sonobus://-Link).
url_escape() {
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) out+="$(printf '%%%02X' "'$c")" ;;
        esac
    done
    printf '%s' "$out"
}

# Den sonobus://-Link für die Gruppe erzeugen.
sonobus_link() {
    local host="${1:-$AP_IP}" link
    link="sonobus://${host}:${SB_SERVER_PORT}/?g=$(url_escape "$SB_GROUP")"
    if [ -n "${SB_GROUP_PASSWORD:-}" ]; then
        link="${link}&p=$(url_escape "$SB_GROUP_PASSWORD")"
    fi
    printf '%s' "$link"
}
