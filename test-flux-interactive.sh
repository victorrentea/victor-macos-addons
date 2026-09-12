#!/bin/bash
set -uo pipefail

# Does the word "interactiv" in an email really keep the Terminal window open?
#
# Runs the REAL flux-agent.sh end to end, with the three rehearsal hooks it
# already has ($FLUX_AGENT_CLAUDE, $FLUX_AGENT_DRY_RUN, $FLUX_AGENT_OUTPUT_DIR)
# plus a fake `curl` on PATH standing in for AgentMail — so nothing is fetched,
# nothing is mailed, no real claude is spent, and the production log and session
# records are untouched.
#
# What is asserted is the contract with FluxAgentLauncher: the SENTINEL. "ok"
# closes the window, "interactive" keeps it and hands it to a live claude — the
# literal has to match FluxAgentVerdict on the Swift side (FluxAgentVerdictTests
# guards the other end of that string).

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENT="$HERE/flux-agent.sh"
TMP="$(mktemp -d /tmp/flux-interactive-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

mkdir -p "$TMP/bin"

# Fake AgentMail: answers the thread GET with $TMP/thread.json and HTTP 200.
cat > "$TMP/bin/curl" <<'CURL'
#!/bin/bash
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && cat "$FAKE_THREAD" > "$out"
printf '200'
CURL

# Fake claude: prints a report for the unattended `-p` run, and announces itself
# for the interactive handoff (which gets no `-p`).
cat > "$TMP/bin/claude" <<'CLAUDE'
#!/bin/bash
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then printf '%s' "$a" > "$FLUX_PROMPT_DUMP"; fi
  prev="$a"
done
for a in "$@"; do
  if [ "$a" = "-p" ]; then echo "STUB REPORT: work done."; exit 0; fi
done
echo "STUB INTERACTIVE CLAUDE"
exit 0
CLAUDE
chmod +x "$TMP/bin/curl" "$TMP/bin/claude"

# One run of the real script over a one-message thread with $1 as the body.
# Echoes the sentinel verdict; the transcript of the run lands in $TMP/run.log.
run_agent() {
  local body="$1" mid="test-$RANDOM-$$@mail.gmail.com"
  python3 - "$body" "$mid" > "$TMP/thread.json" <<'PY'
import json, sys
body, mid = sys.argv[1], sys.argv[2]
print(json.dumps({
    "subject": "test", "message_count": 1,
    "messages": [{"message_id": mid, "from": "Victor Rentea <victorrentea@gmail.com>",
                  "timestamp": "2026-09-12T10:00:00Z", "subject": "test",
                  "text": body, "extracted_text": body}],
}))
PY
  rm -f "$TMP/sentinel"
  rm -f "$TMP/prompt.dump"
  PATH="$TMP/bin:$PATH" \
  FAKE_THREAD="$TMP/thread.json" \
  FLUX_PROMPT_DUMP="$TMP/prompt.dump" \
  FLUX_AGENT_CLAUDE="$TMP/bin/claude" \
  FLUX_AGENT_DRY_RUN=1 \
  FLUX_AGENT_OUTPUT_DIR="$TMP/out" \
  FLUX_AGENT_CWD="$TMP" \
    bash "$AGENT" "$TMP/sentinel" "$mid" "thread-$RANDOM" </dev/null > "$TMP/run.log" 2>&1
  cat "$TMP/sentinel" 2>/dev/null
}

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ✅ $label → $actual"; PASS=$((PASS+1))
  else
    echo "  ❌ $label → got '$actual', expected '$expected'"; FAIL=$((FAIL+1))
  fi
}

echo "── sentinel verdicts ───────────────────────────────────────────────"
check "plain mail closes the window"        ok          "$(run_agent 'Fixeaza te rog bug-ul din X.')"
check "interactiv"                          interactive "$(run_agent 'Vreau o sesiune interactiv pe tema asta.')"
check "interactivă (diacritic)"             interactive "$(run_agent 'Porneste o sesiune interactivă, te rog.')"
check "interactiva"                         interactive "$(run_agent 'as vrea o sesiune interactiva aici')"
check "Interactive (english, capitalised)"  interactive "$(run_agent 'Make this one Interactive so we can talk.')"

echo "── the handoff itself ──────────────────────────────────────────────"
run_agent 'Sesiune interactivă, te rog.' > /dev/null
if grep -q "INTERACTIVE — the reply is mailed, the session is yours" "$TMP/run.log"; then
  echo "  ✅ the window announces the handoff"; PASS=$((PASS+1))
else
  echo "  ❌ no handoff banner in the run log"; FAIL=$((FAIL+1))
fi
if grep -q "STUB INTERACTIVE CLAUDE" "$TMP/run.log"; then
  echo "  ✅ a live claude is actually started"; PASS=$((PASS+1))
else
  echo "  ❌ claude was never started interactively"; FAIL=$((FAIL+1))
fi
# claude must be TOLD it is interactive, or it signs off as if it will never be
# asked anything again — the whole point is that the report is not a farewell.
if grep -q "THIS ONE IS INTERACTIVE" "$TMP/prompt.dump"; then
  echo "  ✅ the prompt tells claude the session continues"; PASS=$((PASS+1))
else
  echo "  ❌ the interactive note never reached the prompt"; FAIL=$((FAIL+1))
fi
run_agent 'Fixeaza bug-ul din X.' > /dev/null
if grep -q "THIS ONE IS INTERACTIVE" "$TMP/prompt.dump"; then
  echo "  ❌ a plain mail got the interactive note"; FAIL=$((FAIL+1))
else
  echo "  ✅ a plain mail gets no interactive note"; PASS=$((PASS+1))
fi
# The production log and session dir must be untouched by a test run.
if [ -d "$TMP/out/flux-sessions" ]; then
  echo "  ✅ test sessions stay in the scratch dir"; PASS=$((PASS+1))
else
  echo "  ❌ no scratch session dir — is FLUX_AGENT_OUTPUT_DIR honoured?"; FAIL=$((FAIL+1))
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
