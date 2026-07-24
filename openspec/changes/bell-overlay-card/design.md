## Context

VictorAddons is a single always-running Swift/AppKit menu-bar app. It embeds a local WebSocket server (`LocalWebSocketServer`, `ws://127.0.0.1:8765`) to which the training-assistant daemon connects as a client. Today the server handles `display_emoji` (relayed to the on-screen `EmojiAnimator`), `session_started`/`session_ended`, `pdf_export_alarm`, and `ping`; unknown message types are logged and ignored (`handleText()`). Each message type maps to a typed callback the server exposes (`onEmoji`, `onSessionMessage`, `onPdfExportAlarm`, …) which `AppDelegate` wires up during startup.

The overlay already has all the primitives this change needs:
- **`BottomLeftBanner`** — a bottom-left overlay panel with `show(text:backgroundColor:hoverNudge:)`, `dismiss()`, `dismissSinking()`, `isVisible`, `hoverable: Bool` at construction, and an `onHover` callback that fires once when the cursor enters. `HoverNudge` is `{ none, up, down }`.
- **`SilentTranscriptionWarning.swift`** — a compact controller that owns a `BottomLeftBanner(hoverable: true)`, sets `banner.onHover = { self.snooze() }`, plays a chime via `NSSound`, and calls `banner.show(text:, backgroundColor:, hoverNudge: .down)` with **no auto-fade** so the banner persists until hover. This is a near-exact template for the bell card.
- **`SoundManager.shared`** — `play(_ filename:volume:bluetoothCompensated:)` for bundled sounds; `NSSound(named:)` for system sounds.
- **`TabletHttpServer`** — the `GET /test/*` headless preview hooks (e.g. `/test/presentation/warn`, `/test/group-photo`) that show overlay UI without stealing focus, for testing during a live session on the right-hand external screen (never the projected retina).

The **contrast with a native macOS notification is the whole point**: as the `GroupPhotoBreakPolicy` note records, macOS silently suppresses native notifications for this locally-signed, un-entitled app while PowerPoint is presenting fullscreen. The app's own always-on-top `BottomLeftBanner` shows regardless — which is exactly why the bell must be a banner card, not `NSUserNotification`.

## Goals / Non-Goals

**Goals:**
- Accept the shared `bell_ring` message on the existing local WS server and surface it as a typed `onBellRing(caller)` callback.
- On a bell: play a bell sound and show a **persistent, hover-dismissible** bottom-left card reading exactly `🔔 [Name] is calling you`.
- Support a small **stack** so several near-simultaneous bells are each visible, not overwritten.
- Reuse `SilentTranscriptionWarning.swift` as the controller template and the existing sound/banner primitives — minimal new surface.
- Provide a `GET /test/bell` headless preview hook.

**Non-Goals:**
- No native `NSUserNotification` (suppressed during fullscreen presenting — see Context).
- No changes to the daemon or the web participant page (those live in `training-assistant` change `attention-notifications`).
- No auto-fade / timed dismissal — the card is persistent by design.
- No per-caller identity beyond the name string in the message (no avatars/colours in phase 1).

## Decisions

### D1: New `bell_ring` case + `onBellRing` callback on the WS server
Add `var onBellRing: ((String) -> Void)?` near the other `on*` callbacks (~ line 9) and, in `handleText()` (~ line 192), a branch mirroring `display_emoji`:
```swift
case "bell_ring":
    let caller = json["caller"] as? String ?? "Someone"
    DispatchQueue.main.async { [weak self] in self?.onBellRing?(caller) }
```
`caller` falls back to a neutral "Someone" if absent, so a malformed message never crashes and still alerts the host. As with emoji, the message may also be relayed to other connected clients if that pattern is kept; the bell has a single consumer (the overlay) so relaying is optional.

**Alternative considered:** overloading the emoji path with a special "bell emoji" — rejected; the bell needs a persistent card, not a flying-up sprite, and a distinct type keeps the protocol legible.

### D2: Dedicated bell-card controller copied from `SilentTranscriptionWarning`
Create `BellCard.swift` (name TBD) as a small controller that owns a `BottomLeftBanner(hoverable: true)` with `banner.onHover = { [weak self] in self?.dismiss() }`. On a bell it calls:
```swift
banner.show(text: "🔔 \(caller) is calling you",
            backgroundColor: <bell tint>,
            hoverNudge: .down)   // previews the sinking "put away" exit
```
with **no auto-dismiss timer** — the card stays until the host hovers it, at which point `banner.dismissSinking()` runs (the same "put away" gesture the silent-warning uses). The tint is a distinct bell colour (e.g. a warm amber/orange) so it reads differently from the red silent-warning.

