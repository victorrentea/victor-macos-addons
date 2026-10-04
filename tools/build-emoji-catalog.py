#!/usr/bin/env python3
"""Regenerate Sources/VictorAddons/Resources/emoji-catalog.json for the ⌥⌥ (left Option double tap) picker.

Three sources, joined on the emoji with its FE0F selectors stripped:

- Unicode's emoji-test.txt   — the order and the groups (the order every picker uses)
- macOS CoreEmoji AppleName  — which emoji THIS Mac can draw, and Apple's own names, en + ro
- CLDR annotations           — the search keywords, en + ro ("piersică" finds 🍑)

AppleName is the filter on purpose: emoji-test.txt is always a release ahead of
the system font, and a cell that draws as a tofu box is worse than a missing one.
Skin-tone variants are left out — the grid shows the base, as Apple's does.

Run it after a macOS upgrade that adds emoji:  python3 tools/build-emoji-catalog.py
"""
import json
import pathlib
import plistlib
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources/VictorAddons/Resources/emoji-catalog.json"
CORE_EMOJI = pathlib.Path("/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources")
EMOJI_TEST = "https://unicode.org/Public/emoji/latest/emoji-test.txt"
CLDR = "https://raw.githubusercontent.com/unicode-org/cldr-json/main/cldr-json/cldr-annotations-full/annotations/{}/annotations.json"
SKIN_TONES = {chr(c) for c in range(0x1F3FB, 0x1F400)}


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


def main() -> None:
    names = {lang: apple_names(lang) for lang in ("en", "ro")}
    notes = {lang: cldr(lang) for lang in ("en", "ro")}

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

        def kw(lang):
            return " ".join(notes[lang].get(k, {}).get("default", []))

        rows.append([
            emoji,
            len(groups) - 1,
            names["en"][k],
            names["ro"].get(k, ""),
            kw("en"),
            kw("ro"),
        ])

    OUT.write_text(json.dumps({"groups": groups, "emoji": rows}, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(rows)} emoji in {len(groups)} groups -> {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
