"""Sources of results. Each provider searches one kind of thing and knows what
to do with its own items.

An item is a plain dict sent to the overlay as JSON:

  id         "<provider>:<key>", stable across searches where possible
  title      the main line
  subtitle   the second line (path, description…)
  icon       a Nerd Font glyph, or
  appIcon    an icon-theme name (apps, windows), or
  image      a file path (clipboard images)
  accessory  short text on the right ("Application", a shortcut, a result)
  arg        {"placeholder": "…"} when the item takes an argument first
  recordable False keeps it out of the recent list (windows, calculations…)

Keys starting with "_" stay in the backend: what the provider needs to act.
"""

from __future__ import annotations

from .. import match


def item(provider: str, key: str, title: str, **fields) -> dict:
    out = {"id": f"{provider}:{key}", "title": str(title), "subtitle": "", "icon": "", "appIcon": "",
           "image": "", "accessory": "", "recordable": True}
    out.update({k: v for k, v in fields.items() if v is not None})
    return out


def action(aid: str, title: str, icon: str = "", shortcut: str = "") -> dict:
    return {"id": aid, "title": title, "icon": icon, "shortcut": shortcut}


# Instructions a provider returns from run(); the overlay carries them out.
def close() -> dict:
    return {"type": "close"}


def toast(text: str, error: bool = False, sticky: bool = False) -> dict:
    return {"type": "toast", "text": text, "error": error, "sticky": sticky}


def set_query(q: str) -> dict:
    return {"type": "query", "q": q}


def refresh() -> dict:
    return {"type": "refresh"}


def launch_app(app_id: str, name: str = "", action_id: str = "") -> dict:
    return {"type": "launch-app", "appId": app_id, "name": name, "action": action_id}


def detail(title: str, text: str, fmt: str = "plain", stream: str = "", actions: list | None = None,
           icon: str = "") -> dict:
    return {"type": "detail", "title": title, "text": text, "format": fmt, "stream": stream,
            "actions": actions or [], "icon": icon}


def form(form_id: str, title: str, fields: list, submit: str = "Save", icon: str = "") -> dict:
    return {"type": "form", "form": {"id": form_id, "title": title, "fields": fields, "submit": submit,
                                     "icon": icon}}


class Provider:
    id = ""
    name = ""
    prefix = ""          # typed before a search to search only this provider
    in_global = True     # part of the normal search by default
    slow = False         # searched in a thread; results stream in after the fast ones
    description = ""

    def __init__(self, ctx):
        self.ctx = ctx

    @property
    def settings(self):
        return self.ctx.settings

    def available(self) -> bool:
        return True

    def refresh(self) -> None:
        """Called (in a thread) each time the launcher opens."""

    def search(self, q: str, scoped: bool) -> list[dict]:
        return []

    def browse(self) -> list[dict]:
        """What shows for the bare prefix, before anything is typed."""
        return []

    def actions(self, it: dict) -> list[dict]:
        return [action("default", "Open", "󰏌")]

    def run(self, it: dict, aid: str, arg: str | None) -> list[dict]:
        return [close()]

    def resolve(self, item_id: str) -> dict | None:
        """The current item for an id from history, or None if it is gone."""
        return None

    def submit(self, form_id: str, values: dict) -> list[dict]:
        return [close()]

    # Helpers ------------------------------------------------------------------

    @staticmethod
    def rank(q: str, items: list[dict], keywords_key: str = "_keywords", minimum: int = 1) -> list[dict]:
        out = []
        for it in items:
            s = match.score(q, it["title"], it.get(keywords_key, []), it.get("subtitle", ""))
            if s >= minimum:
                it = dict(it)
                it["score"] = s
                out.append(it)
        return out
