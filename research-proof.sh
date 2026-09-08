#!/bin/bash
# research-proof.sh
#
# 🔬 "Fact-check the last 10 minutes" — fired from the menu bar (see
# ResearchProofLauncher.swift) or headlessly via GET /test/research-proof.
#
# Pipeline, in one sentence: wait for whisper to catch up, cut the last 10
# minutes of speech out of today's transcript, let claude pull the *checkable*
# claims out of it, fan out one researcher per claim, prove every quote with a
# substring search rather than a second opinion, and render the verdicts into a
# fixed HTML template the room can read off the projector.
#
# Three decisions are load-bearing and are NOT free to change casually:
#
#  1. The wait (settle) happens HERE, visibly, before anything else. Whisper
#     writes a line 6–15 s after the words were spoken (12 s chunks, 2 s
#     overlap, early flush on silence), so the sentence that made Victor reach
#     for the menu is the one sentence not yet in the file. See
#     TranscriptSettlePolicy.swift — these constants mirror it.
#  2. The quote check is `verify-quote.py`, a normalised substring search. A
#     second model asked "did the first one lie?" agrees with it, and can
#     hallucinate the confirmation. grep cannot.
#  3. claude writes JSON, never HTML. The page shape is fixed in
#     research-proof-template.html so a report shown to a room looks the same
#     every single time.
#
# Args: $1 = sentinel path (ok|fail, launcher waits on it)
#       $2 = report HTML path (the launcher polls for THIS file and opens it)

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
OUTPUT_DIR="$HERE/addons-output"
TEMPLATE="$HERE/research-proof-template.html"
VERIFY="$HERE/verify-quote.py"
LOCK="/tmp/research-proof.lock"
SENTINEL="${1:-}"
REPORT="${2:-$OUTPUT_DIR/research-proof-$(date +%F-%H%M%S).html}"
VERDICT="fail"

WINDOW_MINUTES=10          # Victor's call: 10 min is "the topic we are on", not "the sentence I just said"
MAX_CLAIMS=8               # past this a projected page stops being readable and the run stops being minutes
MIN_WORDS=40               # under this the window is a pause, not a discussion

RUN_DIR="$(mktemp -d /tmp/research-proof-XXXXXX)"
WINDOW_FILE="$RUN_DIR/window.txt"
JSON_FILE="$RUN_DIR/report.json"

mkdir -p "$OUTPUT_DIR"
LOG="$OUTPUT_DIR/research-proof-$(date +%F).log"
exec > >(tee -a "$LOG") 2>&1
echo
echo "########## $(date '+%F %T')  research-proof run (pid $$, report=$REPORT) ##########"

finish() { [ -n "$SENTINEL" ] && printf '%s' "$VERDICT" > "$SENTINEL"; }

# A report is ALWAYS produced, including for failures: the launcher opens the
# file the moment it appears and puts it on the projected screen, so a run that
# dies silently would leave Victor staring at a menu that did nothing.
render() {  # render <json-file>
  python3 - "$TEMPLATE" "$1" "$REPORT" <<'PY'
import json, pathlib, sys
tpl, data, out = (pathlib.Path(p) for p in sys.argv[1:4])
payload = json.loads(data.read_text())          # parse first: never ship broken JSON into the page
# </script> inside a quote would close the data island and turn the rest of the
# report into markup; the JSON spec lets us escape the slash, so we do.
text = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
out.write_text(tpl.read_text().replace("__DATA__", text))
print(f"  report -> {out}")
PY
}

bail() {  # bail <verdict-for-sentinel> <headline>
  python3 - "$JSON_FILE" "$2" <<'PY'
import json, pathlib, sys, time
pathlib.Path(sys.argv[1]).write_text(json.dumps(
    {"generated": time.strftime("%H:%M"), "window": "—",
     "claims": [], "skipped": [sys.argv[2]]}, ensure_ascii=False))
PY
  render "$JSON_FILE" || true
  VERDICT="$1"
}

# --- single-instance guard -------------------------------------------------
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "⏳ A research-proof run is already going (pid $(cat "$LOCK")). Skipping."
  VERDICT="ok"; finish; sleep 2; exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"; rm -rf "$RUN_DIR"; finish' EXIT

for f in "$TEMPLATE" "$VERIFY"; do
  [ -f "$f" ] || { echo "⚠️  missing $f"; exit 1; }
done

# RESEARCH_PROOF_TX points the run at a transcript of your choosing. The
# research fan-out is the half of this feature that a normal run often never
# reaches — a ten-minute window with nothing checkable in it is a perfectly
# common (and correct) empty result — so exercising it needs a window that
# deliberately contains claims. Testing only, never set in production.
TX="${RESEARCH_PROOF_TX:-$(ls -t "$OUTPUT_DIR"/*-transcription.txt 2>/dev/null | head -1)}"
if [ -z "$TX" ]; then
  echo "⚠️  No *-transcription.txt in $OUTPUT_DIR — nothing to fact-check."
  bail ok "No transcript today"; finish; sleep 3; exit 0
