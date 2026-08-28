#!/usr/bin/env python3
"""Read the day's speaker verdicts as a labelled transcript.

The verdicts do not go into the transcript, and that is deliberate — labels
lived there once and were removed on 2026-08-14 for being wrong too often, so
the way back in is to be provable first. But "provable" and "invisible" are not
the same thing, and a dark launch nobody can watch is one nobody will check.

So: the same lines, side by side with what the classifier thinks, in a file it
cannot write to.

    python3 tools/watch-speakers.py        # today, once
    python3 tools/watch-speakers.py -f     # follow, like tail -f
    python3 tools/watch-speakers.py 2026-08-27
"""
import json
import sys
import time
from datetime import datetime
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "addons-output"

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
GREEN, YELLOW, GREY = "\033[32m", "\033[33m", "\033[90m"

# A segment that could not be cut finer prints its span as a dash rather than
# as 0.0-12.0: the absence of offsets is information, and inventing a plausible
# looking span would hide exactly the case worth noticing.
def _span(row):
    if "start" not in row:
        return "  —  "
    return f"{row['start']:>4.1f}s"


def render(row) -> str:
    label, score = row.get("label"), row.get("score")
    if label == "Victor":
        who, colour = "🎙️  Victor  ", GREEN
    elif label == "Audience":
        who, colour = "👥  Audience", YELLOW
    else:
        who, colour = "·   —       ", GREY
    s = f"{score:+.2f}" if isinstance(score, (int, float)) else "  · "
    return (f"{DIM}{row['t']}{RESET} {DIM}{_span(row)}{RESET} "
            f"{colour}{who}{RESET} {DIM}{s}{RESET}  {colour}{row['text']}{RESET}")


def main():
    args = [a for a in sys.argv[1:]]
    follow = "-f" in args or "--follow" in args
    days = [a for a in args if not a.startswith("-")]
    day = days[0] if days else datetime.now().strftime("%Y-%m-%d")
    path = OUT / f"{day}-speakers.jsonl"

    print(f"{BOLD}{path.name}{RESET}  "
          f"{GREEN}Victor{RESET} / {YELLOW}Audience{RESET} / {GREY}abstained{RESET}"
          f"{'  (following)' if follow else ''}\n")

    seen = 0
    while True:
        if path.exists():
            lines = path.read_text(encoding="utf-8").splitlines()
            for line in lines[seen:]:
                if not line.strip():
                    continue
                try:
                    print(render(json.loads(line)))
                except Exception:  # a half-written last line, mid-append
                    continue
            seen = len(lines)
        if not follow:
            if not path.exists():
                print(f"{GREY}nothing yet — whisper writes this only when somebody talks{RESET}")
            return
        time.sleep(1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
