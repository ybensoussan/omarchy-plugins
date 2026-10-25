"""The launcher's own commands: settings, search modes, favourites and aliases."""

from __future__ import annotations

from . import Provider, action, close, form, item, refresh, set_query, toast
from .. import util
from ..settings import ENGINES

FALLBACKS = [("web", "Search the web"), ("claude", "Ask Claude"), ("opencode", "Ask OpenCode"), ("files", "Search files")]


def choice(key, label, value, options, hint=""):
    return {"key": key, "label": label, "type": "choice", "value": value, "hint": hint,
            "options": [{"value": v, "label": l} for v, l in options]}


def toggle(key, label, value, hint=""):
    return {"key": key, "label": label, "type": "toggle", "value": bool(value), "hint": hint}


def text(key, label, value, hint=""):
    return {"key": key, "label": label, "type": "text", "value": str(value or ""), "hint": hint}


def number(key, label, value, lo, hi, hint=""):
    return {"key": key, "label": label, "type": "number", "value": int(value), "min": lo, "max": hi, "hint": hint}


def section(label):
    return {"type": "section", "label": label}


def link(label, item_id, hint=""):
    return {"type": "link", "label": label, "item": item_id, "hint": hint}


def as_list(value) -> list[str]:
    return [p.strip() for p in str(value or "").split(",") if p.strip()]


