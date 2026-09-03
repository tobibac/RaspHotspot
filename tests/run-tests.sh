#!/bin/bash
# Prüft die Hilfsfunktionen aus lib/common.sh gegen feste Testdaten.
# Aufruf: ./tests/run-tests.sh   (braucht kein root, ändert nichts am System)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

export ASOUND_DIR="${HERE}/fixtures/asound"
# shellcheck source=../lib/common.sh
. "${ROOT}/lib/common.sh"

fails=0
check() { # check <beschreibung> <ist> <soll>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FEHL %s\n       ist:  %s\n       soll: %s\n' "$1" "$2" "$3"
        fails=$((fails + 1))
    fi
}

echo "Soundkarten-Erkennung"
check "Karten werden gelistet" \
      "$(list_audio_cards | wc -l)" "2"
check "MixPre wird gefunden" \
      "$(detect_audio_card MixPre | cut -f2)" "MixPre10T"
check "Index stimmt" \
      "$(detect_audio_card MixPre | cut -f1)" "1"
check "Suche ist unabhängig von Groß-/Kleinschreibung" \
      "$(detect_audio_card mixpre | cut -f2)" "MixPre10T"
check "ohne Treffer: erste USB-Karte mit Eingang" \
      "$(detect_audio_card GibtEsNicht | cut -f2)" "MixPre10T"
check "Beschreibung wird mitgeliefert" \
      "$(detect_audio_card MixPre | cut -f3)" "USB-Audio - MixPre-10T"

echo "Kanalmasken (JUCE, binär MSB-first)"
check "Kanal 1-2"  "$(channel_bitmask 1 2)" "11"
check "Kanal 1-4"  "$(channel_bitmask 1 4)" "1111"
check "Kanal 3-4"  "$(channel_bitmask 3 2)" "1100"
check "Kanal 5"    "$(channel_bitmask 5 1)" "10000"

echo "Verbindungslink"
AP_IP="10.42.0.1"; SB_SERVER_PORT="10998"; SB_GROUP="ArizonaArizona"; SB_GROUP_PASSWORD=""
check "einfacher Link" \
      "$(sonobus_link)" "sonobus://10.42.0.1:10998/?g=ArizonaArizona"
SB_GROUP="Arizona Arizona"
check "Leerzeichen werden kodiert" \
      "$(sonobus_link)" "sonobus://10.42.0.1:10998/?g=Arizona%20Arizona"
SB_GROUP="ArizonaArizona"; SB_GROUP_PASSWORD="geheim&1"
check "Passwort wird angehängt und kodiert" \
      "$(sonobus_link)" "sonobus://10.42.0.1:10998/?g=ArizonaArizona&p=geheim%261"
SB_GROUP_PASSWORD=""

echo "XML-Maskierung"
check "Sonderzeichen" "$(xml_escape 'A & <B> "C"')" 'A &amp; &lt;B&gt; &quot;C&quot;'

echo "Konfiguration erzeugen"
tmp="$(mktemp -d)"
AP_SSID="TestWLAN"; SB_GROUP="TestGruppe"; SB_INPUT_CHANNELS="4"
render_config "${ROOT}/config.env.example" "${tmp}/conf" 2>/dev/null
check "SSID übernommen"     "$(grep '^AP_SSID=' "${tmp}/conf")"          'AP_SSID="TestWLAN"'
check "Gruppe übernommen"   "$(grep '^SB_GROUP=' "${tmp}/conf")"         'SB_GROUP="TestGruppe"'
check "Kanäle übernommen"   "$(grep '^SB_INPUT_CHANNELS=' "${tmp}/conf")" 'SB_INPUT_CHANNELS="4"'
check "Kommentare bleiben"  "$([ "$(grep -c '^#' "${tmp}/conf")" -gt 20 ] && echo ja)" "ja"
# Die erzeugte Datei muss sich sauber einlesen lassen (bash und systemd).
( set -e; . "${tmp}/conf" ) >/dev/null 2>&1
check "Ergebnis ist gültige Shell-Syntax" "$?" "0"
check "keine Zeilenfortsetzung/Substitution" \
      "$(grep -cE '\$\(|`' "${tmp}/conf")" "0"
rm -rf "$tmp"

echo "Kommandozeilen-Format (JUCE nimmt Langoptionen nur als --option=wert)"
runner_sb="${ROOT}/bin/rasphotspot-sonobus-run"
runner_aoo="${ROOT}/bin/rasphotspot-aooserver-run"
check "SonoBus: --group="        "$(grep -c -- '"--group=\${SB_GROUP}"' "$runner_sb")" "1"
check "SonoBus: --username="     "$(grep -c -- '"--username=\${SB_USERNAME}"' "$runner_sb")" "1"
check "SonoBus: --connectionserver=" \
      "$(grep -c -- '"--connectionserver=127.0.0.1:\${SB_SERVER_PORT}"' "$runner_sb")" "1"
check "SonoBus: keine Langoption mit Leerzeichen" \
      "$(grep -cE '^\s+--[a-z-]+ +"' "$runner_sb")" "0"
check "aooserver: --port="       "$(grep -c -- '"--port=' "$runner_aoo")" "1"
check "aooserver: --logdir="     "$(grep -c -- '"--logdir=' "$runner_aoo")" "1"
check "aooserver: keine Langoption mit Leerzeichen" \
      "$(grep -cE '(args=\(|args\+=\()--[a-z-]+ ' "$runner_aoo")" "0"

echo "Build-Parallelität"
check "mindestens 1 Job" "$([ "$(build_jobs)" -ge 1 ] && echo ja)" "ja"

echo ""
if [ "$fails" -eq 0 ]; then
    echo "Alle Tests bestanden."
else
    echo "${fails} Test(s) fehlgeschlagen."
    exit 1
fi
