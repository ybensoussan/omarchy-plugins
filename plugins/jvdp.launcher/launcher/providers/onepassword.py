"""1Password: find an item, copy its password, username or one-time code.

Only titles, vaults and URLs are kept, in memory; secrets are fetched when you
pick one, copied with wl-copy's --sensitive flag (so Omarchy's clipboard
history skips them) and cleared after the configured number of seconds.

`op` asks the 1Password app for permission once per session (the backend's,
which lasts as long as the shell). Asking needs the keyboard, which the overlay
holds, so whenever op might ask, the launcher closes first and comes back when
the list is there. It never pops up an authorization prompt on its own.
"""

from __future__ import annotations

import json
import subprocess
import threading
import time

from . import Provider, action, close, item, toast
from .. import util

CATEGORY_ICONS = {"LOGIN": "󰌆", "PASSWORD": "󰌆", "API_CREDENTIAL": "󰯄", "SSH_KEY": "󰣀", "SECURE_NOTE": "󰎞",
                  "CREDIT_CARD": "󰆛", "SERVER": "󰒋", "DATABASE": "󰆼", "IDENTITY": "󰀉"}


def op_run(argv: list[str], timeout: float) -> subprocess.CompletedProcess:
    """op in the backend's own session, the only commands that run there."""
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)


def op_argv(settings, *args) -> list[str]:
    # No setsid here: the backend leads a session of its own (bin/launcher),
    # so every op call shares one authorization, like commands in a terminal.
    argv = ["op"] + list(args)
    account = settings.get("onepassword.account", "")
    if account:
        argv += ["--account", account]
    return argv


