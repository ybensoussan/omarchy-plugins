"""The backend the overlay talks to: one JSON object per line, both ways.

From the overlay:
  {"op": "apps", "apps": [...]}            the app list (from Omarchy's app library)
  {"op": "open"}                           the launcher opened: refresh what may have changed
  {"op": "query", "seq": 7, "q": "fire"}   search
  {"op": "actions", "seq": 8, "id": "…"}   the actions for one result
  {"op": "run", "id": "…", "action": "default", "arg": null}
  {"op": "submit", "form": "settings", "values": {...}}
  {"op": "copy", "text": "…"}              copy text the overlay shows (an answer, output)
  {"op": "stop"}                           a streaming answer was closed
  {"op": "chat", "turn": "1-0", "q": "…", "session": ""}   a question in the chat window

To the overlay:
  {"op": "results", "seq": 7, "items": [...], "done": false}   (again as slow sources finish)
  {"op": "actions", "seq": 8, "actions": [...]}
  {"op": "do", "steps": [...]}             what to do after a run or submit
  {"op": "stream", "stream": "s1", "text": "…", "status": "…", "done": true}
  {"op": "chat", "turn": "1-0", "text": "…", "status": "…", "session": "…", "done": true}
"""

from __future__ import annotations

import json
import sys
import threading
import traceback

from . import util
from .providers import action, close, form, item, refresh, set_query, toast
from .providers.apps import Apps, Windows
from .providers.builtin import Builtin
from .providers.calc import Calculator
from .providers.files import Files
from .providers.knowledge import Claude, Manual, OpenCode
from .providers.omarchy import OmarchyMenu
from .providers.bitwarden import Bitwarden
from .providers.plugins import Plugins
from .providers.scripts import Scripts
from .providers.system import Azure, Devices, Keybindings, Processes, Shell, Themes
from .providers.text import Clipboard, Emoji, Snippets
from .providers.web import Quicklinks, Web
from .providers.work import Herdr, Projects
from .providers.worldclock import WorldClock
from .settings import Settings
from .state import History

PROVIDERS = [Builtin, Apps, OmarchyMenu, Plugins, Scripts, Quicklinks, Snippets, Herdr, Projects, Windows,
             Calculator, WorldClock, Files, Manual, Devices, Themes, Bitwarden, Azure, Clipboard, Emoji,
             Web, Shell, Claude, OpenCode, Processes, Keybindings]

MAX_RESULTS = 80
GLOBAL_MIN = 300
COMMON_ACTIONS = ("fav", "unfav", "alias", "unalias", "forget")


def public(it: dict, favourites: list, aliases_for: dict) -> dict:
    out = {k: v for k, v in it.items() if not k.startswith("_")}
    out["fav"] = it["id"] in favourites
    if it["id"] in aliases_for and not out.get("accessory"):
        out["accessory"] = aliases_for[it["id"]]
    out.setdefault("arg", None)
    return out