fi

echo "════════════════════════════════════════════════════════════════"
echo "  🔬  Research Proof — the last $WINDOW_MINUTES minutes"
echo "  Transcript: $(basename "$TX")"
echo "════════════════════════════════════════════════════════════════"

# --- 1. settle: has whisper caught up? -------------------------------------
# Mirrors TranscriptSettlePolicy: a floor (the in-flight chunk must be closed
# AND transcribed), then "the file stopped growing" as the signal that the
# backlog drained, then a give-up because a slightly stale window beats none.
MIN_WAIT=8; QUIET=2.5; MAX_WAIT=25
echo "⏳ waiting for Whisper to catch up (max ${MAX_WAIT}s)…"
START=$(date +%s)
LAST_SIZE=$(wc -c < "$TX")
LAST_GROWTH=$START
while :; do
  sleep 0.4
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START ))
  SIZE=$(wc -c < "$TX")
  if [ "$SIZE" -ne "$LAST_SIZE" ]; then LAST_SIZE=$SIZE; LAST_GROWTH=$NOW; fi
  QUIET_FOR=$(( NOW - LAST_GROWTH ))
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "   …gave up waiting after ${ELAPSED}s (long backlog) — going with what is in the file"; break
  fi
  if [ "$ELAPSED" -ge "$MIN_WAIT" ] && awk "BEGIN{exit !($QUIET_FOR >= $QUIET)}"; then
    echo "   …caught up after ${ELAPSED}s (file quiet for ${QUIET_FOR}s)"; break
  fi
done

# --- 2. cut the window ------------------------------------------------------
# Anchored on the NEWEST LINE IN THE FILE, not on the wall clock — exactly the
# reason TranscriptTail.lastMinutes gives: whisper stamps a line when it writes
# it, so a clock-anchored window silently loses its own tail.
awk -v W="$WINDOW_MINUTES" '
  /^\[[0-9][0-9]:[0-9][0-9]\]/ {
    mod = substr($0,2,2)*60 + substr($0,5,2)
    n++; mins[n] = mod; text[n] = $0; anchor = mod
  }
  END {
    for (i = 1; i <= n; i++) {
      age = anchor - mins[i]
      if (age >= 0 && age <= W) print text[i]
    }
  }' "$TX" > "$WINDOW_FILE"

WORDS=$(wc -w < "$WINDOW_FILE" | tr -d ' ')
LINES=$(wc -l < "$WINDOW_FILE" | tr -d ' ')
RANGE="$(head -1 "$WINDOW_FILE" | cut -c2-6)–$(tail -1 "$WINDOW_FILE" | cut -c2-6)"
echo "📄 window: $LINES lines, $WORDS words, $RANGE"

if [ "$WORDS" -lt "$MIN_WORDS" ]; then
  echo "⚠️  Too little speech in the last $WINDOW_MINUTES minutes ($WORDS words) — nothing to check."
  bail ok "Too little speech in the window ($WORDS words)"; finish; sleep 3; exit 0
fi

# --- 3. claude: extract → research → adversarially verify → JSON ------------
( while true; do sleep 20; printf '  … still working (%s)\n' "$(date +%H:%M:%S)"; done ) &
HEARTBEAT=$!
trap 'kill "$HEARTBEAT" 2>/dev/null; rm -f "$LOCK"; rm -rf "$RUN_DIR"; finish' EXIT

PROMPT="You are fact-checking the last $WINDOW_MINUTES minutes of a LIVE technical training session that Victor Rentea is teaching right now. The result is projected on the screen the room is watching, within minutes. Unattended: never ask a question, never stop to confirm.

TRANSCRIPT WINDOW (Romanian and English mixed, auto-transcribed by a local Whisper — it garbles technical terms and sometimes invents fluent sentences nobody said):
$WINDOW_FILE

Write your result as JSON to: $JSON_FILE
Verify every quote with: python3 $VERIFY <url> <quote>

STEP 1 — EXTRACT CHECKABLE CLAIMS (at most $MAX_CLAIMS)
Keep only statements that a public source could confirm or contradict: numbers and benchmarks, version and release facts, 'X is faster/safer/cheaper than Y', attributions ('Fowler says…', 'the JVM spec requires…'), API and default-value claims, dates, standards.
Discard opinions, teaching preferences, jokes, war stories, anything about the people in the room, and anything a source could never settle. List what you discarded in 'skipped' (a few words each).
Prefer the claims that would actually matter if they were WRONG — a wrong number a room is writing down beats a trivially true aside.
If the transcript is too garbled to know what was claimed, that is a legitimate empty result — say so in 'skipped' and write zero claims rather than inventing a claim to check.

STEP 2 — RESEARCH (one subagent per claim, launched IN PARALLEL, in a single message)
Each researcher: search the web, open the promising pages, and come back with 1–2 pieces of evidence — a LITERAL quote copied character-for-character off the page, its URL, the site name, the publication date if visible, and a tier:
  tier 1 = primary: official docs, specs, RFCs, the vendor's own changelog/blog, the paper itself, source code
  tier 2 = secondary: a serious engineering blog, a conference talk, a well-known book
  tier 3 = anything else
