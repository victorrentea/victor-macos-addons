# Session Notes (SessionNotesAppender + BottomLeftBanner)

Capturing text into the training notes, and the bottom-left pill UX that confirms/undoes it.

- **📝 Selection-or-clipboard → session notes (⌘⌃S)** — `SessionNotesAppender.copySelectionAndAppend` simulates ⌘C and, if the pasteboard's `changeCount` moved, appends the selection; if it did **not** move (the app no-op'd the copy = nothing was selected) it falls back to whatever is already on the clipboard. One key covers both because at the moment of pressing they are one intent — "put THIS in the notes" — and remembering which of two shortcuts matches the current state of the screen is the friction that stopped it being used mid-talk. Selection wins when both exist: it is the fresher of the two. Moved off **⌃⌥C** so it lands on the ⌘⌃ cheat-sheet (`notes`). **⌘⌃V** (clipboard-only) and its menu item stay — a menu *click* can never capture the previous app's selection, so the clipboard entry is the only one that works from the menu. **That key was ⌃⌥V until 2026-09-17**, when it took ⌘⌃V off the 🎙️ transcript picker (which became a menu row): the append is the everyday half of that pair — the picker only means anything while Whisper is running in the room — and ⌘⌃ is where this app's everyday keys live, so the clipboard half sitting under a different modifier pair from its own ⌘⌃S sibling was the odd one out. ⌃⌥V is left **unbound** rather than kept as a second way in: ⌃⌥ is the emoji board now, and a lone survivor of the old arrangement is exactly what gets discovered by accident years later. On the ⌘⌃ cheat-sheet the key reads `clipboard` — the *source*, since S one row over already says `notes` — with the same 🚀 accent, which is the pair's whole point: same shelf, one takes what is selected, the other what was copied.
- **🤖 The same capture, filed as a prompt (⌘⌃P, 2026-09-08)** — `sendSelectionAsPrompt` is `copySelectionAndAppend` with `marker: .agentPrompt`, so the two keys differ by exactly one character in the notes file: 📋 sent by hand, 🤖 sent to an agent. That character is not cosmetic — the daemon builds the participants' **Prompts** tab by reading 🤖 lines back out of this file, so ⌘⌃P is the manual way onto a list that is otherwise filled only by what the prompt interception happens to see. It writes immediately and shows ⌘⌃S's hover-to-**undo** pill (pressing the key was the confirmation), unlike `offerPrompt`, which must hover-to-**commit** because nobody asked for it. Full write-up in `hotkeys-launchers.md`.


## 🤖 Prompts panel — the week of intercepted prompts (2026-09-22)

`PromptCaptureStore` + `PromptCapturePolicy` + `PromptHistoryPanel`, opened from
the top-level **🤖 Prompts…** menu row.

**Why it exists.** An intercepted prompt used to live for exactly `hoverActionDuration`
(9.5 s): `offerPrompt` put the pill up, and if the hover didn't come the text was
gone. But prompts are typed *while talking* — mid-sentence, in front of a room —
which is precisely when nobody hovers anything. The pill was therefore missing
the prompts most worth showing the participants. The panel is the second chance:
the same offer, still open days later, with a **Send** button per row that makes
the same `- 🤖 <text>` line the hover would have made. Nothing new reaches the room
through it; only *when* Victor decides changes.

- **It records only while a training session is active** — `AppDelegate`'s existing
  `isSessionActive` guard, unchanged, decides both the pill and the store. Outside a
  session a prompt is ordinary work, not material for the room, and a list that also
  holds every evening's debugging is a list nobody scrolls.
- **Seven calendar days**, today plus the six before it (`PromptCapturePolicy.prune`) —
  not a rolling 7×24 h window, because "Wednesday's prompts" is how the list is read and
  a day that half-expires at lunchtime reads as data loss. Storage is one JSON file in
  `~/Library/Caches/ro.victorrentea.macos-addons/prompt-capture/`, the same reclaimable
  place the clipboard history uses: nothing here is an archive — the notes file is where
  a prompt is *kept* once it is sent.
- **The badge says which agent** — 🅒 Claude, 🅖 Copilot, 🤖 unknown. Both capture hooks
  (`~/.claude/hooks/capture-prompt.sh`, `~/.copilot/hooks/capture-prompt.sh`) now append
  `?src=` to the same route; a hook that sends none still captures, just unbadged, so the
  parameter can never become a reason a prompt is lost.
- **`sent` is the whole state.** The pill's hover (`offerPrompt`'s new `onAccepted`) and
  the panel's Send button set the same flag, so a prompt that already reached the
  participants' Prompts tab shows a retired "Sent" button instead of offering the room
  the same line twice. The flag is also why this is a store and not a log.
- **One block-list, two consumers.** `PromptCapturePolicy.blockedPrefixes` (today just
  `<task-notification>`) is now the single source `SessionNotesAppender` reads too —
  a text the pill refuses to offer must not turn up in the panel with a live Send button.
- **Sending writes into *today's* notes**, because `writeNotes` only ever knows the current
  session folder. That is deliberate: a prompt from Monday sent on Wednesday is Wednesday's
  contribution to the room. With no session running there is no notes file at all, and the
  failure flashes in the bottom-left banner (`SessionNotesAppender.sendPrompt` →
  `reportWriteFailure`) — the panel can be open on a day with nothing to write to.
