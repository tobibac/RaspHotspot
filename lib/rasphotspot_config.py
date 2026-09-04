"""Schema und Prüfung der RaspHotspot-Konfiguration.

Wird von zwei Seiten benutzt:

* ``rasphotspot-portal``  – unprivilegiert, baut daraus das Web-Formular und
  prüft die Eingaben ein erstes Mal (für verständliche Fehlermeldungen).
* ``rasphotspot-apply``   – läuft als root und prüft *nochmal* alles selbst,
  bevor etwas in die Konfiguration geschrieben wird.

Die zweite Prüfung ist der eigentliche Schutz: die Konfigurationsdatei wird von
Root-Skripten mit ``source`` eingelesen und von systemd als EnvironmentFile
benutzt. Ein Wert, der Anführungszeichen oder ``$`` enthält, wäre damit eine
Einladung zur Befehlsausführung als root. Deshalb kommen hier nur Werte durch,
die einem engen Muster entsprechen – alles andere wird abgelehnt, nicht
"repariert".
"""

import ipaddress
import re

# Zeichen, die in keinem Wert vorkommen dürfen: sie hätten in der von bash
# gelesenen Datei eine Sonderbedeutung.
FORBIDDEN = re.compile(r'["\\$`\r\n\x00]')

SEND_FORMATS = [
    ("pcm16", "PCM 16 Bit – kürzeste Latenz, ~1,5 Mbit/s je Zuhörer"),
    ("pcm24", "PCM 24 Bit – wie pcm16, mehr Bandbreite"),
    ("pcm32", "PCM 32 Bit"),
    ("opus256", "Opus 256 kbit/s"),
    ("opus160", "Opus 160 kbit/s"),
    ("opus128", "Opus 128 kbit/s"),
    ("opus96", "Opus 96 kbit/s – guter Kompromiss bei vielen Zuhörern"),
    ("opus64", "Opus 64 kbit/s"),
    ("opus48", "Opus 48 kbit/s"),
    ("opus24", "Opus 24 kbit/s"),
    ("opus16", "Opus 16 kbit/s – sparsamste Einstellung, +20 ms"),
]

JITTER_MODES = [
    ("auto-full", "automatisch, wächst und schrumpft (empfohlen)"),
    ("auto-up", "automatisch, wächst nur"),
    ("initial", "einmalig beim Verbinden messen"),
    ("off", "fester Wert"),
]


class Field:
    """Ein Konfigurationsfeld: wie es heißt, was erlaubt ist, was es auslöst."""

    def __init__(self, key, label, kind, group, applies,
                 help="", choices=None, minimum=None, maximum=None,
                 max_length=None, allow_empty=False, pattern=None):
        self.key = key
        self.label = label
        self.kind = kind            # text | password | int | choice | bool
        self.group = group          # netzwerk | sonobus | audio | seite
        self.applies = applies      # netzwerk | audio | seite
        self.help = help
        self.choices = choices or []
        self.minimum = minimum
        self.maximum = maximum
        self.max_length = max_length
        self.allow_empty = allow_empty
        self.pattern = re.compile(pattern) if pattern else None

    def check(self, value):
        """Gibt den geprüften Wert zurück oder wirft ValueError."""
        value = "" if value is None else str(value).strip()

        if FORBIDDEN.search(value):
            raise ValueError(
                f"{self.label}: Anführungszeichen, Backslash, $ und ` sind nicht erlaubt"
            )

        if value == "":
            if self.allow_empty:
                return ""
            raise ValueError(f"{self.label}: darf nicht leer sein")

        if self.max_length and len(value.encode("utf-8")) > self.max_length:
            raise ValueError(f"{self.label}: höchstens {self.max_length} Zeichen")

        if self.kind == "int":
            if not re.fullmatch(r"\d+", value):
                raise ValueError(f"{self.label}: bitte eine Zahl eingeben")
            number = int(value)
            if self.minimum is not None and number < self.minimum:
                raise ValueError(f"{self.label}: mindestens {self.minimum}")
            if self.maximum is not None and number > self.maximum:
                raise ValueError(f"{self.label}: höchstens {self.maximum}")
            return str(number)

        if self.kind == "choice":
            allowed = [c[0] for c in self.choices]
            if value not in allowed:
                raise ValueError(f"{self.label}: unbekannter Wert '{value}'")
            return value

        if self.kind == "bool":
            if value not in ("yes", "no"):
                raise ValueError(f"{self.label}: nur 'yes' oder 'no'")
            return value

        if self.pattern and not self.pattern.fullmatch(value):
            raise ValueError(f"{self.label}: ungültige Eingabe")

        return value


