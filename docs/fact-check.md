# 🔬 Fact-check

**What it does:** the menu row **🔬 Fact-check last 30 s** (and `GET /test/research-proof`)
takes the last ~30 s of today's transcript and hands it to **Walkie Talkie** as a ⚡ quick
question. The answer comes up in Walkie's reply pop-up beside the pointer, the way an answer
to a question Victor dictated does: first words in about a second, signed `— Opus …`, then
rewritten after a 🌐 web search and a 🧐 adversarial review. The ✕ stops the checks.

**Code:** `FactCheck` (`Sources/VictorAddons/FactCheck.swift`). `header(for:)` and
`prompt(for:)` are pure and tested in `FactCheckTests`.

## The handoff

- **Window:** `TranscriptTail.lastSeconds(parsed, seconds: 30)`. It counts lines, at about
  8 s each, because the `[HH:MM]` stamps cannot express 30 s. It is capped at 2 minutes back,
  so a click after a pause does not check a conversation from before the break. Fewer than
  5 words → Basso, nothing is sent.
- **No waiting for whisper.** The file trails speech by about one whisper batch (~8 s), so
  the window is roughly *40 s ago → 8 s ago*. `TranscriptSettlePolicy` would add the last
  sentence at the cost of an 8 s floor, and speed is what this feature is for.
- **Channel:** `POST http://127.0.0.1:{8917,8918,8919}/ask {token, text, prompt}`. The first
  port to answer 200 wins, the same as `walkie-reply`. The token is
  `~/.walkie-talkie/reply-token`, the same one `/reply` checks. `text` is the pop-up's
  header: `🔬 «…the last 60 characters said»`, so he can see which part of the conversation
  is being checked. `prompt` is what the model gets. Walkie's side of the route is described
  in `walkie-talkie/.claude/rules/destinations-and-outbox.md`.
- **Framing:** *"This discussion was just overheard in a live training room …"*, then the
  transcript, then: find the claimed facts and anything left unknown or unanswered, check
  them, and answer as you would answer a question, one line each, ✅/❌/❓ plus the correct
  fact, in the language of the discussion. It asks for the list explicitly because Walkie's
  quick system prompt says "one short sentence, no lists unless asked". Without that, four
  claims would come back as one sentence.
- **Failure is audible, never a hang:** if Walkie is down, the token is missing or the token
  is refused, it plays Basso and writes an overlay error line. Nothing blocks the menu.

## Why it changed (2026-10-15)

Until then this was **🔬 Fact-check last 10 min**: `research-proof.sh` ran an unattended
`claude` in a self-closing Terminal. It extracted claims, sent researcher subagents to check
them, proved each quote by substring search (`verify-quote.py`) and rendered a fixed HTML
report on the Retina. A run took about 5 minutes. Victor: *"this fact check I expected to
return very fast answers to me"*. The script, `verify-quote.py`, the template and
`ResearchProofLauncher` were deleted in the same commit, and git keeps them.