class OnePassword(Provider):
    id = "onepassword"
    name = "1Password"
    prefix = "1p"
    slow = True

    def __init__(self, ctx):
        super().__init__(ctx)
        self.items: list[dict] = []
        self.loaded_at = 0.0
        self.error = ""
        self.locked = False
        self._loading = threading.Lock()

    def available(self):
        return util.have("op")

    def _load(self, may_ask: bool = False) -> None:
        with self._loading:
            if time.time() - self.loaded_at < 600 and self.items:
                return
            # whoami never prompts. Not authorized yet: with the overlay open
            # that becomes an Unlock row (may_ask False); after it has closed,
            # the list call below lets op ask.
            try:
                who = op_run(op_argv(self.settings, "whoami"), 8)
                ok, msg = who.returncode == 0, who.stderr.strip()
            except (OSError, subprocess.SubprocessError) as e:
                ok, msg = False, str(e)
            if not ok and not may_ask:
                self.locked = True
                self.error = (msg.splitlines() or ["not signed in"])[-1]
                return
            self.locked = False
            try:
                out = op_run(op_argv(self.settings, "item", "list", "--format", "json"), 60)
            except (OSError, subprocess.SubprocessError) as e:
                self.error = str(e)
                return
            if out.returncode != 0:
                self.error = (out.stderr.strip().splitlines() or ["op failed"])[-1]
                return
            try:
                rows = json.loads(out.stdout or "[]")
            except ValueError:
                rows = []
            items = []
            for r in rows:
                if not isinstance(r, dict) or not r.get("id"):
                    continue
                cat = str(r.get("category") or "")
                urls = [u.get("href", "") for u in r.get("urls", []) if isinstance(u, dict)]
                vault = (r.get("vault") or {}).get("name", "")
                sub = " · ".join(x for x in [vault, str(r.get("additional_information") or "")] if x)
                items.append(item("onepassword", r["id"], str(r.get("title") or "(untitled)"), subtitle=sub,
                                  icon=CATEGORY_ICONS.get(cat, "󰌆"), accessory="1Password", recordable=False,
                                  _keywords=[str(r.get("additional_information") or "")] + urls,
                                  _uid=r["id"], _urls=urls, _category=cat, _vault=vault))
            self.items = items
            self.loaded_at = time.time()
            self.error = ""

    def search(self, q, scoped):
        if scoped:
            self._load()
            if not self.items:
                return [item("onepassword", "unlock", "Unlock 1Password",
                             subtitle="Enter: 1Password asks to allow the launcher, then it comes back with your items",
                             icon="󰌾", accessory="1Password", recordable=False, score=1, _unlock=True)]
            if not q.strip():
                return [dict(it, score=1) for it in sorted(self.items, key=lambda i: i["title"].lower())]
        # In the normal search only once the list is there, and only close matches.
        return self.rank(q, self.items, minimum=1 if scoped else 700)

    def resolve(self, item_id):
        for it in self.items:
            if it["id"] == item_id:
                return it
        # Not listed yet this session: enough to act on by id.
        return None

    def actions(self, it):
        if it.get("_unlock"):
            return [action("default", "Unlock", "󰌾")]
        primary = self.settings.get("onepassword.primary", "password")
        acts = {
            "password": action("password", "Copy password", "󰌆"),
            "username": action("username", "Copy username", "󰀄"),
            "otp": action("otp", "Copy one-time code", "󰦯"),
        }
        order = [primary] + [k for k in ("password", "username", "otp") if k != primary]
        out = [dict(acts[order[0]], id="default", shortcut="")]
        out[0]["_does"] = order[0]
        shortcuts = {"password": "ctrl+c", "username": "ctrl+u", "otp": "ctrl+o"}
        for k in order[1:]:
            out.append(dict(acts[k], shortcut=shortcuts[k]))
        if it.get("_urls"):
            out.append(action("url", "Open website", "󰖟", "ctrl+enter"))
        out.append(action("app", "Show in 1Password", "󰌾", "ctrl+shift+o"))
        return out

    def run(self, it, aid, arg):
        if it.get("_unlock"):
            threading.Thread(target=self._unlock, daemon=True).start()
            return [close()]
        if aid == "app":
            util.open_target(f"onepassword://view-item/?i={it['_uid']}")
            return [close()]
        if aid == "url":
            util.open_target(it["_urls"][0])
            return [close()]
        if aid == "default":
            aid = self.settings.get("onepassword.primary", "password")
        # Close first: if op has to ask for authorization, its dialog needs the
        # keyboard, which the overlay holds while it is open.
        threading.Thread(target=self._copy, args=(it, aid), daemon=True).start()
        return [close()]

    def _unlock(self) -> None:
        time.sleep(0.3)
        self.loaded_at = 0.0
        self._load(may_ask=True)
        if self.items:
            util.spawn(["omarchy-shell", "shell", "summon", "jvdp.launcher", json.dumps({"query": "1p "})])
        else:
            util.notify("1Password", self.error or "Could not list your items", icon="1password")

    def _copy(self, it: dict, aid: str) -> None:
        time.sleep(0.3)
        uid = it["_uid"]
        if aid == "otp":
            args = ["item", "get", uid, "--otp"]
        elif aid == "username":
            args = ["item", "get", uid, "--fields", "label=username", "--format", "json"]
        else:
            args = ["item", "get", uid, "--fields", "type=concealed", "--reveal", "--format", "json"]
        try:
            out = op_run(op_argv(self.settings, *args), 60)
        except (OSError, subprocess.SubprocessError) as e:
            util.notify("1Password", str(e), icon="1password")
            return
        if out.returncode != 0:
            util.notify("1Password", (out.stderr.strip().splitlines() or ["failed"])[-1], icon="1password")
            return
        value = out.stdout.strip()
        if aid != "otp":
            value = _field_value(value)
        if not value:
            what = {"otp": "one-time code", "username": "username"}.get(aid, "password")
            util.notify("1Password", f"{it['title']} has no {what}", icon="1password")
            return
        util.copy(value, sensitive=True)
        seconds = int(self.settings.get("onepassword.clearAfter", 30) or 0)
        util.clear_clipboard_after(seconds, value)
        what = {"otp": "One-time code", "username": "Username"}.get(aid, "Password")
        util.notify(f"{what} copied", f"{it['title']}" + (f" · cleared in {seconds}s" if seconds else ""),
                    icon="1password")


def _field_value(raw: str) -> str:
    """op prints one field as an object, several as a list; take the first value."""
    try:
        data = json.loads(raw)
    except ValueError:
        return raw
    if isinstance(data, list):
        data = data[0] if data else {}
    return str(data.get("value") or "") if isinstance(data, dict) else ""
