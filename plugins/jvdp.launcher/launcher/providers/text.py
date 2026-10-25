"""Text you put somewhere: clipboard history, emoji and snippets."""

from __future__ import annotations

import datetime
import json
import os
import re
import uuid

from . import Provider, action, close, form, item, refresh, set_query, toast
from .. import match, util

CLIP_HISTORY = util.HOME / ".local/state/omarchy/clipboard-history.json"
EMOJI_JSON = os.path.join(util.OMARCHY_PATH, "shell/plugins/emojis/emojis.json")


class Clipboard(Provider):
    """Omarchy's clipboard history (the Super+Ctrl+V manager), searchable here."""

    id = "clipboard"
    name = "Clipboard history"
    prefix = "cb"
    in_global = False

    def _entries(self) -> list[dict]:
        try:
            with open(CLIP_HISTORY, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            return []
        out = []
        for i, e in enumerate(data if isinstance(data, list) else []):
            if not isinstance(e, dict):
                continue
            if e.get("type") == "text" and isinstance(e.get("text"), str):
                text = e["text"]
                one_line = " ".join(text.split())
                lines = text.count("\n") + 1
                out.append(item("clipboard", str(i), one_line[:200] or "(blank)",
                                subtitle=f"{lines} lines · {len(text)} characters" if lines > 1 else f"{len(text)} characters",
                                icon="󰅍", accessory="Clipboard", recordable=False, _index=i, _text=text))
            elif isinstance(e.get("path"), str) and os.path.exists(e["path"]):
                out.append(item("clipboard", str(i), os.path.basename(e["path"]),
                                subtitle=str(e.get("mime") or "image"), image=e["path"], icon="󰋩",
                                accessory="Clipboard", recordable=False, _index=i, _path=e["path"],
                                _mime=str(e.get("mime") or "image/png")))
        return out

    def search(self, q, scoped):
        entries = self._entries()
        if not q.strip():
            return [dict(e, score=500 - i) for i, e in enumerate(entries[:100])]
        out = []
        ql = match.fold(q)
        for i, e in enumerate(entries):
            hay = match.fold(e.get("_text") or e["title"])
            if ql in hay:
                out.append(dict(e, score=700 - min(i, 300)))
            elif len(out) < 50:
                s = match.score_text(q, e["title"][:120])
                if s >= 400:
                    out.append(dict(e, score=s - 200 - min(i, 100)))
        return out

    def browse(self):
        return self.search("", True)

    def actions(self, it):
        acts = [action("default", "Paste", "󰆒"), action("copy", "Copy", "󰆏", "ctrl+c")]
        if it.get("_text"):
            acts.append(action("show", "Show full text", "󰈙", "ctrl+enter"))
        acts.append(action("manager", "Open clipboard manager", "󰅌", "ctrl+m"))
        return acts

    def run(self, it, aid, arg):
        helper = os.path.join(util.OMARCHY_PATH, "bin")
        idx = str(it["_index"])
        if aid == "manager":
            util.spawn(["omarchy-shell", "shell", "summon", "omarchy.clipboard"])
            return [close()]
        if aid == "show":
            from . import detail
            return [detail("Clipboard", it["_text"], icon="󰅍",
                           actions=[action("copy", "Copy", "󰆏", "ctrl+c")])]
        if it.get("_path"):
            argv = [os.path.join(helper, "omarchy-clipboard-paste-file")]
            if aid == "copy":
                argv.append("--copy-only")
            util.spawn(argv + [it["_mime"], it["_path"]])
            return [close()]
        argv = [os.path.join(helper, "omarchy-clipboard-paste-text")]
        argv += ["--copy-only"] if aid == "copy" else ["--shift-insert"]
        _later(argv + ["--history-index", idx])
        return [close()]


def _later(argv):
    """After the overlay has gone, so a paste lands in the app underneath."""
    util.spawn(["bash", "-c", 'sleep 0.25; exec "$@"', "bash"] + argv)


class Emoji(Provider):
    id = "emoji"
    name = "Emoji"
    prefix = ":"
    in_global = False

    def __init__(self, ctx):
        super().__init__(ctx)
        self._emojis = None

    def _load(self):
        if self._emojis is None:
            try:
                with open(EMOJI_JSON, encoding="utf-8") as f:
                    data = json.load(f)
                self._emojis = [(e["e"], e.get("k", "")) for e in data if isinstance(e, dict) and e.get("e")]
            except (OSError, ValueError, KeyError):
                self._emojis = []
        return self._emojis

    def _item(self, e, k, score):
        name = k.split("  ")[0]
        words = k.split()
        # Omarchy's keyword list starts with the emoji's name; keep it short.
        title = " ".join(words[:5]) if words else e
        return item("emoji", e, title, icon=e, accessory="Emoji", recordable=True, score=score,
                    subtitle="", _emoji=e, _keywords=[name])

    def search(self, q, scoped):
        q = q.strip()
        out = []
        for i, (e, k) in enumerate(self._load()):
            if not q:
                if i < 80:
                    out.append(self._item(e, k, 500 - i))
                continue
            s = max((match.score_text(q, w) for w in k.split()), default=0)
            if s >= 600:
                out.append(self._item(e, k, s - i // 50))
            if len(out) >= 120:
                break
        return out

    def browse(self):
        return self.search("", True)

    def resolve(self, item_id):
        e = item_id.split(":", 1)[1]
        for em, k in self._load():
            if em == e:
                return self._item(em, k, 0)
        return None

    def actions(self, it):
        return [action("default", "Insert", "󰆒"), action("copy", "Copy", "󰆏", "ctrl+c")]

    def run(self, it, aid, arg):
        if aid == "copy":
            util.copy(it["_emoji"])
            return [close()]
        _later([os.path.join(util.OMARCHY_PATH, "bin/omarchy-menu-emoji-insert"), it["_emoji"]])
        return [close()]


def expand_snippet(text: str, clipboard: str | None = None) -> str:
    """Fill in {date}, {time}, {datetime}, {weekday}, {uuid} and {clipboard}."""
    now = datetime.datetime.now()
    values = {
        "date": now.strftime("%Y-%m-%d"), "time": now.strftime("%H:%M"),
        "datetime": now.strftime("%Y-%m-%d %H:%M"), "weekday": now.strftime("%A"),
        "uuid": str(uuid.uuid4()),
    }

    def sub(m):
        key = m.group(1)
        if key == "clipboard":
            return clipboard if clipboard is not None else util.run(["wl-paste", "--no-newline"], timeout=2)
        return values.get(key, m.group(0))

    return re.sub(r"\{(date|time|datetime|weekday|uuid|clipboard)\}", sub, text)


class Snippets(Provider):
    id = "snippets"
    name = "Snippets"
    prefix = "sn"
    description = "Saved text; {date} {time} {clipboard} {uuid} are filled in"

    def _items(self):
        out = [item("snippets", "new", "Create snippet", subtitle="Save text to paste with a few keys",
                    icon="󰐕", accessory="Snippet", recordable=False, _new=True)]
        for i, sn in enumerate(self.settings.get("snippets", [])):
            if not isinstance(sn, dict) or not sn.get("text"):
                continue
            name = str(sn.get("name") or sn["text"][:40])
            kw = str(sn.get("keyword") or "")
            preview = " ".join(str(sn["text"]).split())[:120]
            out.append(item("snippets", f"{i}:{name}", name, subtitle=preview, icon="󰅪",
                            accessory=kw or "Snippet", _keywords=[kw] if kw else [], _index=i,
                            _text=str(sn["text"]), _kw=kw))
        return out

    def search(self, q, scoped):
        items = self._items()
        ql = q.strip().lower()
        out = []
        for it in self.rank(q, items[1:]):
            if it.get("_kw") and it["_kw"].lower() == ql:
                it["score"] = 980
            out.append(it)
        if scoped:
            out += [dict(items[0], score=300)]
        return out

    def browse(self):
        return self._items()

    def resolve(self, item_id):
        for it in self._items():
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        if it.get("_new"):
            return [action("default", "Create snippet", "󰐕")]
        return [action("default", "Paste", "󰆒"), action("copy", "Copy", "󰆏", "ctrl+c"),
                action("edit", "Edit snippet", "󰏫", "ctrl+e"), action("delete", "Delete snippet", "󰆴", "ctrl+d")]

    def run(self, it, aid, arg):
        if it.get("_new") or aid == "edit":
            sn = {} if it.get("_new") else self.settings.get("snippets", [])[it["_index"]]
            return [form(f"snippet:{'new' if it.get('_new') else it['_index']}",
                         "Create snippet" if it.get("_new") else "Edit snippet", [
                             {"key": "name", "label": "Name", "type": "text", "value": sn.get("name", "")},
                             {"key": "keyword", "label": "Keyword", "type": "text", "value": sn.get("keyword", ""),
                              "hint": "Type it in the launcher to find this snippet first"},
                             {"key": "text", "label": "Text", "type": "textarea", "value": sn.get("text", ""),
                              "hint": "{date} {time} {datetime} {weekday} {uuid} {clipboard} are filled in"},
                         ], icon="󰅪")]
        if aid == "delete":
            snippets = list(self.settings.get("snippets", []))
            if 0 <= it["_index"] < len(snippets):
                snippets.pop(it["_index"])
                self.settings.set_many({"snippets": snippets})
            return [toast("Deleted " + it["title"]), refresh()]
        text = expand_snippet(it["_text"])
        if aid == "copy":
            util.copy(text)
            return [toast("Copied"), close()]
        util.paste(text)
        return [close()]

    def submit(self, form_id, values):
        which = form_id.split(":", 1)[1]
        text = str(values.get("text") or "")
        if not text.strip():
            return [toast("A snippet needs some text", True)]
        entry = {"name": str(values.get("name") or "").strip() or text.strip().splitlines()[0][:40],
                 "keyword": str(values.get("keyword") or "").strip(), "text": text}
        snippets = list(self.settings.get("snippets", []))
        if which == "new":
            snippets.append(entry)
        else:
            snippets[int(which)] = entry
        self.settings.set_many({"snippets": snippets})
        return [toast("Saved " + entry["name"]), set_query("sn ")]
