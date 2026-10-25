"""Files and folders: recently used ones in the normal search, everything under
the configured folders behind `/` (searched with fd)."""

from __future__ import annotations

import os
import subprocess
import time
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

from . import Provider, action, close, item, toast
from .. import match, util

RECENT_XBEL = util.HOME / ".local/share/recently-used.xbel"

ICONS = {
    "dir": "󰉋", "image": "󰈟", "video": "󰈫", "audio": "󰈣", "pdf": "󰈦", "archive": "󰗄",
    "code": "󰈮", "text": "󰈙", "sheet": "󰈛", "doc": "󰈬", "slides": "󰈧", "file": "󰈔",
}
EXT_KIND = {}
for kind, exts in {
    "image": "png jpg jpeg gif webp svg heic avif bmp tiff",
    "video": "mp4 mkv webm mov avi m4v",
    "audio": "mp3 flac ogg opus wav m4a aac",
    "pdf": "pdf",
    "archive": "zip tar gz xz zst 7z rar bz2 tgz",
    "code": "py js ts tsx jsx qml rs go c h cpp sh bash lua json toml yaml yml rb java kt swift html css",
    "text": "txt md org log csv conf ini",
    "sheet": "xlsx xls ods",
    "doc": "docx doc odt rtf",
    "slides": "pptx ppt odp key",
}.items():
    for ext in exts.split():
        EXT_KIND[ext] = kind


def icon_for(path: str, is_dir: bool = False) -> str:
    if is_dir:
        return ICONS["dir"]
    ext = path.rsplit(".", 1)[-1].lower() if "." in os.path.basename(path) else ""
    return ICONS.get(EXT_KIND.get(ext, "file"), ICONS["file"])


def recent_files(limit: int = 60) -> list[str]:
    try:
        tree = ET.parse(RECENT_XBEL)
    except (OSError, ET.ParseError):
        return []
    rows = []
    for bm in tree.getroot().iter("bookmark"):
        href = bm.get("href", "")
        if not href.startswith("file://"):
            continue
        path = urllib.parse.unquote(href[7:])
        rows.append((bm.get("visited") or bm.get("modified") or "", path))
    rows.sort(reverse=True)
    seen = []
    for _, p in rows:
        if p not in seen and os.path.exists(p):
            seen.append(p)
        if len(seen) >= limit:
            break
    return seen


class Files(Provider):
    id = "files"
    name = "Files"
    prefix = "/"
    in_global = True     # recent files only; the full search needs the prefix
    slow = True

    def __init__(self, ctx):
        super().__init__(ctx)
        self.recent: list[str] = []

    def available(self):
        return True

    def refresh(self):
        if self.settings.get("files.recent"):
            self.recent = recent_files()

    def _item(self, path: str, score: int = 0, recent: bool = False) -> dict:
        is_dir = os.path.isdir(path)
        name = os.path.basename(path.rstrip("/")) or path
        return item("files", path, name, subtitle=util.tilde(os.path.dirname(path)),
                    icon=icon_for(path, is_dir), accessory="Recent file" if recent else ("Folder" if is_dir else "File"),
                    recordable=False, score=score, _path=path, _dir=is_dir)

    def search(self, q, scoped):
        q = q.strip()
        out = []
        if self.settings.get("files.recent"):
            for p in self.recent:
                s = match.score(q, os.path.basename(p)) if q else 500
                if s >= (600 if not scoped else 300):
                    out.append(self._item(p, s - (100 if not scoped else 0), recent=True))
        if scoped and len(q) >= 2:
            # Typing quickly fires a search per key; wait a moment, and skip
            # this one if a newer search has started meanwhile.
            seq = self.ctx.current_seq
            time.sleep(0.12)
            if self.ctx.current_seq != seq:
                return []
            have = {it["_path"] for it in out}
            for p in self._fd(q):
                if p not in have:
                    s = match.score(q, os.path.basename(p.rstrip("/")))
                    out.append(self._item(p.rstrip("/"), s or 100))
        return out

    def browse(self):
        return [self._item(p, 500 - i, recent=True) for i, p in enumerate(self.recent[:30])]

    def _fd(self, q: str) -> list[str]:
        if not util.have("fd"):
            return []
        roots = [str(util.expand(r)) for r in self.settings.get("files.roots", ["~"]) if util.expand(r).exists()]
        if not roots:
            return []
        argv = ["fd", "--absolute-path", "--max-results", "150", "--color", "never",
                "--max-depth", str(int(self.settings.get("files.maxDepth", 8) or 8)), "--ignore-case"]
        if self.settings.get("files.hidden"):
            argv.append("--hidden")
        for ex in self.settings.get("files.exclude", []):
            argv += ["--exclude", str(ex)]
        # Every word must appear in the full path, the last one in the name.
        words = q.split()
        argv += ["--full-path", ".*".join(_regex_escape(w) for w in words)] if len(words) > 1 \
            else [_regex_escape(q)]
        argv += roots
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=3, start_new_session=True)
        except (OSError, subprocess.SubprocessError):
            return []
        return [line for line in out.stdout.splitlines() if line]

    def actions(self, it):
        acts = [action("default", "Open", "󰏌"),
                action("reveal", "Show in file manager", "󰉋", "ctrl+enter"),
                action("terminal", "Open terminal here", "", "ctrl+t"),
                action("editor", "Open in editor", "󰷈", "ctrl+e"),
                action("copy-path", "Copy path", "󰆏", "ctrl+shift+c")]
        if not it.get("_dir"):
            acts.append(action("copy-file", "Copy file", "󰆏", "ctrl+c"))
        return acts

    def run(self, it, aid, arg):
        path = it["_path"]
        if not os.path.exists(path):
            return [toast("That file is gone", True)]
        folder = path if it.get("_dir") else os.path.dirname(path)
        if aid == "reveal":
            util.open_target(folder)
        elif aid == "terminal":
            util.terminal(cwd=folder)
        elif aid == "editor":
            util.editor(path)
        elif aid == "copy-path":
            util.copy(path)
            return [toast("Copied " + util.tilde(path))]
        elif aid == "copy-file":
            util.copy_files([path])
            return [toast("Copied the file")]
        else:
            util.open_target(path)
        return [close()]


def _regex_escape(s: str) -> str:
    out = []
    for c in s:
        out.append("\\" + c if c in r".^$*+?()[]{}|\\" else c)
    return "".join(out)
