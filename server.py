#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Weather proxy service (Open-Meteo).

Single-process Python 3 stdlib HTTP server. No external dependencies.
Works identically on Alpine LXC and inside a Docker container.
"""

import hashlib
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
STATIC_DIR = os.path.join(BASE_DIR, "static")
DB_PATH = os.path.join(BASE_DIR, "nebosvod.db")

SESSION_COOKIE = "neb_session"

SCRYPT_N = 16384
SCRYPT_R = 8
SCRYPT_P = 1

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
GEOCODE_SEARCH_URL = "https://geocoding-api.open-meteo.com/v1/search"
GEOCODE_GET_URL = "https://geocoding-api.open-meteo.com/v1/get"
NOMINATIM_REVERSE_URL = "https://nominatim.openstreetmap.org/reverse"

CURRENT_VARS = (
    "temperature_2m,apparent_temperature,relative_humidity_2m,pressure_msl,"
    "wind_speed_10m,wind_direction_10m,weather_code,precipitation,cloud_cover"
)
DAILY_VARS = (
    "temperature_2m_max,temperature_2m_min,sunrise,sunset,windspeed_10m_max,"
    "winddirection_10m_dominant,weather_code,precipitation_sum,"
    "precipitation_probability_max"
)
HOURLY_VARS = (
    "temperature_2m,relative_humidity_2m,pressure_msl,wind_speed_10m,"
    "wind_direction_10m,weather_code,precipitation,precipitation_probability"
)

USER_AGENT = "weather-proxy/1.0"

WEATHER_CODES = {
    0: "Ясно",
    1: "Преим. ясно",
    2: "Облачно",
    3: "Пасмурно",
    45: "Туман",
    48: "Гололёд",
    51: "Слабая морось",
    53: "Морось",
    55: "Сильная морось",
    56: "Ледяная крупа",
    57: "Ледяной дождь",
    61: "Небольшой дождь",
    63: "Дождь",
    65: "Ливень",
    66: "Дождь с гололёдом",
    67: "Сильный гололёд",
    71: "Неб. снег",
    73: "Снег",
    75: "Снегопад",
    77: "Снежная крупа",
    80: "Неб. ливень",
    81: "Ливень",
    82: "Сильный ливень",
    85: "Снегопад",
    86: "Сильный снег",
    95: "Гроза",
    96: "Гроза с градом",
    99: "Ураган",
}

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
}

COORD_RE = re.compile(
    r"""
    ^\s*
    (?:(?P<lat_hemi_lead>[NS])\s*)?
    (?P<lat>[-+]?\d{1,3}(?:\.\d+)?)
    (?:\s*°)?
    (?:\s*(?P<lat_hemi>[NS]))?
    (?:\s*[,;]\s*|\s+)
    (?:(?P<lon_hemi_lead>[EW])\s*)?
    (?P<lon>[-+]?\d{1,3}(?:\.\d+)?)
    (?:\s*°)?
    (?:\s*(?P<lon_hemi>[EW]))?
    \s*$
    """,
    re.IGNORECASE | re.VERBOSE,
)

# Administrative suffixes stripped from reverse-geocoded region names.
ADMIN_SUFFIXES = (
    "муниципальный округ",
    "городской округ",
    "муниципальный район",
    "сельское поселение",
    "городское поселение",
    "округ",
    "район",
)


# Degrees-minutes-seconds coordinates: "54°46′00″ с. ш. 20°36′00″ в. д.",
# "54°46′ с.ш. 20°36′ в.д.", "54°46′00″N 20°36′00″E",
# "54 46 00 N, 20 36 00 E", "54°46′00″ с. ш., 20°36′00″ в. д.".
# Tried after COORD_RE. Hemisphere may be latin N/S/E/W or Russian
# с.ш./ю.ш./в.д./з.д. with optional dots and spaces (normalized on match).
_HEMI_WORD = r"(?:[nswe]|[сювз]\s*\.?\s*[шд]\.?)"


def _axis_dms(prefix):
    return (
        r"(?P<{p}_deg>\d{{1,3}})"
        r"(?:"
        r"(?:\s*°\s*|\s+)"
        r"(?P<{p}_min>\d{{1,2}})"
        r"(?:"
        r"(?:\s*[′']\s*|\s+)"
        r"(?P<{p}_sec>\d{{1,2}}(?:\.\d+)?)"
        r"(?:\s*[″\"]\s*)?"
        r")?"
        r")?"
        r"(?:\s*[′']\s*)?"
        r"(?:\s*(?P<{p}_hemi>{hemi}))?"
    ).format(p=prefix, hemi=_HEMI_WORD)


COORD_DMS_RE = re.compile(
    r"^\s*"
    + _axis_dms("lat")
    + r"(?:\s*[,;]\s*|\s+)"
    + _axis_dms("lon")
    + r"\s*$",
    re.IGNORECASE | re.VERBOSE,
)


def _normalize_hemi(token):
    if not token:
        return ""
    t = re.sub(r"[.\s]", "", token).lower()
    return {
        "n": "N", "s": "S", "e": "E", "w": "W",
        "сш": "N", "юш": "S", "вд": "E", "зд": "W",
    }.get(t, "")


def _parse_dms(m):
    try:
        lat = float(m.group("lat_deg"))
        lon = float(m.group("lon_deg"))
    except (TypeError, ValueError):
        return None
    if m.group("lat_min"):
        lat += int(m.group("lat_min")) / 60.0
    if m.group("lat_sec"):
        lat += float(m.group("lat_sec")) / 3600.0
    if m.group("lon_min"):
        lon += int(m.group("lon_min")) / 60.0
    if m.group("lon_sec"):
        lon += float(m.group("lon_sec")) / 3600.0
    lat_hemi = _normalize_hemi(m.group("lat_hemi"))
    lon_hemi = _normalize_hemi(m.group("lon_hemi"))
    if lat_hemi == "S":
        lat = -lat
    if lon_hemi == "W":
        lon = -lon
    return lat, lon


def parse_coords(q):
    """Parse a coordinate query into (latitude, longitude), or None.

    Accepts decimal-degree forms like "58.705° N, 59.485° E",
    "58.705N 59.485E", "N 58.705, E 59.485" and "58.705, 59.485", plus
    degrees-minutes-seconds forms with latin or Russian hemisphere markers
    ("54°46′00″ с. ш. 20°36′00″ в. д."). S/ю.ш. → negative latitude,
    W/з.д. → negative longitude.
    """
    q = q or ""
    m = COORD_RE.match(q)
    if m:
        try:
            lat = float(m.group("lat"))
            lon = float(m.group("lon"))
        except (TypeError, ValueError):
            return None
        lat_hemi = (m.group("lat_hemi") or m.group("lat_hemi_lead") or "").upper()
        lon_hemi = (m.group("lon_hemi") or m.group("lon_hemi_lead") or "").upper()
        if lat_hemi == "S":
            lat = -abs(lat)
        if lon_hemi == "W":
            lon = -abs(lon)
        return lat, lon
    m = COORD_DMS_RE.match(q)
    if m:
        return _parse_dms(m)
    return None


TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def hash_password(password):
    """Return 'salt$hash' hex string (scrypt, stdlib)."""
    salt = secrets.token_hex(16)
    digest = hashlib.scrypt(
        password.encode("utf-8"),
        salt=bytes.fromhex(salt),
        n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P,
    ).hex()
    return salt + "$" + digest


def verify_password(password, stored):
    """Constant-time check of a password against a 'salt$hash' string."""
    try:
        salt_hex, digest_hex = stored.split("$", 1)
        digest = hashlib.scrypt(
            password.encode("utf-8"),
            salt=bytes.fromhex(salt_hex),
            n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P,
        ).hex()
        return secrets.compare_digest(digest, digest_hex)
    except (ValueError, TypeError):
        return False


class AuthStore:
    """SQLite-backed users, per-user city selection and sessions."""

    def __init__(self, db_path):
        self.db_path = db_path
        self.lock = threading.Lock()
        self._init_db()

    def _connect(self):
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self):
        with self.lock:
            conn = self._connect()
            try:
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS users ("
                    "id INTEGER PRIMARY KEY,"
                    "username TEXT UNIQUE NOT NULL,"
                    "password_hash TEXT NOT NULL,"
                    "created_at TEXT,"
                    "display_mode TEXT NOT NULL DEFAULT 'compact',"
                    "city_filter TEXT NOT NULL DEFAULT 'all'"
                    ")"
                )
                # Migration: add per-user display settings to older databases.
                cols = {
                    row["name"]
                    for row in conn.execute("PRAGMA table_info(users)").fetchall()
                }
                if "display_mode" not in cols:
                    conn.execute(
                        "ALTER TABLE users ADD COLUMN display_mode "
                        "TEXT NOT NULL DEFAULT 'compact'"
                    )
                if "city_filter" not in cols:
                    conn.execute(
                        "ALTER TABLE users ADD COLUMN city_filter "
                        "TEXT NOT NULL DEFAULT 'all'"
                    )
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS user_cities ("
                    "user_id INTEGER,"
                    "city_id INTEGER,"
                    "PRIMARY KEY(user_id, city_id)"
                    ")"
                )
                conn.execute(
                    "CREATE TABLE IF NOT EXISTS sessions ("
                    "token TEXT PRIMARY KEY,"
                    "username TEXT NOT NULL,"
                    "created_at TEXT"
                    ")"
                )
                conn.commit()
            finally:
                conn.close()

    # ---- users --------------------------------------------------------
    def create_user(self, username, password):
        """Create a user. Raises ValueError if the username already exists."""
        now = datetime.now(timezone.utc).isoformat()
        stored = hash_password(password)
        with self.lock:
            conn = self._connect()
            try:
                conn.execute(
                    "INSERT INTO users (username, password_hash, created_at)"
                    " VALUES (?, ?, ?)",
                    (username, stored, now),
                )
                conn.commit()
            except sqlite3.IntegrityError:
                raise ValueError("exists")
            finally:
                conn.close()
        return username

    def get_user(self, username):
        with self.lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT * FROM users WHERE username = ?", (username,)
                ).fetchone()
                return dict(row) if row else None
            finally:
                conn.close()

    # ---- sessions -----------------------------------------------------
    def create_session(self, username):
        token = secrets.token_hex(32)
        now = datetime.now(timezone.utc).isoformat()
        with self.lock:
            conn = self._connect()
            try:
                conn.execute(
                    "INSERT INTO sessions (token, username, created_at)"
                    " VALUES (?, ?, ?)",
                    (token, username, now),
                )
                conn.commit()
            finally:
                conn.close()
        return token

    def get_username_by_token(self, token):
        with self.lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT username FROM sessions WHERE token = ?", (token,)
                ).fetchone()
                return row["username"] if row else None
            finally:
                conn.close()

    def delete_session(self, token):
        with self.lock:
            conn = self._connect()
            try:
                conn.execute("DELETE FROM sessions WHERE token = ?", (token,))
                conn.commit()
            finally:
                conn.close()

    # ---- per-user cities ---------------------------------------------
    def get_user_cities(self, username):
        with self.lock:
            conn = self._connect()
            try:
                rows = conn.execute(
                    "SELECT uc.city_id FROM user_cities uc"
                    " JOIN users u ON u.id = uc.user_id"
                    " WHERE u.username = ? ORDER BY uc.city_id",
                    (username,),
                ).fetchall()
                return [int(r["city_id"]) for r in rows]
            finally:
                conn.close()

    def set_user_city(self, username, city_id, enabled):
        with self.lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT id FROM users WHERE username = ?", (username,)
                ).fetchone()
                if row is None:
                    return
                user_id = int(row["id"])
                if enabled:
                    conn.execute(
                        "INSERT OR IGNORE INTO user_cities (user_id, city_id)"
                        " VALUES (?, ?)",
                        (user_id, city_id),
                    )
                else:
                    conn.execute(
                        "DELETE FROM user_cities WHERE user_id = ? AND city_id = ?",
                        (user_id, city_id),
                    )
                conn.commit()
            finally:
                conn.close()

    # ---- per-user display settings ------------------------------------
    def get_display_prefs(self, username):
        with self.lock:
            conn = self._connect()
            try:
                row = conn.execute(
                    "SELECT display_mode, city_filter FROM users WHERE username = ?",
                    (username,),
                ).fetchone()
                if row is None:
                    return {"display_mode": "compact", "city_filter": "all"}
                return {
                    "display_mode": row["display_mode"] or "compact",
                    "city_filter": row["city_filter"] or "all",
                }
            finally:
                conn.close()

    def set_display_mode(self, username, mode):
        with self.lock:
            conn = self._connect()
            try:
                conn.execute(
                    "UPDATE users SET display_mode = ? WHERE username = ?",
                    (mode, username),
                )
                conn.commit()
            finally:
                conn.close()

    def set_city_filter(self, username, value):
        with self.lock:
            conn = self._connect()
            try:
                conn.execute(
                    "UPDATE users SET city_filter = ? WHERE username = ?",
                    (value, username),
                )
                conn.commit()
            finally:
                conn.close()


class OpenMeteoError(Exception):
    """Raised when Open-Meteo returns an error or is unreachable."""


def wind_rhumb(deg):
    """Map wind direction degrees to 8 Russian rhumbs."""
    if deg is None:
        return "Нет данных"
    d = float(deg)
    if d >= 337.0 or d < 23.0:
        return "С"
    if d < 68.0:
        return "СВ"
    if d < 113.0:
        return "В"
    if d < 158.0:
        return "ЮВ"
    if d < 203.0:
        return "Ю"
    if d < 248.0:
        return "ЮЗ"
    if d < 293.0:
        return "З"
    return "СЗ"


def condition_text(code):
    if code is None:
        return "Нет данных"
    return WEATHER_CODES.get(int(code), "Нет данных")


def severity(code):
    """Map a WMO weather code to a severity rank (higher = more severe)."""
    if code is None:
        return 0
    c = int(code)
    if c == 0:
        return 0
    if c == 1:
        return 1
    if c == 2:
        return 2
    if c == 3:
        return 3
    if c in (45, 48):
        return 4
    if 51 <= c <= 57:
        return 5
    if 61 <= c <= 67:
        return 6
    if 71 <= c <= 77:
        return 7
    if 80 <= c <= 82:
        return 8
    if c in (85, 86):
        return 9
    if c == 95:
        return 10
    if c in (96, 99):
        return 11
    return 0


def hpa_to_mmhg(hpa):
    if hpa is None:
        return 0
    return int(round(float(hpa) * 750062.0 / 1000000.0))


def round1(value):
    if value is None:
        return 0.0
    return round(float(value), 1)


def round_int(value):
    if value is None:
        return 0
    return int(round(float(value)))


def hhmm(value):
    """'2026-08-14T05:12' -> '05:12' (strip date part)."""
    if not value:
        return ""
    s = str(value)
    if "T" in s:
        return s.split("T", 1)[1][:5]
    return s[:5]


def fmt_updated_at(utc_offset_seconds):
    """ISO-8601 with the city's UTC offset, e.g. 2026-08-14T15:30:00+05:00."""
    off = int(utc_offset_seconds or 0)
    now = datetime.now(timezone.utc) + timedelta(seconds=off)
    sign = "+" if off >= 0 else "-"
    off = abs(off)
    return "{}{}{:02d}:{:02d}".format(
        now.strftime("%Y-%m-%dT%H:%M:%S"), sign, off // 3600, (off % 3600) // 60
    )


