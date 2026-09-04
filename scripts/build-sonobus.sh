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

# --- Vorflug: genug Speicher? -----------------------------------------------
# Das muss vor dem Klonen passieren, damit ein Abbruch nicht erst nach 400 MB
# Download kommt.
ensure_build_memory "${BUILD_MEMORY_MB:-4096}" || \
    die "Zu wenig Speicher für den SonoBus-Build – siehe Hinweise oben."
trap release_build_memory EXIT INT TERM

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

# Den Speicherhunger von GCC etwas zügeln. Das wirkt auch im
# juceaide-Unterbau, weil CMake beim ersten Konfigurieren CXXFLAGS aus der
# Umgebung übernimmt – Flags über die Kommandozeile kommen dort nicht an.
export CXXFLAGS="${CXXFLAGS:-} --param ggc-min-expand=10 --param ggc-min-heapsize=32768"
export CFLAGS="${CFLAGS:-} --param ggc-min-expand=10 --param ggc-min-heapsize=32768"

# Ein abgebrochenes "cmake" hinterlässt einen Cache, aber kein Makefile – und
# dieser halbe Cache übernimmt unsere Umgebung nicht mehr. Dann lieber neu
# anfangen. Bereits übersetzte Dateien (Makefile vorhanden) bleiben natürlich
# liegen, damit ein unterbrochener Build weiterlaufen kann statt von vorn.
if [ -f "${DIR}/build/CMakeCache.txt" ] && [ ! -f "${DIR}/build/Makefile" ]; then
    warn "Abgebrochenes cmake gefunden – räume ${DIR}/build und fange neu an."
    rm -rf "${DIR}/build"
fi

info "Konfiguriere Build (cmake)"
if ! cmake -DCMAKE_BUILD_TYPE=Release -B "${DIR}/build" -S "$DIR"; then
    warn "cmake ist gescheitert – versuche es einmal mit leerem Build-Verzeichnis."
    rm -rf "${DIR}/build"
    cmake -DCMAKE_BUILD_TYPE=Release -B "${DIR}/build" -S "$DIR"
fi

if [ "$(ram_mb)" -lt 1500 ]; then
    info "Baue SonoBus mit ${JOBS} Job(s) – mit nur $(ram_mb) MB RAM dauert das"
    info "mehrere Stunden. Am besten über Nacht laufen lassen (oder --sonobus-deb)."
else
    info "Baue SonoBus mit ${JOBS} Job(s) – auf einem Pi typischerweise 30-90 Minuten"
fi
cmake --build "${DIR}/build" --target SonoBus_Standalone --config Release -j "$JOBS"

BIN="${DIR}/build/SonoBus_artefacts/Release/Standalone/sonobus"
[ -x "$BIN" ] || BIN="${DIR}/build/SonoBus_artefacts/Standalone/sonobus"
[ -x "$BIN" ] || die "Gebautes Binary nicht gefunden (erwartet unter ${DIR}/build/SonoBus_artefacts/...)"

install -m 755 "$BIN" "${PREFIX}/bin/sonobus"
ok "installiert: ${PREFIX}/bin/sonobus"
