"""Bitwarden: find an item, copy its password, username or one-time code.

Uses the `bw` CLI. Only names, usernames and URLs are kept, in memory; secrets
are fetched when you pick one, copied with wl-copy's --sensitive flag (so
Omarchy's clipboard history skips them) and cleared after the configured
number of seconds.

The session key lives in $XDG_RUNTIME_DIR/bw-vault.session (mode 600), the
same file the bw-vault terminal UI uses, so unlocking in either unlocks both.
Unlocking asks for your master password in a form inside the launcher; it goes
to `bw` through the environment, never argv, and is not kept.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time

from . import Provider, action, close, form, item, set_query, toast
from .. import util

SESSION_FILE = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "bw-vault.session")
TYPE_ICONS = {1: "󰌆", 2: "󰎞", 3: "󰆛", 4: "󰀉", 5: "󰣀"}


def session() -> str:
    try:
        with open(SESSION_FILE, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def bw_run(args: list[str], timeout: float = 60) -> subprocess.CompletedProcess:
    env = dict(os.environ, BW_NOINTERACTION="true")
    key = session()
    if key:
        env["BW_SESSION"] = key
    return subprocess.run(["bw"] + args, capture_output=True, text=True, timeout=timeout, env=env,
                          stdin=subprocess.DEVNULL)


class Bitwarden(Provider):
    id = "bitwarden"
    name = "Bitwarden"
    prefix = "bw"
    slow = True

    def __init__(self, ctx):
        super().__init__(ctx)
        self.items: list[dict] = []
        self.loaded_at = 0.0
        self.error = ""
        self._loading = threading.Lock()
        self._unlocking = threading.Lock()

    def available(self):
        return util.have("bw")

    def _load(self) -> None:
        with self._loading:
            if not session():
                # Locked (here or elsewhere): forget the list.
                self.items, self.loaded_at = [], 0.0
                self.error = "locked"
                return
            if time.time() - self.loaded_at < 600 and self.items:
                return
            try:
                out = bw_run(["list", "items"])
            except (OSError, subprocess.SubprocessError) as e:
                self.error = str(e)
                return
            if out.returncode != 0:
                # An expired or wrong session key: forget it so Unlock shows.
                self.items = []
                self.error = (out.stderr.strip().splitlines() or ["bw failed"])[-1]
                try:
                    os.remove(SESSION_FILE)
                except OSError:
                    pass
                return
            try:
                rows = json.loads(out.stdout or "[]")
            except ValueError:
                rows = []
            items = []
            for r in rows:
                if not isinstance(r, dict) or not r.get("id") or r.get("deletedDate"):
                    continue
                login = r.get("login") or {}
                user = str(login.get("username") or "")
                urls = [u.get("uri", "") for u in login.get("uris") or []
                        if isinstance(u, dict) and str(u.get("uri", "")).startswith(("http://", "https://"))]
                items.append(item("bitwarden", r["id"], str(r.get("name") or "(untitled)"), subtitle=user,
                                  icon=TYPE_ICONS.get(r.get("type"), "󰌆"), accessory="Bitwarden", recordable=False,
                                  _keywords=[user] + urls, _uid=r["id"], _urls=urls,
                                  _login=r.get("type") == 1, _totp=bool(login.get("totp"))))
            self.items = items
            self.loaded_at = time.time()
            self.error = ""

    def search(self, q, scoped):
        if scoped:
            self._load()
            if not self.items:
                sub = ("Enter: type your master password here, and your items appear"
                       if not self.error or self.error == "locked" else self.error)
                return [item("bitwarden", "unlock", "Unlock Bitwarden", subtitle=sub, icon="󰌾",
                             accessory="Bitwarden", recordable=False, score=1, _unlock=True)]
            if not q.strip():
                return [dict(it, score=1) for it in sorted(self.items, key=lambda i: i["title"].lower())]
        if not session():
            return []
        return self.rank(q, self.items, minimum=1 if scoped else 700)

    def resolve(self, item_id):
        for it in self.items:
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        if it.get("_unlock"):
            return [action("default", "Unlock", "󰌾")]
        primary = self.settings.get("bitwarden.primary", "password")
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
        out.append(action("lock", "Lock Bitwarden", "󰌾", "ctrl+shift+l"))
        return out

    def run(self, it, aid, arg):
        if it.get("_unlock"):
            try:
                status = json.loads(bw_run(["status"], 15).stdout or "{}").get("status")
            except (OSError, ValueError, subprocess.SubprocessError):
                status = None
            if status == "unauthenticated":
                util.terminal(["bw", "login"])
                return [close()]
            return [form("bitwarden", "Unlock Bitwarden",
                         [{"type": "info", "label": "Master password for the vault; it is not stored."},
                          {"key": "password", "label": "Master password", "type": "password", "value": "", "hint": ""}],
                         submit="Unlock", icon="󰌾")]
        if aid == "lock":
            try:
                os.remove(SESSION_FILE)
            except OSError:
                pass
            self.items, self.loaded_at = [], 0.0
            threading.Thread(target=lambda: bw_run(["lock"], 10), daemon=True).start()
            return [close()]
        if aid == "url":
            util.open_target(it["_urls"][0])
            return [close()]
        if aid == "default":
            aid = self.settings.get("bitwarden.primary", "password")
        threading.Thread(target=self._copy, args=(it, aid), daemon=True).start()
        return [close()]

    def submit(self, form_id, values):
        password = str(values.get("password") or "")
        if not password:
            return [toast("Enter your master password", True)]
        if not self._unlocking.acquire(blocking=False):
            return [toast("Still unlocking…", sticky=True)]
        # bw takes a few seconds (it starts node, then derives the key), so
        # answer at once and report back from a thread.
        threading.Thread(target=self._unlock, args=(password,), daemon=True).start()
        return [toast("Unlocking…", sticky=True)]

    def _say(self, *steps) -> None:
        self.ctx.emit({"op": "do", "steps": list(steps)})

    def _unlock(self, password: str) -> None:
        try:
            env = dict(os.environ, BW_PASSWORD=password, BW_NOINTERACTION="true")
            try:
                out = subprocess.run(["bw", "unlock", "--passwordenv", "BW_PASSWORD", "--raw"], capture_output=True,
                                     text=True, timeout=60, env=env, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
            except (OSError, subprocess.SubprocessError) as e:
                self._say(toast(str(e), True))
                return
            key = out.stdout.strip()
            if out.returncode != 0 or not key:
                msg = (out.stderr.strip().splitlines() or ["Unlock failed"])[-1]
                if "not the expected type" in msg or "Invalid master password" in msg:
                    msg = "Wrong master password"
                self._say(toast(msg, True))
                return
            fd = os.open(SESSION_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(key + "\n")
            try:
                os.remove(os.path.join(os.path.dirname(SESSION_FILE), "bw-vault.index"))
            except OSError:
                pass
            self._say(toast("Unlocked, loading your items…", sticky=True))
            self.loaded_at = 0.0
            self._load()   # so the list is ready when the search comes back
            self._say(set_query("bw "), toast("Unlocked" if self.items else (self.error or "Unlocked")))
        finally:
            self._unlocking.release()

    def _copy(self, it: dict, aid: str) -> None:
        what = {"otp": "totp", "username": "username"}.get(aid, "password")
        try:
            out = bw_run(["get", what, it["_uid"]])
        except (OSError, subprocess.SubprocessError) as e:
            util.notify("Bitwarden", str(e), icon="bitwarden")
            return
        if out.returncode != 0:
            util.notify("Bitwarden", (out.stderr.strip().splitlines() or ["failed"])[-1], icon="bitwarden")
            return
        value = out.stdout.strip()
        if not value:
            label = {"otp": "one-time code", "username": "username"}.get(aid, "password")
            util.notify("Bitwarden", f"{it['title']} has no {label}", icon="bitwarden")
            return
        util.copy(value, sensitive=True)
        seconds = int(self.settings.get("bitwarden.clearAfter", 30) or 0)
        util.clear_clipboard_after(seconds, value)
        label = {"otp": "One-time code", "username": "Username"}.get(aid, "Password")
        util.notify(f"{label} copied", it["title"] + (f" · cleared in {seconds}s" if seconds else ""),
                    icon="bitwarden")
