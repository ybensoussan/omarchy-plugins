"""Commands for the other jvdp plugins, each shown only when that plugin is
installed: Snag, Awake, Atmosphere, Netwatch, Clock+ and Weather+."""

from __future__ import annotations

import datetime
import json
import os
import re

from . import Provider, action, close, detail, item, toast
from .. import util

PLUGINS = util.HOME / ".config/omarchy/plugins"
ATMOSPHERE_EFFECTS = ["static", "gradient", "wave", "breathe", "aurora", "sparkle", "comet", "fire", "pulse"]
KEYBOARD_EFFECTS = ["static", "gradient", "wave", "breathe", "aurora", "sparkle", "ripple", "trail"]
DOMAIN = re.compile(r"^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")


def installed(plugin_id: str) -> bool:
    return (PLUGINS / plugin_id).exists()


def _bin(plugin_id: str, name: str) -> str:
    return str(PLUGINS / plugin_id / "bin" / name)


def cmd(key, title, subtitle, icon, argv=None, keywords=(), arg=None, run=None, plugin=""):
    return item("plugins", key, title, subtitle=subtitle, icon=icon, accessory=plugin,
                _keywords=list(keywords), _argv=argv, _run=run, arg=arg)


class Plugins(Provider):
    id = "plugins"
    name = "Plugin commands"
    description = "Snag, Awake, Atmosphere, Netwatch, Clock+, Weather+"

    def _commands(self) -> list[dict]:
        out = []
        if installed("jvdp.snag"):
            snag = _bin("jvdp.snag", "snag")
            out += [
                cmd("snag", "Download video from clipboard link", "Snag · saves to your downloads", "󰇚",
                    [snag], ["snag", "youtube", "x", "instagram", "tiktok", "save"], plugin="Snag"),
                cmd("snag-gif", "Download clipboard link as GIF", "Snag", "󰵸", [snag, "--as", "gif"],
                    ["snag", "gif"], plugin="Snag"),
                cmd("snag-audio", "Download clipboard link as audio", "Snag", "󰎆", [snag, "--as", "audio"],
                    ["snag", "mp3", "audio"], plugin="Snag"),
                cmd("snag-url", "Download video from…", "Snag · paste or type a link", "󰇚", None, ["snag"],
                    arg={"placeholder": "Link to a post"}, run="snag-url", plugin="Snag"),
                cmd("snag-panel", "Snag downloads", "Snag · open the panel", "󰇚",
                    ["omarchy-shell", "shell", "toggle", "jvdp.snag"], ["snag", "downloads"], plugin="Snag"),
            ]
        if installed("jvdp.awake"):
            awake = _bin("jvdp.awake", "omarchy-awake")
            for dur, label in (("1h", "1 hour"), ("4h", "4 hours"), ("8h", "8 hours"), ("on", "until turned off")):
                out.append(cmd(f"awake-{dur}", f"Stay awake {label}", "Awake · no screen lock or sleep", "󰅶",
                               [awake, dur], ["awake", "caffeine", "coffee", "keep awake", "sleep"], plugin="Awake"))
            out += [
                cmd("awake-off", "Allow sleep again", "Awake · turn it off", "󰛊", [awake, "off"],
                    ["awake", "caffeine", "off"], plugin="Awake"),
                cmd("awake-for", "Stay awake for…", "Awake · e.g. 90m, 2h, +30m", "󰅶", None, ["awake", "caffeine"],
                    arg={"placeholder": "Duration, e.g. 90m"}, run="awake-for", plugin="Awake"),
            ]
        if util.have("atmosphere") or installed("jvdp.atmosphere"):
            atm = "atmosphere"
            out += [
                cmd("atm-toggle", "Lights on/off", "Atmosphere · keyboard and case", "󰌵", [atm, "toggle"],
                    ["atmosphere", "rgb", "lights", "led"], plugin="Atmosphere"),
                cmd("atm-snow", "Snow on the screens", "Atmosphere · toggle", "󰖘", [atm, "snow", "toggle"],
                    ["atmosphere", "snow", "winter"], plugin="Atmosphere"),
                cmd("atm-party", "Party lights", "Atmosphere · toggle", "󰙯", [atm, "party", "toggle"],
                    ["atmosphere", "party", "disco"], plugin="Atmosphere"),
            ]
            for e in ATMOSPHERE_EFFECTS:
                out.append(cmd(f"atm-case-{e}", f"Case lighting: {e}", "Atmosphere · effect", "󰸌",
                               [atm, "effect", e], ["atmosphere", "rgb", "effect", "case", "fans"], plugin="Atmosphere"))
            for e in KEYBOARD_EFFECTS:
                out.append(cmd(f"atm-kb-{e}", f"Keyboard lighting: {e}", "Atmosphere · effect", "󰌌",
                               [atm, "keyboard", "effect", e], ["atmosphere", "rgb", "effect", "keyboard"],
                               plugin="Atmosphere"))
        if installed("jvdp.netwatch") and os.path.exists("/usr/local/lib/omarchy-netwatch/netwatch-block"):
            out += [
                cmd("nw-block", "Block a domain…", "Netwatch · system-wide, asks for your password", "󰒃", None,
                    ["netwatch", "block", "firewall", "dns", "ads"], arg={"placeholder": "example.com"},
                    run="nw-block", plugin="Netwatch"),
                cmd("nw-unblock", "Unblock a domain…", "Netwatch", "󰒄", None, ["netwatch", "unblock"],
                    arg={"placeholder": "example.com"}, run="nw-unblock", plugin="Netwatch"),
                cmd("nw-panel", "Network monitor", "Netwatch · connections, map, log", "󰛳",
                    ["omarchy-shell", "shell", "toggle", "jvdp.netwatch"], ["netwatch", "network", "connections"],
                    plugin="Netwatch"),
            ]
        if installed("jvdp.clock"):
            out += [
                cmd("agenda", "Today's agenda", "Clock+ · calendar events", "󰃭", None,
                    ["calendar", "agenda", "meetings", "events", "today", "clock"], run="agenda", plugin="Clock+"),
                cmd("join", "Join next meeting", "Clock+ · opens the meeting link", "󰤙", None,
                    ["meeting", "teams", "join", "call", "zoom", "meet"], run="join", plugin="Clock+"),
                cmd("clock-refresh", "Refresh calendars", "Clock+", "󰑓",
                    ["omarchy-shell", "jvdp.clock", "refresh"], ["calendar", "refresh", "sync"], plugin="Clock+"),
            ]
        if installed("jvdp.weather"):
            out.append(cmd("weather", "Weather", "Weather+ · forecast", "󰖐",
                           ["omarchy-shell", "shell", "toggle", "jvdp.weather"], ["weather", "forecast", "rain"],
                           plugin="Weather+"))
        if installed("jvdp.meetings") and os.path.exists(util.HOME / ".local/bin/meetings"):
            out.append(cmd("meetings", "Start or stop meeting notes", "Omarchy Meetings · transcribe a meeting", "󰍬",
                           [str(util.HOME / ".local/bin/meetings")], ["meeting", "record", "transcribe", "notes"],
                           plugin="Meetings"))
        return out

    def search(self, q, scoped):
        found = self.rank(q, self._commands())
        # "awake 2h": the command that takes a duration, filled in.
        head, _, rest = q.strip().partition(" ")
        if rest and head.lower() == "awake" and installed("jvdp.awake"):
            found.append(dict(cmd("awake-for", f"Stay awake for {rest}", "Awake", "󰅶", None, run="awake-for",
                                  plugin="Awake"), score=960, _filled=rest, recordable=False))
        if rest and head.lower() == "block" and installed("jvdp.netwatch"):
            found.append(dict(cmd("nw-block", f"Block {rest}", "Netwatch", "󰒃", None, run="nw-block",
                                  plugin="Netwatch"), score=960, _filled=rest, recordable=False))
        return found

    def browse(self):
        return self._commands()

    def resolve(self, item_id):
        for it in self._commands():
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        return [action("default", "Run", "󰘳")]

    def run(self, it, aid, arg):
        if it.get("_filled"):
            arg = it["_filled"]
        # "join" also comes from the agenda page's action.
        what = "join" if aid == "join" else it.get("_run")
        if what == "snag-url":
            if not arg or not re.match(r"^https?://", arg.strip()):
                return [toast("That isn't a link", True)]
            util.spawn([_bin("jvdp.snag", "snag"), arg.strip()])
        elif what == "awake-for":
            dur = (arg or "").strip()
            if not re.fullmatch(r"\+?\d+[mh]?|on|off", dur):
                return [toast("Use a duration like 90m or 2h", True)]
            util.spawn([_bin("jvdp.awake", "omarchy-awake"), dur])
        elif what in ("nw-block", "nw-unblock"):
            domain = (arg or "").strip().lower().removeprefix("https://").removeprefix("http://").split("/")[0]
            if not DOMAIN.match(domain):
                return [toast("That isn't a domain name", True)]
            util.spawn(["pkexec", "/usr/local/lib/omarchy-netwatch/netwatch-block",
                        "block" if what == "nw-block" else "unblock", domain])
        elif what == "agenda":
            return [detail("Today's agenda", agenda_text(), icon="󰃭",
                           actions=[action("join", "Join next meeting", "󰤙", "ctrl+j")])]
        elif what == "join":
            ev = next_meeting()
            if not ev:
                return [toast("No meeting with a link coming up", True)]
            util.open_target(ev["url"])
        else:
            util.spawn(it["_argv"])
        return [close()]


