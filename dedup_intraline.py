#!/usr/bin/env python3
"""
Remove lines where the content itself is a hallucination loop:
a short phrase repeated many times within a single line.
Detection: split into words, if unique word types <= 4 and total words > 20
and top word covers > 50% of all words → hallucination.
"""
import re

FILE = "/Users/victorrentea/workspace/victor-macos-addons/addons-output/2026-04-07-transcription.txt"

LINE_RE = re.compile(r'^\[\d+:\d+\] .+?: (.+)$')

def is_hallucination(line: str) -> bool:
    m = LINE_RE.match(line.rstrip())
    if not m:
        return False
    content = m.group(1)

    # Character-level repetition (e.g. อออออออ, aaaaaaa)
    if len(content) > 20:
        from collections import Counter
        char_counts = Counter(content)
        top_char, top_count = char_counts.most_common(1)[0]
        if top_char != ' ' and top_count / len(content) > 0.7:
            return True

    # Word-level repetition (e.g. "Right there. Right there. ...")
    words = content.split()
    if len(words) < 20:
        return False
    unique = set(w.lower().strip('.,!?') for w in words)
    if len(unique) > 4:
        return False
    from collections import Counter
    counts = Counter(w.lower().strip('.,!?') for w in words)
    top_freq = counts.most_common(1)[0][1]
    if top_freq / len(words) > 0.5:
        return True
    return False

with open(FILE, 'r', encoding='utf-8') as f:
    lines = f.readlines()

kept = []
removed = 0
total_chars = 0
for line in lines:
    if is_hallucination(line):
        removed += 1
        total_chars += len(line)
        print(f"[{removed}] -{len(line)}ch | {line.rstrip()[:120]!r}", flush=True)
    else:
        kept.append(line)

# Write back preserving any tail appended concurrently
with open(FILE, 'r+', encoding='utf-8') as f:
    original = ''.join(lines)
    current = f.read()
    new_tail = current[len(original):]
    f.seek(0)
    f.write(''.join(kept) + new_tail)
    f.truncate()

print(f"\nDone! Removed {removed} hallucination lines, {total_chars} characters.", flush=True)
