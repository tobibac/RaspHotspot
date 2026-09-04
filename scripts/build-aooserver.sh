#!/bin/bash
# Baut den AOO-Verbindungsserver (essej/aooserver) und installiert ihn nach
# /usr/local/bin/aooserver.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=../lib/common.sh
. "${LIB_DIR}/common.sh"

need_root
load_config

REPO="https://github.com/essej/aooserver.git"
DIR="${SRC_DIR}/aooserver"
JOBS="$(build_jobs)"

install -d "$SRC_DIR"

# aooserver ist deutlich genügsamer als SonoBus, aber auf einem 1-GB-Pi wird
# es auch hier knapp.
ensure_build_memory "${BUILD_MEMORY_MB_AOOSERVER:-2048}" || \
    die "Zu wenig Speicher für den aooserver-Build – siehe Hinweise oben."
trap release_build_memory EXIT INT TERM

if [ -d "${DIR}/.git" ]; then
    info "Aktualisiere Quellen in ${DIR}"
    git -C "$DIR" fetch --depth 1 origin "${AOOSERVER_GIT_REF:-HEAD}"
    git -C "$DIR" checkout -f FETCH_HEAD
else
    info "Hole Quellen von ${REPO}"
    rm -rf "$DIR"
    if [ -n "${AOOSERVER_GIT_REF:-}" ]; then
        git clone --depth 1 --branch "${AOOSERVER_GIT_REF}" "$REPO" "$DIR"
    else
        git clone --depth 1 "$REPO" "$DIR"
    fi
fi

info "Baue aooserver mit ${JOBS} Job(s) – das dauert auf einem Pi ein paar Minuten"
make -C "${DIR}/Builds/LinuxMakefile" CONFIG=Release -j "$JOBS"

install -m 755 "${DIR}/Builds/LinuxMakefile/build/aooserver" "${PREFIX}/bin/aooserver"
ok "installiert: ${PREFIX}/bin/aooserver"
