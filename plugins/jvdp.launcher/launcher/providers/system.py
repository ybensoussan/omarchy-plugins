"""The machine: shell commands, processes, keyboard shortcuts, audio, Bluetooth,
Wi-Fi, themes and Azure subscriptions."""

from __future__ import annotations

import json
import os
import re
import signal

from . import Provider, action, close, detail, item, refresh, toast
from .. import match, util


class Shell(Provider):
    id = "shell"
    name = "Shell command"
    prefix = ">"
    in_global = False

    def search(self, q, scoped):
        q = q.strip()
        if not q:
            return [item("shell", "hint", "Type a command to run", icon="", accessory="Shell",
                         recordable=False, score=1, _hint=True)]
        mode = self.settings.get("shell.mode", "terminal")
        return [item("shell", "run", q, subtitle="Run in a terminal" if mode == "terminal" else "Run in the background",
                     icon="", accessory="Shell", recordable=False, score=990, _cmd=q)]

    def actions(self, it):
        if it.get("_hint"):
            return []
        return [action("default", "Run", ""),
                action("terminal" if self.settings.get("shell.mode") != "terminal" else "background",
                       "Run in a terminal" if self.settings.get("shell.mode") != "terminal" else "Run in the background",
                       "", "ctrl+enter"),
                action("output", "Run and show the output here", "󰈙", "ctrl+o")]

    def run(self, it, aid, arg):
        if it.get("_hint"):
            return []
        cmd = it["_cmd"]
        mode = self.settings.get("shell.mode", "terminal")
        if aid == "output":
            ok, out = util.run_ok(["bash", "-lc", cmd], timeout=15)
            return [detail(cmd, out or ("(no output)" if ok else "(failed)"), icon="",
                           actions=[action("copy", "Copy output", "󰆏", "ctrl+c")])]
        if aid == "terminal" or (aid == "default" and mode == "terminal"):
            # Keep the window open afterwards so the output can be read.
            util.terminal(["bash", "-lc", cmd + '; echo; read -rsn1 -p "Press any key to close…"'],
                          cwd=str(util.HOME))
        else:
            util.spawn_shell(cmd, cwd=str(util.HOME))
        return [close()]


class Processes(Provider):
    id = "processes"
    name = "Kill process"
    prefix = "kill"
    in_global = False

    def _procs(self) -> list[dict]:
        me = os.getpid()
        uid = os.getuid()
        out = []
        for pid in os.listdir("/proc"):
            if not pid.isdigit() or int(pid) in (me, os.getppid()):
                continue
            try:
                st = os.stat(f"/proc/{pid}")
                if st.st_uid != uid:
                    continue
                with open(f"/proc/{pid}/comm") as f:
                    comm = f.read().strip()
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    cmdline = f.read().replace(b"\0", b" ").decode(errors="replace").strip()
                with open(f"/proc/{pid}/statm") as f:
                    rss_pages = int(f.read().split()[1])
            except (OSError, ValueError, IndexError):
                continue
            mem = rss_pages * os.sysconf("SC_PAGE_SIZE") / 1048576
            out.append(item("processes", pid, comm, subtitle=f"{pid} · {cmdline[:140]}",
                            icon="󰍛", accessory=f"{mem:.0f} MB", recordable=False, _pid=int(pid), _mem=mem,
                            _keywords=[cmdline[:200]]))
        return out

    def search(self, q, scoped):
        procs = self._procs()
        if not q.strip():
            return [dict(p, score=int(p["_mem"])) for p in sorted(procs, key=lambda p: -p["_mem"])[:60]]
        return self.rank(q, procs, minimum=500)

    def browse(self):
        return self.search("", True)

    def actions(self, it):
        return [action("default", "Quit (SIGTERM)", "󰅖"), action("kill", "Force kill (SIGKILL)", "󰚌", "ctrl+enter"),
                action("copy", "Copy PID", "󰆏", "ctrl+c")]

    def run(self, it, aid, arg):
        if aid == "copy":
            util.copy(str(it["_pid"]))
            return [toast("Copied PID")]
        try:
            os.kill(it["_pid"], signal.SIGKILL if aid == "kill" else signal.SIGTERM)
        except OSError as e:
            return [toast(f"Could not stop {it['title']}: {e.strerror}", True)]
        return [toast(f"Stopped {it['title']}"), refresh()]


