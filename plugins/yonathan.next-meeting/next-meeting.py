#!/usr/bin/env python3
import json, os, re, sys, urllib.request
from datetime import datetime, timedelta, timezone
import icalendar, recurring_ical_events

cfg = os.path.expanduser("~/.config/omarchy/next-meeting.url")
cache = os.path.expanduser("~/.cache/next-meeting.ics")
url = open(cfg).read().strip()
try:
    data = urllib.request.urlopen(url, timeout=20).read()
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    open(cache, "wb").write(data)
except Exception:
    if not os.path.exists(cache):
        print(json.dumps({"error": "fetch failed"})); sys.exit(0)
    data = open(cache, "rb").read()

now = datetime.now(timezone.utc)
cal = icalendar.Calendar.from_ical(data)
events = recurring_ical_events.of(cal).between(now - timedelta(hours=1), now + timedelta(days=2))
pat = re.compile(r"https://teams\.(?:microsoft|live)\.com/[^\s<>\"\\]+")
eod = (now.astimezone() + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
out = []
for e in events:
    start, end = e.get("DTSTART").dt, e.get("DTEND").dt
    if not isinstance(start, datetime) or end <= now or start >= eod:
        continue
    title = str(e.get("SUMMARY", ""))
    if title in ("Free", "Away") or str(e.get("TRANSP", "")) == "TRANSPARENT":
        continue
    text = " ".join(str(e.get(k, "")) for k in ("X-MICROSOFT-SKYPETEAMSMEETINGURL", "LOCATION", "DESCRIPTION"))
    m = pat.search(text.replace("\\n", " "))
    out.append({"title": title, "start": int(start.timestamp()), "end": int(end.timestamp()),
                "url": m.group(0).rstrip(".,)") if m else ""})
out.sort(key=lambda x: x["start"])
# Prefer the first meeting with a call link among those starting soon; else first overall
print(json.dumps(out[0] if out else {}))