class WeatherService:
    def __init__(self):
        self.config = self._load_config()
        self.cache = {}                 # city_id -> {"fetched_at": ts, "data": {...}}
        self.cache_lock = threading.Lock()
        self.config_lock = threading.Lock()
        self.flight_locks = {}          # city_id -> Lock (single flight per city)
        self.flight_guard = threading.Lock()
        # ProxyHandler({}) bypasses env proxies (http_proxy / https_proxy / no_proxy).
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({})
        )

    # ---- config ---------------------------------------------------------
    def _load_config(self):
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)

    def save_config(self):
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(self.config, f, ensure_ascii=False, indent=2)
            f.write("\n")

    def get_locations(self):
        with self.config_lock:
            return [dict(c) for c in self.config["locations"]]

    def find_city(self, city_id=None, alias=None):
        with self.config_lock:
            locations = list(self.config["locations"])
        for loc in locations:
            if city_id is not None:
                try:
                    if int(loc.get("id")) == int(city_id):
                        return loc
                except (TypeError, ValueError):
                    pass
            if alias is not None:
                if loc.get("alias") == alias or loc.get("name") == alias:
                    return loc
        return None

    @property
    def cache_ttl(self):
        return int(self.config.get("cache_ttl", 1800))

    # ---- HTTP helpers ---------------------------------------------------
    def _get_json(self, url, timeout=10, headers=None, attempts=3, retry_delay=1.5):
        hdrs = {
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        }
        if headers:
            hdrs.update(headers)
        req = urllib.request.Request(url, headers=hdrs)
        for attempt in range(1, attempts + 1):
            retryable = True
            try:
                with self.opener.open(req, timeout=timeout) as resp:
                    raw = resp.read().decode("utf-8", "replace")
                return json.loads(raw)
            except urllib.error.HTTPError as e:
                # 4xx (bad params / unknown id) are permanent; only retry
                # 5xx and 429 (rate limit).
                retryable = e.code >= 500 or e.code == 429
                err = OpenMeteoError("Open-Meteo HTTP %s" % e.code)
            except urllib.error.URLError as e:
                err = OpenMeteoError("Open-Meteo unreachable: %s" % e.reason)
            except json.JSONDecodeError:
                err = OpenMeteoError("Invalid JSON from Open-Meteo")
            except Exception as e:  # noqa: BLE001 - defensive wrapper
                err = OpenMeteoError("Open-Meteo error: %s" % e)

            if not retryable or attempt >= attempts:
                raise err
            time.sleep(retry_delay * attempt)
        raise OpenMeteoError("Open-Meteo error")

    # ---- Open-Meteo -----------------------------------------------------
    def fetch_open_meteo(self, city):
        params = {
            "latitude": city["latitude"],
            "longitude": city["longitude"],
            "current": CURRENT_VARS,
            "daily": DAILY_VARS,
            "hourly": HOURLY_VARS,
            "past_days": 1,
            "windspeed_unit": "ms",
            "timezone": "auto",
        }
        url = FORECAST_URL + "?" + urllib.parse.urlencode(params)
        data = self._get_json(url)
        if data.get("error"):
            raise OpenMeteoError(data.get("reason", "Open-Meteo error"))
        return data

    def build_weather(self, city, om):
        current = om.get("current") or {}
        daily = om.get("daily") or {}
        hourly = om.get("hourly") or {}
        utc_off = om.get("utc_offset_seconds", 0)

        def daily_first(key):
            arr = daily.get(key)
            return arr[0] if arr else None

        cur_code = current.get("weather_code")
        day_code = daily_first("weather_code")

        # Night window: today's sunset -> tomorrow's sunrise (local time, no tz).
        # With past_days=1 the daily arrays start at yesterday, so sunset[1] is
        # today's sunset and sunrise[2] is tomorrow's sunrise.
        night_idxs = []
        if (
            isinstance(hourly.get("time"), list)
            and isinstance(daily.get("sunset"), list)
            and len(daily["sunset"]) > 1
            and isinstance(daily.get("sunrise"), list)
            and len(daily["sunrise"]) > 2
        ):
            try:
                start = datetime.fromisoformat(daily["sunset"][1])
                end = datetime.fromisoformat(daily["sunrise"][2])
                night_idxs = [
                    i for i, t in enumerate(hourly["time"])
                    if start <= datetime.fromisoformat(t) < end
                ]
            except (TypeError, ValueError):
                night_idxs = []

        def hour_vals(key):
            arr = hourly.get(key)
            if not isinstance(arr, list):
                return []
            return [arr[i] for i in night_idxs if i < len(arr) and arr[i] is not None]

        nightly = {
            "temperature_min": None,
            "temperature_max": None,
            "wind_speed_max": None,
            "wind_direction_dominant": "—",
            "pressure_mmhg": None,
            "condition": "—",
            "weather_code": None,
            "precipitation_probability": None,
            "precipitation_sum": None,
        }

        if night_idxs:
            temps = hour_vals("temperature_2m")
            winds = hour_vals("wind_speed_10m")
            winddirs = hour_vals("wind_direction_10m")
            pressures = hour_vals("pressure_msl")
            codes = hour_vals("weather_code")
            precips = hour_vals("precipitation")
            precip_probs = hour_vals("precipitation_probability")

            if temps:
                nightly["temperature_min"] = int(round(min(temps)))
                nightly["temperature_max"] = int(round(max(temps)))
            if winds:
                nightly["wind_speed_max"] = round(max(winds), 1)
            if winddirs:
                counts = {}
                for d in winddirs:
                    r = wind_rhumb(d)
                    counts[r] = counts.get(r, 0) + 1
                nightly["wind_direction_dominant"] = max(counts, key=counts.get)
            if pressures:
                nightly["pressure_mmhg"] = hpa_to_mmhg(
                    sum(pressures) / len(pressures)
                )
            if codes:
                most_severe = max(codes, key=severity)
                nightly["weather_code"] = int(most_severe)
                nightly["condition"] = condition_text(most_severe)
            if precip_probs:
                nightly["precipitation_probability"] = int(round(max(precip_probs)))
            if precips:
                nightly["precipitation_sum"] = round(sum(precips), 1)

        return {
            "city_id": int(city["id"]),
            "name": city.get("name", ""),
            "timezone": city.get("timezone") or om.get("timezone") or "",
            "updated_at": fmt_updated_at(utc_off),
            "current": {
                "temperature": round_int(current.get("temperature_2m")),
                "feels_like": round_int(current.get("apparent_temperature")),
                "humidity": round_int(current.get("relative_humidity_2m")),
                "pressure_mmhg": hpa_to_mmhg(current.get("pressure_msl")),
                "wind_speed": round1(current.get("wind_speed_10m")),
                "wind_direction": wind_rhumb(current.get("wind_direction_10m")),
                "condition": condition_text(cur_code),
                "weather_code": int(cur_code) if cur_code is not None else None,
                "precipitation": round1(current.get("precipitation")),
                "cloud_cover": round_int(current.get("cloud_cover")),
            },
            "daily": {
                "temp_max": round_int(daily_first("temperature_2m_max")),
                "temp_min": round_int(daily_first("temperature_2m_min")),
                "sunrise": hhmm(daily_first("sunrise")),
                "sunset": hhmm(daily_first("sunset")),
                "wind_speed_max": round1(daily_first("windspeed_10m_max")),
                "wind_direction_dominant": wind_rhumb(
                    daily_first("winddirection_10m_dominant")
                ),
                "condition": condition_text(day_code),
                "weather_code": int(day_code) if day_code is not None else None,
                "precipitation_sum": round1(daily_first("precipitation_sum")),
                "precipitation_probability": round_int(
                    daily_first("precipitation_probability_max")
                ),
            },
            "nightly": nightly,
            "current_units": {
                "temperature": "°C",
                "feels_like": "°C",
                "humidity": "%",
                "pressure_mmhg": "мм рт. ст.",
                "wind_speed": "м/с",
                "precipitation": "мм",
                "cloud_cover": "%",
                "wind_direction": "румб",
                "condition": "текст",
                "weather_code": "WMO",
            },
            "daily_units": {
                "temp_max": "°C",
                "temp_min": "°C",
                "sunrise": "HH:MM",
                "sunset": "HH:MM",
                "wind_speed_max": "м/с",
                "wind_direction_dominant": "румб",
                "condition": "текст",
                "weather_code": "WMO",
                "precipitation_sum": "мм",
                "precipitation_probability": "%",
            },
            "nightly_units": {
                "temperature_min": "°C",
                "temperature_max": "°C",
                "wind_speed_max": "м/с",
                "wind_direction_dominant": "румб",
                "pressure_mmhg": "мм рт. ст.",
                "condition": "текст",
                "weather_code": "WMO",
                "precipitation_probability": "%",
                "precipitation_sum": "мм",
            },
        }

    def get_weather(self, city_id, refresh=False):
        now = time.time()
        with self.cache_lock:
            entry = self.cache.get(city_id)
        if (not refresh and entry
                and (now - entry["fetched_at"]) < self.cache_ttl):
            return entry["data"]

        lock = self._flight_lock(city_id)
        with lock:
            # Re-check inside the lock: another thread may have refetched.
            now = time.time()
            with self.cache_lock:
                entry = self.cache.get(city_id)
            if (not refresh and entry
                    and (now - entry["fetched_at"]) < self.cache_ttl):
                return entry["data"]

            city = self.find_city(city_id=city_id)
            if city is None:
                return None
            data = self.build_weather(city, self.fetch_open_meteo(city))
            with self.cache_lock:
                self.cache[city_id] = {"fetched_at": time.time(), "data": data}
            return data

    def _flight_lock(self, city_id):
        with self.flight_guard:
            return self.flight_locks.setdefault(city_id, threading.Lock())

    # ---- geocoding ------------------------------------------------------
    def _reverse_geocode_city(self, lat, lon):
        """Resolve coordinates to a city name via Nominatim. None on failure."""
        params = {
            "lat": lat,
            "lon": lon,
            "format": "json",
            "accept-language": "ru",
            "zoom": 10,
        }
        url = NOMINATIM_REVERSE_URL + "?" + urllib.parse.urlencode(params)
        headers = {"User-Agent": "weather-proxy/1.0 (homelab)"}
        try:
            data = self._get_json(url, headers=headers)
        except OpenMeteoError:
            return None
        address = data.get("address") or {}
        for key in ("city", "town", "village", "municipality", "county"):
            val = address.get(key)
            if val:
                return val
        display = (data.get("display_name") or "").split(",", 1)
        if display and display[0].strip():
            return display[0].strip()
        return None

    def _open_meteo_search(self, name):
        if not name:
            return []
        params = {
            "name": name,
            "count": 5,
            "language": "ru",
            "format": "json",
        }
        url = GEOCODE_SEARCH_URL + "?" + urllib.parse.urlencode(params)
        try:
            data = self._get_json(url)
        except OpenMeteoError:
            return []
        out = []
        for r in data.get("results") or []:
            out.append({
                "id": r.get("id"),
                "name": r.get("name"),
                "latitude": r.get("latitude"),
                "longitude": r.get("longitude"),
                "country": r.get("country"),
                "admin1": r.get("admin1"),
                "timezone": r.get("timezone"),
            })
        return out

    @staticmethod
    def _strip_admin_suffixes(name):
        if not name:
            return ""
        s = name
        for suf in ADMIN_SUFFIXES:
            s = re.sub(re.escape(suf), " ", s, flags=re.IGNORECASE)
        return re.sub(r"\s+", " ", s).strip(" ,;—–-")

    @staticmethod
    def _candidate_names(name):
        cands = []

        def add(c):
            c = (c or "").strip()
            if c and c not in cands:
                cands.append(c)

        add(name)
        add(WeatherService._strip_admin_suffixes(name))
        stripped = WeatherService._strip_admin_suffixes(name)
        # Russian adjective endings: "Качканарский" → "Качканар", "Нижнетуринский" → "Нижнетур"
        for w in re.split(r"\s+", stripped):
            base = re.sub(r"(ский|цкий|ское|цкое|ская|цкая)$", "", w, flags=re.IGNORECASE)
            if base and base != w:
                add(base)
        words = (name or "").split()
        if words:
            add(" ".join(words[:2]))
        return cands

    @staticmethod
    def _is_in_russia(lat, lon):
        if not (-90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0):
            return False
        if not (41.0 <= lat <= 82.0):
            return False
        if 19.0 <= lon <= 180.0:
            return True
        return -180.0 <= lon <= -169.0  # Chukotka

    @staticmethod
    def _direct_id(lat, lon):
        return int((lat + 90) * 100000) * 1000000 + int((lon + 180) * 100000)

    def _make_direct_result(self, lat, lon, name):
        display = (name or "").strip()
        if not display:
            display = "Координаты: {:.3f}, {:.3f}".format(lat, lon)
        return {
            "id": self._direct_id(lat, lon),
            "name": display,
            "latitude": lat,
            "longitude": lon,
            "country": "Россия" if self._is_in_russia(lat, lon) else "",
            "admin1": "",
            "timezone": "",
            "direct": True,
        }

    def _geocode_coords(self, lat, lon):
        name = self._reverse_geocode_city(lat, lon) or ""
        best = None
        best_dist = None
        seen_ids = set()
        for cand in self._candidate_names(name):
            for r in self._open_meteo_search(cand):
                rid = r.get("id")
                if rid is not None:
                    if rid in seen_ids:
                        continue
                    seen_ids.add(rid)
                try:
                    rlat = float(r.get("latitude"))
                    rlon = float(r.get("longitude"))
                except (TypeError, ValueError):
                    continue
                dlat = rlat - lat
                dlon = rlon - lon
                dist2 = dlat * dlat + dlon * dlon
                if dist2 > 4.0:
                    continue
                if best_dist is None or dist2 < best_dist:
                    best_dist = dist2
                    best = r
        if best is not None:
            return [best]
        return [self._make_direct_result(lat, lon, name)]

    def geocode_search(self, q):
        coords = parse_coords(q)
        if coords is not None:
            return self._geocode_coords(coords[0], coords[1])
        return self._open_meteo_search(q)

    def geocode_get(self, gid):
        params = {"id": gid, "language": "ru", "format": "json"}
        url = GEOCODE_GET_URL + "?" + urllib.parse.urlencode(params)
        try:
            data = self._get_json(url)
        except OpenMeteoError:
            return None
        if not data or data.get("error"):
            return None
        result = data
        if "results" in data:
            results = data["results"]
            if not results:
                return None
            result = results[0]
        if not result.get("id"):
            return None
        return result

    def make_alias(self, name, gid):
        if not name:
            return "city_%s" % gid
        alias = "".join(TRANSLIT.get(ch, ch) for ch in name.lower())
        alias = re.sub(r"[^a-z0-9]+", "_", alias).strip("_")
        return alias or ("city_%s" % gid)

    def _discover_timezone(self, lat, lon):
        params = {
            "latitude": lat,
            "longitude": lon,
            "current": "temperature_2m",
            "timezone": "auto",
            "forecast_days": 1,
        }
        url = FORECAST_URL + "?" + urllib.parse.urlencode(params)
        try:
            data = self._get_json(url)
        except OpenMeteoError:
            return ""
        return data.get("timezone") or ""

    def _find_duplicate(self, city):
        with self.config_lock:
            locations = list(self.config["locations"])
        cid = city.get("id")
        clat = city.get("latitude")
        clon = city.get("longitude")
        for loc in locations:
            try:
                if int(loc.get("id")) == int(cid):
                    return loc
            except (TypeError, ValueError):
                pass
            try:
                if (abs(float(loc.get("latitude")) - float(clat)) <= 0.001
                        and abs(float(loc.get("longitude")) - float(clon)) <= 0.001):
                    return loc
            except (TypeError, ValueError):
                pass
        return None

    def add_city(self, body):
        """Add a city from a request body dict.

        Returns (city, status) where status is "created", "exists" or "error".
        """
        body = body or {}
        lat_raw = body.get("latitude")
        lon_raw = body.get("longitude")

        if lat_raw is not None or lon_raw is not None:
            # Direct coordinates (from a "direct": true result or user input).
            if lat_raw is None or lon_raw is None:
                return None, "error"
            try:
                lat = float(lat_raw)
                lon = float(lon_raw)
            except (TypeError, ValueError):
                return None, "error"
            if not (-90.0 <= lat <= 90.0) or not (-180.0 <= lon <= 180.0):
                return None, "error"
            name = body.get("name") or "Координаты: {:.3f}, {:.3f}".format(lat, lon)
            gid = body.get("id")
            if gid is not None:
                try:
                    gid = int(gid)
                except (TypeError, ValueError):
                    gid = None
            if gid is None:
                gid = self._direct_id(lat, lon)
            timezone = body.get("timezone") or ""
            if not timezone:
                timezone = self._discover_timezone(lat, lon)
            new_city = {
                "id": gid,
                "name": name,
                "alias": self.make_alias(name, gid),
                "latitude": lat,
                "longitude": lon,
                "timezone": timezone,
            }
        else:
            # Existing flow: resolve an Open-Meteo geocoding id.
            gid = body.get("id")
            if gid is None:
                return None, "error"
            info = self.geocode_get(gid)
            if info is None:
                return None, "error"
            new_city = {
                "id": int(info.get("id")),
                "name": info.get("name", ""),
                "alias": self.make_alias(info.get("name"), info.get("id")),
                "latitude": info.get("latitude"),
                "longitude": info.get("longitude"),
                "timezone": info.get("timezone") or "",
            }

        dup = self._find_duplicate(new_city)
        if dup is not None:
            return dup, "exists"

        with self.config_lock:
            self.config["locations"].append(new_city)
            self.save_config()
        return new_city, "created"