def _events() -> list[dict]:
    path = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}", "omarchy-clock/events.json")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    return [e for e in data.get("events", []) if isinstance(e, dict) and not e.get("declined")]


def agenda_text() -> str:
    today = datetime.date.today().isoformat()
    rows = []
    for e in sorted(_events(), key=lambda e: e.get("start", 0)):
        if e.get("date") != today:
            continue
        if e.get("all_day"):
            when = "all day"
        else:
            s = datetime.datetime.fromtimestamp(e["start"]).strftime("%H:%M")
            t = datetime.datetime.fromtimestamp(e["end"]).strftime("%H:%M")
            when = f"{s}–{t}"
        line = f"{when:>13}  {e.get('title') or '(no title)'}"
        extra = " · ".join(x for x in [e.get("calendar") or "", e.get("location") or ""] if x)
        if extra:
            line += f"\n{'':>13}  {extra}"
        rows.append(line)
    if not rows:
        return "Nothing on the calendar today."
    return "\n".join(rows)


def next_meeting() -> dict | None:
    now = datetime.datetime.now().timestamp()
    # Calendar data comes from outside: only open web links.
    upcoming = [e for e in _events() if re.match(r"^https?://", str(e.get("url") or "")) and not e.get("all_day")
                and e.get("end", 0) > now and e.get("start", 0) < now + 12 * 3600]
    upcoming.sort(key=lambda e: e["start"])
    return upcoming[0] if upcoming else None
