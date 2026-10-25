"""World clock: the time somewhere else.

  time in tokyo · tokyo time · what time is it in new york · nyc
  15:00 in tokyo          your 15:00 there
  3pm london in tokyo     London's 3 PM in Tokyo
"""

from __future__ import annotations

import datetime
import re
import zoneinfo

from . import Provider, action, close, item, toast
from .. import match, util

# Places people say that aren't the city in the zone name.
ALIASES = {
    "nyc": "America/New_York", "new york": "America/New_York", "ny": "America/New_York",
    "la": "America/Los_Angeles", "los angeles": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
    "sf": "America/Los_Angeles", "seattle": "America/Los_Angeles", "silicon valley": "America/Los_Angeles",
    "boston": "America/New_York", "washington": "America/New_York", "miami": "America/New_York",
    "austin": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago",
    "denver": "America/Denver", "phoenix": "America/Phoenix", "toronto": "America/Toronto",
    "vancouver": "America/Vancouver", "montreal": "America/Toronto", "mexico city": "America/Mexico_City",
    "rio": "America/Sao_Paulo", "sao paulo": "America/Sao_Paulo", "buenos aires": "America/Argentina/Buenos_Aires",
    "amsterdam": "Europe/Amsterdam", "leiden": "Europe/Amsterdam", "rotterdam": "Europe/Amsterdam",
    "utrecht": "Europe/Amsterdam", "the hague": "Europe/Amsterdam", "den haag": "Europe/Amsterdam",
    "netherlands": "Europe/Amsterdam", "holland": "Europe/Amsterdam", "nl": "Europe/Amsterdam",
    "uk": "Europe/London", "england": "Europe/London", "scotland": "Europe/London", "ireland": "Europe/Dublin",
    "germany": "Europe/Berlin", "munich": "Europe/Berlin", "frankfurt": "Europe/Berlin", "hamburg": "Europe/Berlin",
    "france": "Europe/Paris", "spain": "Europe/Madrid", "barcelona": "Europe/Madrid", "italy": "Europe/Rome",
    "milan": "Europe/Rome", "portugal": "Europe/Lisbon", "porto": "Europe/Lisbon", "belgium": "Europe/Brussels",
    "antwerp": "Europe/Brussels", "switzerland": "Europe/Zurich", "geneva": "Europe/Zurich",
    "sweden": "Europe/Stockholm", "norway": "Europe/Oslo", "denmark": "Europe/Copenhagen",
    "finland": "Europe/Helsinki", "poland": "Europe/Warsaw", "greece": "Europe/Athens", "turkey": "Europe/Istanbul",
    "russia": "Europe/Moscow", "ukraine": "Europe/Kyiv", "kiev": "Europe/Kyiv",
    "dubai": "Asia/Dubai", "uae": "Asia/Dubai", "abu dhabi": "Asia/Dubai", "israel": "Asia/Jerusalem",
    "tel aviv": "Asia/Jerusalem", "india": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata",
    "new delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata",
    "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "shenzhen": "Asia/Shanghai",
    "japan": "Asia/Tokyo", "osaka": "Asia/Tokyo", "kyoto": "Asia/Tokyo", "korea": "Asia/Seoul",
    "vietnam": "Asia/Ho_Chi_Minh", "hanoi": "Asia/Bangkok", "thailand": "Asia/Bangkok", "bali": "Asia/Makassar",
    "indonesia": "Asia/Jakarta", "philippines": "Asia/Manila", "singapore": "Asia/Singapore",
    "australia": "Australia/Sydney", "canberra": "Australia/Sydney", "new zealand": "Pacific/Auckland",
    "nz": "Pacific/Auckland", "wellington": "Pacific/Auckland", "hawaii": "Pacific/Honolulu",
    "south africa": "Africa/Johannesburg", "cape town": "Africa/Johannesburg", "egypt": "Africa/Cairo",
    "nigeria": "Africa/Lagos", "kenya": "Africa/Nairobi", "suriname": "America/Paramaribo",
    "curacao": "America/Curacao", "aruba": "America/Aruba", "utc": "UTC", "gmt": "UTC",
}
TZ_ABBR = {"cet": "Europe/Amsterdam", "cest": "Europe/Amsterdam", "est": "America/New_York",
           "edt": "America/New_York", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles",
           "cst": "America/Chicago", "jst": "Asia/Tokyo", "ist": "Asia/Kolkata", "bst": "Europe/London",
           "aest": "Australia/Sydney"}

_ZONES: dict[str, str] | None = None


def zones() -> dict[str, str]:
    """"tokyo" → "Asia/Tokyo", for every zone, plus the aliases above."""
    global _ZONES
    if _ZONES is None:
        out = {}
        for z in zoneinfo.available_timezones():
            if "/" not in z or z.startswith(("Etc/", "SystemV/", "US/", "posix/", "right/")):
                continue
            city = z.rsplit("/", 1)[1].replace("_", " ").lower()
            out.setdefault(city, z)
        out.update(ALIASES)
        out.update(TZ_ABBR)
        _ZONES = out
    return _ZONES


