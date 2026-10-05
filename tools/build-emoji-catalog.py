#!/usr/bin/env python3
"""Regenerate Sources/VictorAddons/Resources/emoji-catalog.json for the ⌥⌥ (left Option double tap) picker.

Sources, joined on the emoji with its FE0F selectors stripped:

- Unicode's emoji-test.txt   — the order and the groups (the order every picker uses)
- macOS CoreEmoji AppleName  — which emoji THIS Mac can draw, and Apple's own names, en + ro
- CLDR annotations           — the search keywords, en + ro ("piersică" finds 🍑)
- extra synonyms, en only, ranked below the three above (the 7th column):
  emojilib (muan/emojilib, community tags: 👍 "approve", "agree", "+1"),
  emojibase (tags + the GitHub / Slack / JoyPixels shortcodes people already type),
  emojidb.org (the crowd's word → emoji votes, cached in tools/emojidb-keywords.json
  by tools/fetch-emojidb.py — "left" also finds 👈)

AppleName is the filter on purpose: emoji-test.txt is always a release ahead of
the system font, and a cell that draws as a tofu box is worse than a missing one.
Skin-tone variants are left out — the grid shows the base, as Apple's does.

Then the symbols that are **not** emoji — €, ₠, ℃, ⌘, ★, ∈, ① — the ones the
Mac's own picker finds for "eur" and ours did not (Victor, 2026-10-05). The set is
Apple's Character Viewer default categories (CharacterPalette.app, read from this
Mac) minus the blocks nobody types (APL, bracket pieces, control pictures, math
alphanumerics, mahjong/cards, Byzantine music) and minus ASCII. Each is labelled
by its Unicode name + CLDR en/ro, plus tools/symbol-labels.json: a friendly en/ro
name and search words written by research agents for the ~70% CLDR leaves bare.
A symbol missing from that file still ships, under its Unicode name.

Run it after a macOS upgrade that adds emoji:  python3 tools/build-emoji-catalog.py
"""
import json
import pathlib
import unicodedata
import plistlib
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/VictorAddons/Resources/emoji-catalog.json"
CORE_EMOJI = pathlib.Path("/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources")
EMOJI_TEST = "https://unicode.org/Public/emoji/latest/emoji-test.txt"
CLDR = "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-annotations-full/annotations/{}/annotations.json"
EMOJILIB = "https://raw.githubusercontent.com/muan/emojilib/main/dist/emoji-en-US.json"
EMOJIBASE = "https://cdn.jsdelivr.net/npm/emojibase-data@latest/en/{}.json"
EMOJIDB = ROOT / "tools/emojidb-keywords.json"
SKIN_TONES = {chr(c) for c in range(0x1F3FB, 0x1F400)}
PALETTE = pathlib.Path("/System/Library/Input Methods/CharacterPalette.app/Contents/Resources")
SYMBOL_LABELS = ROOT / "tools/symbol-labels.json"
# Character Viewer's default Symbols categories, and per category the code point
# ranges left out (DROP) or the only ones kept (KEEP).
SYMBOL_CATEGORIES = [
    "CurrencySymbols", "LetterlikeSymbols", "Punctuation", "Parentheses", "SignStandardSymbols",
    "Bullets", "TechnicalSymbols", "MathematicalSymbols", "Arrows", "Pictographs", "Digits",
    "MusicalSymbols", "GeometricalShapes", "EnclosedCharacters",
]
DROP = {
    "Parentheses": [(0x239B, 0x23B3)],                                   # bracket pieces
    "Bullets": [(0x1F7A1, 0x1F7D4)],                                     # geometric shapes extended
    # APL, bracket and integral pieces, dentistry, electrical, control pictures, OCR, box drawing
    "TechnicalSymbols": [(0x2320, 0x2321), (0x2336, 0x237A), (0x2395, 0x2395), (0x239B, 0x23B3), (0x23B7, 0x23BD),
                         (0x23C0, 0x23CC), (0x23DA, 0x23E7), (0x2400, 0x2426), (0x2440, 0x244A),
                         (0x2500, 0x257F)],
    "MathematicalSymbols": [(0x2A00, 0x2AFF), (0x27C0, 0x27EF), (0x2980, 0x29FF), (0x1D400, 0x1D7FF), (0x2320, 0x23FF)],
    "Arrows": [(0x2900, 0x297F), (0x1F800, 0x1F8FF)],
    "Pictographs": [(0x1F000, 0x1F0FF)],                                 # mahjong, dominoes, cards
    "MusicalSymbols": [(0x1D000, 0x1D2FF)],                              # Byzantine / Western musical
}
KEEP = {"GeometricalShapes": [(0x25A0, 0x25FF)], "EnclosedCharacters": [(0x2460, 0x24FF), (0x2776, 0x2793)]}


def key(e: str) -> str:
    return e.replace("️", "")


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def apple_names(lang: str) -> dict:
    raw = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(CORE_EMOJI / f"{lang}.lproj/AppleName.strings")],
        check=True, capture_output=True,
    ).stdout
    return {key(k): v for k, v in json.loads(raw).items()}


def cldr(lang: str) -> dict:
    data = json.loads(fetch(CLDR.format(lang)))["annotations"]["annotations"]
    return {key(k): v for k, v in data.items()}


