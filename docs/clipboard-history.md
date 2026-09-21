# 📋 Clipboard history — ⌘⇧V

**What it is**: Flycut's gesture, with images. Hold ⌘⇧, tap **V** to walk back
through the last 40 things that passed through the clipboard, let go of ⌘ to
paste the one on screen.

**Why it exists**: Flycut (which ran on this Mac until 2026-09-16, and which
this replaces) keeps **text only**. The thing most often copied during a
workshop is a ⌃P screenshot going into an agent's terminal, and that is exactly
what Flycut silently drops — the clip is gone the moment the next one lands.
Victor asked for the same gesture with the one thing it could never do.

---

## The gesture

| key | while the bezel is up | on the legend |
|---|---|---|
| **⌘⇧V** | open it (on the current clipboard), then step one clip older each press | — |
| **V** | the same step — the hold never has to be broken | ✅ |
| **↑ ↓ ← →** | walk, wrapping at both ends | ✅ |
| **release ⌘** | take this one — the way the gesture normally ends | — |
| **Esc** | out, clipboard untouched | ✅ |
| **⏎** | take this one | no |
| **⌫ / ⌦** | forget this clip (and its files), stay open on the next | no |
| any other key | out, and the key **passes through** to whatever you were typing in | — |

**The legend is shorter than the key list, on purpose.** It is read at a glance
with a hand already holding ⌘⇧, so it names only the keys that belong to *that
hold*: `V next · ↑↓ walk · Esc`. ⏎ only duplicates what letting go of ⌘ already
does and ⌫ is not something anyone reaches for mid-gesture, so both work and
neither is advertised (2026-09-17).

**The digits are gone entirely** — they jumped straight to a clip, as they do in
Flycut, and Victor: *"1-9 jump nu voi folosi vreodată"*. A key the gesture claims
but nobody presses is worse than one it ignores, because it is swallowed from
whatever you were typing into; they now fall through like any other key — the
bezel closes and the digit reaches the document.

**Opening on clip #1 — the current clipboard — is deliberate**: it makes a quick
double-tap of ⌘⇧V an ordinary paste, and every further V a step back in time.

**Nothing is pasted when the bezel was opened from the menu row** (📋 *Clipboard
History…*) or from `GET /test/clipboard-history`. There is no held ⌘ to let go
of there, nothing is guaranteeing which window has focus, and a synthetic ⌘V
into the wrong window is worse than one more keypress: the pick lands on the
clipboard and Victor pastes it himself. The paste only happens on the path that
began with a hotkey.

**Flycut must be quit.** Our event tap swallows ⌘⇧V before anything else on the
Mac sees it, so a running Flycut never shows its own bezel — but it is still
there, still recording a second history, still in the login items. Removing it
is the point of this feature.

## What the bezel shows

One clip at a time, centred on the **screen under the cursor** (never pinned to
the built-in retina — that is what the room's projector mirrors, and the last
thing Victor copied is not always something the room should read).

**The frame is the same for every clip**: one box, **a quarter of the screen's
area** — Victor's size — i.e. half its width by half its height. Sizing the
panel to its contents was the first version and it was wrong: walking a list of
mixed clips made the whole thing grow and shrink around its own centre on every
press, so the first line of a long text clip and of a short one landed at
different heights and the eye had to find the words again each time. Now only
the content changes (2026-09-17).

- **An image** is fitted inside that box, aspect ratio kept, **never scaled up
  past 1:1** — a copied 120×40 button should look like a small thing, not a wall
  of interpolation — and centred in it.
