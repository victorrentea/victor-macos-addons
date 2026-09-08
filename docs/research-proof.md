# 🔬 Research Proof — fact-check the last 10 minutes

**Menu row `🔬 Fact-check last 10 min`** (under 🐕 Tail) → `ResearchProofLauncher` →
`research-proof.sh` → an unattended `claude` → an HTML report that opens **on the
Retina, in front, by itself**. Headless trigger: `GET /test/research-proof`.

The point of the feature is not "search the web about what Victor said" — a model
does that on its own and gets it plausibly wrong. The point is the **proof**: every
quote in the report has been re-fetched and found in the source page by a substring
search, and the report says so, per quote, on screen.

## The pipeline

1. **Settle.** The run waits for whisper before reading anything: floor 8 s, then
   2.5 s of the transcript file not growing, give up at 25 s. Constants mirror
   `TranscriptSettlePolicy` (see [transcription.md](transcription.md) for why they
   are what they are). Without it the run reads a file that is missing exactly the
   sentence that made Victor reach for the menu.
2. **Cut the window.** `awk` keeps the `[HH:MM]` lines within 10 minutes of the
   **newest line in the file**, not of the wall clock — same anchor, same reason,
   as `TranscriptTail.lastMinutes`. Under `MIN_WORDS` (40) the window is a pause,
   not a discussion, and the run stops with a report that says so.
3. **Extract claims** — at most 8, and only ones a public source could settle:
   numbers, versions, "X is faster than Y", attributions, API defaults, dates.
   Opinions and jokes are listed in `skipped` and shown in the report footer, so a
   silent run and a run that decided there was nothing to check look different.
4. **Research** — one subagent per claim, in parallel, each returning a literal
   quote + URL + site + date + source tier (1 primary / 2 secondary / 3 other).
5. **Verify adversarially** — the part everything else exists to serve, below.
6. **Render + open.** claude writes JSON; the script substitutes it into
   `research-proof-template.html`; the launcher opens the file on the Retina.

## Why the quote check is `grep`, not a second model

`verify-quote.py <url> <quote>` re-fetches the page, strips tags, normalises
(NFKC, case, curly quotes and dashes, punctuation → spaces, whitespace collapsed)
and looks for the **longest contiguous run of the quote's words**. Contiguous
matters: "X is faster than Y" and "Y is faster than X" share every word and mean
opposite things.

Asking a second model "did the first one lie?" was the obvious design and is the
wrong one — it reads the same page through the same lens, agrees, and can
*hallucinate the confirmation*, which is the exact failure the feature exists to
prevent. A substring search cannot. So the model is left with the one question it
is genuinely better at: **does this real quote actually support the claim, or is
it merely about the same topic?**

Five outcomes, and the last two are the reason it is not a boolean:

| check | meaning |
|---|---|
| `found` | the whole quote is on the page |
| `approx` | ≥ 90 % of it is contiguously there — trimmed or lightly edited |
| `absent` | the page loaded fine and does **not** say this |
| `thin` | the page loaded but carries almost no text (SPA, paywall, cookie wall) |
| `unreachable` | 404 / 403 / timeout / not text |

`thin` and `unreachable` mean **"could not check"**, which is the opposite
conclusion from `absent`, and a `true/false` would have merged them. The prompt
forbids calling a claim confirmed on either.

The match is decided *before* the thinness test: a genuinely short page that does
carry the sentence has proved the quote, and reporting that as unchecked would
throw away the one answer the run went for.

## Why the report is a template, not model-written HTML

claude writes `report.json` and nothing else. The page shape lives in
`research-proof-template.html`, because **the report is projected to the room**
and a model that re-authors the page every run re-decides the design every run.

Everything about the layout follows from "the back row reads this":

- **Contradictions first, confirmations last and folded.** A run that ends in
  eight green cards and one red one must not make the red one scroll-work — the
  red card *is* the output; the green ones are the receipt.
- **Every card LEADS with the raw `[HH:MM]` transcript line**, in quotes, with no
  label in front of it. Whisper invents fluent sentences nobody said, and a
  beautifully sourced fact-check of an invented claim looks exactly like a real
  one — the line is the one-glance escape hatch: *I never said that*. The label
  it used to carry ("s-a spus:") was dropped because the room is often
  English-speaking, and the quote marks say the same thing in no words at all.
- **The check is rendered as what it is** — `quote found on the page` /
  `QUOTE IS NOT ON THE PAGE` with the coverage percentage — so "the source says
  it" and "a model said the source says it" can never be confused on screen.
- **Every page the researchers opened is a favicon strip at the foot**, hover for
  the exact URL. Dead ends are kept and dimmed: "I looked here and it gave me
  nothing" is part of an honest trail, and at full contrast it would read as
  evidence. Icons come from the site's own `/favicon.ico` first and only fall
  back to a proxy, so researching a topic does not tell a third party what.
  Hover uses the page's own tooltip component (`data-tip`, delegated on
  `document`, 150 ms, flips and clamps) — a native `title=` takes ~500 ms to
  appear, longer than anyone hovers a 46 px icon before giving up.
- **All fixed strings are English** — terminal output and report chrome alike.
  Only the model's own prose (the claim, the note) stays in the language the
  claim was made in.

Ordering is `contradicted → partly → not_found → unverified → confirmed`.

## A report is always produced

Every way a run can end writes a page: no transcript today, a silent ten minutes,
claude crashing, unparseable JSON. The launcher opens whichever page it finds.
This is not tidiness — the click's whole feedback is the page appearing, and a run
that failed silently would leave Victor staring at a menu that did nothing.

## Operational notes

- **Runs on the subscription** (`env -u ANTHROPIC_API_KEY`, `--model opus`,
  `--strict-mcp-config` with no servers — WebSearch/WebFetch/Bash are built in).
- **One at a time, twice over**: a pid lock in the script (the menu and the HTTP
  hook are separate entry points) *and* a `running` flag in the launcher, because
  the script's guard makes a second run exit quietly and the launcher would then
  poll for a report nobody is writing.
- **Terminal window**: the `BreakSummaryLauncher` sentinel handshake verbatim —
  it closes on `ok`, stays open on failure. Terminal's `busy` flag is not usable
  here; see [summaries.md](summaries.md) for the 2026-06-30 bug it caused.
- **Everything is logged** to `addons-output/research-proof-YYYY-MM-DD.log`, and
  a JSON that failed to parse is kept as `research-proof-broken-HHMMSS.json`.
- **A real run is ~5 minutes** end to end, measured 2026-09-08 on a window with
  4 checkable claims: 46 pages opened, 8 quoted, every quote `found` at
  coverage 1.0. Budget accordingly — it is a coffee-length wait, not a click.
- `RESEARCH_PROOF_TX=<file>` points a run at a transcript of your choosing.
  The research fan-out is the half of the feature a normal run often never
  reaches — a ten-minute window with nothing checkable in it is a common and
  *correct* empty result — so exercising it needs a window that deliberately
  contains claims. Testing only.
- **Never edit `research-proof.sh` while a run is in flight.** bash reads a
  script incrementally by byte offset; changing the bytes ahead of the
  interpreter mid-run makes it resume in the middle of a token. Cost one
  test run on 2026-09-08 to a syntax error inside the prompt heredoc.
- Reports pile up in `addons-output/research-proof-*.html`; there is no retention
  policy yet.
