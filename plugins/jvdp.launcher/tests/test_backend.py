"""Backend tests: python3 -m unittest discover -s tests (from the repo root)."""

import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from launcher import match  # noqa: E402
from launcher.providers import calc, knowledge, omarchy, scripts, text, web, worldclock  # noqa: E402
from launcher.settings import Settings  # noqa: E402


class MatchTest(unittest.TestCase):
    def test_order_of_preference(self):
        q = "fire"
        exact = match.score_text(q, "fire")
        prefix = match.score_text(q, "Firefox")
        word = match.score_text(q, "Zen Firefox")
        sub = match.score_text(q, "Campfire")
        scattered = match.score_text(q, "First rare")
        self.assertGreater(exact, prefix)
        self.assertGreater(prefix, word)
        self.assertGreater(word, sub)
        self.assertGreater(sub, scattered)

    def test_initials_and_accents(self):
        self.assertGreaterEqual(match.score_text("vsc", "Visual Studio Code"), 700)
        self.assertGreater(match.score_text("cafe", "Café Noir"), 0)
        self.assertGreaterEqual(match.score_text("send", "LocalSend"), 700)

    def test_no_match(self):
        self.assertEqual(match.score_text("xyz", "Firefox"), 0)


class CalcTest(unittest.TestCase):
    def test_arithmetic(self):
        self.assertEqual(calc.format_number(calc.safe_eval("2*(3+4)")), "14")
        self.assertEqual(calc.format_number(calc.safe_eval("2^10")), "1024")
        self.assertEqual(calc.format_number(calc.safe_eval("sqrt(16) + 1")), "5")
        self.assertEqual(calc.format_number(calc.safe_eval("50% * 30")), "15")

    def test_refuses_code(self):
        for expr in ("__import__('os')", "open('x')", "().__class__", "9**99999", "factorial(10000)"):
            with self.assertRaises(Exception):
                calc.safe_eval(expr)

    def test_search_skips_words_and_dates(self):
        c = calc.Calculator(_Ctx())
        self.assertEqual(c.search("firefox", False), [])
        self.assertEqual(c.search("2026", False), [])
        self.assertEqual(c.search("1+1", False)[0]["title"], "2")


class WorldClockTest(unittest.TestCase):
    def test_phrasings(self):
        for q in ("time in tokyo", "what time is it in Tokyo?", "tokyo time", "time tokyo"):
            kind, groups = worldclock.parse(q)
            self.assertEqual(kind, "now", q)
            self.assertEqual(worldclock.find_zone(groups[0])[1], "Asia/Tokyo", q)

    def test_aliases_and_conversion(self):
        self.assertEqual(worldclock.find_zone("nyc")[1], "America/New_York")
        self.assertEqual(worldclock.find_zone("leiden")[1], "Europe/Amsterdam")
        clock = worldclock.WorldClock(_Ctx())
        res = clock.search("3pm london in tokyo", False)
        self.assertEqual(len(res), 1)
        self.assertRegex(res[0]["title"], r"^\d\d:\d\d$")

    def test_not_a_place(self):
        self.assertEqual(worldclock.WorldClock(_Ctx()).search("screen time", False), [])


class MarkdownTest(unittest.TestCase):
    def test_images_and_html_are_neutralised(self):
        md = 'Hi ![x](https://evil.example/t.png) <img src="https://evil.example/a"> and <b>bold</b>'
        out = knowledge.sanitize_markdown(md)
        self.assertNotIn("evil.example/t.png", out)
        self.assertNotIn("<img", out)
        self.assertNotIn("<b>", out)

    def test_code_is_left_alone(self):
        md = "Run `a < b`:\n```\nif a < b:\n```\nthen <x>"
        out = knowledge.sanitize_markdown(md)
        self.assertIn("`a < b`", out)
        self.assertIn("if a < b:", out)
        self.assertIn("&lt;x&gt;", out)

    def test_unclosed_backtick(self):
        self.assertNotIn("<img", knowledge.sanitize_markdown("oops ` <img src=x>"))


class JsoncTest(unittest.TestCase):
    def test_comments_commas_and_urls(self):
        data = omarchy.parse_jsonc('{\n // c\n "a": {"url": "https://x.y//z", },\n /* b */ "b": [1,2,],\n}')
        self.assertEqual(data["a"]["url"], "https://x.y//z")
        self.assertEqual(data["b"], [1, 2])

    def test_real_menu_parses(self):
        rows = omarchy.load_menu()
        if os.path.exists(omarchy.MENU_DEFAULT):
            self.assertIn("system.lock", rows)


