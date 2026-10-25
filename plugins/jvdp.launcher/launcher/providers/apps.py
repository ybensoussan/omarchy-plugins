"""Applications, and the open windows to switch to."""

from __future__ import annotations

import json

from . import Provider, action, close, item, launch_app, toast
from .. import util


class Apps(Provider):
    """The app list comes from the shell (Omarchy's own app library), so hidden
    entries stay hidden and launching shows Omarchy's launch feedback."""

    id = "apps"
    name = "Applications"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.entries: list[dict] = []

    def set_apps(self, apps: list) -> None:
        out = []
        for a in apps if isinstance(apps, list) else []:
            if not isinstance(a, dict) or not a.get("id"):
                continue
            app_id = str(a["id"])
            name = str(a.get("name") or app_id)
            keywords = [str(a.get("generic") or ""), str(a.get("exec") or "").split(" ")[0].split("/")[-1]]
            keywords += [str(k) for k in (a.get("keywords") or []) if k]
            out.append(item("apps", app_id, name,
                            subtitle=str(a.get("comment") or a.get("generic") or ""),
                            appIcon=str(a.get("icon") or ""), accessory="Application",
                            _keywords=[k for k in keywords if k], _actions=a.get("actions") or []))
            for act in a.get("actions") or []:
                if not isinstance(act, dict) or not act.get("id"):
                    continue
                out.append(item("apps", f"{app_id}#{act['id']}", f"{name}: {act.get('name') or act['id']}",
                                appIcon=str(act.get("icon") or a.get("icon") or ""), accessory="Application",
                                _keywords=[name], _app=app_id, _action=str(act["id"]), _sub=True))
        self.entries = out

    def search(self, q, scoped):
        found = self.rank(q, self.entries)
        # An app's own actions ("New Private Window") only when asked for closely.
        return [it for it in found if not it.get("_sub") or it["score"] >= 700]

    def browse(self):
        return [it for it in self.entries if not it.get("_sub")]

    def resolve(self, item_id):
        for it in self.entries:
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        return [action("default", "Open", "󰏌"),
                action("files", "Show desktop file", "󰉋", "ctrl+o"),
                action("copy-id", "Copy desktop id", "󰆏", "ctrl+shift+c")]

    def run(self, it, aid, arg):
        app_id = it.get("_app") or it["id"].split(":", 1)[1]
        if aid == "copy-id":
            util.copy(app_id)
            return [toast("Copied " + app_id)]
        if aid == "files":
            for base in ("~/.local/share/applications", "/usr/share/applications"):
                p = util.expand(base) / app_id
                if not p.name.endswith(".desktop"):
                    p = p.with_name(p.name + ".desktop")
                if p.exists():
                    util.open_target(str(p.parent))
                    return [close()]
            return [toast("Desktop file not found", True)]
        return [launch_app(app_id, it["title"], it.get("_action", "")), close()]


class Windows(Provider):
    id = "windows"
    name = "Windows"
    prefix = "win"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.clients: list[dict] = []

    def available(self):
        return util.have("hyprctl")

    def refresh(self):
        raw = util.run(["hyprctl", "clients", "-j"], timeout=2)
        try:
            clients = json.loads(raw) if raw else []
        except ValueError:
            clients = []
        items = []
        for c in clients if isinstance(clients, list) else []:
            if not isinstance(c, dict) or not c.get("mapped", True) or not c.get("address"):
                continue
            cls = str(c.get("class") or c.get("initialClass") or "")
            title = str(c.get("title") or cls)
            ws = c.get("workspace", {}) if isinstance(c.get("workspace"), dict) else {}
            items.append(item("windows", str(c["address"]), title or cls,
                              subtitle=f"{cls} · workspace {ws.get('name', '?')}",
                              appIcon=_icon_for_class(cls), accessory="Window", recordable=False,
                              _keywords=[cls, str(c.get("initialTitle") or "")],
                              _focus=c.get("focusHistoryID", 99)))
        self.clients = items

    def search(self, q, scoped):
        found = self.rank(q, self.clients)
        for it in found:
            # Below apps with the same name: typing "zen" opens… the app list first.
            it["score"] -= 40
        return found

    def browse(self):
        return sorted(self.clients, key=lambda it: it.get("_focus", 99))

    def actions(self, it):
        return [action("default", "Switch to window", "󰖯"),
                action("here", "Move to this workspace", "󱂬", "ctrl+enter"),
                action("close", "Close window", "󰅖", "ctrl+w")]

    def run(self, it, aid, arg):
        addr = "address:" + it["id"].split(":", 1)[1]
        if aid == "close":
            util.spawn(["hyprctl", "dispatch", "closewindow", addr])
            self.clients = [c for c in self.clients if c["id"] != it["id"]]
            return [toast("Closed " + it["title"]), {"type": "refresh"}]
        if aid == "here":
            util.spawn(["hyprctl", "dispatch", "movetoworkspace", f"+0,{addr}"])
        util.spawn(["hyprctl", "dispatch", "focuswindow", addr])
        return [close()]


def _icon_for_class(cls: str) -> str:
    # Most apps name their icon after the window class; web apps and a few
    # others don't, and the overlay falls back to a generic icon for those.
    c = cls.strip()
    known = {"foot": "foot", "Alacritty": "Alacritty", "com.mitchellh.ghostty": "com.mitchellh.ghostty",
             "zen": "zen-browser", "teams-for-linux": "teams-for-linux"}
    if c in known:
        return known[c]
    if c.startswith("teams-"):
        return "teams-for-linux"
    return c.lower() if c else ""