def find_zone(place: str) -> tuple[str, str] | None:
    """(display name, zone) for a place, exact first, then the best close match."""
    p = match.fold(place).strip(" ?.!,")
    if not p:
        return None
    z = zones()
    if p in z:
        return _display(p), z[p]
    if len(p) < 3:
        return None
    best = None
    for name, zone in z.items():
        s = match.score_text(p, name)
        if s >= 800 and (best is None or s > best[0]):
            best = (s, name, zone)
    return (_display(best[1]), best[2]) if best else None


def _display(name: str) -> str:
    return name.upper() if len(name) <= 4 and name in TZ_ABBR or name in ("uk", "uae", "nyc", "nz", "la", "sf", "nl") \
        else name.title()


TIME = r"(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?"
PATTERNS = [
    # what time is it in X / time in X / time X
    (re.compile(r"^(?:what(?:'s| is)?\s+(?:the\s+)?)?time(?:\s+is\s+it)?\s+(?:in|at)\s+(.+)$"), "now"),
    (re.compile(r"^time\s+(.+)$"), "now"),
    (re.compile(r"^(.+?)\s+time$"), "now"),
    # 3pm london in tokyo
    (re.compile(rf"^{TIME}\s+(.+?)\s+(?:in|to)\s+(.+)$"), "convert"),
    # 15:00 in tokyo (your time there)
    (re.compile(rf"^{TIME}\s+(?:in|to)\s+(.+)$"), "local"),
]


def parse(q: str):
    q = match.fold(q).strip(" ?")
    for rx, kind in PATTERNS:
        m = rx.match(q)
        if m:
            return kind, m.groups()
    return None


def _when(hour: str, minute: str | None, ampm: str | None, tz) -> datetime.datetime | None:
    h, mi = int(hour), int(minute or 0)
    if ampm:
        if not 1 <= h <= 12:
            return None
        h = h % 12 + (12 if ampm == "pm" else 0)
    if h > 23 or mi > 59:
        return None
    today = datetime.datetime.now(tz).date()
    return datetime.datetime.combine(today, datetime.time(h, mi), tzinfo=tz)


def describe(dt: datetime.datetime, here: datetime.datetime) -> str:
    """"Thursday · 7 hours ahead" next to a time."""
    offset = (dt.utcoffset() - here.utcoffset()).total_seconds() / 3600
    if offset == 0:
        rel = "same time as here"
    else:
        hours = f"{abs(offset):g} hour{'s' if abs(offset) != 1 else ''}"
        rel = f"{hours} {'ahead' if offset > 0 else 'behind'}"
    day = dt.strftime("%A")
    if dt.date() != here.date():
        day += " (" + ("tomorrow" if dt.date() > here.date() else "yesterday") + ")"
    return f"{day} · {rel} · {dt.tzname()}"


class WorldClock(Provider):
    id = "worldclock"
    name = "World clock"
    prefix = "tz"
    description = "“time in tokyo”, “nyc time”, “15:00 in tokyo”, “3pm london in tokyo”"

    def search(self, q, scoped):
        q = q.strip()
        if not q:
            return []
        local = datetime.datetime.now().astimezone()
        parsed = parse(q)
        if not parsed and scoped:
            parsed = ("now", (q,))
        if not parsed:
            return []
        kind, groups = parsed
        if kind == "now":
            found = find_zone(groups[0])
            if not found:
                return []
            name, zone = found
            there = datetime.datetime.now(zoneinfo.ZoneInfo(zone))
            title = there.strftime("%H:%M")
            return [item("worldclock", f"now:{zone}", title, subtitle=f"{name} · {describe(there, local)}",
                         icon="󰥔", accessory=name, recordable=False, score=995, _text=f"{title} in {name}")]
        if kind == "local":
            hour, minute, ampm, place = groups
            found = find_zone(place)
            if not found:
                return []
            name, zone = found
            start = _when(hour, minute, ampm, local.tzinfo)
            if not start:
                return []
            there = start.astimezone(zoneinfo.ZoneInfo(zone))
            title = there.strftime("%H:%M")
            return [item("worldclock", f"conv:{zone}", title,
                         subtitle=f"{start.strftime('%H:%M')} here is {title} in {name} · {describe(there, start)}",
                         icon="󰥔", accessory=name, recordable=False, score=995,
                         _text=f"{start.strftime('%H:%M')} here = {title} in {name}")]
        hour, minute, ampm, src, dst = groups
        a, b = find_zone(src), find_zone(dst)
        if not a or not b:
            return []
        start = _when(hour, minute, ampm, zoneinfo.ZoneInfo(a[1]))
        if not start:
            return []
        there = start.astimezone(zoneinfo.ZoneInfo(b[1]))
        title = there.strftime("%H:%M")
        return [item("worldclock", f"conv:{a[1]}:{b[1]}", title,
                     subtitle=f"{start.strftime('%H:%M')} in {a[0]} is {title} in {b[0]} · {describe(there, start)}",
                     icon="󰥔", accessory=b[0], recordable=False, score=995,
                     _text=f"{start.strftime('%H:%M')} {a[0]} = {title} {b[0]}")]

    def actions(self, it):
        return [action("default", "Copy time", "󰆏"), action("copy-all", "Copy with place", "󰆏", "ctrl+shift+c")]

    def run(self, it, aid, arg):
        util.copy(it["_text"] if aid == "copy-all" else it["title"])
        return [toast("Copied"), close()]