def _ip_field(key, label, group, applies, help=""):
    return Field(key, label, "text", group, applies, help=help,
                 pattern=r"(?:\d{1,3}\.){3}\d{1,3}", max_length=15)


FIELDS = [
    # --- WLAN ---------------------------------------------------------------
    Field("AP_SSID", "WLAN-Name (SSID)", "text", "netzwerk", "netzwerk",
          max_length=32,
          help="So heißt das Netz, das der Pi aufspannt."),
    Field("AP_PASSWORD", "WLAN-Passwort", "password", "netzwerk", "netzwerk",
          allow_empty=True, max_length=63,
          help="Leer lassen für ein offenes Netz. Sonst 8 bis 63 Zeichen (WPA2)."),
    Field("AP_COUNTRY", "Funkland", "text", "netzwerk", "netzwerk",
          pattern=r"[A-Za-z]{2}", max_length=2,
          help="Zwei Buchstaben, z. B. DE. Legt die erlaubten Kanäle fest."),
    Field("AP_BAND", "Frequenzband", "choice", "netzwerk", "netzwerk",
          choices=[("a", "5 GHz – mehr Bandbreite (nicht auf jedem Pi)"),
                   ("bg", "2,4 GHz – mehr Reichweite, überall verfügbar")],
          help="Kann der Pi kein 5 GHz, schaltet er selbst auf 2,4 GHz um."),
    Field("AP_CHANNEL", "Kanal", "int", "netzwerk", "netzwerk",
          minimum=1, maximum=196,
          help="2,4 GHz: 1, 6 oder 11. 5 GHz: 36, 40, 44 oder 48."),
    _ip_field("AP_IP", "Adresse des Pi", "netzwerk", "netzwerk",
              "Unter dieser Adresse erreichst du Anleitung und Einstellungen."),

    # --- SonoBus ------------------------------------------------------------
    Field("SB_GROUP", "Gruppenname", "text", "sonobus", "audio",
          max_length=64,
          help="Diese Gruppe betreten die Zuhörer in SonoBus."),
    Field("SB_GROUP_PASSWORD", "Gruppenpasswort", "password", "sonobus", "audio",
          allow_empty=True, max_length=64,
          help="Leer lassen, wenn jeder beitreten darf."),
    Field("SB_USERNAME", "Name des Pi in der Gruppe", "text", "sonobus", "audio",
          max_length=64,
          help="So taucht der Ton in der Teilnehmerliste auf."),
    Field("SB_SERVER_PORT", "Port des Verbindungsservers", "int", "sonobus", "audio",
          minimum=1024, maximum=65535,
          help="Nur ändern, wenn 10998 belegt ist."),

    # --- Klang und Latenz ---------------------------------------------------
    Field("SB_SEND_FORMAT", "Sendeformat", "choice", "audio", "audio",
          choices=SEND_FORMATS,
          help="PCM ist am schnellsten, Opus spart Funkbandbreite."),
    Field("SB_BUFFER_SIZE", "Audiopuffer", "choice", "audio", "audio",
          choices=[("64", "64 Samples – 1,3 ms, nur für starke Pis"),
                   ("128", "128 Samples – 2,7 ms (empfohlen)"),
                   ("256", "256 Samples – 5,3 ms, stabiler"),
                   ("512", "512 Samples – 10,7 ms"),
                   ("1024", "1024 Samples – 21,3 ms, sehr stabil")],
          help="Kleiner heißt weniger Verzögerung, aber mehr Aussetzerrisiko."),
    Field("SB_SAMPLE_RATE", "Samplerate", "choice", "audio", "audio",
          choices=[("48000", "48 kHz (empfohlen)"), ("44100", "44,1 kHz")],
          help="Muss zur Einstellung am MixPre passen."),
    Field("SB_JITTER_MS", "Jitterpuffer (ms)", "int", "audio", "audio",
          minimum=0, maximum=500,
          help="Startwert. SonoBus regelt ihn danach selbst nach."),
    Field("SB_JITTER_MODE", "Jitterpuffer regeln", "choice", "audio", "audio",
          choices=JITTER_MODES),
    Field("SB_INPUT_FIRST_CHANNEL", "Erster Eingangskanal", "int", "audio", "audio",
          minimum=1, maximum=32,
          help="MixPre-10T: 1 ist die Stereo-Mischung, ab 3 die ISO-Spuren."),
    Field("SB_INPUT_CHANNELS", "Anzahl Kanäle", "int", "audio", "audio",
          minimum=1, maximum=32,
          help="2 für Stereo."),
    Field("SB_ENABLE_OUTPUT", "Rückweg zum MixPre", "bool", "audio", "audio",
          help="Gibt den Ton der anderen auf den USB-Rückkanälen aus."),
    Field("AUDIO_CARD_MATCH", "Audiogerät (Suchmuster)", "text", "audio", "audio",
          max_length=64, pattern=r"[A-Za-z0-9 ._\-]+",
          help="Teil des Namens der Soundkarte, z. B. MixPre."),
    Field("AUDIO_PCM_TYPE", "ALSA-Zugriff", "choice", "audio", "audio",
          choices=[("hw", "direkt – beste Latenz, feste Kanalzuordnung"),
                   ("plug", "mit Umwandlung – robuster bei zickigen Geräten")]),

    # --- Begrüßungsseite ----------------------------------------------------
    Field("PORTAL_ENABLE", "Begrüßungsseite zeigen", "bool", "seite", "netzwerk",
          help="Öffnet sich beim Einbuchen automatisch."),
    Field("PORTAL_TITLE", "Überschrift", "text", "seite", "seite",
          max_length=60),
    Field("PORTAL_NOTE", "Zusatzhinweis", "text", "seite", "seite",
          allow_empty=True, max_length=300,
          help="Erscheint oben auf der Seite, z. B. „Soundcheck ab 18 Uhr“."),
]