**Alternative considered:** reuse the shared `StatusBanner` used for "started"/"paused" flashes — rejected because those auto-fade; the bell must persist and be hover-dismissible, which is precisely the `SilentTranscriptionWarning` shape.

### D3: Stacking multiple bells
If a second bell arrives while a card is showing, the controller SHALL keep both visible rather than overwriting. Options: maintain a small array of `BottomLeftBanner` instances offset vertically, or coalesce into a single card that lists callers ("🔔 Ana + Dan are calling you"). Phase 1 default: a **small vertical stack** of independent cards (cap ~3, oldest hover-dismissed or auto-collapsed beyond the cap), since each caller wants their own acknowledgement. The exact stacking geometry is a flagged detail (Open Questions).

### D4: Bell sound
Play a bell/chime on each bell via `SoundManager.shared.play("<bell>.mp3")` (a bundled sound) or `NSSound(named:)` for a system sound (e.g. "Glass"/"Ping"), matching how `SilentTranscriptionWarning` plays `NSSound(named: "Basso")`. The specific asset is a flagged detail.

### D5: Headless test hook
Add `GET /test/bell` (and optionally `GET /test/bell?name=<n>`) to `TabletHttpServer`, wired in `AppDelegate` like `/test/group-photo`, to show a bell card with a sample name immediately — bypassing the need for a live daemon connection — so the card can be verified on the right-hand external screen during a session.

### D6: Shared `bell_ring` contract (documented identically in both repos)
This is the single wire contract linking `victor-macos-addons` and `training-assistant`. It is written verbatim below and in the `attention-notifications` design in the training-assistant repo.

```
Message:    bell_ring
Transport:  ws://127.0.0.1:8765   (the addons-owned local WebSocket server;
            the daemon connects as a client via AddonBridgeClient)
Direction:  daemon → overlay      (in docs/addons-ws.yaml terms: a `subscribe`
            message — one the daemon sends TO addons)
Payload:
    {
      "type":   "bell_ring",
      "caller": "<participant display name>"
    }
Fields:
  - type   (string, required): the literal "bell_ring"
  - caller (string, required): the ringing participant's resolved display name.
           Real name once `participant-real-names` lands; otherwise the current
           fictional/assigned name. Never the raw UUID when a name is known.
Semantics:  Fire-and-forget, best-effort. If the overlay is not connected the
            daemon logs the drop and returns success to the participant (no
            error surfaces). On receipt the overlay plays a bell sound and shows
            a PERSISTENT, hover-dismissible bottom-left card reading exactly
            "🔔 [caller] is calling you" (caller name substituted). Multiple
            bells may stack. There is no auto-fade timer — the card stays until
            the host hovers it away.
```

## Risks / Trade-offs

- **Bell spam → many stacked cards.** The daemon side throttles/rate-limits rings (training-assistant `attention-notifications`), so the overlay can trust the arrival rate; the stack cap (D3) is a second line of defence.
- **Caller name may not be "real" yet** (pre `participant-real-names`) → the card shows the current fictional name; acceptable and self-correcting once real names ship in the daemon.
- **Card persists — could linger if unattended.** By design (the host must acknowledge). If a lingering card proves annoying, a generous auto-collapse could be added later; phase 1 keeps it hover-only per the user's decision.
- **Testing on the projected retina.** Per repo convention, do visual verification on the right-hand external screen, never the projected retina; `/test/bell` supports this.
- **Stronger than the reverse direction.** Because the overlay is a native always-running app, the bell reliably reaches the host even over fullscreen PowerPoint — unlike the host→participant browser direction. This asymmetry is expected.

## Migration Plan

1. Ship this overlay change; `bell_ring` handling + `/test/bell` are live on the next `build-app.sh` + app restart. With no daemon sending `bell_ring` yet, nothing changes at runtime except the new (dormant) code path and the test hook.
2. Ship the training-assistant `attention-notifications` change so the daemon sends `bell_ring` on a participant ring.
3. Verify end-to-end: participant taps the bell → daemon logs + forwards → overlay plays sound + shows the card.
4. Ship order is independent: an older overlay logs-and-ignores `bell_ring`; a newer overlay with no daemon support simply never receives one.

## Open Questions

- **[FLAG] Stacking model:** independent stacked cards (cap ~3) vs a single coalesced card listing callers. Default: a small vertical stack.
- **[FLAG] Bell sound asset:** a bundled bell mp3 vs a macOS system sound (e.g. "Glass"/"Ping"); confirm the choice and volume.
- **[FLAG] Card tint:** the background colour distinguishing the bell card from the red silent-warning (proposed: warm amber/orange).
- **[FLAG] Card longevity:** confirm hover-only dismissal with no auto-collapse for phase 1 (matches the user's "persistent" decision).