class Server:
    def __init__(self, out=sys.stdout):
        self._out = out
        self._write_lock = threading.Lock()
        self.current_seq = 0
        self.current_q = ""
        self.history = History()
        self.providers = []
        self.settings = Settings()
        self.providers = [cls(self) for cls in PROVIDERS]
        self.settings.source_defaults = {p.id: {"enabled": True, "global": p.in_global, "prefix": p.prefix}
                                         for p in self.providers}
        self.settings.reload(force=True)
        self.by_id = {p.id: p for p in self.providers}
        self.items: dict[str, dict] = {}      # every result sent recently, by id
        self._streams = 0
        self._refreshing = threading.Lock()

    # Plumbing ---------------------------------------------------------------

    def emit(self, obj: dict) -> None:
        line = json.dumps(obj, ensure_ascii=False)
        with self._write_lock:
            self._out.write(line + "\n")
            self._out.flush()

    def new_stream(self) -> str:
        self._streams += 1
        return f"s{self._streams}"

    def prefix_of(self, p) -> str:
        return str(self.settings.source(p.id).get("prefix", p.prefix) or "")

    def enabled(self, p) -> bool:
        return bool(self.settings.source(p.id).get("enabled", True)) and p.available()

    def in_global(self, p) -> bool:
        return self.enabled(p) and bool(self.settings.source(p.id).get("global", p.in_global))

    def refresh_all(self, wait: bool = False) -> None:
        def work():
            if not self._refreshing.acquire(blocking=False):
                return
            try:
                threads = [threading.Thread(target=self._safe_refresh, args=(p,), daemon=True)
                           for p in self.providers if self.enabled(p)]
                for t in threads:
                    t.start()
                for t in threads:
                    t.join(timeout=10)
            finally:
                self._refreshing.release()
            # Whatever is on screen may have changed (windows, menu conditions…).
            self.query(self.current_seq, self.current_q, rerun=True)

        if wait:
            work()
        else:
            threading.Thread(target=work, daemon=True).start()

    @staticmethod
    def _safe_refresh(p) -> None:
        try:
            p.refresh()
        except Exception:
            traceback.print_exc(file=sys.stderr)

    def remember(self, items: list[dict]) -> None:
        for it in items:
            self.items[it["id"]] = it
        if len(self.items) > 4000:
            for k in list(self.items)[:2000]:
                del self.items[k]

    def find(self, item_id: str) -> dict | None:
        it = self.items.get(item_id)
        if it:
            return it
        p = self.by_id.get(item_id.split(":", 1)[0])
        if p:
            try:
                return p.resolve(item_id)
            except Exception:
                traceback.print_exc(file=sys.stderr)
        return None

    # Searching --------------------------------------------------------------

    def scope(self, q: str):
        """(provider, rest) when the query starts with a provider's prefix."""
        low = q.lower()
        best = None
        for p in self.providers:
            if not self.enabled(p):
                continue
            prefix = self.prefix_of(p).lower()
            if not prefix:
                continue
            symbol = len(prefix) == 1 and not prefix.isalnum()
            if (symbol and low.startswith(prefix)) or low.startswith(prefix + " "):
                if best is None or len(prefix) > len(best[1]):
                    best = (p, prefix)
        scripts = self.by_id.get("scripts")
        if scripts and self.enabled(scripts):
            for prefix, script in scripts.list_prefixes().items():
                if low.startswith(prefix.lower() + " ") and (best is None or len(prefix) > len(best[1])):
                    best = (("script", script), prefix)
        if best is None:
            return None, q
        return best[0], q[len(best[1]):].lstrip()

    def query(self, seq: int, q: str, rerun: bool = False) -> None:
        if rerun and seq != self.current_seq:
            return
        self.current_seq = seq
        self.current_q = q
        self.settings.reload()
        if not q.strip():
            self._emit_results(seq, self.home(), done=True)
            return
        target, rest = self.scope(q)
        if target is not None:
            self._scoped(seq, target, rest)
            return
        self._global(seq, q.strip())

    def _search(self, p, q: str, scoped: bool) -> list[dict]:
        try:
            if scoped and not q.strip():
                found = p.browse() or p.search("", True)
                found = [dict(it, score=it.get("score", 0) or (len(found) - i)) for i, it in enumerate(found)]
            else:
                found = p.search(q, scoped)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            return []
        return found

    def _scoped(self, seq: int, target, rest: str) -> None:
        def work():
            if isinstance(target, tuple):
                found = self.by_id["scripts"].list_search(target[1], rest)
            else:
                found = self._search(target, rest, True)
            if seq == self.current_seq:
                self._emit_results(seq, self._rank(found, rest, keep_order=not rest.strip()), done=True)

        p = target if not isinstance(target, tuple) else None
        if p is not None and not p.slow:
            work()
        else:
            self._emit_results(seq, [], done=False)
            threading.Thread(target=work, daemon=True).start()

    def _global(self, seq: int, q: str) -> None:
        fast, slow = [], []
        for p in self.providers:
            if self.in_global(p):
                (slow if p.slow else fast).append(p)
        found: list[dict] = []
        for p in fast:
            found += self._search(p, q, False)
        # Loose matches (letters scattered through a long title) only clutter
        # the normal search; behind a prefix they stay.
        found = [it for it in found if it.get("score", 0) >= GLOBAL_MIN]
        state = {"found": found, "pending": len(slow)}
        lock = threading.Lock()
        self._emit_results(seq, self._rank(found, q) + self.fallbacks(q), done=not slow)

        def work(p):
            more = [it for it in self._search(p, q, False) if it.get("score", 0) >= GLOBAL_MIN]
            with lock:
                state["found"] = state["found"] + more
                state["pending"] -= 1
                done = state["pending"] == 0
                if seq == self.current_seq and (more or done):
                    self._emit_results(seq, self._rank(state["found"], q) + self.fallbacks(q), done=done)

        for p in slow:
            threading.Thread(target=work, args=(p,), daemon=True).start()

    def _rank(self, found: list[dict], q: str, keep_order: bool = False) -> list[dict]:
        favourites = self.settings.get("favourites", [])
        aliases = {a.lower(): i for a, i in self.settings.get("aliases", {}).items()}
        ql = q.strip().lower()
        seen = set()
        ranked = []
        for it in found:
            if it["id"] in seen:
                continue
            seen.add(it["id"])
            s = float(it.get("score", 0))
            if not keep_order:
                if it.get("recordable", True):
                    s += self.history.boost(it["id"], ql)
                if it["id"] in favourites:
                    s += 80
            if aliases.get(ql) == it["id"]:
                s += 5000
            it = dict(it, score=s)
            ranked.append(it)
        # An alias typed exactly brings its item even when no source matched it.
        if ql in aliases and aliases[ql] not in seen:
            hit = self.find(aliases[ql])
            if hit:
                ranked.append(dict(hit, score=6000))
        ranked.sort(key=lambda it: -it["score"])
        return ranked[:MAX_RESULTS]

    def fallbacks(self, q: str) -> list[dict]:
        out = self._fallbacks(q)
        for it in out:
            it["score"] = 0
        self.remember(out)
        return out

    def _fallbacks(self, q: str) -> list[dict]:
        out = []
        for key in self.settings.get("general.fallbacks", []):
            if key == "web" and self.enabled(self.by_id["web"]):
                out.append(dict(self.by_id["web"].fallback(q), section="fallback"))
            elif key == "claude" and self.enabled(self.by_id["claude"]):
                out.append(dict(self.by_id["claude"].fallback(q), section="fallback"))
            elif key == "opencode" and self.enabled(self.by_id["opencode"]):
                out.append(dict(self.by_id["opencode"].fallback(q), section="fallback"))
            elif key == "files" and self.enabled(self.by_id["files"]):
                prefix = self.prefix_of(self.by_id["files"]) or "/"
                out.append(item("launcher", "find-files", f"Search files for “{q}”", icon="󰈞",
                                accessory="Files", recordable=False, section="fallback",
                                _query=prefix + ("" if len(prefix) == 1 and not prefix.isalnum() else " ") + q))
        return out

    def home(self) -> list[dict]:
        mode = self.settings.get("general.home", "favourites-recent")
        if mode == "nothing":
            return []
        out = []
        favs = self.settings.get("favourites", [])
        for fid in favs:
            it = self.find(fid) or self.history.snapshot(fid)
            if it:
                out.append(dict(it, section="Favourites", score=0))
        if mode == "favourites-recent":
            shown = set(favs)
            for snap in self.history.recent(12):
                if snap.get("id") in shown:
                    continue
                # The source's current item, else what it looked like when used
                # (a file, a project, a Bitwarden item before its list loads).
                current = self.find(snap["id"])
                if current is None:
                    if snap["id"].split(":", 1)[0] in ("apps", "omarchy", "plugins", "launcher", "scripts"):
                        continue    # uninstalled or removed
                    current = snap
                shown.add(snap["id"])
                out.append(dict(current, section="Recent", score=0))
                if len([o for o in out if o.get("section") == "Recent"]) >= 8:
                    break
        # Fill the rest of the screen, so it never opens empty: the dock's
        # pinned apps, then a few things worth knowing the launcher does.
        rows = int(self.settings.get("general.rows", 9) or 9)
        if len(out) < rows + 3:
            shown = {o["id"] for o in out}
            for sid in self.suggestions():
                if len(out) >= rows + 3:
                    break
                if sid in shown:
                    continue
                it = self.find(sid)
                if it:
                    shown.add(sid)
                    out.append(dict(it, section="Suggested", score=0))
        # "Ask …" rows follow their toggle (Settings) on the opening screen too;
        # ones you pinned as favourites stay.
        fallbacks = self.settings.get("general.fallbacks", [])
        hidden = {f"launcher:mode:{k}" for k in ("claude", "opencode") if k not in fallbacks}
        hidden |= {f"{k}:ask" for k in ("claude", "opencode") if k not in fallbacks}
        return [o for o in out if o.get("section") == "Favourites" or o["id"] not in hidden]

    def suggestions(self) -> list[str]:
        ids = []
        try:
            with open(util.HOME / ".config/omarchy/shell.json", encoding="utf-8") as f:
                pinned = (json.load(f).get("dock") or {}).get("pinned") or []
        except (OSError, ValueError, AttributeError):
            pinned = []
        ids += ["apps:" + str(p) for p in pinned if isinstance(p, str)]
        ids += ["plugins:agenda", "launcher:mode:clipboard", "launcher:mode:files", "launcher:mode:claude", "launcher:mode:opencode",
                "launcher:mode:bitwarden", "launcher:mode:emoji", "launcher:settings"]
        return ids

    def _emit_results(self, seq: int, items: list[dict], done: bool) -> None:
        self.remember(items)
        favs = self.settings.get("favourites", [])
        aliases_for = {v: k for k, v in self.settings.get("aliases", {}).items()}
        self.emit({"op": "results", "seq": seq, "items": [public(it, favs, aliases_for) for it in items],
                   "done": done})

    # Acting -----------------------------------------------------------------

    def actions(self, seq: int, item_id: str) -> None:
        it = self.find(item_id)
        acts = []
        if it:
            p = self.by_id.get(item_id.split(":", 1)[0])
            try:
                acts = list(p.actions(it)) if p else []
            except Exception:
                traceback.print_exc(file=sys.stderr)
            if it.get("recordable", True) and not item_id.startswith("launcher:find-files"):
                fav = item_id in self.settings.get("favourites", [])
                acts.append(action("unfav" if fav else "fav", "Remove from favourites" if fav else "Add to favourites",
                                   "󰓒", "ctrl+p"))
                aliases = [a for a, i in self.settings.get("aliases", {}).items() if i == item_id]
                acts.append(action("alias", f"Change alias ({aliases[0]})" if aliases else "Set alias…", "󰌌", "ctrl+l"))
                if aliases:
                    acts.append(action("unalias", "Remove alias", "󰌍"))
                if item_id in self.history.entries:
                    acts.append(action("forget", "Remove from recent", "󰆴"))
        self.emit({"op": "actions", "seq": seq, "id": item_id,
                   "actions": [{k: v for k, v in a.items() if not k.startswith("_")} for a in acts]})

    def run(self, item_id: str, aid: str, arg) -> None:
        aid = aid or "default"
        it = self.find(item_id)
        if not it:
            self.emit({"op": "do", "steps": [toast("That result is gone", True), refresh()]})
            return
        try:
            steps = self._run(it, aid, arg)
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            steps = [toast(f"Something went wrong: {e}", True)]
        for st in steps:
            if st.get("type") == "detail":
                st.setdefault("item", item_id)
        self.emit({"op": "do", "steps": steps})

    def _run(self, it: dict, aid: str, arg) -> list[dict]:
        item_id = it["id"]
        if aid in COMMON_ACTIONS:
            return self._common(it, aid, arg)
        if item_id == "launcher:find-files":
            return [set_query(it["_query"])]
        # An item that takes an argument asks for it first.
        if it.get("arg") and arg is None and aid == "default":
            return [{"type": "arg", "item": item_id, "action": aid, "title": it["title"],
                     "placeholder": it["arg"].get("placeholder", "")}]
        p = self.by_id.get(item_id.split(":", 1)[0])
        if not p:
            return [toast("Unknown result", True)]
        steps = p.run(it, aid, arg)
        if it.get("recordable", True) and any(s.get("type") in ("close", "launch-app", "detail") for s in steps):
            self.history.record(it, self.current_q.strip().lower())
        return steps

    def _common(self, it: dict, aid: str, arg) -> list[dict]:
        item_id = it["id"]
        if aid in ("fav", "unfav"):
            favs = [f for f in self.settings.get("favourites", []) if f != item_id]
            if aid == "fav":
                favs.append(item_id)
                self.history.record(it)     # so it shows even before its source has refreshed
            self.settings.set_many({"favourites": favs})
            return [toast(("Added " if aid == "fav" else "Removed ") + it["title"]), refresh()]
        if aid == "forget":
            self.history.forget(item_id)
            return [toast("Removed from recent"), refresh()]
        aliases = {a: i for a, i in self.settings.get("aliases", {}).items() if i != item_id}
        if aid == "unalias":
            self.settings.set_many({"aliases": aliases})
            return [toast("Alias removed"), refresh()]
        current = next((a for a, i in self.settings.get("aliases", {}).items() if i == item_id), "")
        return [form(f"alias:{item_id}", f"Alias for {it['title']}", [
            {"key": "alias", "label": "Alias", "type": "text", "value": current,
             "hint": "Typing exactly this puts the result first"}], icon="󰌌")]

    def submit(self, form_id: str, values: dict) -> None:
        try:
            if form_id.startswith("alias:"):
                item_id = form_id.split(":", 1)[1]
                alias = str(values.get("alias") or "").strip().lower()
                aliases = {a: i for a, i in self.settings.get("aliases", {}).items() if i != item_id and a != alias}
                if alias:
                    aliases[alias] = item_id
                    it = self.find(item_id)
                    if it:
                        self.history.record(it)
                self.settings.set_many({"aliases": aliases})
                steps = [toast(f"Alias “{alias}” saved" if alias else "Alias removed"), set_query(alias)]
            else:
                owner = {"snippet": "snippets", "quicklink": "quicklinks", "bitwarden": "bitwarden"}.get(form_id.split(":", 1)[0], "launcher")
                steps = self.by_id[owner].submit(form_id, values if isinstance(values, dict) else {})
        except Exception as e:
            traceback.print_exc(file=sys.stderr)
            steps = [toast(f"Could not save: {e}", True)]
        self.emit({"op": "do", "steps": steps})

    # Main loop --------------------------------------------------------------

    def handle(self, msg: dict) -> None:
        op = msg.get("op")
        if op == "apps":
            self.by_id["apps"].set_apps(msg.get("apps") or [])
        elif op == "open":
            self.refresh_all()
        elif op == "query":
            self.query(int(msg.get("seq") or 0), str(msg.get("q") or ""))
        elif op == "actions":
            self.actions(int(msg.get("seq") or 0), str(msg.get("id") or ""))
        elif op == "run":
            # Runs can block (op, az, pactl); keep reading queries meanwhile.
            threading.Thread(target=self.run, args=(str(msg.get("id") or ""), str(msg.get("action") or "default"),
                                                    msg.get("arg")), daemon=True).start()
        elif op == "submit":
            self.submit(str(msg.get("form") or ""), msg.get("values") or {})
        elif op == "copy":
            util.copy(str(msg.get("text") or ""))
        elif op == "stop":
            self.by_id.get(str(msg.get("agent") or "claude"), self.by_id["claude"]).cancel()
        elif op == "chat":
            self.by_id.get(str(msg.get("agent") or "claude"), self.by_id["claude"]).chat(str(msg.get("turn") or ""), str(msg.get("q") or ""),
                                      str(msg.get("session") or ""))

    def serve(self, stdin=sys.stdin) -> None:
        self.emit({"op": "hello"})
        self.refresh_all()
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if isinstance(msg, dict):
                try:
                    self.handle(msg)
                except Exception:
                    traceback.print_exc(file=sys.stderr)
