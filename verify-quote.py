#!/usr/bin/env python3
"""verify-quote.py — "is this sentence ACTUALLY on that page?", answered by grep.

The adversarial half of the 🔬 Research Proof run. A researcher agent comes back
with (claim, url, quote); the tempting design is to hand all three to a second
model and ask "did it lie?". That second model reads the same page through the
same lens and agrees far too often — and worse, it can *hallucinate the
confirmation*, which is the one failure the whole feature exists to prevent.

So the existence check is not a model at all. It is: fetch the URL, strip it to
text, normalise, and look for the words. Deterministic, unhallucinatable, and
it costs a second. The model is left with the ONLY question it is actually
better at than a substring search — *does this quote support the claim?* — and
it answers that knowing the quote is real.

Normalisation is deliberately aggressive (case, punctuation, curly quotes,
whitespace, NFKC) because a real quote and a page differ in exactly those ways
after a copy-paste through a model, and none of those differences make it a
different sentence. What it will NOT forgive is different *words*.

Output is one JSON object on stdout, always — a crash is a verdict too:

    {"check": "found|approx|absent|thin|unreachable",
     "coverage": 0.0-1.0,       # longest run of the quote's words found, as a fraction
     "matched_words": int, "total_words": int,
     "longest_match": "...",    # what WAS found, so the report can show the drift
     "http": 200, "title": "...", "page_words": int, "url": "..."}

    found      the whole quote is there (modulo punctuation/case)
    approx     >= 90% of it is contiguously there — a trimmed or lightly edited quote
    absent     the page loaded fine and does not say this
    thin       the page loaded but carries almost no text (JS-rendered, paywall)
    unreachable  404 / 403 / timeout / not text — verification impossible, NOT a lie

`thin` and `unreachable` exist so the report can distinguish "the source does
not say this" from "I could not check", which are opposite conclusions that a
boolean would have collapsed into one.

Usage:  verify-quote.py <url> <quote>
"""

import json
import re
import sys
import unicodedata
import urllib.error
import urllib.request
from html.parser import HTMLParser

TIMEOUT = 20
MAX_BYTES = 3_000_000
# A default urllib UA is 403'd by a good share of doc sites and every CDN with a
# bot rule; being refused is not evidence about the quote, so we look like a browser.
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0 Safari/537.36")
# Under this many words a page is not "silent about the quote", it is a shell we
# failed to render (SPA, cookie wall, paywall) — a different verdict entirely.
THIN_WORDS = 60
APPROX_COVERAGE = 0.90


class Text(HTMLParser):
    """Tags out, text in. `script`/`style`/`noscript` bodies are code, not prose —
    left in, a JSON blob in a <script> can 'contain' a quote the reader never sees."""

    SKIP = {"script", "style", "noscript", "svg", "head"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip_depth = 0
        self.title_next = False
        self.title = ""

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip_depth += 1
        if tag == "title":
            self.title_next = True

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skip_depth:
            self.skip_depth -= 1
        if tag == "title":
            self.title_next = False

    def handle_data(self, data):
        if self.title_next and not self.title:
            self.title = data.strip()
        if not self.skip_depth:
            self.parts.append(data)

    def text(self):
        return " ".join(self.parts)


def normalise(s: str) -> str:
    """Everything that a copy-paste can change, flattened; the words themselves, kept.

    NFKC folds the typographic look-alikes (ﬁ, non-breaking space, full-width
    latin); the manual map covers the ones NFKC deliberately keeps distinct —
    curly quotes and dashes, which is precisely what a model rewrites when it
    quotes. Then anything that is not a letter or a digit becomes a space, so
    punctuation, markup leftovers and line wrapping stop mattering.
    """
    s = unicodedata.normalize("NFKC", s)
    for a, b in (("‘", "'"), ("’", "'"), ("“", '"'), ("”", '"'),
                 ("–", "-"), ("—", "-"), ("…", "...")):
        s = s.replace(a, b)
    s = s.lower()
    s = "".join(ch if (ch.isalnum()) else " " for ch in s)
    return re.sub(r"\s+", " ", s).strip()


def longest_run(quote_words, page: str):
    """The longest CONTIGUOUS stretch of the quote that appears on the page.

    Contiguous, not bag-of-words: "X is faster than Y" and "Y is faster than X"
    share every word and mean opposite things, and a fact-check that cannot tell
    them apart is worse than none. Searching longest-first means the first hit is
    the answer, so the common case (a real quote) costs one substring search.
    """
    n = len(quote_words)
    for length in range(n, 0, -1):
        for start in range(0, n - length + 1):
            phrase = " ".join(quote_words[start:start + length])
            if phrase and phrase in page:
                return length, phrase
    return 0, ""


def fetch(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept-Language": "en,ro;q=0.8"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        ctype = (resp.headers.get("Content-Type") or "").lower()
        raw = resp.read(MAX_BYTES)
        charset = resp.headers.get_content_charset() or "utf-8"
        return resp.status, ctype, raw.decode(charset, errors="replace")


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"check": "unreachable", "error": "usage: verify-quote.py <url> <quote>"}))
        return 2

    url, quote = sys.argv[1], " ".join(sys.argv[2:])
    out = {"url": url, "check": "unreachable", "coverage": 0.0,
           "matched_words": 0, "total_words": 0, "longest_match": "",
           "http": 0, "title": "", "page_words": 0}

    try:
        status, ctype, body = fetch(url)
    except urllib.error.HTTPError as e:
        out["http"] = e.code
        out["error"] = f"HTTP {e.code}"
        print(json.dumps(out, ensure_ascii=False))
        return 2
    except Exception as e:                      # timeout, DNS, TLS, decode
        out["error"] = f"{type(e).__name__}: {e}"
        print(json.dumps(out, ensure_ascii=False))
        return 2

    out["http"] = status
    # A PDF or an image is not "absent" — it is unchecked. Saying so is the point.
    if "html" in ctype:
        p = Text()
        p.feed(body)
        text, out["title"] = p.text(), p.title
    elif "text/" in ctype or "json" in ctype:
        text = body
    else:
        out["error"] = f"unsupported content-type: {ctype or 'unknown'}"
        print(json.dumps(out, ensure_ascii=False))
        return 2

    page = normalise(text)
    out["page_words"] = len(page.split())

    q_words = normalise(quote).split()
    out["total_words"] = len(q_words)
    if not q_words:
        out["error"] = "empty quote"
        print(json.dumps(out, ensure_ascii=False))
        return 2

    matched, phrase = longest_run(q_words, page)
    out["matched_words"] = matched
    out["longest_match"] = phrase
    out["coverage"] = round(matched / len(q_words), 3)

    # The match is decided BEFORE the thinness check: a genuinely short page that
    # does carry the sentence has proved the quote, and calling that "could not
    # check" would throw away the one answer we came for. Thinness only explains
    # a MISS — that is the case where it changes the verdict.
    if matched == len(q_words):
        out["check"] = "found"
        rc = 0
    elif out["coverage"] >= APPROX_COVERAGE:
        out["check"] = "approx"
        rc = 0
    elif out["page_words"] < THIN_WORDS:
        out["check"] = "thin"
        rc = 3
    else:
        out["check"] = "absent"
        rc = 1

    print(json.dumps(out, ensure_ascii=False))
    return rc


if __name__ == "__main__":
    sys.exit(main())
