#!/usr/bin/env python3
"""
Remove consecutive duplicate lines from a transcription file.
Runs in a loop, removing one duplicate per pass, until TARGET_REMOVALS reached.
Safe for files being appended to concurrently.
"""
import time
import os
import sys

FILE = "/Users/victorrentea/workspace/victor-macos-addons/addons-output/2026-04-07-transcription.txt"
TARGET_REMOVALS = 999999

total_removed = 0
total_chars_removed = 0

while total_removed < TARGET_REMOVALS:
    try:
        with open(FILE, 'r', encoding='utf-8') as f:
            content = f.read()
    except FileNotFoundError:
        print(f"File not found: {FILE}", flush=True)
        time.sleep(2)
        continue

    lines = content.splitlines(keepends=True)

    # Find first consecutive duplicate
    dup_index = None
    for i in range(1, len(lines)):
        if lines[i] == lines[i - 1]:
            dup_index = i
            break

    if dup_index is None:
        print(f"\nNo more duplicates found. Done!", flush=True)
        break

    # Remove that one duplicate line, preserve any new content appended since we read
    cleaned_lines = lines[:dup_index] + lines[dup_index + 1:]
    cleaned = ''.join(cleaned_lines)

    try:
        with open(FILE, 'r+', encoding='utf-8') as f:
            current = f.read()
            # Anything appended after our snapshot
            new_tail = current[len(content):]
            f.seek(0)
            f.write(cleaned + new_tail)
            f.truncate()
    except Exception as e:
        print(f"Write error: {e}", flush=True)
        time.sleep(1)
        continue

    chars_removed = len(lines[dup_index])
    total_removed += 1
    total_chars_removed += chars_removed
    removed_line = lines[dup_index].rstrip()
    print(f"[{total_removed}] -{chars_removed}ch (total -{total_chars_removed}ch) | {removed_line!r}", flush=True)

print(f"\nDone! Removed {total_removed} duplicate lines, {total_chars_removed} characters total.", flush=True)