class Handler(BaseHTTPRequestHandler):
    service = None  # type: WeatherService
    server_version = "WeatherProxy/1.0"

    # ---- logging --------------------------------------------------------
    def log_message(self, fmt, *args):
        print("[%s] %s %s" % (
            datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            self.address_string(),
            fmt % args,
        ), flush=True)

    # ---- JSON helper ----------------------------------------------------
    def send_json(self, status, obj, headers=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    # ---- auth helpers --------------------------------------------------
    def _get_cookie(self, name):
        header = self.headers.get("Cookie", "")
        for part in header.split(";"):
            part = part.strip()
            if not part:
                continue
            if "=" not in part:
                continue
            key, value = part.split("=", 1)
            if key.strip() == name:
                return urllib.parse.unquote(value.strip())
        return None

    def current_user(self):
        token = self._get_cookie(SESSION_COOKIE)
        if not token:
            return None
        return self.service.auth.get_username_by_token(token)

    def _session_cookie_headers(self, username):
        token = self.service.auth.create_session(username)
        return {
            "Set-Cookie": "%s=%s; HttpOnly; Path=/; SameSite=Lax" % (
                SESSION_COOKIE, token
            )
        }

    @staticmethod
    def _clear_cookie_headers():
        return {
            "Set-Cookie": "%s=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0"
            % SESSION_COOKIE
        }

    def _read_json(self):
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
            body = self.rfile.read(length).decode("utf-8", "replace")
            payload = json.loads(body) if body.strip() else {}
        except (ValueError, json.JSONDecodeError):
            return None
        if not isinstance(payload, dict):
            return None
        return payload

    # ---- static ---------------------------------------------------------
    def serve_static(self, path, versioned=False):
        rel = path.split("?", 1)[0]
        if rel.startswith("/static/"):
            rel = rel[len("/static/"):]
        else:
            rel = rel.lstrip("/")
        rel = urllib.parse.unquote(rel)
        if rel == "":
            rel = "index.html"
        filepath = os.path.normpath(os.path.join(STATIC_DIR, rel))
        # Path traversal guard.
        if not (filepath == STATIC_DIR
                or filepath.startswith(STATIC_DIR + os.sep)):
            self.send_json(404, {"error": "Not found", "reason": "not_found"})
            return
        if not os.path.isfile(filepath):
            self.send_json(404, {"error": "Not found", "reason": "not_found"})
            return
        ext = os.path.splitext(filepath)[1].lower()
        ctype = CONTENT_TYPES.get(ext, "application/octet-stream")
        with open(filepath, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if ext == ".html":
            self.send_header("Cache-Control", "no-cache")
        elif ext in (".css", ".js"):
            if versioned:
                self.send_header(
                    "Cache-Control", "public, max-age=31536000, immutable"
                )
            else:
                self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    # ---- routing --------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)
        versioned = "v=" in parsed.query

        if path in ("/", "/index.html"):
            self.serve_static("/index.html")
        elif path == "/api/cities":
            self.handle_cities()
        elif path == "/api/all-cities":
            self.handle_all_cities()
        elif path == "/api/me":
            self.handle_me()
        elif path == "/api/weather":
            self.handle_weather(qs)
        elif path == "/api/geocode":
            self.handle_geocode(qs)
        elif path.startswith("/static/"):
            self.serve_static(path, versioned=versioned)
        elif path in ("/style.css", "/app.js", "/nebosvod.ico", "/logo.png"):
            self.serve_static(path, versioned=versioned)
        else:
            self.send_json(404, {"error": "Not found", "reason": "not_found"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/cities":
            self.handle_add_city()
        elif parsed.path == "/api/register":
            self.handle_register()
        elif parsed.path == "/api/login":
            self.handle_login()
        elif parsed.path == "/api/logout":
            self.handle_logout()
        elif parsed.path == "/api/settings":
            self.handle_settings()
        else:
            self.send_json(404, {"error": "Not found", "reason": "not_found"})

    # ---- API handlers ---------------------------------------------------
    def handle_cities(self):
        # Always return ALL locations, identical for guests and logged-in
        # users. Per-user tile visibility is a frontend concern only.
        self.send_json(200, {"cities": self.service.get_locations()})

    def handle_all_cities(self):
        self.send_json(200, {"cities": self.service.get_locations()})

    def handle_me(self):
        user = self.current_user()
        if user is None:
            self.send_json(401, {"error": "not_logged_in"})
            return
        prefs = self.service.auth.get_display_prefs(user)
        self.send_json(200, {
            "user": user,
            "cities": self.service.auth.get_user_cities(user),
            "display_mode": prefs["display_mode"],
            "city_filter": prefs["city_filter"],
        })

    def handle_register(self):
        payload = self._read_json()
        if payload is None:
            self.send_json(400, {"error": "bad_request"})
            return
        username = (payload.get("username") or "").strip().lower()
        password = payload.get("password") or ""
        if not (3 <= len(username) <= 32) or len(password) < 6:
            self.send_json(400, {"error": "bad_request"})
            return
        try:
            self.service.auth.create_user(username, password)
        except ValueError:
            self.send_json(409, {"error": "exists"})
            return
        headers = self._session_cookie_headers(username)
        self.send_json(201, {"user": username}, headers=headers)

    def handle_login(self):
        payload = self._read_json()
        if payload is None:
            self.send_json(400, {"error": "bad_request"})
            return
        username = (payload.get("username") or "").strip().lower()
        password = payload.get("password") or ""
        user = self.service.auth.get_user(username)
        if user is None or not verify_password(password, user["password_hash"]):
            self.send_json(401, {"error": "bad_credentials"})
            return
        headers = self._session_cookie_headers(username)
        self.send_json(200, {"user": username}, headers=headers)

    def handle_logout(self):
        token = self._get_cookie(SESSION_COOKIE)
        if token:
            self.service.auth.delete_session(token)
        self.send_json(200, {"ok": True}, headers=self._clear_cookie_headers())

    def handle_settings(self):
        user = self.current_user()
        if user is None:
            self.send_json(401, {"error": "not_logged_in"})
            return
        payload = self._read_json()
        if payload is None:
            self.send_json(400, {"error": "bad_request"})
            return

        # Each shape is independent: display_mode, city_filter or city toggle.
        if "display_mode" in payload:
            mode = payload.get("display_mode")
            if mode not in ("compact", "full"):
                self.send_json(400, {"error": "bad_request"})
                return
            self.service.auth.set_display_mode(user, mode)
            self.send_json(200, {"ok": True})
            return

        if "city_filter" in payload:
            filt = payload.get("city_filter")
            if filt not in ("all", "selected", "selected_first"):
                self.send_json(400, {"error": "bad_request"})
                return
            self.service.auth.set_city_filter(user, filt)
            self.send_json(200, {"ok": True})
            return

        try:
            city_id = int(payload.get("city_id"))
        except (TypeError, ValueError):
            self.send_json(400, {"error": "bad_request"})
            return
        if not isinstance(payload.get("enabled"), bool):
            self.send_json(400, {"error": "bad_request"})
            return
        self.service.auth.set_user_city(user, city_id, payload["enabled"])
        self.send_json(200, {"ok": True})

    def handle_weather(self, qs):
        city_id_raw = (qs.get("city_id") or [None])[0]
        alias = (qs.get("city") or [None])[0]
        refresh = (qs.get("refresh") or ["0"])[0] in ("1", "true", "yes")

        if city_id_raw is None and alias is None:
            self.send_json(400, {
                "error": "Missing city_id or city",
                "reason": "no_parameter",
            })
            return

        city_id = None
        if city_id_raw is not None:
            try:
                city_id = int(city_id_raw)
            except (TypeError, ValueError):
                self.send_json(400, {
                    "error": "Invalid city_id",
                    "reason": "bad_parameter",
                })
                return

        city = self.service.find_city(city_id=city_id, alias=alias)
        if city is None:
            self.send_json(404, {
                "error": "Unknown city",
                "reason": "unknown_city",
            })
            return

        try:
            data = self.service.get_weather(int(city["id"]), refresh=refresh)
        except OpenMeteoError as e:
            self.send_json(502, {"error": str(e), "reason": "upstream"})
            return
        if data is None:
            self.send_json(404, {
                "error": "Unknown city",
                "reason": "unknown_city",
            })
            return
        self.send_json(200, data)

    def handle_geocode(self, qs):
        q = (qs.get("q") or [None])[0]
        if not q:
            self.send_json(400, {
                "error": "Missing q",
                "reason": "no_parameter",
            })
            return
        results = self.service.geocode_search(q)
        self.send_json(200, {"results": results})

    def handle_add_city(self):
        payload = self._read_json()
        if payload is None:
            self.send_json(400, {"error": "Invalid JSON", "reason": "bad_request"})
            return

        if (payload.get("id") is None
                and payload.get("latitude") is None
                and payload.get("longitude") is None):
            self.send_json(400, {
                "error": "Missing id or coordinates",
                "reason": "no_parameter",
            })
            return

        city, status = self.service.add_city(payload)
        if status == "error":
            self.send_json(400, {
                "error": "Geocoding failed",
                "reason": "geocode",
            })
            return
        if status == "exists":
            # Logged-in users expect an existing city to appear for them too.
            user = self.current_user()
            if user is not None:
                self.service.auth.set_user_city(user, int(city["id"]), True)
            self.send_json(409, {
                "error": "City already exists",
                "reason": "exists",
            })
            return

        # New city added: auto-enable it for a logged-in user.
        user = self.current_user()
        if user is not None:
            self.service.auth.set_user_city(user, int(city["id"]), True)
        self.send_json(201, {"city": city})


def main():
    service = WeatherService()
    service.auth = AuthStore(DB_PATH)
    Handler.service = service
    port = int(os.environ.get("WEATHER_PORT", service.config.get("port", 8080)))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True
    print("weather-proxy listening on 0.0.0.0:%d" % port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("weather-proxy shutting down", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