class Builtin(Provider):
    id = "launcher"
    name = "Launcher"

    def _commands(self) -> list[dict]:
        out = [item("launcher", "settings", "Launcher settings", subtitle="Look, sources, search, Bitwarden, Claude, OpenCode…",
                    icon="󰒓", accessory="Launcher", _keywords=["preferences", "config", "options", "launcher"]),
               item("launcher", "sources", "Search sources", subtitle="Turn sources on or off and set their prefixes",
                    icon="󰍉", accessory="Launcher", _keywords=["settings", "providers", "prefix"]),
               item("launcher", "reload", "Reload launcher", subtitle="Re-read settings, scripts and the menu",
                    icon="󰑓", accessory="Launcher", recordable=False, _keywords=["refresh", "restart"]),
               item("launcher", "forget", "Clear launcher history", subtitle="Forget recently used items",
                    icon="󰆴", accessory="Launcher", recordable=False, _keywords=["recent", "frecency", "reset"]),
               item("launcher", "scripts-folder", "Open script commands folder",
                    subtitle=util.tilde(util.USER_DIR / "commands"), icon="󰉋", accessory="Launcher",
                    _keywords=["scripts", "extensions", "commands"])]
        # One row per prefix: "Search Files", "Clipboard History"…
        for p in self.ctx.providers:
            prefix = self.ctx.prefix_of(p)
            if not prefix or not self.ctx.enabled(p):
                continue
            out.append(item("launcher", f"mode:{p.id}", p.name, subtitle=p.description or f"Type “{prefix}” to search only this",
                            icon=_MODE_ICONS.get(p.id, "󰍉"), accessory=prefix,
                            _keywords=[prefix, "search " + p.name], _prefix=prefix))
        return out

    def search(self, q, scoped):
        return self.rank(q, self._commands())

    def browse(self):
        return self._commands()

    def resolve(self, item_id):
        if item_id == "launcher:reset-settings":
            return item("launcher", "reset-settings", "Reset settings", recordable=False)
        for it in self._commands():
            if it["id"] == item_id:
                return it
        return None

    def actions(self, it):
        return [action("default", "Open", "󰏌")]

    def run(self, it, aid, arg):
        key = it["id"].split(":", 1)[1]
        if key.startswith("mode:"):
            p = it["_prefix"]
            return [set_query(p if len(p) == 1 and not p.isalnum() else p + " ")]
        if key == "settings":
            return [self.settings_form()]
        if key == "sources":
            return [self.sources_form()]
        if key == "reload":
            self.settings.reload(force=True)
            self.ctx.refresh_all(wait=True)
            return [toast("Reloaded"), refresh()]
        if key == "reset-settings":
            self.settings.reset()
            return [toast("Settings reset"), {"type": "settings-changed"}, set_query("")]
        if key == "forget":
            self.ctx.history.clear()
            return [toast("History cleared"), refresh()]
        if key == "scripts-folder":
            folder = util.USER_DIR / "commands"
            folder.mkdir(parents=True, exist_ok=True)
            util.open_target(str(folder))
            return [close()]
        return [close()]

    # Forms ----------------------------------------------------------------

    def settings_form(self) -> dict:
        s = self.settings.get
        fallbacks = s("general.fallbacks", [])
        fields = [
            section("Look"),
            choice("general.position", "Position", s("general.position"), [("top", "Upper third"), ("center", "Centered")]),
            number("general.width", "Width", s("general.width"), 480, 1400, "In pixels, before scaling"),
            number("general.rows", "Rows", s("general.rows"), 4, 20, "Results visible before scrolling"),
            toggle("general.showSubtitles", "Second line", s("general.showSubtitles"), "Path, description or details under each result"),
            section("Search"),
            choice("general.home", "Before typing", s("general.home"),
                   [("favourites-recent", "Favourites and recent"), ("favourites", "Favourites only"), ("nothing", "Nothing")]),
            toggle("general.rememberQuery", "Remember the last search", s("general.rememberQuery")),
        ]
        for key, label in FALLBACKS:
            if key in ("claude", "opencode"):
                continue   # toggled in their own sections below
            fields.append(toggle(f"fallback.{key}", f"Under every search: {label}", key in fallbacks))
        fields += [
            link("Search sources…", "launcher:sources", "Which sources are searched, and their prefixes"),
            section("Web"),
            choice("web.engine", "Search engine", s("web.engine"), [(k, v[0]) for k, v in ENGINES.items()]),
            text("web.custom", "Custom engine URL", s("web.custom"), "With {query}, for the Custom engine"),
            link(f"Quicklinks ({len(s('quicklinks', []))})…", "launcher:mode:quicklinks", "Add, edit or delete them there"),
            link(f"Snippets ({len(s('snippets', []))})…", "launcher:mode:snippets"),
            section("Files and projects"),
            text("files.roots", "Folders to search", ", ".join(s("files.roots", [])), "Comma separated"),
            text("files.exclude", "Skip", ", ".join(s("files.exclude", [])), "Folder names, comma separated"),
            toggle("files.hidden", "Include hidden files", s("files.hidden")),
            number("files.maxDepth", "Depth", s("files.maxDepth"), 1, 30, "How many folders deep"),
            toggle("files.recent", "Recent files in the normal search", s("files.recent")),
            text("projects.roots", "Project folders", ", ".join(s("projects.roots", [])),
                 "Globs, comma separated: ~/Projects/* or ~/Work/*/* for client/project"),
            choice("projects.open", "Open a project in", s("projects.open"),
                   [("terminal", "Terminal"), ("editor", "Editor"), ("files", "File manager")]),
            text("manual.files", "Manual", ", ".join(s("manual.files", [])),
                 "Markdown files that help searches by heading, comma separated"),
            section("Commands"),
            choice("shell.mode", "Shell commands (>)", s("shell.mode"), [("terminal", "Run in a terminal"), ("background", "Run in the background")]),
            toggle("calculator.currency", "Live exchange rates", s("calculator.currency"),
                   "qalc fetches rates once a day; off keeps the calculator offline"),
            section("Bitwarden"),
            choice("bitwarden.primary", "Enter copies", s("bitwarden.primary"),
                   [("password", "Password"), ("username", "Username"), ("otp", "One-time code")]),
            number("bitwarden.clearAfter", "Clear clipboard after", s("bitwarden.clearAfter"), 0, 600, "Seconds; 0 keeps it"),
            section("Claude"),
            toggle("fallback.claude", "Show “Ask Claude” under every search", "claude" in fallbacks,
                   "Off hides the row; `ask ` still works"),
            choice("claude.model", "Model", s("claude.model"), [("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")]),
            text("claude.folder", "Asks from", s("claude.folder"), "Its CLAUDE.md is the context; your home folder by default"),
            text("claude.space", "herdr space", s("claude.space"), "Ctrl+Enter hands the question to this space; empty hides it"),
            section("OpenCode"),
            toggle("fallback.opencode", "Show “Ask OpenCode” under every search", "opencode" in fallbacks,
                   "Off hides the row; `oc ` still works"),
            text("opencode.model", "Model", s("opencode.model"), "provider/model, like anthropic/claude-sonnet-4-5; empty uses your OpenCode default"),
            text("opencode.agent", "Agent", s("opencode.agent"), "plan is read-only; build can change files; empty uses your default"),
            text("opencode.variant", "Reasoning effort", s("opencode.variant"), "Provider-specific, like high or minimal; empty for the default"),
            text("opencode.folder", "Asks from", s("opencode.folder"), "Where OpenCode starts, for the chat and the terminal UI"),
            section("Favourites and aliases"),
            {"type": "info", "label": f"{len(s('favourites', []))} favourites, {len(s('aliases', {}))} aliases",
             "hint": "Tab on any result: Add to favourites (Ctrl+P) or Set alias"},
            link("Reset settings to defaults", "launcher:reset-settings", "Keeps quicklinks, snippets, aliases and favourites"),
        ]
        return form("settings", "Launcher settings", fields, icon="󰒓")

    def sources_form(self) -> dict:
        fields = [{"type": "info", "label": "Everywhere: part of the normal search. With prefix: only after typing its prefix."}]
        for p in self.ctx.providers:
            if p.id in ("launcher",):
                continue
            src = self.settings.source(p.id)
            state = "off" if not src.get("enabled", True) else ("global" if src.get("global", p.in_global) else "prefix")
            fields.append(section(p.name + ("" if p.available() else " (not available here)")))
            fields.append(choice(f"sources.{p.id}.state", "Search", state,
                                 [("global", "Everywhere"), ("prefix", "With prefix only"), ("off", "Off")],
                                 p.description))
            fields.append(text(f"sources.{p.id}.prefix", "Prefix", src.get("prefix", p.prefix)))
        return form("sources", "Search sources", fields, icon="󰍉")

    def submit(self, form_id, values):
        if form_id == "sources":
            out = {}
            for key, value in values.items():
                parts = key.split(".")
                if len(parts) != 3 or parts[0] != "sources":
                    continue
                if parts[2] == "state":
                    out[f"sources.{parts[1]}.enabled"] = value != "off"
                    out[f"sources.{parts[1]}.global"] = value == "global"
                elif parts[2] == "prefix":
                    out[key] = str(value).strip()
            self.settings.set_many(out)
            return [toast("Saved"), set_query("")]
        if form_id == "settings":
            out = {}
            fallbacks = []
            for key, value in values.items():
                if key.startswith("fallback."):
                    if value:
                        fallbacks.append(key.split(".", 1)[1])
                    continue
                if key in ("files.roots", "files.exclude", "projects.roots", "manual.files"):
                    value = as_list(value)
                elif key in ("general.width", "general.rows", "files.maxDepth", "bitwarden.clearAfter"):
                    try:
                        value = int(value)
                    except (TypeError, ValueError):
                        continue
                out[key] = value
            out["general.fallbacks"] = [k for k, _ in FALLBACKS if k in fallbacks]
            self.settings.set_many(out)
            return [toast("Saved"), {"type": "settings-changed"}, set_query("")]
        return [close()]


_MODE_ICONS = {"files": "󰈔", "clipboard": "󰅍", "emoji": "󰞅", "shell": "", "web": "󰖟", "calc": "󰃬",
               "bitwarden": "󰌆", "claude": "󰚩", "opencode": "󰆍", "processes": "󰍛", "keybindings": "󰌌", "snippets": "󰅪",
               "quicklinks": "󰌷", "windows": "󰖯", "herdr": "", "projects": "", "themes": "󰸌",
               "manual": "󰈙", "worldclock": "󰥔", "azure": "󰠅"}
