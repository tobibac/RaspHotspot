#!/usr/bin/env python3
"""Prüft das Konfigurationsschema – vor allem, dass nichts durchrutscht,
was später als root ausgeführt werden könnte."""

import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "lib"))

import rasphotspot_config as schema  # noqa: E402

fails = 0


def check(description, actual, expected):
    global fails
    if actual == expected:
        print(f"  ok   {description}")
    else:
        print(f"  FEHL {description}\n       ist:  {actual!r}\n       soll: {expected!r}")
        fails += 1


BASE = {
    "AP_SSID": "Test", "AP_PASSWORD": "", "AP_BAND": "bg", "AP_CHANNEL": "6",
    "AP_IP": "10.42.0.1", "SB_GROUP": "Gruppe", "SERVICE_USER": "sonobus",
}

print("Abwehr gefährlicher Eingaben")
for evil in ['a"; reboot', "a`id`", "a$(id)", "a\\b", "a\nAP_IP=1.2.3.4"]:
    _, errors = schema.validate({"AP_SSID": evil}, BASE)
    check(f"abgelehnt: {evil!r}", bool(errors), True)

checked, _ = schema.validate({"SERVICE_USER": "root", "SB_JITTER_MS": "12"}, BASE)
check("gesperrter Schlüssel wird verworfen", "SERVICE_USER" in checked, False)
check("erlaubter Schlüssel kommt durch", checked.get("SB_JITTER_MS"), "12")

print("Regeln für einzelne Felder")
_, errors = schema.validate({"AP_PASSWORD": "kurz"}, BASE)
check("WPA-Passwort zu kurz", len(errors), 1)
checked, errors = schema.validate({"AP_PASSWORD": "langgenug1"}, BASE)
check("WPA-Passwort mit 10 Zeichen", errors, [])
checked, errors = schema.validate({"AP_PASSWORD": ""}, BASE)
check("leeres Passwort = offenes Netz", errors, [])

_, errors = schema.validate({"AP_BAND": "bg", "AP_CHANNEL": "36"}, BASE)
check("Kanal 36 auf 2,4 GHz abgelehnt", len(errors), 1)
_, errors = schema.validate({"AP_BAND": "a", "AP_CHANNEL": "36"}, BASE)
check("Kanal 36 auf 5 GHz erlaubt", errors, [])

_, errors = schema.validate({"AP_IP": "999.1.1.1"}, BASE)
check("unsinnige IP abgelehnt", len(errors), 1)
_, errors = schema.validate({"SB_SERVER_PORT": "80"}, BASE)
check("Port unter 1024 abgelehnt", len(errors), 1)
_, errors = schema.validate({"SB_SEND_FORMAT": "mp3"}, BASE)
check("unbekanntes Format abgelehnt", len(errors), 1)
_, errors = schema.validate({"SB_BUFFER_SIZE": "128"}, BASE)
check("gültiger Puffer akzeptiert", errors, [])
_, errors = schema.validate({"SB_ENABLE_OUTPUT": "vielleicht"}, BASE)
check("Ja/Nein-Feld prüft den Wert", len(errors), 1)
_, errors = schema.validate({"AP_SSID": ""}, BASE)
check("leerer Pflichtwert abgelehnt", len(errors), 1)
_, errors = schema.validate({"PORTAL_NOTE": ""}, BASE)
check("leerer optionaler Wert erlaubt", errors, [])
_, errors = schema.validate({"AP_SSID": "x" * 33}, BASE)
check("SSID über 32 Zeichen abgelehnt", len(errors), 1)

print("Schreiben der Konfiguration")
template = os.path.join(ROOT, "config.env.example")
values = schema.read_conf(template)
values.update({"AP_SSID": "Neuer Name", "SB_GROUP": "NeueGruppe"})
rendered = schema.render_conf(template, values)

with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as handle:
    handle.write(rendered)
    written = handle.name

again = schema.read_conf(written)
check("neuer Wert steht drin", again.get("AP_SSID"), "Neuer Name")
check("anderer Wert unverändert", again.get("SERVICE_USER"), "sonobus")
check("Kommentare bleiben erhalten",
      rendered.count("#") >= open(template).read().count("#"), True)
check("jede Zeile ist Kommentar, leer oder KEY=\"wert\"",
      all(line.startswith("#") or not line.strip()
          or (line.split("=", 1)[1].startswith('"') and line.rstrip().endswith('"'))
          for line in rendered.splitlines()), True)
os.unlink(written)

print("Betroffene Bereiche")
check("SSID-Änderung betrifft das Netz",
      schema.what_changed({"AP_SSID": "alt"}, {"AP_SSID": "neu"}), {"netzwerk"})
check("Formatwechsel betrifft den Ton",
      schema.what_changed({"SB_SEND_FORMAT": "pcm16"}, {"SB_SEND_FORMAT": "opus96"}), {"audio"})
check("unveränderter Wert löst nichts aus",
      schema.what_changed({"SB_GROUP": "a"}, {"SB_GROUP": "a"}), set())

sys.exit(1 if fails else 0)