Never quote from search-result snippets — open the page. Prefer tier 1; a tier-3 source that merely repeats a claim is nearly worthless and must be labelled honestly.
It is a perfectly good outcome to come back with NOTHING. Say so. Do not settle for a page that is vaguely on-topic.
Each researcher must ALSO report EVERY page URL it actually opened, including the dead ends — the pages that turned out to be irrelevant, paywalled or wrong. That trail is what makes the report auditable instead of merely assertive, and it is rendered as a strip of site icons at the foot of the page.

STEP 3 — ADVERSARIAL VERIFICATION (this is the point of the whole feature)
For EVERY piece of evidence, run: python3 $VERIFY <url> <quote>
It re-fetches the page and searches for the words. Copy its 'check' and 'coverage' verbatim into the evidence object — never guess them, never soften them.
  found/approx → the quote is real. Now judge the only thing left: does it actually SUPPORT the claim, or is it merely about the same topic?
  absent       → the quote was invented or mangled. Either replace it with a real one from the page, or drop the evidence entirely. NEVER keep an 'absent' quote and call the claim confirmed.
  thin/unreachable → could not be checked. That is NOT confirmation; the claim is 'unverified' unless other evidence stands.
Then have a second subagent per claim argue the OPPOSITE case: search for sources that contradict it, and challenge whether the surviving evidence really says what it is being used to say. A claim only stays 'confirmed' if that attack fails.

STEP 4 — WRITE THE JSON (exactly this shape, nothing else)
{
  \"generated\": \"HH:MM\",
  \"window\": \"$RANGE\",
  \"claims\": [
    {
      \"claim\": \"the claim, in the language it was said, one sentence\",
      \"transcript\": \"the [HH:MM] line(s) it came from, copied VERBATIM from the window file — this leads the card, in quotes, so it must read as what was actually heard, uncorrected\",
      \"verdict\": \"contradicted | partly | not_found | unverified | confirmed\",
      \"note\": \"one or two sentences: what the sources ACTUALLY say. For 'contradicted', lead with the correction — 'ai spus X; sursa spune Y'.\",
      \"evidence\": [
        {\"quote\": \"literal text from the page\", \"url\": \"https://…\", \"site\": \"docs.oracle.com\",
         \"tier\": 1, \"date\": \"2025-03\", \"check\": \"found\", \"coverage\": 1.0}
      ]
    }
  ],
  \"sources\": [
    {\"url\": \"https://…the exact page that was opened…\", \"site\": \"docs.oracle.com\", \"used\": true}
  ],
  \"skipped\": [\"what you deliberately did not check\"]
}
'sources' is EVERY page any researcher opened during the whole run, deduplicated by URL, in the order they were visited. 'used' is true when a quote from that page made it into the report and false for a dead end — dead ends are kept and shown dimmed, because 'I looked here and it gave me nothing' is part of an honest trail. Give the exact URL that was navigated, not the site's home page: it is what shows on hover.
Verdicts mean: contradicted = the sources say otherwise. partly = true with a caveat that matters. not_found = searched, found nothing either way. unverified = found something but could not verify the quote. confirmed = real quote from a good source that squarely supports it, and the adversarial pass failed to break it.
'note' is written in the language the claim was made in (usually Romanian) and is read off a projector — plain, short, no hedging filler.

Do not write HTML. Do not write anything to $REPORT. Do not touch any file except $JSON_FILE. Do not commit anything.
Print a one-line summary at the end (how many claims, how many contradicted)."

cd "$RUN_DIR" || true
# Subscription auth (see summarize-on-break.sh): the exported ANTHROPIC_API_KEY
# is out of credit and shadows the logged-in account. --strict-mcp-config keeps
# the connectors out — this run needs WebSearch/WebFetch and Bash, all built in.
env -u ANTHROPIC_API_KEY "$CLAUDE" -p "$PROMPT" --model opus --dangerously-skip-permissions \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}'
STATUS=$?

kill "$HEARTBEAT" 2>/dev/null
echo

if [ "$STATUS" -ne 0 ] || [ ! -s "$JSON_FILE" ]; then
  echo "⚠️  claude exited $STATUS / no JSON written — rendering a failure page so the run is visible."
  bail fail "The run failed — see $LOG"
  finish
  echo "   (log: $LOG)"
  read -r -t 1800 _ || true
  exit 0
fi

if ! render "$JSON_FILE"; then
  echo "⚠️  claude's JSON did not parse. A copy is kept for the post-mortem."
  cp "$JSON_FILE" "$OUTPUT_DIR/research-proof-broken-$(date +%H%M%S).json" 2>/dev/null
  bail fail "claude returned invalid JSON — see $LOG"
  finish
  read -r -t 1800 _ || true
  exit 0
fi

echo "✅ done — the report is opening on the retina."
VERDICT="ok"
finish
sleep 4
exit 0