- **No shortcut, by design.** The row is read between topics, never mid-gesture, and the
  ⌘⌃ sheet is full. The panel opens centred on **the screen under the mouse**, not the
  built-in retina — that one is what the room sees.

Test hook: `GET /test/prompt-history` (`?clear=1` empties the week first) — see `testing.md`.

**Notes banner — the pill carries the notes marker (2026-08-14).** Both bottom-left notes pills now open with the very emoji their line will carry in the notes file, straight off `SessionNotesAppender.Marker` (one source, so the two can't drift): an **intercepted agent prompt** shows as `🤖 <text>` and an **intercepted / hand-sent text** as `📋 <text>` — the latter replacing the word `Pasted:`, since the mark is recognised faster than the word and it is the same mark the reader will meet again in the notes list a moment later. Previously the prompt pill had no prefix at all and the paste pill spelled its verb out, so at a glance the two flows were the one thing the pill didn't say — which is exactly what the markers were introduced to disambiguate in the file itself.

**Notes banner — outcome-flavored exits (2026-06):** Every *interactive* bottom-left pill ends one of two ways, and the exit animation tells the user **which**, so the gesture and the feedback match:
- **`dismissRisingFade()` — accept / commit.** The pill (and its hint) float straight up ~140px while fading over **~1s** (`.easeIn`), as if the text lifts off into the notes. Used when you **hover-confirm "Send prompt to notes?"** and when a paste's undo window **lapses un-hovered** (it stuck).
- **`dismissSinking()` — cancel / say "no / stop".** The pill (and its hint) slide straight **DOWN** off the bottom of the screen over **~0.7s** (`.easeIn`, no fade — it's anchored at the bottom edge, so dropping it past its own height carries it fully out of view), the mirror image of the rising "accept". Used when you **hover-to-undo a paste** and when you **hover-to-snooze the 😶 silent-transcription warning** (`SilentTranscriptionWarning.snooze`) — in both cases the downward motion alone reads as "dismissed / put away".
- Wiring lives in `SessionNotesAppender`: a banner-free **`writeNotes`** core feeds both entry points (`pasteAndOfferUndo` for keypress pastes, the `offerPrompt` hover handler for prompt-capture); **`performUndo` returns `Bool`** so the caller sinks the pill *only* when the undo actually landed. The old `"↩️ Undone"` / `"pasted in notes"` text flashes are gone — the animation **is** the feedback. The hover-approve window itself is `hoverActionDuration` (**7.5s**). The notes flows and the silent-warning snooze use the rising/sinking pair; status banners still use plain `dismiss()`.
- **A pill may only paint on its own screen (`PillPlacement`, 2026-09-08).** The banner builds one panel per screen, and every gesture moves that panel *as a window*: the ±10 pt hover nudge, the +140 pt rise, the −150 pt sink. A window that leaves its screen does not disappear, though — it is drawn on whatever display the arrangement puts there, and the displays here are not islands: one DELL sits directly ABOVE the built-in retina, so **that monitor's bottom edge and the retina's top edge are the same line**. Its pill sliding 150 pt "off the bottom" was therefore drawn 60 pt below the retina's top: a full pill flashing across the top of the *projected* screen for the last ~80 ms of **every un-hovered prompt offer** (measured with `CGWindowListCopyWindowInfo`: the panel's CG y went −90 → 38 → 56, i.e. straight into the retina, then `orderOut`). Nothing was mis-computed — the frame was exactly what the code asked for; the code asked for a point belonging to another display. The rule now: **downward motion never moves the window.** It stays parked on its screen's bottom edge and the pill slides down INSIDE it, clipped at that edge — the same "slides off the bottom" look, with no pixel able to land anywhere else. Upward motion still moves the window (bounded by 140 pt on a screen a thousand points tall, and the pill has to stay *visible* while it floats). The split is the whole of `PillPlacement` (pure + unit-tested against the real arrangement); `BottomLeftBanner.place(_:offset:duration:)` is the only thing that positions a panel, so the nudge and both exits inherit it. The sink also lost its `NSAnimationContext` window animation on the way — it is now the same imperative 60 Hz timer as the rise, one driver per frame — and it turns `ignoresMouseEvents` on as it starts, since a window that no longer travels with the pill would otherwise sit invisibly swallowing clicks in the corner where the hand rests.
- **A parked cursor is not a decision (`HoverMotionGate`).** The 2 s hold that fires `onHover` used to require only that the cursor be *inside* the pill — and the pill sits in the bottom-left corner, exactly where a hand naturally leaves the mouse, so a prompt sent itself to the notes (or a paste undid itself) with nobody touching anything. The dwell now also requires the cursor to keep **moving**: in every **0.5 s slice** it must travel at least **4 pt** (rolling anchor, so a slow continuous drag counts as well as a jiggle; 1 px trackpad jitter does not). A slice with no movement **zeroes the dwell progress** — the whitening/nudge visibly falls back to rest — and the gate re-arms, so moving again rebuilds it from zero. Motionless = never fires, however long the cursor stays. The rule is pure + unit-tested in `HoverMotionGate`; `BottomLeftBanner.tickHoverDwell` is the only caller.
