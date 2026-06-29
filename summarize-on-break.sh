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
# human-readable byte size: "850 B" / "41.2 KB" / "1.3 MB"
hsize() { awk -v b="$1" 'BEGIN{ if(b<1024) printf "%d B",b; else if(b<1048576) printf "%.1f KB",b/1024; else printf "%.1f MB",b/1048576 }'; }

LINES="$(wc -l < "$TX" | tr -d ' ')"
BYTES="$(wc -c < "$TX" | tr -d ' ')"
DATE="$(basename "$TX" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')"
FOLDER="$(ls -dt "$SESSIONS_DIR"/*/ 2>/dev/null | grep -- "$DATE" | head -1)"
echo "  Transcript : $(basename "$TX")  ($LINES lines, $(hsize "$BYTES") total)"
if [ -n "$FOLDER" ] && [ -f "${FOLDER}Discussion.md" ]; then
  WM_TS="$(grep -oE 'last_processed=[^ ]+' "${FOLDER}Discussion.md" 2>/dev/null | head -1 | cut -d= -f2)"
  WM_LINES="$(grep -oE 'lines_through=[0-9]+' "${FOLDER}Discussion.md" 2>/dev/null | head -1 | cut -d= -f2)"
  if [ -n "$WM_LINES" ] && [ "$WM_LINES" -gt 0 ] 2>/dev/null; then
    DELTA_LINES=$(( LINES - WM_LINES ))
    DELTA_BYTES="$(tail -n +$((WM_LINES + 1)) "$TX" | wc -c | tr -d ' ')"
    if [ "$DELTA_LINES" -le 0 ]; then
      echo "  Processing : NOTHING NEW — watermark ($WM_LINES) is already at/after the last line ($LINES)"
    else
      echo "  Processing : $DELTA_LINES new lines ($(hsize "$DELTA_BYTES")) — lines $((WM_LINES + 1))–$LINES, everything AFTER ${WM_TS:-the watermark}  (delta)"
    fi
  elif [ -n "$WM_TS" ]; then
    echo "  Processing : everything AFTER $WM_TS  (delta; watermark has no line count, size unknown)"
  else
    echo "  Processing : whole transcript — $LINES lines, $(hsize "$BYTES")  (Discussion.md has no watermark yet)"
  fi
else
  echo "  Processing : ALL $LINES lines ($(hsize "$BYTES")) — fresh, first run today"
fi
echo "  Session    : ${FOLDER:-<auto-detect inside claude>}"
echo "════════════════════════════════════════════════════════════════"
echo

# --- run claude headless ---------------------------------------------------
# Heartbeat so the window doesn't look hung while claude reads the transcript.
( while true; do sleep 15; printf '  … still processing (%s)\n' "$(date +%H:%M:%S)"; done ) &
HEARTBEAT=$!
trap 'kill "$HEARTBEAT" 2>/dev/null; rm -f "$LOCK"' EXIT

PROMPT="Use the training-summarizer skill (victor-skills:training-summarizer) in HEADLESS BREAK-DELTA mode — an unattended run triggered by a coffee-break timer.

Do EXACTLY this and nothing else:
- Auto-detect the newest training transcription and its session folder (Step 0). If you cannot resolve them, print one line saying why and exit WITHOUT writing anything.
- Read ONLY the transcript after the Discussion.md last_processed watermark (or from the start if Discussion.md does not exist yet).
- Append the new first-level-synthesis section(s) to Discussion.md ONLY (with inline 🤖 / ❌ per the skill).
- WATERMARK ANCHORED TO THE START OF THIS RUN: the transcript had exactly ${LINES} lines when this run started. When you set the Discussion.md watermark, lines_through MUST be <= ${LINES}, AND no further than the last section you actually committed. Any line beyond ${LINES} landed DURING this (possibly multi-minute) run — e.g. break-time chats spoken during the break — and MUST be left for the next run. Do NOT re-count the file at the end. This way break-time chatter and a closed/killed window are never lost or skipped; the next run re-reads from the watermark.
- Do NOT create or modify ai-summary.md (the participant brief) — it is built only at wrap-up from the complete Discussion.md.
- Do NOT run any Step 8 background streams: no link verification, no wiki builds (A/B), no image captions (D), no Obsidian, no relay listener.
- Never ask questions; this is unattended.
First print the [HH:MM]–[HH:MM] transcript range you are about to process, then do the work and stop."

cd "$HOME" || true
# Use Victor's Claude subscription (Keychain OAuth), NOT the ANTHROPIC_API_KEY the
# shell exports from ~/.training-assistants-secrets.env — that key shadows the
# subscription and fails "Credit balance is too low". Unsetting it lets claude fall
# back to the logged-in account (verified 2026-06-29: unset → auth OK on opus).
# --strict-mcp-config + empty config: break-delta only reads the transcript and
# writes Discussion.md, so skip loading the claude.ai connectors (serena,
# codegraph, playwright, …) — they're pure startup overhead + context bloat here.
env -u ANTHROPIC_API_KEY "$CLAUDE" -p "$PROMPT" --model opus --dangerously-skip-permissions \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}'
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
