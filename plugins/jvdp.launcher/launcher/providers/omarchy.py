"""Every row of the Omarchy menu (Super+Space) as a command, plus its submenus.

Reads the same JSONC files the menu does: Omarchy's defaults, then the user's
extensions on top, and checks the rows' `when` / `disabled` / `checked`
conditions in one batched bash call each time the launcher opens.
"""

from __future__ import annotations

import json
import os
import subprocess

from . import Provider, action, close, item, toast
from .. import util

MENU_DEFAULT = os.path.join(util.OMARCHY_PATH, "default/omarchy/omarchy-menu.jsonc")
MENU_USER = util.HOME / ".config/omarchy/extensions/omarchy-menu.jsonc"


def parse_jsonc(text: str):
    """JSON with // and /* */ comments and trailing commas."""
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    cleaned = "".join(out)
    # Trailing commas: a comma followed only by whitespace before } or ].
    result = []
    in_str = False
    k = 0
    while k < len(cleaned):
        c = cleaned[k]
        if in_str:
            result.append(c)
            if c == "\\" and k + 1 < len(cleaned):
                result.append(cleaned[k + 1])
                k += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            result.append(c)
        elif c == ",":
            j = k + 1
            while j < len(cleaned) and cleaned[j] in " \t\r\n":
                j += 1
            if j < len(cleaned) and cleaned[j] in "}]":
                k += 1
                continue
            result.append(c)
        else:
            result.append(c)
        k += 1
    return json.loads("".join(result))


def load_menu() -> dict:
    rows: dict = {}
    for path in (MENU_DEFAULT, MENU_USER):
        try:
            with open(path, encoding="utf-8") as f:
                data = parse_jsonc(f.read())
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        for key, row in data.items():
            if isinstance(row, dict):
                merged = dict(rows.get(key, {}))
                merged.update(row)
                rows[key] = merged
    return rows


def check_conditions(rows: dict) -> dict:
    """Run every condition once: {(id, field): True/False}."""
    lines = []
    keys = []
    for rid, row in rows.items():
        for field in ("when", "disabled", "checked"):
            cond = row.get(field)
            if isinstance(cond, str) and cond.strip():
                keys.append((rid, field))
                lines.append(f"if ( {cond} ) >/dev/null 2>&1 </dev/null; then echo 1; else echo 0; fi")
    if not lines:
        return {}
    try:
        out = subprocess.run(["bash", "-c", "\n".join(lines)], capture_output=True, text=True, timeout=8,
                             start_new_session=True,
                             env=dict(os.environ, PATH=os.path.join(util.OMARCHY_PATH, "bin") + ":" + os.environ.get("PATH", "")))
        answers = out.stdout.split()
    except (OSError, subprocess.SubprocessError):
        answers = []
    return {k: (answers[i] == "1") for i, k in enumerate(keys) if i < len(answers)}


class OmarchyMenu(Provider):
    id = "omarchy"
    name = "Omarchy commands"

    def __init__(self, ctx):
        super().__init__(ctx)
        self.rows: dict = {}
        self.items: list[dict] = []
        self._build(load_menu(), {})

    def refresh(self):
        rows = load_menu()
        self._build(rows, check_conditions(rows))

    def _label_path(self, rows: dict, rid: str) -> str:
        parts = rid.split(".")
        labels = []
        for i in range(1, len(parts)):
            parent = rows.get(".".join(parts[:i]), {})
            labels.append(str(parent.get("label") or parts[i - 1]))
        return " › ".join(labels)

    def _build(self, rows: dict, cond: dict) -> None:
        self.rows = rows
        items = []
        for rid, row in rows.items():
            if cond.get((rid, "when")) is False:
                continue
            # Parent hidden → the row is unreachable in the menu, so here too.
            parts = rid.split(".")
            if any(cond.get((".".join(parts[:i]), "when")) is False for i in range(1, len(parts))):
                continue
            label = str(row.get("label") or rid)
            path = self._label_path(rows, rid)
            is_menu = not row.get("action")
            disabled = cond.get((rid, "disabled")) is True
            top = str(rows.get(parts[0], {}).get("label") or "Omarchy") if len(parts) > 1 else "Omarchy"
            accessory = "Installed" if disabled else ("On" if cond.get((rid, "checked")) else ("Menu" if is_menu else top))
            if is_menu and rid == "apps":
                continue
            keywords = [str(a) for a in row.get("aliases", []) if isinstance(a, str)]
            if row.get("description"):
                keywords.append(str(row["description"]))
            keywords.append(path)
            items.append(item("omarchy", rid, label, subtitle=path or "Omarchy menu",
                              icon=str(row.get("icon") or ""), accessory=accessory,
                              _keywords=keywords, _action=str(row.get("action") or ""),
                              _target=str(row.get("target") or ""), _menu=is_menu, _disabled=disabled,
                              _depth=len(parts), _side=parts[0] in ("install", "remove")))
        self.items = items

    def search(self, q, scoped):
        found = self.rank(q, self.items)
        for it in found:
            # Leaf commands over submenus, shallow over deep; installed-already last.
            # Installing or removing software is rarer than using what's there.
            it["score"] -= (30 if it["_menu"] else 0) + it["_depth"] * 5 + (200 if it["_disabled"] else 0) \
                + (90 if it.get("_side") else 0)
        return found

    def browse(self):
        return [it for it in self.items if it["_depth"] == 1]

    def resolve(self, item_id):
        for it in self.items:
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        acts = [action("default", "Open menu" if it["_menu"] else "Run", "󰘳")]
        acts.append(action("menu", "Show in Omarchy menu", "󰍜", "ctrl+enter"))
        if it["_action"]:
            acts.append(action("copy", "Copy command", "󰆏", "ctrl+shift+c"))
        return acts

    def run(self, it, aid, arg):
        rid = it["id"].split(":", 1)[1]
        if aid == "copy":
            util.copy(it["_action"])
            return [toast("Copied the command")]
        if it["_disabled"] and aid == "default":
            return [toast(f"{it['title']} is already installed")]
        if aid == "menu" or it["_menu"]:
            target = it["_target"] or (rid if it["_menu"] else rid.rsplit(".", 1)[0] if "." in rid else "root")
            payload = json.dumps({"initialMenu": target})
            util.spawn(["omarchy-shell", "shell", "summon", "omarchy.menu", payload])
            return [close()]
        # Menu actions are shell lines from Omarchy's (or the user's) own config.
        util.spawn_shell(it["_action"])
        return [close()]