def extras() -> dict:
    """emoji key -> extra English synonyms, from everything that is not Apple or CLDR."""
    out: dict = {}

    def add(emoji: str, text: str) -> None:
        out.setdefault(key(emoji), []).append(text.replace("_", " ").replace("-", " "))

    for emoji, tags in json.loads(fetch(EMOJILIB)).items():
        for tag in tags:
            add(emoji, tag)
    hex_to_emoji = {}
    for row in json.loads(fetch(EMOJIBASE.format("data"))):
        hex_to_emoji[row["hexcode"]] = row["emoji"]
        for tag in row.get("tags", []):
            add(row["emoji"], tag)
    for source in ("shortcodes/github", "shortcodes/iamcal", "shortcodes/joypixels", "shortcodes/emojibase"):
        for hexcode, codes in json.loads(fetch(EMOJIBASE.format(source))).items():
            if hexcode in hex_to_emoji:
                for code in [codes] if isinstance(codes, str) else codes:
                    add(hex_to_emoji[hexcode], code)
    if EMOJIDB.exists():
        # emojidb answers every word, and for a rare one it pads the list with
        # whatever is popular (👍 for "hippopotamus", ✨ for 1223 words). So the
        # further down the list, the rarer an emoji must be to count: its first
        # pick always, ranks 2-3 unless it is everywhere, 4-6 only if it is niche.
        votes = json.loads(EMOJIDB.read_text())
        spread = {}
        for emoji in votes.values():
            for e in emoji:
                spread[e] = spread.get(e, 0) + 1
        for word, emoji in votes.items():
            for rank, e in enumerate(emoji):
                if rank == 0 or (rank < 3 and spread[e] <= 150) or (rank < 6 and spread[e] <= 40):
                    add(e, word)
    return out


def symbols(have: set, notes: dict) -> list:
    """(symbol, en name, ro name, en keywords, ro keywords) for every useful non-emoji symbol."""
    labels = json.loads(SYMBOL_LABELS.read_text()) if SYMBOL_LABELS.exists() else {}

    def chars(category: str) -> list:
        data = plistlib.loads((PALETTE / f"Category-{category}.plist").read_bytes())["CVCategoryData"]
        lists = [data["Data"]] if "Data" in data else [section["Data"] for section in data["DataArray"]]
        return [chr(int(t, 16)) if t.startswith("0x") and len(t) > 2 else t
                for text in lists for t in text.split(",") if t]

    def within(ch: str, ranges: list) -> bool:
        return any(a <= ord(ch[0]) <= b for a, b in ranges)

    out, seen = [], set(have)
    for category in SYMBOL_CATEGORIES:
        for ch in chars(category):
            ch = key(ch).replace("\ufe0e", "")
            if len(ch) != 1 or ord(ch) < 0x80 or ch == "\u00ad" or ch in seen:
                continue
            if within(ch, DROP.get(category, [])) or (category in KEEP and not within(ch, KEEP[category])):
                continue
            seen.add(ch)
            uname = unicodedata.name(ch, "").lower()
            label = labels.get(ch, {})
            cldr_en, cldr_ro = notes["en"].get(ch, {}), notes["ro"].get(ch, {})
            out.append((
                ch,
                label.get("en") or " ".join(cldr_en.get("tts", [])) or uname,
                label.get("ro") or " ".join(cldr_ro.get("tts", [])),
                " ".join(cldr_en.get("default", []) + [label.get("en_kw", ""), uname]),
                " ".join(cldr_ro.get("default", []) + [label.get("ro_kw", "")]),
            ))
    return out


def main() -> None:
    names = {lang: apple_names(lang) for lang in ("en", "ro")}
    notes = {lang: cldr(lang) for lang in ("en", "ro")}
    more = extras()

    groups: list[str] = []
    rows = []
    seen = set()
    group = None
    for line in fetch(EMOJI_TEST).decode("utf-8").splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if not line or line.startswith("#") or "; fully-qualified" not in line:
            continue
        if group == "Component":
            continue
        codes = line.split(";", 1)[0].split()
        emoji = "".join(chr(int(c, 16)) for c in codes)
        k = key(emoji)
        if k in seen or SKIN_TONES & set(emoji) or k not in names["en"]:
            continue
        seen.add(k)
        if not groups or groups[-1] != group:
            groups.append(group)

        def extra(k, already):
            """The synonyms not already among the name and CLDR keywords, each word once."""
            seen_words = set(already.lower().split())
            kept = []
            for text in more.get(k, []):
                for w in text.lower().split():
                    if w not in seen_words:
                        seen_words.add(w)
                        kept.append(w)
            return " ".join(kept)

        def kw(lang):
            return " ".join(notes[lang].get(k, {}).get("default", []))

        rows.append([
            emoji,
            len(groups) - 1,
            names["en"][k],
            names["ro"].get(k, ""),
            kw("en"),
            kw("ro"),
            extra(k, names["en"][k] + " " + kw("en")),
        ])

    symbol_group = groups.index("Symbols")
    found = symbols(seen, notes)
    rows += [[ch, symbol_group, en, ro, kw_en, kw_ro, ""] for ch, en, ro, kw_en, kw_ro in found]

    OUT.write_text(json.dumps({"groups": groups, "emoji": rows}, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(rows) - len(found)} emoji + {len(found)} symbols in {len(groups)} groups -> {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
