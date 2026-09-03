#!/bin/bash
# Baut die SonoBus-Standalone-Anwendung (enthält den Headless-Modus) und
# installiert sie nach /usr/local/bin/sonobus.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=../lib/common.sh
. "${LIB_DIR}/common.sh"

need_root
load_config

REPO="https://github.com/sonosaurus/sonobus.git"
DIR="${SRC_DIR}/sonobus"
JOBS="$(build_jobs)"

install -d "$SRC_DIR"

if [ -d "${DIR}/.git" ]; then
    info "Aktualisiere Quellen in ${DIR}"
    git -C "$DIR" fetch --depth 1 origin "${SONOBUS_GIT_REF:-HEAD}"
    git -C "$DIR" checkout -f FETCH_HEAD
else
    info "Hole Quellen von ${REPO} (ca. 400 MB)"
    rm -rf "$DIR"
    if [ -n "${SONOBUS_GIT_REF:-}" ]; then
        git clone --depth 1 --branch "${SONOBUS_GIT_REF}" "$REPO" "$DIR"
    else
        git clone --depth 1 "$REPO" "$DIR"
    fi
fi

# Wenig RAM? Ohne Swap bricht der Compiler gerne mit "internal compiler error" ab.
mem_mb=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
swap_mb=$(( $(awk '/^SwapTotal:/ {print $2}' /proc/meminfo) / 1024 ))
if [ "$mem_mb" -lt 1800 ] && [ "$swap_mb" -lt 900 ]; then
    warn "Nur ${mem_mb} MB RAM und ${swap_mb} MB Swap – der Build kann scheitern."
    warn "Empfehlung: Swap vergrößern (/etc/dphys-swapfile: CONF_SWAPSIZE=2048,"
    warn "danach 'sudo systemctl restart dphys-swapfile')."
fi

# SonoBus baut mit JUCE_JACK=1 – ohne diese Header bricht der Build mittendrin ab.
if [ ! -f /usr/include/jack/jack.h ] && ! compgen -G "/usr/include/*/jack/jack.h" >/dev/null; then
    die "jack/jack.h fehlt – bitte 'sudo apt install libjack-jackd2-dev' ausführen."
fi

info "Konfiguriere Build (cmake)"
cmake -DCMAKE_BUILD_TYPE=Release -B "${DIR}/build" -S "$DIR"

info "Baue SonoBus mit ${JOBS} Job(s) – auf einem Pi 4 typischerweise 30-60 Minuten"
cmake --build "${DIR}/build" --target SonoBus_Standalone --config Release -j "$JOBS"

BIN="${DIR}/build/SonoBus_artefacts/Release/Standalone/sonobus"
[ -x "$BIN" ] || BIN="${DIR}/build/SonoBus_artefacts/Standalone/sonobus"
[ -x "$BIN" ] || die "Gebautes Binary nicht gefunden (erwartet unter ${DIR}/build/SonoBus_artefacts/...)"

install -m 755 "$BIN" "${PREFIX}/bin/sonobus"
ok "installiert: ${PREFIX}/bin/sonobus"