MOD_NAMES = [(64, "Super"), (4, "Ctrl"), (8, "Alt"), (1, "Shift")]


def shortcut_label(modmask: int, key: str) -> str:
    mods = [name for bit, name in MOD_NAMES if modmask & bit]
    key = {"SPACE": "Space", "RETURN": "Enter", "code:13": "4"}.get(key, key)
    if len(key) == 1:
        key = key.upper()
    return " + ".join(mods + [key])


class Keybindings(Provider):
    id = "keybindings"
    name = "Keyboard shortcuts"
    prefix = "keys"
    in_global = False

    def _binds(self):
        raw = util.run(["hyprctl", "binds", "-j"], timeout=2)
        try:
            binds = json.loads(raw) if raw else []
        except ValueError:
            return []
        out = []
        for i, b in enumerate(binds):
            desc = str(b.get("description") or "").strip()
            if not desc or b.get("submap"):
                continue
            label = shortcut_label(int(b.get("modmask") or 0), str(b.get("key") or ""))
            out.append(item("keybindings", f"{i}", desc, subtitle=label, icon="󰌌", accessory=label,
                            recordable=False, _keywords=[label], _label=label))
        return out

    def search(self, q, scoped):
        binds = self._binds()
        if not q.strip():
            return binds
        return self.rank(q, binds)

    def browse(self):
        return self._binds()

    def actions(self, it):
        return [action("default", "Copy shortcut", "󰆏")]

    def run(self, it, aid, arg):
        util.copy(it["_label"])
        return [toast(f"{it['title']}: {it['_label']}")]


class Devices(Provider):
    """Audio outputs and inputs, paired Bluetooth devices, known Wi-Fi networks."""

    id = "devices"
    name = "Audio, Bluetooth and Wi-Fi"
    slow = True

    def __init__(self, ctx):
        super().__init__(ctx)
        self.items: list[dict] = []

    def refresh(self):
        items = []
        items += self._audio("sinks", "Audio output", "󰓃")
        items += self._audio("sources", "Microphone", "󰍬")
        items += self._bluetooth()
        items += self._wifi()
        self.items = items

    def _audio(self, kind: str, label: str, icon: str) -> list[dict]:
        if not util.have("pactl"):
            return []
        default = util.run(["pactl", "get-default-" + kind[:-1]], timeout=2).strip()
        try:
            rows = json.loads(util.run(["pactl", "-f", "json", "list", kind], timeout=2) or "[]")
        except ValueError:
            return []
        out = []
        for r in rows:
            name = str(r.get("name") or "")
            if not name or name.endswith(".monitor"):
                continue
            desc = str(r.get("description") or name)
            on = name == default
            out.append(item("devices", f"{kind}:{name}", desc, subtitle=label, icon=icon,
                            accessory="Active" if on else label, recordable=True,
                            _keywords=[label, "audio", "sound"], _kind=kind, _name=name, _on=on))
        return out

    def _bluetooth(self) -> list[dict]:
        if not util.have("bluetoothctl"):
            return []
        out = []
        for line in util.run(["bluetoothctl", "devices", "Paired"], timeout=2).splitlines():
            m = re.match(r"Device ([0-9A-F:]{17}) (.+)", line.strip())
            if not m:
                continue
            mac, name = m.groups()
            info = util.run(["bluetoothctl", "info", mac], timeout=2)
            on = "Connected: yes" in info
            out.append(item("devices", f"bt:{mac}", name, subtitle="Bluetooth", icon="󰂯" if not on else "󰂱",
                            accessory="Connected" if on else "Bluetooth", _keywords=["bluetooth"],
                            _kind="bt", _mac=mac, _on=on))
        return out

    def _wifi(self) -> list[dict]:
        if not util.have("nmcli"):
            return []
        out = []
        for line in util.run(["nmcli", "-t", "-f", "NAME,TYPE,ACTIVE", "connection", "show"], timeout=2).splitlines():
            parts = re.split(r"(?<!\\):", line)
            if len(parts) < 3 or "wireless" not in parts[1]:
                continue
            name = parts[0].replace("\\:", ":")
            on = parts[2] == "yes"
            out.append(item("devices", f"wifi:{name}", name, subtitle="Wi-Fi network", icon="󰖩",
                            accessory="Connected" if on else "Wi-Fi", _keywords=["wifi", "wi-fi", "network"],
                            _kind="wifi", _name=name, _on=on))
        return out

    def search(self, q, scoped):
        return self.rank(q, self.items, minimum=600 if not scoped else 1)

    def resolve(self, item_id):
        for it in self.items:
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        kind = it["_kind"]
        if kind in ("sinks", "sources"):
            return [action("default", "Use this " + ("output" if kind == "sinks" else "microphone"), "󰓃")]
        if kind == "bt":
            return [action("default", "Disconnect" if it["_on"] else "Connect", "󰂯")]
        return [action("default", "Disconnect" if it["_on"] else "Connect", "󰖩")]

    def run(self, it, aid, arg):
        kind = it["_kind"]
        if kind in ("sinks", "sources"):
            ok, out = util.run_ok(["pactl", "set-default-" + kind[:-1], it["_name"]])
            return [toast(("Now using " + it["title"]) if ok else out, not ok), close()]
        if kind == "bt":
            verb = "disconnect" if it["_on"] else "connect"
            util.spawn(["bluetoothctl", verb, it["_mac"]])
            util.notify(("Disconnecting " if it["_on"] else "Connecting ") + it["title"], icon="bluetooth")
            return [close()]
        verb = "down" if it["_on"] else "up"
        util.spawn(["nmcli", "connection", verb, it["_name"]])
        return [close()]


