"""Fuzzy matching: how well a query matches a title (and its keywords).

Scores run from 0 (no match) to about 1000. The order of preference is the
one people expect from a launcher: the whole title, then the start of the
title, then the start of a word ("fire" → "Zen Firefox"), then the initials
("vsc" → "Visual Studio Code"), then a substring, then the letters in order.
"""

from __future__ import annotations

import re
import unicodedata

_WORD_SPLIT = re.compile(r"[\s\-_./:·›()\[\]]+")


def fold(text: str) -> str:
    """Lower case without accents, so "café" matches "cafe"."""
    text = unicodedata.normalize("NFKD", str(text or ""))
    return "".join(c for c in text if not unicodedata.combining(c)).casefold()


def _words(text: str) -> list[str]:
    # Split camelCase too: "LocalSend" has the words "local" and "send".
    spaced = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", str(text or ""))
    return [w for w in _WORD_SPLIT.split(fold(spaced)) if w]


def score_text(query: str, text: str) -> int:
    """How well one query matches one string (0 = not at all)."""
    q = fold(query).strip()
    t = fold(text)
    if not q or not t:
        return 0
    if t == q:
        return 1000
    if t.startswith(q):
        return 900 - min(len(t) - len(q), 80)
    words = _words(text)
    for i, w in enumerate(words):
        if w.startswith(q):
            return 800 - min(i * 10, 60) - min(len(w) - len(q), 30)
    # Every query word starts a word of the text, in any order: "code vis".
    qwords = [w for w in q.split() if w]
    if len(qwords) > 1 and all(any(w.startswith(qw) for w in words) for qw in qwords):
        return 760
    initials = "".join(w[0] for w in words)
    if len(q) >= 2 and initials.startswith(q.replace(" ", "")):
        return 720
    pos = t.find(q)
    if pos >= 0:
        return 600 - min(pos * 4, 100)
    return _subsequence(q.replace(" ", ""), t)


def _subsequence(q: str, t: str) -> int:
    """Letters of q in order inside t; tighter runs score higher."""
    if len(q) < 2:
        return 0
    i = 0
    first = -1
    gaps = 0
    last = -1
    for j, c in enumerate(t):
        if i < len(q) and c == q[i]:
            if first < 0:
                first = j
            elif j != last + 1:
                gaps += j - last - 1
            last = j
            i += 1
    if i < len(q):
        return 0
    span_penalty = min(gaps * 6 + first * 2, 300)
    return max(1, 400 - span_penalty)


def score(query: str, title: str, keywords: str | list[str] = "", subtitle: str = "") -> int:
    """Best score over the title, keywords (a bit less) and subtitle (less still)."""
    best = score_text(query, title)
    if best >= 900:
        return best
    kws = keywords if isinstance(keywords, list) else [keywords] if keywords else []
    for kw in kws:
        s = score_text(query, kw)
        if s:
            best = max(best, s - 120)
    if subtitle:
        s = score_text(query, subtitle)
        if s >= 600:
            best = max(best, s - 300)
    return best
