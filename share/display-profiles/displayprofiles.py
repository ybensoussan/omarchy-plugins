#!/usr/bin/env python3
"""Display & workspace profiles for Hyprland (Omarchy).

Single owner of monitor layout, workspace naming and profile switching.

Omarchy (4.5+) gives every monitor its own workspaces 1-10, numbered by Hyprland in a block
of ten per monitor (default/hypr/monitor-workspaces.lua). A profile names those ten slots per
monitor and hides the ones it does not use; it never moves workspaces between monitors.

Data (user editable through the Displays & Workspaces plugin):
  ~/.config/hypr/display-profiles/catalog.json      app rules per workspace name (shared by profiles)
  ~/.config/hypr/display-profiles/profiles/*.json   per-profile monitor layout + slot names/visibility
Generated (never edit by hand):
  ~/.config/hypr/workspace-profile.lua              dofile'd by hyprland.lua
  ~/.config/hypr/workspace-order.json               read by the workspaces bar widget
State:
  ~/.local/state/display-profiles/state.json        active profile, last monitor signature
"""

import copy
import fcntl
import json
import os
import re
import select
import socket
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME") or HOME / ".config")
STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state")
HYPR = CONFIG_HOME / "hypr"
DATA = HYPR / "display-profiles"
PROFILES = DATA / "profiles"
CATALOG = DATA / "catalog.json"
STATE_DIR = STATE_HOME / "display-profiles"
STATE = STATE_DIR / "state.json"
LOCK = STATE_DIR / "lock"
ACTIVE_LUA = HYPR / "workspace-profile.lua"
ORDER_JSON = HYPR / "workspace-order.json"
MENU = CONFIG_HOME / "omarchy/extensions/omarchy-menu.jsonc"
LEGACY_PROFILES = HYPR / "workspace-profiles"
MONITORS_LUA = HYPR / "monitors.lua"
OMARCHY_TOGGLES = STATE_HOME / "omarchy/toggles/hypr"
OMARCHY_BLOCKS = STATE_HOME / "omarchy/monitor-workspaces"
SLOTS = 10
DEFAULT_VISIBLE = 5
INTERNAL_RE = re.compile(r"^(eDP|LVDS|DSI)-")
MANAGED_BEGIN = "-- >>> omarchy-display-profiles: internal panel of the active profile (keeps Omarchy lid/clamshell handling in sync) >>>"
MANAGED_END = "-- <<< omarchy-display-profiles <<<"
OWN_MARKER = "-- set by omarchy-display-profiles"

PROFILE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
WORKSPACE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,23}$")
MODE_RE = re.compile(r"^(\d+)x(\d+)(?:@([\d.]+)(?:Hz)?)?$")
QUARTER_TURNS = {1, 3, 5, 7}

DEFAULT_CATALOG = {
    "version": 1,
    "workspaces": [
        {"name": "terminal", "number": 1, "apps": ["^kitty$", "^org\\.omarchy\\.agent$"]},
        {"name": "browser", "number": 2, "apps": ["^zen$"]},
        {"name": "editor", "number": 3, "apps": ["^dev\\.zed\\.Zed$"]},
        {"name": "remote", "number": 4, "apps": ["^org\\.remmina\\.Remmina$"]},
        {"name": "utilities", "number": 5, "apps": ["^slack$", "^Bitwarden$"]},
        {"name": "references", "number": 6, "apps": []},
        {"name": "ai", "number": 7, "apps": ["^com\\.anthropic\\.Claude$", "^ai\\.opencode\\.desktop$"]},
        {"name": "outlook", "number": 8, "apps": ["^chrome-faolnafnngnfdaknnbpnkhgohbobgegn-Default$"]},
        {"name": "teams", "number": 9, "apps": ["^chrome-ompifgpmddkgmclendfeacglnodjjndh-Default$"]},
        {"name": "10", "number": 10, "apps": []},
    ],
}


class UserError(Exception):
    """An error whose message is shown to the user verbatim."""


# --------------------------------------------------------------------------
# Hyprland access (replaced by a fake in tests)
# --------------------------------------------------------------------------

class Hypr:
    def _run(self, *args, check=True):
        result = subprocess.run(["hyprctl", *args], text=True, capture_output=True)
        if check and result.returncode != 0:
            raise UserError("hyprctl %s failed: %s" % (args[0], (result.stderr or result.stdout).strip()))
        return result.stdout

    def _json(self, *args):
        return json.loads(self._run("-j", *args) or "null")

    def monitors(self):
        return self._json("monitors", "all") or []

    def clients(self):
        return self._json("clients") or []

    def workspaces(self):
        return self._json("workspaces") or []

    def active_window(self):
        window = self._json("activewindow")
        return window if isinstance(window, dict) and window.get("address") else None

    def reload(self):
        self._run("reload")

    def config_errors(self):
        return [line for line in self._run("configerrors", check=False).splitlines() if line.strip()]

    def lua(self, code):
        return self._run("repl", code).strip()

    def blocks(self):
        """Connector -> Omarchy workspace block, asking Omarchy (which assigns new monitors one)."""
        code = ("local out = {} "
                "if o and o.workspaces and o.workspaces.workspace_id then "
                "for _, m in ipairs(hl.get_monitors()) do "
                "out[#out + 1] = m.name .. '=' .. ((o.workspaces.workspace_id(m, 1) - 1) // %d) end end "
                "return table.concat(out, ',')" % SLOTS)
        result = {}
        try:
            text = self.lua(code)
        except UserError:
            text = ""
        for part in text.split(","):
            name, _, block = part.partition("=")
            if name and block.strip().lstrip("-").isdigit():
                result[name.strip()] = int(block)
        return result or read_omarchy_blocks()

    def sleep(self, seconds):
        time.sleep(seconds)


def read_omarchy_blocks():
    """Connector -> block from Omarchy's state file (fallback when Hyprland cannot be asked)."""
    result = {}
    try:
        lines = OMARCHY_BLOCKS.read_text().splitlines()
    except OSError:
        return result
    for line in lines:
        fields = line.split("\t")
        if len(fields) >= 3 and fields[0].isdigit() and fields[1]:
            result[fields[1]] = int(fields[0])
    return result


def lua_str(value):
    """Encode a Python string as a Lua string literal."""
    out = ['"']
    for ch in str(value):
        code = ord(ch)
        if ch in '"\\':
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\n")
        elif code < 32 or code == 127:
            out.append("\\%03d" % code)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def num(value):
    """Format a number for Lua without trailing noise."""
    value = float(value)
    if value.is_integer():
        return str(int(value))
    return ("%.6f" % value).rstrip("0").rstrip(".")


