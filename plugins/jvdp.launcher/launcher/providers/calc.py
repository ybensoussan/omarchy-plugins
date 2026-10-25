"""Calculator: sums, units, currencies, dates and time zones.

Uses qalc (libqalculate) when installed: `5 ft to cm`, `100 usd to eur`,
`today + 3 weeks`, `days until 2026-12-25`, `15:00 Tokyo to Amsterdam`.
Without it, plain arithmetic still works through a safe evaluator.
"""

from __future__ import annotations

import ast
import math
import operator
import re
import subprocess
import time

from . import Provider, action, close, item, toast
from .. import util

_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv,
        ast.FloorDiv: operator.floordiv, ast.Mod: operator.mod, ast.Pow: operator.pow,
        ast.USub: operator.neg, ast.UAdd: operator.pos}
_NAMES = {k: getattr(math, k) for k in ("pi", "e", "tau", "sqrt", "sin", "cos", "tan", "asin", "acos", "atan",
                                         "log", "log10", "log2", "exp", "floor", "ceil", "factorial")}
_NAMES.update({"abs": abs, "round": round, "ln": math.log})

LOOKS_LIKE_MATH = re.compile(r"\d")
WORDY = re.compile(r"^[a-zA-Z\s]+$")
DATE = re.compile(r"\d{4}-\d{1,2}-\d{1,2}|\d{1,2}:\d{2}")


def safe_eval(expr: str):
    """Arithmetic only: numbers, + - * / // % ^ **, parentheses and math functions."""
    expr = expr.replace("^", "**").replace("×", "*").replace("÷", "/").replace(",", ".")
    expr = re.sub(r"(\d+(?:\.\d+)?)\s*%", r"(\1/100)", expr)
    tree = ast.parse(expr, mode="eval")

    def ev(node):
        if isinstance(node, ast.Expression):
            return ev(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
            left, right = ev(node.left), ev(node.right)
            if isinstance(node.op, ast.Pow) and abs(right) > 1000:
                raise ValueError("exponent too large")
            return _OPS[type(node.op)](left, right)
        if isinstance(node, ast.UnaryOp) and type(node.op) in _OPS:
            return _OPS[type(node.op)](ev(node.operand))
        if isinstance(node, ast.Name) and node.id in _NAMES and not callable(_NAMES[node.id]):
            return _NAMES[node.id]
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and callable(_NAMES.get(node.func.id)) \
                and not node.keywords and len(node.args) <= 2:
            args = [ev(a) for a in node.args]
            if node.func.id == "factorial" and (args[0] > 500 or args[0] != int(args[0])):
                raise ValueError("factorial too large")
            return _NAMES[node.func.id](*args)
        raise ValueError("not arithmetic")

    return ev(tree)


def format_number(value) -> str:
    if isinstance(value, bool):
        raise ValueError
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            raise ValueError
        if value == int(value) and abs(value) < 1e15:
            return str(int(value))
        return f"{value:.10g}"
    raise ValueError


class Calculator(Provider):
    id = "calc"
    name = "Calculator"
    prefix = "="
    slow = True
    description = "Sums, units, currencies, dates; qalc when installed"

    def __init__(self, ctx):
        super().__init__(ctx)
        self._rates_checked = 0.0

    def search(self, q, scoped):
        q = q.strip()
        if not q or (not scoped and (not LOOKS_LIKE_MATH.search(q) or WORDY.match(q))):
            return []
        if not scoped and re.fullmatch(r"[\d\s.,]+", q):
            return []   # a bare number is not a calculation
        result = None
        if not DATE.search(q):  # 2026-12-25 is a date, not a subtraction
            try:
                result = format_number(safe_eval(q))
            except Exception:
                result = None
        if result is None and util.have("qalc"):
            result = self._qalc(q)
        if result is None or result == q:
            return []
        return [item("calc", "result", result, subtitle=f"{q} =", icon="󰃬", accessory="Calculator",
                     recordable=False, score=990, _expr=q)]

    def _qalc(self, q: str) -> str | None:
        argv = ["qalc", "-t", "-m", "800"]
        if self.settings.get("calculator.currency") and time.time() - self._rates_checked > 86400:
            # -e: fetch fresh exchange rates (once a day; qalc caches them).
            argv.append("-e")
            self._rates_checked = time.time()
        try:
            out = subprocess.run(argv + [q], capture_output=True, text=True, timeout=6 if "-e" in argv else 2.5, start_new_session=True)
        except (OSError, subprocess.SubprocessError):
            return None
        text = out.stdout.strip().splitlines()
        if out.returncode != 0 or not text:
            return None
        res = text[-1].strip()
        if not res or res.lower().startswith(("error", "warning")) or res == q:
            return None
        # qalc echoes plain words back unchanged ("hello" → "hello").
        if re.fullmatch(r"[a-zA-Z ]+", res) and res.replace(" ", "").lower() == q.replace(" ", "").lower():
            return None
        return res

    def actions(self, it):
        return [action("default", "Copy result", "󰆏"),
                action("paste", "Paste result", "󰆒", "ctrl+enter"),
                action("copy-sum", "Copy sum and result", "󰆏", "ctrl+shift+c")]

    def run(self, it, aid, arg):
        if aid == "paste":
            util.paste(it["title"])
            return [close()]
        if aid == "copy-sum":
            util.copy(f"{it['_expr']} = {it['title']}")
        else:
            util.copy(it["title"])
        return [toast("Copied " + it["title"]), close()]
