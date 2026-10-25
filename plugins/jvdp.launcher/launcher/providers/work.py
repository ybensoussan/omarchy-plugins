"""Where work happens: herdr spaces and project folders."""

from __future__ import annotations

import glob
import json
import os
import re
import time

from . import Provider, action, close, item, toast
from .. import util

SPACES_CONF = util.HOME / ".config/herdr/spaces.conf"


def read_spaces_conf() -> list[dict]:
    """label, folder and command per line of spaces.conf (comments skipped)."""
    out = []
    try:
        lines = SPACES_CONF.read_text(encoding="utf-8").splitlines()
    except OSError:
        return out
    for line in lines:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 2)
        out.append({"label": parts[0], "folder": parts[1] if len(parts) > 1 else "",
                    "command": parts[2] if len(parts) > 2 else ""})
    return out


def focus_herdr_window() -> None:
    """Bring the terminal running herdr forward, or open one."""
    raw = util.run(["hyprctl", "clients", "-j"], timeout=2)
    try:
        clients = json.loads(raw) if raw else []
    except ValueError:
        clients = []
    for c in sorted(clients, key=lambda c: c.get("focusHistoryID", 99)):
        if re.match(r"^[\w.-]+: ", str(c.get("title") or "")) and c.get("class") in ("foot", "Alacritty", "kitty",
                                                                                      "com.mitchellh.ghostty"):
            util.spawn(["hyprctl", "dispatch", "focuswindow", "address:" + c["address"]])
            return
    util.spawn(["omarchy-launch-terminal-herdr"])


class Herdr(Provider):
    id = "herdr"
    name = "herdr spaces"
    prefix = "hs"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.items: list[dict] = []

    def available(self):
        return util.have("herdr")

    def refresh(self):
        running = {}
        raw = util.run(["herdr", "workspace", "list"], timeout=3)
        try:
            for w in json.loads(raw)["result"]["workspaces"]:
                running.setdefault(w.get("label"), w)
        except (ValueError, KeyError, TypeError):
            pass
        items = []
        conf = read_spaces_conf()
        for sp in conf:
            w = running.get(sp["label"])
            items.append(item("herdr", sp["label"], sp["label"], subtitle=util.tilde(util.expand(sp["folder"])),
                              icon="", accessory="Running" if w else "herdr space",
                              _keywords=["herdr", "space", sp["folder"]], _label=sp["label"],
                              _ws=w.get("workspace_id") if w else "", _agent=w.get("agent_status", "") if w else "",
                              _folder=str(util.expand(sp["folder"]))))
        known = {sp["label"] for sp in conf}
        for label, w in running.items():
            if label and label not in known:
                items.append(item("herdr", label, label, subtitle="herdr workspace", icon="",
                                  accessory="Running", _keywords=["herdr"], _label=label,
                                  _ws=w.get("workspace_id", ""), _folder=""))
        self.items = items

    def search(self, q, scoped):
        found = self.rank(q, self.items)
        for it in found:
            if it.get("_agent") == "working":
                it["accessory"] = "Agent working"
        return found

    def browse(self):
        return self.items

    def resolve(self, item_id):
        for it in self.items:
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        acts = [action("default", "Go to space", "")]
        if it.get("_folder"):
            acts += [action("new", "New project in this space…", "󰐕", "ctrl+n"),
                     action("files", "Open folder", "󰉋", "ctrl+o")]
        return acts

    def run(self, it, aid, arg):
        if aid == "files":
            util.open_target(it["_folder"])
            return [close()]
        if aid == "new":
            if not arg:
                return [{"type": "arg", "item": it["id"], "action": "new", "placeholder": "Project name",
                         "title": f"New project in {it['_label']}"}]
            name = re.sub(r"[^\w.-]+", "-", arg.strip()).strip("-")
            if not name:
                return [toast("That name doesn't work as a folder", True)]
            ok, out = util.run_ok(["herdr-spaces", "new", it["_label"], name], timeout=20)
            if not ok:
                return [toast((out.splitlines() or ["herdr-spaces failed"])[-1], True)]
            focus_herdr_window()
            return [close()]
        if not it.get("_ws"):
            # Not running yet: herdr-spaces creates the missing ones.
            util.run_ok(["herdr-spaces"], timeout=20)
            time.sleep(0.3)
            self.refresh()
            it = self.resolve(it["id"]) or it
        if it.get("_ws"):
            util.run_ok(["herdr", "workspace", "focus", it["_ws"]], timeout=3)
        focus_herdr_window()
        return [close()]


class Projects(Provider):
    id = "projects"
    name = "Projects"
    prefix = "pj"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.items: list[dict] = []
        self.scanned = 0.0

    def refresh(self):
        if time.time() - self.scanned < 30 and self.items:
            return
        seen = set()
        items = []
        for pattern in self.settings.get("projects.roots", []):
            for path in sorted(glob.glob(str(util.expand(pattern)))):
                if not os.path.isdir(path) or path in seen or os.path.basename(path).startswith("."):
                    continue
                seen.add(path)
                name = os.path.basename(path)
                parent = os.path.basename(os.path.dirname(path))
                is_git = os.path.isdir(os.path.join(path, ".git"))
                items.append(item("projects", path, name, subtitle=util.tilde(path), icon="" if is_git else "󰉋",
                                  accessory="Project", _keywords=[parent], _path=path))
        self.items = items
        self.scanned = time.time()

    def search(self, q, scoped):
        return self.rank(q, self.items, minimum=1 if scoped else 500)

    def browse(self):
        return self.items

    def resolve(self, item_id):
        for it in self.items:
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        names = {"terminal": ("Open terminal here", ""), "editor": ("Open in editor", "󰷈"),
                 "files": ("Open folder", "󰉋")}
        first = self.settings.get("projects.open", "terminal")
        order = [first] + [k for k in ("terminal", "editor", "files") if k != first]
        keys = {"terminal": "ctrl+t", "editor": "ctrl+e", "files": "ctrl+o"}
        acts = [action("default", names[first][0], names[first][1])]
        acts += [action(k, names[k][0], names[k][1], keys[k]) for k in order[1:]]
        acts.append(action("copy", "Copy path", "󰆏", "ctrl+shift+c"))
        return acts

    def run(self, it, aid, arg):
        path = it["_path"]
        if aid == "default":
            aid = self.settings.get("projects.open", "terminal")
        if aid == "copy":
            util.copy(path)
            return [toast("Copied " + util.tilde(path))]
        if aid == "editor":
            util.editor(path)
        elif aid == "files":
            util.open_target(path)
        else:
            util.terminal(cwd=path)
        return [close()]