- **A text clip** hangs from the box's **top-left corner**, so its first line is
  always on the same pixel, and it **fills the box the way it was copied — line
  breaks and all**, down to the last line that fits, which gets an ellipsis.
  The first version collapsed all whitespace into one paragraph and cut it at
  280 characters; that threw away the one cue the box is big enough to show,
  since an indented block, a stack trace and three paragraphs are recognised by
  their shape (2026-09-21: *"should show the text as it was copied along with
  the new lines, as much as fits the area in which it is displayed"*). Only
  what would waste the area is still normalised: CRLF, tabs → four spaces
  (a real tab jumps the label's own tab stops), trailing blanks, runs of blank
  lines squeezed to one, blank lines at either end. The 4000-character cap in
  `preview` is a safety stop for a pasted log, not the visible cut — the cut is
  `maximumNumberOfLines`, counted in *drawn* lines, so one long line that wraps
  four times spends four of them.

**One line under the box, not two.** The counter, the legend and what-this-clip-
is were a footer row plus a hint row, and two rows of small grey text under a
picture read as a paragraph you are meant to study. Now: `3 / 40` in the accent
colour and the legend on the left, and on the right **only what the clip cannot
say for itself** — `12 minutes ago`, plus a character count when the clip did
not fit the box (then the number stops being trivia: it is the one fact the
panel cannot show, that these words are the opening of something much bigger).
It used to be a fixed 500-character threshold; with the box now showing the text
as copied, "is there more?" is a question about *this* box and *this* clip.

**Nothing describes an image any more.** `🖼️ 3000×2000 · 142 KB` was there on the
theory that two screenshots of the same window are told apart by their size;
Victor, looking at it: *"mărimea pozei în px și kb nu mă interesează"*. You
recognise a picture by looking at it, and the picture is right there at a
quarter of the screen. `📋 812 chars` went the same way for short text, for the
same reason: the words are right there to be read.

**"When", not "which app".** Flycut prints the source application; Victor
explicitly does not want it. Two clips copied out of the same editor are told
apart by *when* — which is also the only thing you actually remember about a
clip you are hunting for.

**The bezel logs where it drew itself** (`📋 clip 1/7 on screen 1728×1079 at
414,239 (panel 900×601)`). It is the one piece of UI here that cannot be
screenshotted on demand — any keystroke dismisses it, so an agent checking on it
while Victor types sees an empty screen and concludes it is broken. One line per
press, and the only way to answer "it did not appear" without taking his
keyboard.

## Where the pixels live

`~/Library/Caches/ro.victorrentea.macos-addons/clipboard-history/`

- `<id>.png` — the bytes that get pasted back.
- `<id>-thumb.png` — long side ≤ 1600 px; **the only file ever displayed**.
- `index.json` — the list itself, so the history survives a restart of the app.

**Pixels are never held in memory.** This is the constraint the whole design is
built around, and the reason a workshop's worth of screenshots is affordable:
the in-memory list is `ClipboardEntry` rows — an id, a pixel size, a byte count,
a date, a fingerprint — and an image is decoded only while the bezel is showing
that one clip, from the *thumbnail*, and dies with the panel.

**Caches, not Application Support**, for the same reason the screenshots folder
is there: it is the one place emptying the Trash and every "free up space" tool
actually reclaim, and macOS may purge it under disk pressure. All welcome — this
is a staging area, never an archive. (A ⌃P that is worth *keeping* is kept by
`ScreenshotManager`, in its own folder, under its own longer retention.)

**And it bounds itself**, on every capture, via `ClipboardHistoryPolicy`
(pure + unit-tested, like `ScreenshotRetentionPolicy`):

| ceiling | value | note |
|---|---|---|
| entries | 40 | Flycut's default; the list is walked by hand, so the end has to be reachable |
| age | 3 days | a clip from last week is not what ⌘⇧V is for |
| bytes | 400 MB | backstop for one heavy day, ~40 retina screenshots |

with three rules that are each a test:

- **The newest clip is never dropped**, by any ceiling. Same guard as the
  screenshots folder: a Mac that wakes with a wrong clock must not be able to
  throw away the thing that was copied one second ago and is about to be pasted.
- **A text clip is never charged against the byte ceiling.** It costs nothing on
  disk. (Found by the test: one 40 MB screenshot at the head of the list took
  every text clip behind it down with it.)
- **Copying the same thing again moves it, it does not add it** — with a fresh
  date, because "2 minutes ago" is now the truth. Without this, a burst of ⌘C on
  one word fills the whole picker with that word.

Files with no row pointing at them (a crash between the PNG write and the index
save) are swept on every capture; nothing else would ever reclaim them.

## How it is wired

- **No poller of its own.** `ClipboardStackManager` already polls `changeCount`
  every 300 ms behind the `PasteboardGate` and already pays for the TIFF→PNG
  conversion of every copied image (for the ⌃V image stack). It hands the result
  to `ClipboardHistoryStore`. One pasteboard read, two consumers.
- **A clip the history itself puts back is not re-captured**: `place()` records
  the resulting `changeCount` and the poller skips it, or pasting from the
  history would rewrite that PNG one tick later.
- **The screen behind it is washed 20% black** (2026-09-22, Victor's) — a
  `ScrimPanel` over the whole `screen.frame` (menu bar and Dock included), one
  window level under the bezel, `ignoresMouseEvents` like everything else here,
  put up and taken down with it. The bezel is read in one glance and the glance
  has to land *in* it; over a bright page a dark box in the middle is just one
  more rectangle. 20% and no more because what is underneath is the context for
  choosing *which* clip — the window you are about to paste into — so it is a
  tint, not a curtain. It follows the cursor's screen on every render, so the
  wash is never left behind on the display the bezel just left.
- **The bezel never takes focus.** `.nonactivatingPanel`, `orderFrontRegardless`,
  and every key arrives through `EventTapManager` — the same way the ⌥
  cheat-sheet and the ⌃P crosshair work. It has to be this way: the gesture ends
  by posting ⌘V into *the app you were typing in*, and an accessory app that
  activated itself to read a keystroke would have to hand focus back and hope.
- **The tap claims the keyboard only while the bezel is up**
  (`setClipboardHistoryOpen`), and a key that is not part of the gesture cancels
  **and passes through** — you reached for something else, so the character
  still belongs in the document.
- **The ⌘V is posted after `KeySimulator.waitForModifiersReleased()`.** The hand
  is still coming off ⌘⇧ at that exact moment and the window server merges live
  modifiers into synthetic events: an unguarded ⌘V arrives as ⌘⇧V — paste-and-
  match-style in half the apps here, and this app's own shortcut in the other
  half, i.e. the bezel re-opening forever. The same trap cost ⌘⌃S a workshop
  once; see `KeySimulator`.
- **An image going into a Claude Code prompt is pasted with ⌃V, not ⌘V**
  (2026-09-22, `ClipboardPasteKeystroke`). Terminal.app answers ⌘V by writing
  the pasteboard's *text* to the pty, and an image clip has none — the ⌃P
  screenshot you just walked to in the bezel simply never appeared. Claude Code
  reads the clipboard itself instead: `chat:imagePaste`, bound to ⌃V, shells out
  to `osascript -e 'the clipboard as «class PNGf»'` and attaches the PNG (its own
  hint says *"control+v (not cmd+v!)"*). The swap is scoped as tightly as it can
  be: **image clips only** (text already pastes fine with ⌘V, through bracketed
  paste and no subprocess) and **only when Terminal.app is in front with a
  Claude window focused** — the `ClaudeSessionTitle` spinner test that ⌘⌃A
  already uses. Everywhere else ⌃V is readline's `quoted-insert`, which eats the
  next keystroke; Copilot CLI has no clipboard-image path at all (checked
  2026-09-22), so it keeps ⌘V and the no-op.

## Files

| file | what |
|---|---|
| `ClipboardHistoryPolicy.swift` | `ClipboardEntry` + the pure rules (insert/dedup/cap, the two ceilings, the age caption, the text preview) |
| `ClipboardHistoryStore.swift` | disk, thumbnails, fingerprints, the index, `place()` |
| `ClipboardHistoryOverlay.swift` | the bezel and its geometry |
| `ClipboardPasteKeystroke.swift` | ⌘V or ⌃V, and the AX read of the window it is about to land in |
| `EventTapManager.swift` | ⌘⇧V, the key routing while it is up, the ⌘-release |
| `ClipboardStackManager.swift` | the shared poll that feeds it |

Headless: `curl 127.0.0.1:55123/test/clipboard-history` opens it in
clipboard-only mode — the only way to look at it without taking Victor's
keyboard.
