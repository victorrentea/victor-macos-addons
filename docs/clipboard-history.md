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

| key | while the bezel is up |
|---|---|
| **⌘⇧V** | open it (on the current clipboard), then step one clip older each press |
| **V** | the same step — the hold never has to be broken |
| **↑ ↓ ← →** | walk, wrapping at both ends |
| **1–9** | jump straight to that clip |
| **⏎** | take this one |
| **⌫ / ⌦** | forget this clip (and its files), stay open on the next |
| **Esc** | out, clipboard untouched |
| **release ⌘** | take this one — the way the gesture normally ends |
| any other key | out, and the key **passes through** to whatever you were typing in |

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

- **An image is drawn at a quarter of the screen's *area*** — Victor's size:
  half the width and half the height for a full-screen capture, the clip's own
  aspect ratio kept. It is never scaled *up* past 1:1; a copied 120×40 button
  should look like a small thing, not a wall of interpolation.
- **A text clip** is one paragraph of preview, whitespace collapsed so a copied
  block of code reads as one thing, cut at 280 characters.
- The footer is `3 / 40` on the left and **when it was copied** on the right —
  `12 minutes ago`, plus `🖼️ 2048×1152 · 3,4 MB` or `📋 812 chars`.

**"When", not "which app".** Flycut prints the source application; Victor
explicitly does not want it. Two clips copied out of the same editor are told
apart by *when* — which is also the only thing you actually remember about a
clip you are hunting for.

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

## Files

| file | what |
|---|---|
| `ClipboardHistoryPolicy.swift` | `ClipboardEntry` + the pure rules (insert/dedup/cap, the two ceilings, the age caption, the text preview) |
| `ClipboardHistoryStore.swift` | disk, thumbnails, fingerprints, the index, `place()` |
| `ClipboardHistoryOverlay.swift` | the bezel and its geometry |
| `EventTapManager.swift` | ⌘⇧V, the key routing while it is up, the ⌘-release |
| `ClipboardStackManager.swift` | the shared poll that feeds it |

Headless: `curl 127.0.0.1:55123/test/clipboard-history` opens it in
clipboard-only mode — the only way to look at it without taking Victor's
keyboard.
