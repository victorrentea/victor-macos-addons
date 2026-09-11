# Live-Session Overlays & the addons ↔ effects contract

WebSocket-driven participant reactions, the join-link banner, and the seam
between this app and **Victor Effects**.

> **The effects moved.** Every desktop effect, `EmojiAnimator`, `SoundManager`,
> the sound→effect map, the 🔥 whip and the soundboard live in the separate
> public repo [`victor-effects`](https://github.com/victorrentea/victor-effects)
> since 2026-09. What each effect draws, how long it lives, and why it looks the
> way it does is documented there (`victor-effects/docs/overlay-effects.md`).
> **Do not re-document an effect here.**

## Overlay components still in this app

- **`JoinLinkBanner`** — the participant join URL and its QR at the top of the
  screen; auto-hides after 20 s with a 3 s fade-out. Its own `NSPanel`, with no
  dependency on anything that left.
- **`LocalWebSocketServer`** — the link to the training-assistant daemon on
  `/ws/__overlay__`: session lifecycle (`session_started`, `session_ended`,
  which enable/disable the join-link menu item), the 🔔 bell card, the pdf
  alarms, and the **client count that is the classroom participant count in the
  menu bar**. That last one is why the server stayed here even though its emoji
  traffic is forwarded.
- **🟢 Interact Link** (menu row) — shows the participant join URL banner;
  enabled while a session is active.
- **`AddonsOverlayPanel` + `MinuteToken`** — the one piece of drawing that did
  *not* leave. See the coffee section below.

## The contract with Victor Effects

This app keeps **55123**; the effects app listens on **55124**
(`EffectsProxy.baseURL`, overridable with `VICTOR_EFFECTS_URL` or the
`Effects.baseURL` default). `EffectsProxy.forward` runs on the **server queue**,
never the main thread — a slow or absent effects app must not be able to freeze
the menu bar.

**Why the port did not move.** Seven local clients point at 55123 — the IntelliJ
plugin's baked default URL, the VS Code extension, `hands-off.sh`, the Chrome
extension, the prompt-capture hook, the test scripts — plus
`adb reverse tcp:55123` on the tablet's USB link and the relay, which calls
`TabletHttpServer.respond` in process and therefore covers the forwarded routes
for free. Moving them is a marketplace release and a dozen edits; one loopback
hop (~1 ms) on `/sound/play` is invisible next to the tablet's own Wi-Fi RTT.

### What is forwarded

Everything under `/effect/`, `/sound/`, `/sounds/`, `/alarm/`,
`/bt-compensation`, `/tiles`, plus `/state`, `/ping` (merged), and the historic
`/test/<effect>` aliases — **verbatim, query string included**, because a
percent-encoded flag or emoji must not be re-encoded on the way through.

### What stays local

`TabletHttpServer.localEffectNames` — exactly three:

| name | why it stayed |
|---|---|
| `training-end` | needs whisper's `VICTOR_VOICE` pulse to know the room went quiet, and that listener never left this process |
| `stop-all` | runs the local half first (stop the 🎵 soundtrack, disarm 🏁) **and then forwards**, in that order — the tablet's stop-all → play → pressed chain depends on it |
| `focus-playlist` | opens a Chrome tab; nothing is drawn, so nothing moved. Its `/test/` alias stays local with it |

Only the exact name is local: `/effect/training-end/stop` is not a carve-out for
its children and is forwarded like anything else.

### The `/ping` merge

The tablet parses **one** object, so the two halves are concatenated rather than
nested — which is why the effects app's `/ping` must stay a flat object.

- The effects half brings `soundsHash`, `tilesHash`, `effectsVersion`,
  `tabletVolume`, `panelMonitor`.
- This half brings a fragment (`onPingExtras`, collected through a short
  `DispatchQueue.main.sync` that only reads state): the Mac's clock and timezone,
  `macLanIps`, the phone-battery mirror, the screen-lock mirror,
  `trainingEndArmed`.
- Plus `effectsUp`.

**With the effects app down the answer is still `ok`, with an empty
`soundsHash`.** That is load-bearing: `MacLink.refreshSyncState` returns early
on an empty hash, so the tablet shows no amber "the Mac is stale" dot; its
`/sound/play` then gets a **404** (`effects-down`) and it plays locally.
Everything else answers **503**. Anything unparseable coming back from the
effects app is reported as down rather than spliced in, where it would break the
tablet's parser instead of one field.

`/ping` is allowed **1.5 s**, shorter than the general 3 s: the tablet pings
every 5 s and a late merged answer is worse than one saying `effectsUp:false`.

### Calls this app makes outward

`EffectsProxy.fire` (fire-and-forget, utility queue, nothing awaited and nothing
reported — a log line about a missed effect during a workshop is noise):

| trigger | fires |
|---|---|
| participant emoji over the WS (`LocalWebSocketServer.onEmoji`) | `/effect/emoji?e=&count=&glow=` |
| ⌘⌃O elephant | `/effect/elephant` |
| ⌘⌃Q Claude mascot | `/effect/claude-peek` |
| 🏁 `TrainingEndSequence` countdown | `/effect/progress-bar/<s>?rider=🏁`, `/effect/progress-bar/stop` |

### The one call inward: ☕

The coffee hold-charge gesture — the floating ☕, the 10 Hz cursor tick, the
charge, the pixel dissolve — is all in the effects app now, because that is
where the pixels are. **The payoff never left**: each explosion arrives as one
`GET /effects/event?type=coffee-popped&x=&y=` (`TabletHttpServer.effectsEvent` →
`AppDelegate.onEffectsEvent`), which either starts the 10-min "UNTIL BREAK"
timer zooming out of the blast, or flies a `−1` at a running break.

A webhook **per pop** rather than a batch per tick is what keeps the "first one
starts the timer, the rest fly their minute at it" rule working: the first event
has already flipped `breakTimer.isShowing` by the time the second arrives.

`MinuteToken` is the one drawing that stayed, and `docs/break-timer.md` explains
why: its target is re-sampled every frame, which a cross-process call cannot do.

## The lifecycle rule, restated

**Every overlay effect must self-terminate at its sound's length — a network
stop message is an optimisation, never the only teardown.** It is enforced in
the effects app now, but it matters *more* since the split: a lost
`/sound/stopped` is now also a lost proxy hop. The rule itself, with the
`trackEffect` / identity-guard mechanics, is documented in
`victor-effects/docs/overlay-effects.md`.

## Sound → effect mapping, in one line

A client reports `GET /sound/pressed/<file>` and `GET /sound/stopped/<file>` by
bare filename and **the Mac** decides which visual goes with it. That decision
(`SoundEffectMap`) is now the effects app's; this app only forwards the two
routes. Changing a pairing still needs no client redeploy — it just needs the
*other* app rebuilt.