# --------------------------------------------------------------------------
# Geometry and monitor facts
# --------------------------------------------------------------------------

def parse_mode(mode):
    match = MODE_RE.match(str(mode or ""))
    if not match:
        return None
    return int(match.group(1)), int(match.group(2)), float(match.group(3)) if match.group(3) else None


def logical_size(width, height, scale, transform):
    scale = float(scale or 1)
    width, height = float(width), float(height)
    if int(transform or 0) in QUARTER_TURNS:
        width, height = height, width
    return width / scale, height / scale


def monitor_rect(monitor):
    w, h = logical_size(monitor["width"], monitor["height"], monitor.get("scale", 1), monitor.get("transform", 0))
    return {"x": float(monitor["x"]), "y": float(monitor["y"]), "w": w, "h": h}


def rects_overlap(a, b):
    eps = 0.5
    return (a["x"] < b["x"] + b["w"] - eps and b["x"] < a["x"] + a["w"] - eps and
            a["y"] < b["y"] + b["h"] - eps and b["y"] < a["y"] + a["h"] - eps)


def clean_scales(width, height):
    """Scales Hyprland renders crisply: multiples of 1/120 giving integer logical sizes."""
    result = []
    for k in range(60, 361):
        scale = k / 120.0
        lw, lh = width / scale, height / scale
        if abs(lw - round(lw)) < 0.01 and abs(lh - round(lh)) < 0.01:
            result.append({"scale": round(scale, 6), "width": int(round(lw)), "height": int(round(lh))})
    return result


def short_label(live):
    name = live.get("name", "")
    if re.match(r"^(eDP|LVDS|DSI)-", name):
        return "Built-in display"
    make = re.sub(r"(?<!\w)(Inc\.?|Corporation|Corp\.?|Co\.,? ?Ltd\.?|Ltd\.?)(?!\w)", "", live.get("make") or "")
    make = re.sub(r"\s+", " ", make).strip(" ,")
    model = (live.get("model") or "").strip()
    if make and model.lower().startswith(make.split()[0].lower()):
        make = ""
    label = (make + " " + model).strip()
    return label or live.get("description") or name


def fingerprint(live):
    return {
        "make": live.get("make") or "",
        "model": live.get("model") or "",
        "serial": live.get("serial") or "",
        "description": live.get("description") or "",
        "output": live.get("name") or "",
    }


def live_modes(live):
    modes = []
    for mode in live.get("availableModes") or []:
        if mode not in modes:
            modes.append(mode)
    return modes


def best_mode(live, width, height, refresh=None, wanted=None):
    """Pick an exact Hyprland mode string for the given resolution/refresh."""
    modes = live_modes(live)
    if wanted and wanted in modes:
        return wanted
    candidates = []
    for mode in modes:
        parsed = parse_mode(mode)
        if parsed and parsed[0] == int(width) and parsed[1] == int(height):
            candidates.append((parsed[2] or 0.0, mode))
    if not candidates:
        return None
    if refresh:
        return min(candidates, key=lambda item: (abs(item[0] - float(refresh)), -item[0]))[1]
    return max(candidates)[1]


def current_mode(live):
    return best_mode(live, live.get("width", 0), live.get("height", 0), live.get("refreshRate")) or \
        "%dx%d@%.2fHz" % (live.get("width", 0), live.get("height", 0), float(live.get("refreshRate") or 60))


# --------------------------------------------------------------------------
# Monitor matching
# --------------------------------------------------------------------------

def match_score(saved, live):
    saved = saved or {}
    live_fp = fingerprint(live)
    s_serial, l_serial = saved.get("serial", ""), live_fp["serial"]
    s_model, s_make = saved.get("model", ""), saved.get("make", "")
    if s_serial and l_serial and s_serial == l_serial and (not s_model or s_model == live_fp["model"]):
        return 100
    if saved.get("description") and saved["description"] == live_fp["description"]:
        return 90
    if s_model and s_model == live_fp["model"] and s_make == live_fp["make"]:
        if s_serial and l_serial and s_serial != l_serial:
            return 0  # an identical model, but a different physical screen
        return 50 + (10 if saved.get("output") == live_fp["output"] else 0)
    if not s_model and not saved.get("description") and saved.get("output") and saved["output"] == live_fp["output"]:
        return 20
    return 0


def resolve(profile, live_monitors):
    """Map every saved monitor to at most one live monitor (and vice versa)."""
    pairs = []
    for index, saved in enumerate(profile.get("monitors", [])):
        for live in live_monitors:
            score = match_score(saved.get("match"), live)
            if score:
                pairs.append((score, index, live["name"]))
    pairs.sort(key=lambda item: (-item[0], item[1]))
    mapping, used = {}, set()
    for score, index, name in pairs:
        if index in mapping or name in used:
            continue
        mapping[index] = name
        used.add(name)
    return [mapping.get(i) for i in range(len(profile.get("monitors", [])))]


def monitor_signature(live_monitors):
    return sorted("%s|%s" % (m.get("name"), m.get("description")) for m in live_monitors)


def detect(profiles, live_monitors):
    """Return the name of the best fully-connected auto profile, or None."""
    live_names = {m["name"] for m in live_monitors}
    best = None
    for profile in profiles:
        if profile.get("auto", True) is False or not profile.get("monitors"):
            continue
        matched = resolve(profile, live_monitors)
        if any(name is None for name in matched):
            continue
        unmatched_live = len(live_names - set(matched))
        score = sum(match_score(p.get("match"), next(m for m in live_monitors if m["name"] == n))
                    for p, n in zip(profile["monitors"], matched))
        key = (len(matched), -unmatched_live, score, profile["name"])
        if best is None or key > best[0]:
            best = (key, profile["name"])
    return best[1] if best else None


# --------------------------------------------------------------------------
# Storage
# --------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return copy.deepcopy(default)
    except json.JSONDecodeError as error:
        raise UserError("%s is not valid JSON: %s" % (path, error))


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(tmp, path)


