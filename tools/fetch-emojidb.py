#!/usr/bin/env python3
"""Refresh tools/emojidb-keywords.json — what people actually type to find an emoji.

emojidb.org ranks, for any word, the emoji its users picked for it ("left" →
👈 ⬅️ ◀ 👉 …). That is the one thing CLDR and Apple's names lack: the crowd's
associations, not a committee's. It only answers word → emoji, so this asks it
about every word the catalogue already knows (Apple names + CLDR + emojilib,
~5500 words) and keeps, per word, the first TOP emoji the catalogue can draw.
`build-emoji-catalog.py` inverts that into extra keywords per emoji.

Separate from the build on purpose: it makes ~5500 requests (Cloudflare-cached,
~25 KB gzipped each, a few minutes at 6 in flight), so its result is committed
and the build reads the file. Rerun it rarely:  python3 tools/fetch-emojidb.py
"""
import concurrent.futures
import gzip
import json
import pathlib
import re
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources/VictorAddons/Resources/emoji-catalog.json"
OUT = ROOT / "tools/emojidb-keywords.json"
CACHE = pathlib.Path.home() / ".cache/emojidb"  # one file per word: an interrupted run resumes
EMOJILIB = "https://raw.githubusercontent.com/muan/emojilib/main/dist/emoji-en-US.json"
TOP = 10
STOP = {"the", "and", "with", "for", "from", "face", "button", "sign", "symbol", "mark", "emoji"}
EMOJI_DIV = re.compile(r'class="emoji"[^>]*>(.*?)</div>', re.S)


def key(e: str) -> str:
    return "".join(c for c in e if c != "️" and not 0x1F3FB <= ord(c) <= 0x1F3FF)


def words(text: str) -> set:
    return {w for w in re.split(r"[^a-z0-9]+", text.lower()) if len(w) >= 3 and w not in STOP}


def get(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept-Encoding": "gzip"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read()
                return (gzip.decompress(body) if r.headers.get("Content-Encoding") == "gzip" else body).decode("utf-8")
        except Exception:
            time.sleep(2 * (attempt + 1))
    return ""


def main() -> None:
    rows = json.loads(CATALOG.read_text())["emoji"]
    known = {key(r[0]) for r in rows}
    vocab = set()
    for r in rows:
        vocab |= words(r[2]) | words(r[4])
    with urllib.request.urlopen(EMOJILIB, timeout=60) as r:
        for tags in json.loads(r.read()).values():
            for tag in tags:
                vocab |= words(tag)
    vocab = sorted(vocab)
    print(f"{len(vocab)} words to ask emojidb")

    CACHE.mkdir(parents=True, exist_ok=True)

    def top(word: str):
        cached = CACHE / f"{word}.json"
        if cached.exists():
            return word, json.loads(cached.read_text())
        html = get(f"https://emojidb.org/{urllib.parse.quote(word)}-emojis")
        picked = []
        for raw in EMOJI_DIV.findall(html):
            k = key(raw.strip())
            if k in known and k not in picked:
                picked.append(k)
                if len(picked) == TOP:
                    break
        if html:
            cached.write_text(json.dumps(picked, ensure_ascii=False))
        return word, picked

    result = {}
    with concurrent.futures.ThreadPoolExecutor(6) as pool:
        for i, (word, picked) in enumerate(pool.map(top, vocab), 1):
            if picked:
                result[word] = picked
            if i % 250 == 0:
                print(f"  {i}/{len(vocab)}", flush=True)
    OUT.write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=0) + "\n")
    print(f"{len(result)} words with emoji -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
