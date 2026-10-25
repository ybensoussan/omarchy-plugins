"""Settings: ~/.config/omarchy/omarchy-launcher.json.

The file holds only what differs from the defaults below, plus the lists the
user builds up (quicklinks, snippets, aliases, favourites). It is re-read
whenever it changes on disk, so editing it by hand works too.
"""

from __future__ import annotations

import copy
import json
import os
import threading

from .util import CONFIG

ENGINES = {
    "duckduckgo": ("DuckDuckGo", "https://duckduckgo.com/?q={query}"),
    "google": ("Google", "https://www.google.com/search?q={query}"),
    "kagi": ("Kagi", "https://kagi.com/search?q={query}"),
    "startpage": ("Startpage", "https://www.startpage.com/do/search?query={query}"),
    "bing": ("Bing", "https://www.bing.com/search?q={query}"),
    "custom": ("Custom", ""),
}

DEFAULT_QUICKLINKS = [
    {"name": "GitHub repository", "keyword": "gh", "url": "https://github.com/{query}"},
    {"name": "GitHub search", "keyword": "ghs", "url": "https://github.com/search?q={query}&type=repositories"},
    {"name": "Arch packages", "keyword": "pkg", "url": "https://archlinux.org/packages/?q={query}"},
    {"name": "AUR packages", "keyword": "aur", "url": "https://aur.archlinux.org/packages?K={query}"},
    {"name": "Arch Wiki", "keyword": "aw", "url": "https://wiki.archlinux.org/index.php?search={query}"},
    {"name": "YouTube", "keyword": "yt", "url": "https://www.youtube.com/results?search_query={query}"},
    {"name": "Wikipedia", "keyword": "wiki", "url": "https://en.wikipedia.org/w/index.php?search={query}"},
    {"name": "Google Maps", "keyword": "maps", "url": "https://www.google.com/maps/search/{query}"},
    {"name": "DeepL translate", "keyword": "tr", "url": "https://www.deepl.com/translator#auto/en/{query}"},
    {"name": "Omarchy manual", "keyword": "", "url": "https://learn.omacom.io/2/the-omarchy-manual"},
]

DEFAULTS = {
    "general": {
        "position": "top",          # top | center
        "width": 760,
        "rows": 9,                  # result rows visible before scrolling
        "home": "favourites-recent",  # favourites-recent | favourites | nothing
        "rememberQuery": False,     # reopen with the last search
        "fallbacks": ["web", "claude", "files"],  # rows under every search
        "showSubtitles": True,
    },
    # Per source: on/off, part of the normal search or only behind its prefix.
    # Filled in from the providers' own defaults (see Registry.source_defaults).
    "sources": {},
    "web": {"engine": "duckduckgo", "custom": ""},
    "files": {
        "roots": ["~"],
        "exclude": ["node_modules", ".git", ".cache", "__pycache__", ".venv", "venv", "target",
                    ".local/share/Trash", ".mozilla", ".zen", ".npm", ".cargo", ".rustup", "go/pkg"],
        "hidden": False,
        "maxDepth": 8,
        "recent": True,             # recently used files in the normal search
    },
    "calculator": {"currency": True},
    "shell": {"mode": "terminal"},  # terminal | background
    # Folder layout: globs for the project folders, the Markdown files `help`
    # searches, and the folder Claude answers from (its CLAUDE.md is the context).
    "projects": {"roots": ["~/Projects/*", "~/projects/*", "~/Work/*", "~/src/*", "~/code/*"],
                 "open": "terminal"},  # terminal | editor | files
    "manual": {"files": [(os.environ.get("DOTFILES") or "~/.dotfiles") + "/README.md"]},
    "bitwarden": {"clearAfter": 30, "primary": "password"},  # password | username | otp
    "opencode": {"model": "", "agent": "plan", "variant": "", "folder": "~"},
    "claude": {"model": "sonnet", "folder": "~", "space": ""},  # space: herdr space for Ctrl+Enter
    "quicklinks": DEFAULT_QUICKLINKS,
    "snippets": [
        {"name": "Today's date", "keyword": "date", "text": "{date}"},
        {"name": "Shrug", "keyword": "shrug", "text": "¯\\_(ツ)_/¯"},
    ],
    "aliases": {},                  # "ff": "app:zen.desktop"
    "favourites": [],               # item ids, in order
}


def _merge(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = _merge(base[k], v) if k in base else v
        return out
    # A list or scalar from the file replaces the default as a whole, but only
    # when the type fits; a hand-edited "width": "wide" falls back.
    if base is None or over is None:
        return over if base is None else base
    if isinstance(base, bool) != isinstance(over, bool):
        return base
    if isinstance(base, (int, float)) and isinstance(over, (int, float)):
        return over
    return over if type(over) is type(base) else base


class Settings:
    def __init__(self, path=CONFIG, source_defaults: dict | None = None):
        self.path = path
        self.source_defaults = source_defaults or {}
        self._lock = threading.Lock()
        self._mtime = None
        self.raw: dict = {}
        self.data: dict = {}
        self.reload(force=True)

    def defaults(self) -> dict:
        d = copy.deepcopy(DEFAULTS)
        d["sources"] = copy.deepcopy(self.source_defaults)
        return d

    def reload(self, force: bool = False) -> None:
        try:
            mtime = os.stat(self.path).st_mtime_ns
        except OSError:
            mtime = None
        if not force and mtime == self._mtime:
            return
        raw = {}
        if mtime is not None:
            try:
                with open(self.path, encoding="utf-8") as f:
                    raw = json.load(f)
            except (OSError, ValueError):
                raw = {}
        with self._lock:
            self._mtime = mtime
            self.raw = raw if isinstance(raw, dict) else {}
            self.data = _merge(self.defaults(), self.raw)

    def get(self, dotted: str, default=None):
        node = self.data
        for part in dotted.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        return node

    def source(self, sid: str) -> dict:
        return self.get(f"sources.{sid}", {}) or {}

    def set_many(self, values: dict) -> None:
        """Set dotted keys and save. Values equal to the default are dropped."""
        with self._lock:
            raw = copy.deepcopy(self.raw)
            for dotted, value in values.items():
                node = raw
                parts = dotted.split(".")
                for part in parts[:-1]:
                    if not isinstance(node.get(part), dict):
                        node[part] = {}
                    node = node[part]
                node[parts[-1]] = value
            raw = _prune(raw, self.defaults())
            self._write(raw)

    def _write(self, raw: dict) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = f"{self.path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(raw, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, self.path)
        self._mtime = None
        self.raw = raw
        self.data = _merge(self.defaults(), raw)

    def reset(self) -> None:
        """Back to the defaults, keeping the user's lists."""
        keep = {k: self.raw[k] for k in ("quicklinks", "snippets", "aliases", "favourites") if k in self.raw}
        with self._lock:
            self._write(keep)


def _prune(raw, defaults):
    """Drop values that equal their default, so the file stays small."""
    if not isinstance(raw, dict) or not isinstance(defaults, dict):
        return raw
    out = {}
    for k, v in raw.items():
        if k in defaults:
            if isinstance(v, dict) and isinstance(defaults[k], dict):
                pruned = _prune(v, defaults[k])
                if pruned:
                    out[k] = pruned
                continue
            if v == defaults[k]:
                continue
        out[k] = v
    return out