FIELDS_BY_KEY = {f.key: f for f in FIELDS}

GROUPS = [
    ("netzwerk", "WLAN"),
    ("sonobus", "SonoBus-Gruppe"),
    ("audio", "Ton und Latenz"),
    ("seite", "Begrüßungsseite"),
]

CONF_LINE = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*"?(.*?)"?\s*$')


def read_conf(path):
    """Liest KEY="wert"-Zeilen. Unbekannte Schlüssel bleiben erhalten."""
    conf = {}
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            match = CONF_LINE.match(line)
            if match:
                conf[match.group(1)] = match.group(2)
    return conf


def validate(values, current=None):
    """Prüft ein Dict {schlüssel: wert}.

    Rückgabe: (geprüfte_werte, fehler). Nur bekannte Schlüssel werden
    übernommen – alles andere fliegt kommentarlos raus, damit über das
    Formular niemand an Feldern wie SERVICE_USER drehen kann.
    """
    checked = {}
    errors = []

    for key, raw in values.items():
        field = FIELDS_BY_KEY.get(key)
        if field is None:
            continue
        try:
            checked[key] = field.check(raw)
        except ValueError as exc:
            errors.append(str(exc))

    merged = dict(current or {})
    merged.update(checked)

    # Zusammenhänge, die sich erst aus mehreren Feldern ergeben
    password = merged.get("AP_PASSWORD", "")
    if password and not 8 <= len(password) <= 63:
        errors.append("WLAN-Passwort: WPA2 verlangt 8 bis 63 Zeichen "
                      "(oder ganz leer für ein offenes Netz)")

    band = merged.get("AP_BAND", "bg")
    try:
        channel = int(merged.get("AP_CHANNEL", "6"))
    except ValueError:
        channel = 6
    if band == "bg" and not 1 <= channel <= 14:
        errors.append("Kanal: auf 2,4 GHz sind nur 1 bis 14 möglich")
    if band == "a" and channel < 32:
        errors.append("Kanal: auf 5 GHz beginnen die Kanäle bei 36")

    for key in ("AP_IP",):
        if key in merged:
            try:
                ipaddress.IPv4Address(merged[key])
            except ValueError:
                errors.append(f"{FIELDS_BY_KEY[key].label}: keine gültige IP-Adresse")

    return checked, errors


def render_conf(template_path, values):
    """Schreibt die Vorlage neu, mit den Werten aus ``values``."""
    lines = []
    with open(template_path, "r", encoding="utf-8") as handle:
        for line in handle:
            match = re.match(r"^([A-Z_][A-Z0-9_]*)=", line)
            if match and match.group(1) in values:
                key = match.group(1)
                lines.append(f'{key}="{values[key]}"\n')
            else:
                lines.append(line)
    return "".join(lines)


def what_changed(old, new):
    """Welche Bereiche sind von den Änderungen betroffen?"""
    areas = set()
    for key, value in new.items():
        if old.get(key) != value:
            field = FIELDS_BY_KEY.get(key)
            if field:
                areas.add(field.applies)
    return areas
