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

echo "Latenz-Zuordnungen"
check "pcm16 -> Index 8"   "$(send_format_index pcm16)"  "8"
check "pcm24 -> Index 9"   "$(send_format_index pcm24)"  "9"
check "opus96 -> Index 4"  "$(send_format_index opus96)" "4"
check "opus16 -> Index 0"  "$(send_format_index opus16)" "0"
check "Unfug -> pcm16"     "$(send_format_index unfug)"  "8"
check "Unfug meldet Fehler" "$(send_format_index unfug >/dev/null; echo $?)" "1"
check "auto-full -> 2"     "$(jitter_mode_index auto-full)" "2"
check "auto-up -> 1"       "$(jitter_mode_index auto-up)"   "1"
check "off -> 0"           "$(jitter_mode_index off)"       "0"
check "Standard ist pcm16 (kein Codec-Delay)" \
      "$(grep -c '^SB_SEND_FORMAT="pcm16"' "${ROOT}/config.env.example")" "1"

echo "Begrüßungsseite (Captive Portal)"
portal_conf="$(mktemp)"
# freien Port vom Betriebssystem geben lassen, damit parallele Läufe sich nicht stören
portal_port="$(python3 -c "
import socket
s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()
")"
cat > "$portal_conf" <<CONF
AP_IP="10.42.0.1"
AP_SSID="TestWLAN"
SB_SERVER_PORT="10998"
SB_GROUP="Arizona & Co"
SB_GROUP_PASSWORD=""
SB_USERNAME="MixPre-10T"
PORTAL_ENABLE="yes"
PORTAL_PORT="${portal_port}"
PORTAL_TITLE="Live-Ton"
PORTAL_NOTE=""
CONF

RASPHOTSPOT_CONF="$portal_conf" \
RASPHOTSPOT_PORTAL_TEMPLATE="${ROOT}/portal/portal.html" \
    "${ROOT}/bin/rasphotspot-portal" >/dev/null 2>&1 &
portal_pid=$!
sleep 2

fetch() {  # fetch <pfad> -> "status<TAB>body"
    python3 - "$1" "$portal_port" <<'PYEOF'
import sys, urllib.request, urllib.error
path, port = sys.argv[1], sys.argv[2]
req = urllib.request.Request(f"http://127.0.0.1:{port}{path}")
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
op = urllib.request.build_opener(NoRedirect)
try:
    r = op.open(req, timeout=5)
    print(f"{r.status}\t{r.read().decode('utf-8', 'replace')}")
except urllib.error.HTTPError as e:
    print(f"{e.code}\t{e.headers.get('Location', '')}")
except Exception as e:
    print(f"000\t{e}")
PYEOF
}

# Statuszeile ist die erste Zeile der Antwort, davor das Feld vor dem Tab.
status_of() { fetch "$1" | head -1 | cut -f1; }

if kill -0 "$portal_pid" 2>/dev/null; then
    root_resp="$(fetch /)"
    check "Startseite liefert 200"      "$(status_of /)" "200"
    check "keine Platzhalter uebrig" \
          "$(printf '%s' "$root_resp" | grep -c '@[A-Z_]\+@')" "0"
    check "Verbindungslink stimmt" \
          "$(printf '%s' "$root_resp" | grep -o 'sonobus://10.42.0.1:10998/?g=Arizona%20%26%20Co' | head -1)" \
          "sonobus://10.42.0.1:10998/?g=Arizona%20%26%20Co"
    check "Sonderzeichen sind HTML-maskiert" \
          "$(printf '%s' "$root_resp" | grep -c 'Arizona & Co')" "0"
    check "maskierte Fassung kommt vor" \
          "$([ "$(printf '%s' "$root_resp" | grep -c 'Arizona &amp; Co')" -ge 1 ] && echo ja)" "ja"
    check "Android-Test wird umgeleitet (302)" \
          "$(status_of /generate_204)" "302"
    check "Umleitung zeigt auf den Pi" \
          "$(fetch /generate_204 | head -1 | cut -f2)" "http://10.42.0.1/"
    check "Apple-Test bekommt die Seite" \
          "$(status_of /hotspot-detect.html)" "200"
    check "Apple-Test enthaelt KEIN Success" \
          "$(fetch /hotspot-detect.html | grep -ci 'success')" "0"
    check "beliebige URL liefert die Seite" \
          "$(status_of /irgendwas)" "200"
    check "Playstore-Link ist die echte Paket-ID" \
          "$(printf '%s' "$root_resp" | grep -c 'id=com.sonosaurus.sonobus')" "1"
    # Beendet sich der Dienst auf SIGTERM sauber? (Regression: shutdown()
    # aus dem Signalhandler im selben Thread verklemmt sich.)
    kill -TERM "$portal_pid" 2>/dev/null
    stopped="nein"
    for _ in $(seq 1 20); do
        kill -0 "$portal_pid" 2>/dev/null || { stopped="ja"; break; }
        sleep 0.25
    done
    check "beendet sich auf SIGTERM" "$stopped" "ja"
    kill -9 "$portal_pid" 2>/dev/null
    wait "$portal_pid" 2>/dev/null
else
    check "Portal startet" "nein (Port ${portal_port} belegt?)" "ja"
fi
rm -f "$portal_conf"

echo "Build-Parallelität"
check "mindestens 1 Job" "$([ "$(build_jobs)" -ge 1 ] && echo ja)" "ja"

echo ""
if [ "$fails" -eq 0 ]; then
    echo "Alle Tests bestanden."
else
    echo "${fails} Test(s) fehlgeschlagen."
    exit 1
fi