def write_text(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def load_catalog():
    catalog = read_json(CATALOG, None)
    if catalog is None:
        catalog = copy.deepcopy(DEFAULT_CATALOG)
    return normalize_catalog(catalog)


def normalize_catalog(catalog):
    """App rules per workspace name. Names are shared by every profile that uses them."""
    if not isinstance(catalog, dict) or not isinstance(catalog.get("workspaces"), list):
        raise UserError("Workspace catalog must contain a workspaces list.")
    seen, result = set(), []
    for item in catalog["workspaces"]:
        name = str(item.get("name", "")).strip()
        if not WORKSPACE_NAME_RE.match(name):
            raise UserError("Invalid workspace name %r: use letters, digits, '-', '_' or '.' (max 24)." % name)
        if name.lower() in seen:
            raise UserError("Workspace name %r is used twice." % name)
        seen.add(name.lower())
        apps = [str(app).strip() for app in item.get("apps", []) if str(app).strip()]
        for app in apps:
            try:
                re.compile(app)
            except re.error as error:
                raise UserError("App rule %r for %s is not a valid regex: %s" % (app, name, error))
        raw_launch = item.get("launch") if isinstance(item.get("launch"), dict) else {}
        launch = {app: str(raw_launch[app]).strip() for app in apps if str(raw_launch.get(app, "")).strip()}
        result.append({"name": name, "apps": apps, "launch": launch})
    return {"version": 2, "workspaces": result}


def profile_path(name):
    if not PROFILE_NAME_RE.match(name or ""):
        raise UserError("Profile names use lowercase letters, digits and '-' (max 32).")
    return PROFILES / (name + ".json")


def list_profiles(catalog=None):
    catalog = catalog or load_catalog()
    profiles = []
    for path in sorted(PROFILES.glob("*.json")):
        try:
            profiles.append(normalize_profile(read_json(path), catalog, strict=False))
        except UserError as error:
            print("warning: skipping %s: %s" % (path.name, error), file=sys.stderr)
    return profiles


def load_profile(name, catalog=None):
    path = profile_path(name)
    if not path.exists():
        raise UserError("Unknown profile: %s" % name)
    return normalize_profile(read_json(path), catalog or load_catalog(), strict=False)


def load_state():
    return read_json(STATE, {}) or {}


def save_state(**updates):
    state = load_state()
    state.update(updates)
    write_json(STATE, state)
    return state


# --------------------------------------------------------------------------
# Profile validation
# --------------------------------------------------------------------------

def default_slots():
    return [{"name": "", "hidden": i >= DEFAULT_VISIBLE} for i in range(SLOTS)]


def normalize_slots(raw, taken, strict):
    """Ten {name, hidden} slots for a monitor. `taken` collects names used in the profile.

    Accepts the v2 format (an ordered `workspaces` list of names): those fill slots 1, 2, ...
    and the remaining slots start hidden, so the bar looks the same as before.
    """
    if isinstance(raw.get("slots"), list):
        source = []
        for i in range(SLOTS):
            item = raw["slots"][i] if i < len(raw["slots"]) else None
            if isinstance(item, dict):
                source.append({"name": str(item.get("name") or "").strip(), "hidden": item.get("hidden") is True})
            else:
                source.append(default_slots()[i])
    elif isinstance(raw.get("workspaces"), list):
        names = [str(n).strip() for n in raw["workspaces"] if str(n).strip()][:SLOTS]
        source = [{"name": names[i] if i < len(names) else "", "hidden": i >= len(names)} for i in range(SLOTS)]
    else:
        source = default_slots()
    slots = []
    for slot in source:
        name = slot["name"]
        if name and not WORKSPACE_NAME_RE.match(name):
            if strict:
                raise UserError("Invalid workspace name %r: use letters, digits, '-', '_' or '.' (max 24)." % name)
            name = ""
        if name and name.lower() in taken:
            if strict:
                raise UserError("Workspace name %r is used twice in this profile." % name)
            name = ""
        if name:
            taken.add(name.lower())
        slots.append({"name": name, "hidden": slot["hidden"]})
    return slots


def normalize_profile(profile, catalog, strict=True):
    """Validate and complete a profile. strict=False tolerates overlaps and bad names in stored files."""
    if not isinstance(profile, dict):
        raise UserError("Profile must be an object.")
    name = str(profile.get("name", "")).strip()
    profile_path(name)
    taken = set()

    monitors = []
    for raw in profile.get("monitors") or []:
        match = raw.get("match") or {}
        match = {key: str(match.get(key) or "") for key in ("make", "model", "serial", "description", "output")}
        if not any(match.values()):
            raise UserError("Every monitor needs an identity.")
        parsed = parse_mode(raw.get("mode"))
        width = int(raw.get("width") or (parsed[0] if parsed else 0))
        height = int(raw.get("height") or (parsed[1] if parsed else 0))
        if width <= 0 or height <= 0:
            raise UserError("Monitor %s has no resolution." % (raw.get("label") or match["output"]))
        mode = str(raw.get("mode") or "") if parsed else "%dx%d" % (width, height)
        scale = float(raw.get("scale") or 1)
        if not 0.25 <= scale <= 4:
            raise UserError("Scale must be between 0.25 and 4.")
        transform = int(raw.get("transform") or 0)
        if transform not in range(8):
            raise UserError("Rotation must be 0-7.")
        monitors.append({
            "match": match,
            "label": str(raw.get("label") or match["model"] or match["output"] or "Display"),
            "enabled": raw.get("enabled", True) is not False,
            "mode": mode,
            "width": width,
            "height": height,
            "x": int(round(float(raw.get("x") or 0))),
            "y": int(round(float(raw.get("y") or 0))),
            "scale": round(scale, 6),
            "transform": transform,
            "slots": normalize_slots(raw, taken, strict),
        })

    for i, a in enumerate(monitors):
        for b in monitors[i + 1:]:
            if a["match"] == b["match"]:
                raise UserError("The same display is listed twice in the profile.")

    enabled = [m for m in monitors if m["enabled"]]
    if strict:
        if monitors and not enabled:
            raise UserError("Enable at least one display.")
        for i, a in enumerate(enabled):
            for b in enabled[i + 1:]:
                if rects_overlap(monitor_rect(a), monitor_rect(b)):
                    raise UserError("%s overlaps %s. Move them apart first." % (a["label"], b["label"]))
    if enabled:
        min_x = min(m["x"] for m in enabled)
        min_y = min(m["y"] for m in enabled)
        for m in monitors:
            m["x"] -= min_x
            m["y"] -= min_y

    return {
        "version": 3,
        "name": name,
        "auto": profile.get("auto", True) is not False,
        "monitors": monitors,
    }


# --------------------------------------------------------------------------
# Planning and generation
# --------------------------------------------------------------------------

def is_internal(output):
    return bool(output and INTERNAL_RE.match(output))


def internal_blocked_by_omarchy():
    """Omarchy disabled the laptop panel itself (lid closed while docked, or its manual toggle)."""
    for name in ("internal-monitor-clamshell.lua", "internal-monitor-disable.lua"):
        path = OMARCHY_TOGGLES / name
        if path.exists() and OWN_MARKER not in path.read_text():
            return True
    return False


def slot_key(slot):
    return "0" if slot == SLOTS else str(slot)


def plan(profile, catalog, live_monitors, blocks=None):
    """Work out monitor rules and, for every usable monitor, its ten workspace slots.

    `blocks` maps connector -> Omarchy block; a slot's workspace id is block * 10 + slot.
    Monitors that are missing, disabled or have no block yet get no workspace rules.
    """
    blocks = blocks or {}
    by_name = {m["name"]: m for m in live_monitors}
    matched = resolve(profile, live_monitors)
    blocked = internal_blocked_by_omarchy()
    matched_usable = [out if not (blocked and is_internal(out)) else None for out in matched]
    order = sorted(range(len(profile["monitors"])),
                   key=lambda i: (profile["monitors"][i]["x"], profile["monitors"][i]["y"]))

    monitor_rules, expected = [], {}
    for i, saved in enumerate(profile["monitors"]):
        output = matched[i]
        if not output:
            continue
        live = by_name[output]
        internal = is_internal(output)
        if not saved["enabled"]:
            monitor_rules.append({"output": output, "disabled": True, "internal": internal})
            expected[output] = {"disabled": True}
            continue
        parsed = parse_mode(saved["mode"])
        mode = best_mode(live, saved["width"], saved["height"], parsed[2] if parsed else None, saved["mode"]) or "preferred"
        modes = live_modes(live)
        if modes and mode == modes[0]:
            # The native mode. An explicit string forces a modeset that some panels (eDP) reject,
            # after which Hyprland silently falls back to auto placement; "preferred" is reliable.
            mode = "preferred"
        rule = {"output": output, "mode": mode, "x": saved["x"], "y": saved["y"],
                "scale": saved["scale"], "transform": saved["transform"], "internal": internal}
        monitor_rules.append(rule)
        if not (internal and blocked):
            expected[output] = {"disabled": False, "x": saved["x"], "y": saved["y"],
                                "scale": saved["scale"], "transform": saved["transform"]}

    monitors, targets = [], []
    for i in order:
        saved = profile["monitors"][i]
        output = matched_usable[i] if saved["enabled"] else None
        if not output:
            continue
        block = blocks.get(output)
        entry = {"output": output, "label": saved["label"], "block": block, "slots": []}
        for index, slot in enumerate(saved["slots"]):
            number = index + 1
            target = {"slot": number, "key": slot_key(number), "name": slot["name"], "hidden": slot["hidden"],
                      "output": output, "label": saved["label"],
                      "id": block * SLOTS + number if block is not None else None}
            entry["slots"].append(target)
            targets.append(target)
        monitors.append(entry)

    apps = []
    entries = {w["name"].lower(): w for w in catalog["workspaces"]}
    for target in targets:
        ws = entries.get(target["name"].lower()) if target["name"] and target["id"] else None
        for app in (ws or {}).get("apps", []):
            apps.append({"pattern": app, "name": target["name"], "id": target["id"],
                         "launch": ws.get("launch", {}).get(app, "")})

    return {"profile": profile["name"], "matched": matched, "monitor_rules": monitor_rules,
            "expected": expected, "monitors": monitors, "targets": targets, "apps": apps}


def render_lua(the_plan):
    lines = [
        "-- Generated by omarchy-display-profiles. Do not edit: use the Displays & Workspaces manager.",
        "-- workspace-profiles." + the_plan["profile"],
    ]
    if any(rule.get("internal") for rule in the_plan["monitor_rules"]):
        lines += [
            "-- Omarchy turns the laptop panel off itself (lid closed while docked / manual toggle); respect that.",
            "local function omarchy_internal_off()",
            "  local dir = (os.getenv(\"XDG_STATE_HOME\") or (os.getenv(\"HOME\") .. \"/.local/state\")) .. \"/omarchy/toggles/hypr/\"",
            "  for _, name in ipairs({ \"internal-monitor-clamshell.lua\", \"internal-monitor-disable.lua\" }) do",
            "    local file = io.open(dir .. name, \"r\")",
            "    if file then file:close() return true end",
            "  end",
            "  return false",
            "end",
        ]
    for rule in the_plan["monitor_rules"]:
        if rule.get("disabled"):
            line = "hl.monitor({ output = %s, disabled = true })" % lua_str(rule["output"])
        else:
            line = "hl.monitor({ output = %s, mode = %s, position = %s, scale = %s, transform = %d })" % (
                lua_str(rule["output"]), lua_str(rule["mode"]), lua_str("%dx%d" % (rule["x"], rule["y"])),
                num(rule["scale"]), rule["transform"])
        if rule.get("internal") and not rule.get("disabled"):
            line = "if not omarchy_internal_off() then " + line + " end"
        lines.append(line)
    # Omarchy owns which monitor shows which workspace (its blocks of ten); only names are set here.
    for target in the_plan["targets"]:
        if not target["name"] or not target["id"]:
            continue
        fields = ["workspace = %s" % lua_str(str(target["id"])), "default_name = %s" % lua_str(target["name"]),
                  "monitor = %s" % lua_str(target["output"])]
        if not target["hidden"]:
            fields.append("persistent = true")
        lines.append("hl.workspace_rule({ %s })" % ", ".join(fields))
    for app in the_plan["apps"]:
        lines.append("o.window(%s, { workspace = %s })" % (lua_str(app["pattern"]), lua_str(str(app["id"]))))
    for app in the_plan["apps"]:
        if app.get("launch"):
            lines.append("o.launch_on_start(%s)" % lua_str(app["launch"]))
    return "\n".join(lines) + "\n"


def order_document(the_plan):
    """Read by the workspaces bar widget: per connector, the ten slots and which are hidden."""
    def slot(t):
        return {"slot": t["slot"], "name": t["name"], "hidden": t["hidden"], "id": t["id"]}
    return {
        "version": 3,
        "profile": the_plan["profile"],
        "monitors": [{"output": m["output"], "label": m["label"], "block": m["block"],
                      "slots": [slot(t) for t in m["slots"]]} for m in the_plan["monitors"]],
        "assignments": [{"id": t["id"], "slot": t["slot"], "name": t["name"], "hidden": t["hidden"],
                         "output": t["output"], "label": t["label"]} for t in the_plan["targets"]],
    }


def sync_omarchy_internal(the_plan):
    """Mirror the internal panel rule into monitors.lua (read by Omarchy's clamshell watcher)."""
    rule = next((r for r in the_plan["monitor_rules"] if r.get("internal")), None)
    block = []
    if rule and not rule.get("disabled"):
        block = [MANAGED_BEGIN,
                 'hl.monitor({ output = %s, mode = "preferred", position = %s, scale = %s })' % (
                     lua_str(rule["output"]), lua_str("%dx%d" % (rule["x"], rule["y"])), num(rule["scale"])),
                 MANAGED_END]
    if MONITORS_LUA.exists():
        text = MONITORS_LUA.read_text()
        pattern = re.compile(re.escape(MANAGED_BEGIN) + r".*?" + re.escape(MANAGED_END) + r"\n?", re.S)
        stripped = pattern.sub("", text)
        new = stripped.rstrip("\n") + "\n" + ("\n" + "\n".join(block) + "\n" if block else "")
        if new != text:
            write_text(MONITORS_LUA, new)
    # A profile that switches the panel off uses Omarchy's own manual toggle, so its watcher agrees.
    flag = OMARCHY_TOGGLES / "internal-monitor-disable.lua"
    if rule and rule.get("disabled"):
        if not flag.exists():
            write_text(flag, 'hl.monitor({ output = %s, disabled = true }) %s\n' % (lua_str(rule["output"]), OWN_MARKER))
    elif flag.exists() and OWN_MARKER in flag.read_text():
        flag.unlink()


def title(name):
    return name.replace("-", " ").replace("_", " ").title()


def sync_menu(the_plan, profiles):
    """Regenerate the workspace and profile entries of the Omarchy menu extension.

    Workspace entries list every visible slot of every monitor, addressed as OUTPUT:SLOT.
    """
    if not MENU.exists():
        return
    lines = MENU.read_text().splitlines()
    visible = [t for t in the_plan["targets"] if not t["hidden"]]

    def entries(prefix, command):
        result = []
        for t in visible:
            key = "%s.%s-%s" % (prefix, re.sub(r"[^a-z0-9-]", "-", t["output"].lower()), t["key"])
            label = title(t["name"]) if t["name"] else "Workspace " + t["key"]
            result.append('  "%s": %s,' % (key, json.dumps(
                {"icon": "󰙀", "label": label, "description": "%s · Super+%s" % (t["label"], t["key"]),
                 "action": "%s %s:%d" % (command, t["output"], t["slot"])}, ensure_ascii=False)))
        return result

    blocks = [
        ("trigger.workspaces", re.compile(r'^\s*"trigger\.workspaces\.[^"]+"\s*:'),
         entries("trigger.workspaces", "omarchy-workspace-switch")),
        ("trigger.move-window-workspace", re.compile(r'^\s*"trigger\.move-window-workspace\.(?!scratchpad")[^"]+"\s*:'),
         entries("trigger.move-window-workspace", "omarchy-workspace-move-window")),
        ("trigger.monitor-profile", re.compile(r'^\s*"trigger\.monitor-profile\.[^"]+"\s*:'),
         ['  "trigger.monitor-profile.%s": %s,' % (p["name"], json.dumps(
             {"icon": "󰍹", "label": title(p["name"]), "action": "omarchy-display-profiles apply " + p["name"]},
             ensure_ascii=False)) for p in profiles]),
    ]
    for parent, pattern, replacement in blocks:
        positions = [i for i, line in enumerate(lines) if pattern.match(line)]
        if positions:
            first = positions[0]
            drop = set(positions)
            lines = [line for i, line in enumerate(lines) if i not in drop]
        else:
            parent_re = re.compile(r'^\s*"%s"\s*:' % re.escape(parent))
            first = next((i + 1 for i, line in enumerate(lines) if parent_re.match(line)), None)
            if first is None:
                continue
        lines[first:first] = replacement
    write_text(MENU, "\n".join(lines) + "\n")


# --------------------------------------------------------------------------
# Applying
# --------------------------------------------------------------------------

class Locked:
    def __init__(self, timeout=30):
        self.timeout = timeout

    def __enter__(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.handle = open(LOCK, "w")
        deadline = time.time() + self.timeout
        while True:
            try:
                fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except BlockingIOError:
                if time.time() > deadline:
                    raise UserError("Another profile operation is still running.")
                time.sleep(0.1)

    def __exit__(self, *exc):
        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()


def unsettled_outputs(expected, live_monitors):
    by_name = {m["name"]: m for m in live_monitors}
    bad = set()
    for output, want in expected.items():
        live = by_name.get(output)
        if live is None:
            continue
        if want["disabled"]:
            if not live.get("disabled"):
                bad.add(output)
            continue
        if live.get("disabled") or abs(live["x"] - want["x"]) > 1 or abs(live["y"] - want["y"]) > 1 or \
                abs(float(live["scale"]) - float(want["scale"])) > 0.01 or int(live["transform"]) != want["transform"]:
            bad.add(output)
    return bad


def settled(expected, live_monitors):
    return not unsettled_outputs(expected, live_monitors)


def wait_settled(hypr, expected, attempts=25):
    live = hypr.monitors()
    for _ in range(attempts):
        hypr.sleep(0.2)
        live = hypr.monitors()
        if settled(expected, live):
            break
    return live


def window_moves(the_plan, clients, workspaces):
    """Decide which windows to move so every named workspace keeps its content."""
    target_by_name = {t["name"].lower(): t for t in the_plan["targets"] if t["name"] and t["id"]}
    ws_names = {w["id"]: w.get("name", "") for w in workspaces}
    compiled = [(re.compile(a["pattern"]), a) for a in the_plan["apps"]]
    moves = []
    for client in clients:
        ws = client.get("workspace") or {}
        ws_id, ws_name = ws.get("id"), ws.get("name") or ws_names.get(ws.get("id"), "")
        if ws_name.startswith("special") or client.get("pinned"):
            continue
        target = target_by_name.get(ws_name.lower())
        if target is None:
            # Unmanaged or orphan workspace: only pull windows that have an app rule.
            if ws_id is not None and ws_id > 0 and str(ws_id) == ws_name:
                continue  # plain numbered workspace; Omarchy keeps those on their monitor
            for pattern, app in compiled:
                if pattern.search(client.get("class") or ""):
                    target = target_by_name.get(app["name"].lower())
                    break
        if target and target["id"] != ws_id:
            moves.append({"address": client["address"], "id": target["id"], "class": client.get("class", "")})
    return moves


def lua_step(expr, tag):
    return "step(function() return %s end, %s)" % (expr, lua_str(tag))


def runtime_script(the_plan, moves, live_after, active_address):
    lines = [
        "local fails = {}",
        "local function step(make, tag)",
        "  local ok, result = pcall(function() return hl.dispatch(make()) end)",
        "  if not ok or (type(result) == 'table' and result.ok == false) then fails[#fails + 1] = tag end",
        "end",
        "local function call(fn, tag)",
        "  if not pcall(fn) then fails[#fails + 1] = tag end",
        "end",
        "local function show(slot, output)",
        "  if o and o.workspaces and o.workspaces.focus then o.workspaces.focus(slot, output)() end",
        "end",
    ]
    for move in moves:
        lines.append(lua_step("hl.dsp.window.move({ window = %s, workspace = %s, follow = false })" % (
            lua_str("address:" + move["address"]), lua_str(str(move["id"]))), "move " + move["class"]))
    for target in the_plan["targets"]:
        if not target["id"]:
            continue
        wid = lua_str(str(target["id"]))
        # Unnamed slots go back to their plain number, which Hyprland uses as the name.
        name = lua_str(target["name"] or str(target["id"]))
        lines.append("do local w = hl.get_workspace(%s) if w and w.name ~= %s then %s end end" % (wid, name, lua_step(
            "hl.dsp.workspace.rename({ workspace = %d, name = %s })" % (target["id"], name),
            "rename " + (target["name"] or str(target["id"])))))
    # A monitor showing a workspace outside its own block, or one of its hidden slots,
    # goes to its first visible slot.
    for monitor in the_plan["monitors"]:
        if monitor["block"] is None:
            continue
        live = next((m for m in live_after if m["name"] == monitor["output"]), None)
        if not live or live.get("disabled"):
            continue
        shown = {t["id"] for t in monitor["slots"] if not t["hidden"]}
        active = (live.get("activeWorkspace") or {}).get("id")
        if shown and active not in shown:
            first = next(t for t in monitor["slots"] if not t["hidden"])
            lines.append("call(function() show(%d, %s) end, %s)" % (
                first["slot"], lua_str(monitor["output"]), lua_str("show " + monitor["output"])))
    if active_address:
        lines.append(lua_step("hl.dsp.focus({ window = %s })" % lua_str("address:" + active_address), "refocus"))
    lines.append("return #fails == 0 and 'ok' or table.concat(fails, '; ')")
    return "\n".join(lines)


def apply_profile(profile, hypr=None, move_windows=True, record=True, manual=False, reason="apply"):
    hypr = hypr or Hypr()
    catalog = load_catalog()
    with Locked():
        live = hypr.monitors()
        if not live:
            raise UserError("No monitors reported by Hyprland.")
        the_plan = plan(profile, catalog, live, hypr.blocks())
        clients, workspaces = hypr.clients(), hypr.workspaces()
        active = hypr.active_window()

        def write_generated():
            write_text(ACTIVE_LUA, render_lua(the_plan))
            write_json(ORDER_JSON, order_document(the_plan))

        write_generated()
        try:
            sync_omarchy_internal(the_plan)
        except OSError as error:
            print("warning: could not sync Omarchy internal panel state: %s" % error, file=sys.stderr)

        hypr.reload()
        live_after = wait_settled(hypr, the_plan["expected"])
        layout_warnings = []
        failing = unsettled_outputs(the_plan["expected"], live_after)
        if failing:
            # Retry once letting Hyprland choose the mode for outputs that rejected their rule.
            for rule in the_plan["monitor_rules"]:
                if rule["output"] in failing and not rule.get("disabled"):
                    rule["mode"] = "preferred"
            write_text(ACTIVE_LUA, render_lua(the_plan))
            hypr.reload()
            live_after = wait_settled(hypr, the_plan["expected"])
            still = unsettled_outputs(the_plan["expected"], live_after)
            if still:
                layout_warnings.append("Hyprland did not accept the layout for " + ", ".join(sorted(still)) + ".")

        # A monitor enabled by this profile only gets its Omarchy block once Hyprland has it.
        blocks_after = hypr.blocks()
        if any(m["block"] != blocks_after.get(m["output"], m["block"]) for m in the_plan["monitors"]):
            rules = the_plan["monitor_rules"]
            the_plan = plan(profile, catalog, live_after, blocks_after)
            the_plan["monitor_rules"] = rules
            write_generated()
            hypr.reload()
        try:
            sync_menu(the_plan, list_profiles(catalog))
        except (OSError, UserError) as error:
            print("warning: menu not updated: %s" % error, file=sys.stderr)
        errors = hypr.config_errors()

        result = "ok"
        moves = window_moves(the_plan, clients, workspaces) if move_windows else []
        if move_windows:
            # Workspaces may have been renamed by an earlier profile; re-read after reload.
            result = hypr.lua(runtime_script(the_plan, moves, live_after, active and active.get("address")))

        if record:
            save_state(active=profile["name"], manual=manual, signature=monitor_signature(live),
                       applied_at=int(time.time()), reason=reason)
        missing = [m["label"] for m, out in zip(profile["monitors"], the_plan["matched"]) if not out]
        return {
            "applied": profile["name"],
            "moved": len(moves),
            "missing": missing,
            "warnings": layout_warnings + ([] if result in ("ok", "") else ["Some steps failed: " + result]) + errors,
        }


# --------------------------------------------------------------------------
# Profiles from the live setup and from the legacy format
# --------------------------------------------------------------------------

def monitor_from_live(live, slots=None):
    return {
        "match": {k: v for k, v in fingerprint(live).items()},
        "label": short_label(live),
        "enabled": not live.get("disabled"),
        "mode": current_mode(live),
        "width": live.get("width", 0),
        "height": live.get("height", 0),
        "x": live.get("x", 0),
        "y": live.get("y", 0),
        "scale": live.get("scale", 1),
        "transform": live.get("transform", 0),
        "slots": copy.deepcopy(slots) if slots else default_slots(),
    }


def draft_from_live(live_monitors, catalog, base=None):
    """A profile describing the current setup, reusing slot names from `base` where monitors match."""
    monitors = [monitor_from_live(m) for m in sorted(live_monitors, key=lambda m: (m.get("x", 0), m.get("y", 0)))]
    if base:
        matched = resolve(base, live_monitors)
        by_output = {m["match"]["output"]: m for m in monitors}
        for saved, output in zip(base["monitors"], matched):
            if output in by_output:
                by_output[output]["slots"] = copy.deepcopy(saved["slots"])
    draft = {"name": "new-profile", "auto": True, "monitors": monitors}
    return normalize_profile(draft, catalog, strict=False)


LEGACY_KEY_NAMES = {"1": "terminal", "2": "browser", "3": "editor", "4": "remote", "5": "utilities",
                    "6": "references", "7": "ai", "8": "outlook", "9": "teams", "10": "10"}


def migrate_legacy(live_monitors, catalog):
    """Convert ~/.config/hypr/workspace-profiles/*.json (v1) into v2 profiles."""
    by_desc = {m.get("description"): m for m in live_monitors}
    by_output = {m.get("name"): m for m in live_monitors}
    catalog_names = {w["name"] for w in catalog["workspaces"]}
    migrated = []
    for path in sorted(LEGACY_PROFILES.glob("*.json")):
        old = read_json(path, {})
        names = old.get("names") or {}
        numbering = old.get("numbering") or {}

        def ws_name(key):
            name = names.get(key) or LEGACY_KEY_NAMES.get(key, key)
            return name if name in catalog_names else None

        monitors, identity_index = [], {}
        for entry in old.get("layout") or []:
            identity = entry.get("monitor", "")
            if identity.startswith("desc:"):
                desc = identity[5:]
                live = by_desc.get(desc)
                match = fingerprint(live) if live else {"make": "", "model": "", "serial": "", "description": desc,
                                                        "output": ""}
                label = short_label(live) if live else desc
            else:
                output = identity.removeprefix("output:")
                live = by_output.get(output)
                match = fingerprint(live) if live else {"make": "", "model": "", "serial": "", "description": "",
                                                        "output": output}
                label = short_label(live) if live else output
            width, height = int(entry.get("width") or 1920), int(entry.get("height") or 1080)
            refresh = entry.get("refreshRate")
            mode = (best_mode(live, width, height, refresh) if live else None) or \
                ("%dx%d@%.2fHz" % (width, height, float(refresh)) if refresh else "%dx%d" % (width, height))
            identity_index[identity] = len(monitors)
            monitors.append({"match": match, "label": label, "enabled": True, "mode": mode,
                             "width": width, "height": height, "x": entry.get("x", 0), "y": entry.get("y", 0),
                             "scale": entry.get("scale", 1), "transform": entry.get("transform", 0),
                             "workspaces": []})
        parked, numbers = [], {}
        for assignment in old.get("assignments") or []:
            key = str(assignment.get("workspace"))
            name = ws_name(key)
            if not name:
                continue
            if numbering.get(key):
                numbers[name] = numbering[key]
            index = identity_index.get(assignment.get("monitor") or "")
            if index is None:
                parked.append(name)
            else:
                monitors[index]["workspaces"].append(name)
        profile = {"name": path.stem, "auto": True, "monitors": monitors, "parked": parked, "numbers": numbers}
        migrated.append(normalize_profile(profile, catalog, strict=False))
    return migrated


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def live_view(live):
    view = []
    for m in live:
        entry = {k: m.get(k) for k in ("name", "description", "make", "model", "serial", "width", "height",
                                       "refreshRate", "x", "y", "scale", "transform", "disabled", "focused")}
        entry["label"] = short_label(m)
        entry["match"] = fingerprint(m)
        entry["mode"] = current_mode(m)
        entry["modes"] = live_modes(m)
        sizes = {}
        for mode in entry["modes"]:
            parsed = parse_mode(mode)
            if parsed:
                sizes.setdefault("%dx%d" % parsed[:2], clean_scales(parsed[0], parsed[1]))
        entry["scales"] = sizes
        entry["activeWorkspace"] = (m.get("activeWorkspace") or {}).get("id")
        view.append(entry)
    return view


def cmd_state(hypr):
    catalog = load_catalog()
    live = hypr.monitors()
    profiles = list_profiles(catalog)
    state = load_state()
    active = state.get("active") if any(p["name"] == state.get("active") for p in profiles) else None
    for profile in profiles:
        matched = resolve(profile, live)
        profile["status"] = {"matched": matched, "complete": all(matched) and bool(matched),
                             "missing": sum(1 for m in matched if not m)}
    base = next((p for p in profiles if p["name"] == active), None)
    windows, seen = [], set()
    for client in hypr.clients():
        cls = client.get("class") or ""
        if cls and cls not in seen:
            seen.add(cls)
            windows.append({"class": cls, "title": client.get("title") or "",
                            "workspace": (client.get("workspace") or {}).get("name", "")})
    return {
        "connected": live_view(live),
        "catalog": catalog,
        "profiles": profiles,
        "active": active,
        "manual": bool(state.get("manual")),
        "detected": detect(profiles, live),
        "current": draft_from_live([m for m in live], catalog, base),
        "windows": sorted(windows, key=lambda w: w["class"].lower()),
    }


def cmd_save(document, rename_from=None):
    catalog = load_catalog()
    profile = normalize_profile(document, catalog, strict=True)
    path = profile_path(profile["name"])
    if rename_from and rename_from != profile["name"]:
        old = profile_path(rename_from)
        if path.exists():
            raise UserError("A profile named %s already exists." % profile["name"])
        write_json(path, profile)
        if old.exists():
            old.unlink()
        state = load_state()
        if state.get("active") == rename_from:
            save_state(active=profile["name"])
    else:
        write_json(path, profile)
    return {"saved": profile["name"], "profile": profile}


def cmd_delete(name):
    path = profile_path(name)
    if not path.exists():
        raise UserError("Unknown profile: %s" % name)
    if load_state().get("active") == name:
        raise UserError("Cannot delete the active profile. Apply another profile first.")
    path.unlink()
    return {"deleted": name}


def cmd_catalog_save(document, hypr):
    """Save the app rules per workspace name; renames ({"renames": {old: new}}) apply to every profile."""
    renames = {str(k).lower(): str(v) for k, v in (document.get("renames") or {}).items()}
    catalog = normalize_catalog(document)
    if renames:
        for path in sorted(PROFILES.glob("*.json")):
            raw = read_json(path, {})
            for monitor in raw.get("monitors") or []:
                for slot in monitor.get("slots") or []:
                    if isinstance(slot, dict) and str(slot.get("name") or "").lower() in renames:
                        slot["name"] = renames[str(slot["name"]).lower()]
            write_json(path, raw)
    write_json(CATALOG, catalog)
    result = {"catalog": catalog}
    active = load_state().get("active")
    if active and profile_path(active).exists():
        result["apply"] = apply_profile(load_profile(active, catalog), hypr, manual=load_state().get("manual", False),
                                        reason="catalog")
    return result


SLOT_REF_RE = re.compile(r"^(.+):(\d+)$")


def resolve_workspace(name):
    """(output, slot) for "OUTPUT:SLOT", a workspace name or a workspace id from the active profile."""
    text = str(name)
    match = SLOT_REF_RE.match(text)
    if match and 1 <= int(match.group(2)) <= SLOTS:
        return match.group(1), int(match.group(2))
    order = read_json(ORDER_JSON, {}) or {}
    for item in order.get("assignments") or []:
        if (item.get("name") and item["name"].lower() == text.lower()) or \
                (item.get("id") is not None and str(item["id"]) == text):
            return item["output"], item["slot"]
    return None


def cmd_switch(name, hypr, send=False):
    if str(name).startswith("special:"):
        workspace = str(name)
        if send:
            code = "hl.dispatch(hl.dsp.window.move({ workspace = %s, follow = true }))" % lua_str(workspace)
        else:
            code = "hl.dispatch(hl.dsp.focus({ workspace = %s }))" % lua_str(workspace)
        hypr.lua(code + " return 'ok'")
        return {"workspace": workspace}
    ref = resolve_workspace(name)
    if ref is None:
        raise UserError("Unknown workspace: %s" % name)
    output, slot = ref
    # Omarchy's focus brings the slot's workspace onto its own monitor (creating it there if needed),
    # so a window sent to an empty slot on another monitor lands on that monitor.
    lines = [
        "local monitor = hl.get_monitor(%s)" % lua_str(output),
        "if not monitor then return 'no monitor' end",
        "local id = o.workspaces.workspace_id(monitor, %d)" % slot,
    ]
    if send:
        lines += [
            "local window = hl.get_active_window()",
            "if not window then return 'no window' end",
            "if not hl.get_workspace(id) then o.workspaces.focus(%d, %s)() end" % (slot, lua_str(output)),
            "hl.dispatch(hl.dsp.window.move({ window = 'address:' .. window.address, workspace = tostring(id), follow = true }))",
        ]
    else:
        lines.append("o.workspaces.focus(%d, %s)()" % (slot, lua_str(output)))
    lines.append("return tostring(id)")
    result = hypr.lua("\n".join(lines))
    if not result.isdigit():
        raise UserError("Could not reach %s:%d (%s)." % (output, slot, result))
    return {"workspace": result, "output": output, "slot": slot}


def sync(hypr, reason, force=False):
    live = hypr.monitors()
    profiles = list_profiles()
    best = detect(profiles, live)
    state = load_state()
    signature = monitor_signature(live)
    if best is None:
        if state.get("signature") != signature:
            save_state(signature=signature)
        return {"skipped": "no matching profile"}
    if not force and best == state.get("active") and signature == state.get("signature"):
        return {"skipped": "already applied"}
    if not force and state.get("manual") and signature == state.get("signature"):
        return {"skipped": "manual profile kept"}
    profile = next(p for p in profiles if p["name"] == best)
    return apply_profile(profile, hypr, manual=False, reason=reason)


def wait_for_stable_monitors(hypr, settle=1.2, timeout=10):
    deadline = time.time() + timeout
    last, stable_since = None, time.time()
    while time.time() < deadline:
        current = monitor_signature(hypr.monitors())
        if current != last:
            last, stable_since = current, time.time()
        elif time.time() - stable_since >= settle:
            return
        time.sleep(0.3)


def cmd_watch(hypr):
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    if not signature:
        raise UserError("HYPRLAND_INSTANCE_SIGNATURE is not set.")
    path = "%s/hypr/%s/.socket2.sock" % (runtime, signature)

    def run_sync(reason, force=False):
        try:
            wait_for_stable_monitors(hypr)
            print(json.dumps(sync(hypr, reason, force)), flush=True)
        except Exception as error:  # the watcher must survive anything
            print("sync failed: %s" % error, file=sys.stderr, flush=True)

    time.sleep(1.5)
    run_sync("startup", force=True)
    while True:
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(path)
        except OSError as error:
            print("cannot connect to %s: %s" % (path, error), file=sys.stderr, flush=True)
            time.sleep(2)
            continue
        buffer, due = b"", None
        with sock:
            while True:
                timeout = None if due is None else max(0.0, due - time.time())
                readable, _, _ = select.select([sock], [], [], timeout)
                if readable:
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    buffer += chunk
                    *events, buffer = buffer.split(b"\n")
                    for event in events:
                        if event.split(b">>", 1)[0] in (b"monitoradded", b"monitoraddedv2",
                                                        b"monitorremoved", b"monitorremovedv2"):
                            due = time.time() + 0.8
                if due is not None and time.time() >= due:
                    due = None
                    run_sync("hotplug")
        time.sleep(1)


def read_document(args):
    raw = args[0] if args and args[0] != "-" else sys.stdin.read()
    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise UserError("Invalid JSON: %s" % error)


USAGE = """usage: omarchy-display-profiles <command>
  state                         JSON state for the UI
  apply NAME [--no-windows]     apply a saved profile
  apply-draft JSON              apply an unsaved profile (for Try)
  auto [--force]                apply the best matching profile
  save JSON [--rename-from OLD] validate and save a profile
  delete NAME                   delete a profile
  catalog-save JSON             save app rules per workspace name (with "renames")
  switch REF | send REF         focus / move the active window to a workspace;
                                REF is OUTPUT:SLOT (e.g. DP-6:1), a workspace name or an id
  upgrade                       rewrite stored profiles in the current format
  migrate [--force]             convert legacy workspace-profiles/*.json
  watch                         follow monitor hotplug events and switch profiles"""


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    hypr = Hypr()
    command, args = argv[0], argv[1:]
    if command == "state":
        result = cmd_state(hypr)
    elif command == "apply":
        if not args:
            raise UserError("apply needs a profile name")
        result = apply_profile(load_profile(args[0]), hypr, move_windows="--no-windows" not in args, manual=True)
    elif command == "apply-draft":
        catalog = load_catalog()
        profile = normalize_profile(read_document(args), catalog, strict=True)
        result = apply_profile(profile, hypr, record=False, reason="try")
    elif command == "auto":
        result = sync(hypr, "manual-auto", force="--force" in args)
    elif command == "save":
        rename_from = args[args.index("--rename-from") + 1] if "--rename-from" in args else None
        doc_args = [a for i, a in enumerate(args) if a != "--rename-from" and (i == 0 or args[i - 1] != "--rename-from")]
        result = cmd_save(read_document(doc_args), rename_from)
    elif command == "delete":
        result = cmd_delete(args[0] if args else "")
    elif command == "catalog-save":
        result = cmd_catalog_save(read_document(args), hypr)
    elif command in ("switch", "send"):
        if not args:
            raise UserError("%s needs a workspace name" % command)
        result = cmd_switch(args[0], hypr, send=command == "send")
    elif command == "upgrade":
        catalog = load_catalog()
        done = []
        for path in sorted(PROFILES.glob("*.json")):
            write_json(path, normalize_profile(read_json(path), catalog, strict=False))
            done.append(path.stem)
        write_json(CATALOG, catalog)
        result = {"upgraded": done}
    elif command == "migrate":
        catalog = load_catalog()
        if not CATALOG.exists():
            write_json(CATALOG, catalog)
        done = []
        for profile in migrate_legacy(hypr.monitors(), catalog):
            path = profile_path(profile["name"])
            if path.exists() and "--force" not in args:
                continue
            write_json(path, profile)
            done.append(profile["name"])
        result = {"migrated": done}
    elif command == "watch":
        cmd_watch(hypr)
        return 0
    else:
        print(USAGE, file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except UserError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