class ScriptHeaderTest(unittest.TestCase):
    def test_script_header(self):
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write("#!/bin/bash\n# @launcher.schemaVersion 1\n# @launcher.title Public IP\n"
                    "# @launcher.mode compact\n# @launcher.argument1 { \"type\": \"text\", \"placeholder\": \"Host\" }\n")
        try:
            meta = scripts.parse_header(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(meta["title"], "Public IP")
        self.assertEqual(meta["mode"], "compact")
        self.assertEqual(meta["arguments"][0]["placeholder"], "Host")

    def test_no_header(self):
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write("#!/bin/bash\necho hi\n")
        try:
            self.assertIsNone(scripts.parse_header(f.name))
        finally:
            os.unlink(f.name)


class TextTest(unittest.TestCase):
    def test_snippet_placeholders(self):
        out = text.expand_snippet("{date} {clipboard} {nope}", clipboard="CLIP")
        self.assertRegex(out, r"^\d{4}-\d{2}-\d{2} CLIP \{nope\}$")

    def test_quicklink_fill(self):
        self.assertEqual(web.fill("https://github.com/{query}", "owner/repo"), "https://github.com/owner/repo")
        self.assertEqual(web.fill("https://x.y/?q={query}", "a b&c"), "https://x.y/?q=a+b%26c")


class SettingsTest(unittest.TestCase):
    def test_defaults_merge_and_prune(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.json")
            with open(path, "w") as f:
                json.dump({"general": {"width": "wide", "rows": 12}}, f)
            s = Settings(path, {"apps": {"enabled": True, "global": True, "prefix": ""}})
            self.assertEqual(s.get("general.width"), 760)    # wrong type → default
            self.assertEqual(s.get("general.rows"), 12)
            s.set_many({"general.rows": 9, "web.engine": "kagi"})
            with open(path) as f:
                saved = json.load(f)
            self.assertNotIn("rows", saved.get("general", {}))   # default again → dropped
            self.assertEqual(saved["web"]["engine"], "kagi")

    def test_manual_reads_the_configured_files(self):
        with tempfile.TemporaryDirectory() as d:
            doc = os.path.join(d, "notes.md")
            with open(doc, "w") as f:
                f.write("# Notes\n\n## Backups\n\nRestic every night.\n")
            path = os.path.join(d, "s.json")
            with open(path, "w") as f:
                json.dump({"manual": {"files": [doc]}}, f)
            ctx = _Ctx()
            ctx.settings = Settings(path)
            manual = knowledge.Manual(ctx)
            self.assertTrue(manual.available())
            manual.refresh()
            self.assertEqual([it["title"] for it in manual.items], ["Backups"])


class ServerTest(unittest.TestCase):
    def test_prefix_scoping_and_fallbacks(self):
        from launcher.server import Server
        buf = io.StringIO()
        server = Server(out=buf)
        p, rest = server.scope("= 2+2")
        self.assertEqual(p.id, "calc")
        self.assertEqual(rest, "2+2")
        p, rest = server.scope("kill firefox")
        self.assertEqual(p.id, "processes")
        p, rest = server.scope("killer queen")
        self.assertIsNone(p)
        fallback_ids = [it["id"] for it in server.fallbacks("abc")]
        self.assertIn("web:search", fallback_ids)


class SecurityTest(unittest.TestCase):
    ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    def test_only_op_runs_in_the_backends_session(self):
        """1Password authorizes the backend's session; nothing else may run in it."""
        import re
        for dirpath, _, files in os.walk(os.path.join(self.ROOT, "launcher")):
            for name in files:
                if not name.endswith(".py"):
                    continue
                src = open(os.path.join(dirpath, name)).read()
                for m in re.finditer(r"subprocess\.(run|Popen)\(", src):
                    call = src[m.start():src.find("\n\n", m.start())]
                    window = src[max(0, m.start() - 400):m.start()]
                    inside_op_run = "def op_run" in window or "def bw_run" in window
                    self.assertTrue("start_new_session=True" in call or inside_op_run,
                                    f"{name}: {call.splitlines()[0]}")

    def test_secret_never_in_argv(self):
        from unittest import mock
        from launcher import util
        calls = []
        with mock.patch.object(util, "spawn", lambda argv, **k: calls.append(argv)), \
                mock.patch.object(util, "run", lambda argv, **k: "hunter2"), \
                mock.patch("threading.Timer") as timer:
            util.clear_clipboard_after(30, "hunter2")
            timer.call_args[0][1]()          # fire the timer now
        import hashlib
        digest = hashlib.sha256(b"hunter2").hexdigest()
        self.assertEqual(calls, [["wl-copy", "--clear"]])
        self.assertFalse(any("hunter2" in a or digest in a for argv in calls for a in argv))

    def test_onepassword_items_are_not_recorded(self):
        from launcher.state import History
        with tempfile.TemporaryDirectory() as d:
            h = History(os.path.join(d, "h.json"))
            h.record({"id": "onepassword:abc", "title": "Bank", "_uid": "abc"})
            h.record({"id": "apps:foot", "title": "foot"})
            self.assertEqual(list(h.entries), ["apps:foot"])
            with open(os.path.join(d, "h.json")) as f:
                self.assertNotIn("Bank", f.read())


class _Ctx:
    def __init__(self):
        self.settings = Settings(os.devnull)
        self.current_seq = 0


if __name__ == "__main__":
    unittest.main()
