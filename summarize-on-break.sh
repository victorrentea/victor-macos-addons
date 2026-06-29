#!/bin/bash
# summarize-on-break.sh
#
# Triggered by the ☕️ Break menu of "Victor Addons" whenever a break of >= 5
# minutes starts (see BreakSummaryLauncher.swift). While Victor is on break, an
# unattended `claude` instance advances the training-summary DELTA: it reads
# only the new transcript since the last watermark and appends the new
# section(s) to Discussion.md ONLY. This amortizes the expensive transcript read
# across the day so the wrap-up run is a tiny delta + a cheap distill.
#
# This window auto-closes when done (the osascript caller polls `busy`).

set -uo pipefail

CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
OUTPUT_DIR="/Users/victorrentea/workspace/victor-macos-addons/addons-output"
SESSIONS_DIR="/Users/victorrentea/My Drive/Cursuri/###sesiuni"
LOCK="/tmp/training-summarizer-break.lock"

# --- single-instance guard -------------------------------------------------
# Never run two summary deltas at once (they would race on Discussion.md).
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "⏳ A summary delta is already running (pid $(cat "$LOCK")). Skipping."
  sleep 2
  exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# --- "since when" banner (best-effort; claude does the authoritative detect) -
TX="$(ls -t "$OUTPUT_DIR"/*-transcription.txt 2>/dev/null | head -1)"
echo "════════════════════════════════════════════════════════════════"
echo "  ☕️  Training-summary delta — processing during the break"
echo "════════════════════════════════════════════════════════════════"
if [ -z "$TX" ]; then
  echo "  ⚠️  No *-transcription.txt found in $OUTPUT_DIR — nothing to do."
  sleep 3
  exit 0
fi
LINES="$(wc -l < "$TX" | tr -d ' ')"
DATE="$(basename "$TX" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')"
FOLDER="$(ls -dt "$SESSIONS_DIR"/*/ 2>/dev/null | grep -- "$DATE" | head -1)"
echo "  Transcript : $(basename "$TX")  ($LINES lines)"
if [ -n "$FOLDER" ] && [ -f "${FOLDER}Discussion.md" ]; then
  WM="$(grep -oE 'last_processed=[^ ]+' "${FOLDER}Discussion.md" 2>/dev/null | head -1 | cut -d= -f2)"
  if [ -n "$WM" ]; then
    echo "  Processing : everything AFTER $WM  (delta)"
  else
    echo "  Processing : whole transcript so far  (Discussion.md has no watermark yet)"
  fi
else
  echo "  Processing : fresh — first run today (Discussion.md not created yet)"
fi
echo "  Session    : ${FOLDER:-<auto-detect inside claude>}"
echo "════════════════════════════════════════════════════════════════"
echo

# --- run claude headless ---------------------------------------------------
# Heartbeat so the window doesn't look hung while claude reads the transcript.
( while true; do sleep 15; printf '  … still processing (%s)\n' "$(date +%H:%M:%S)"; done ) &
HEARTBEAT=$!
trap 'kill "$HEARTBEAT" 2>/dev/null; rm -f "$LOCK"' EXIT

PROMPT='Use the training-summarizer skill (victor-skills:training-summarizer) in HEADLESS BREAK-DELTA mode — an unattended run triggered by a coffee-break timer.

Do EXACTLY this and nothing else:
- Auto-detect the newest training transcription and its session folder (Step 0). If you cannot resolve them, print one line saying why and exit WITHOUT writing anything.
- Read ONLY the transcript after the Discussion.md last_processed watermark (or from the start if Discussion.md does not exist yet).
- Append the new first-level-synthesis section(s) to Discussion.md ONLY (with inline 🤖 / ❌ per the skill), and advance the Discussion.md watermark to the last section you actually wrote (so a closed/killed window never loses or skips unprocessed transcript — the next run re-reads the gap).
- Do NOT create or modify ai-summary.md (the participant brief) — it is built only at wrap-up from the complete Discussion.md.
- Do NOT run any Step 8 background streams: no link verification, no wiki builds (A/B), no image captions (D), no Obsidian, no relay listener.
- Never ask questions; this is unattended.
First print the [HH:MM]–[HH:MM] transcript range you are about to process, then do the work and stop.'

cd "$HOME" || true
# Use Victor's Claude subscription (Keychain OAuth), NOT the ANTHROPIC_API_KEY the
# shell exports from ~/.training-assistants-secrets.env — that key shadows the
# subscription and fails "Credit balance is too low". Unsetting it lets claude fall
# back to the logged-in account (verified 2026-06-29: unset → auth OK on opus).
env -u ANTHROPIC_API_KEY "$CLAUDE" -p "$PROMPT" --model opus --dangerously-skip-permissions
STATUS=$?

kill "$HEARTBEAT" 2>/dev/null
echo
if [ "$STATUS" -eq 0 ]; then
  echo "✅ done — Discussion.md is up to date through this break."
else
  echo "⚠️ claude exited with status $STATUS."
fi
sleep 2
exit 0