class Themes(Provider):
    id = "themes"
    name = "Themes"
    prefix = "theme"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.items: list[dict] = []

    def refresh(self):
        names = [n.strip() for n in util.run(["omarchy-theme-list"], timeout=3).splitlines() if n.strip()]
        current = util.run(["omarchy-theme-current"], timeout=2).strip()
        self.items = [item("themes", n, n, subtitle="Theme", icon="󰸌",
                           accessory="Current" if n.lower() == current.lower() else "Theme",
                           _keywords=["theme"], _name=n) for n in names]

    def search(self, q, scoped):
        return self.rank(q, self.items, minimum=700 if not scoped else 1)

    def browse(self):
        return self.items

    def resolve(self, item_id):
        for it in self.items:
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        return [action("default", "Use theme", "󰸌")]

    def run(self, it, aid, arg):
        util.spawn(["omarchy-theme-set", it["_name"]])
        return [close()]


class Azure(Provider):
    id = "azure"
    name = "Azure subscriptions"
    prefix = "az"

    PROFILE = util.HOME / ".azure/azureProfile.json"

    def available(self):
        return self.PROFILE.exists() and util.have("az")

    def _subs(self):
        try:
            with open(self.PROFILE, encoding="utf-8-sig") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return []
        out = []
        for s in data.get("subscriptions", []):
            if not s.get("id"):
                continue
            out.append(item("azure", s["id"], str(s.get("name") or s["id"]),
                            subtitle=f"Azure subscription · {s.get('user', {}).get('name', '')}",
                            icon="󰠅", accessory="Active" if s.get("isDefault") else "Azure",
                            _keywords=["azure", "subscription", s["id"]], _sid=s["id"]))
        return out

    def search(self, q, scoped):
        return self.rank(q, self._subs(), minimum=650 if not scoped else 1)

    def browse(self):
        return self._subs()

    def resolve(self, item_id):
        for it in self._subs():
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        return [action("default", "Switch to this subscription", "󰠅"), action("copy", "Copy id", "󰆏", "ctrl+c")]

    def run(self, it, aid, arg):
        if aid == "copy":
            util.copy(it["_sid"])
            return [toast("Copied the subscription id")]
        ok, out = util.run_ok(["az", "account", "set", "--subscription", it["_sid"]], timeout=20)
        return [toast(("Azure: " + it["title"]) if ok else (out.splitlines() or ["az failed"])[-1], not ok)]
