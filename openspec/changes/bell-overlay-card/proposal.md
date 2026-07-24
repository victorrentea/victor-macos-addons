## Why

Participants in a live workshop have no low-friction way to get the trainer's attention: unmuting or interrupting is heavy, and reaction emojis fly up and vanish. The trainer, meanwhile, is often mid-presentation with PowerPoint fullscreen on the projected retina — exactly when a native macOS notification would be silently swallowed into Notification Center. This change lets a participant ring a **bell** that reaches the trainer reliably: the always-running VictorAddons overlay app plays a bell sound and shows a **persistent, hover-dismissible card** in the bottom-left carrying the caller's name — visible even over fullscreen slides.

This is the macOS-overlay half of a two-repo feature. The web + daemon half lives in the `training-assistant` repo (change `attention-notifications`), which adds the participant bell button and the daemon router that forwards the ring. The two halves are linked by the shared `bell_ring` WebSocket message on `ws://127.0.0.1:8765`, documented identically in both proposals.

Because the overlay is a separate native app that is always running, the bell reaches the host even with the browser backgrounded or PowerPoint presenting fullscreen — a stronger delivery guarantee than the reverse (host → participant) direction, which is a browser page subject to background-tab throttling.

## What Changes

- **New**: `LocalWebSocketServer.handleText()` accepts a new `case "bell_ring":` message and exposes a new `var onBellRing: ((String) -> Void)?` callback carrying the caller's name (mirroring the existing `onEmoji` / `display_emoji` handling).
- **New**: `AppDelegate` sets `wsServer.onBellRing = { caller in … }` (next to `wsServer.onEmoji`) to (1) play a bell sound (`SoundManager.shared.play(...)` or `NSSound`) and (2) show a persistent bottom-left card carrying the caller name.
- **New**: A dedicated bell-card controller built by copying the `SilentTranscriptionWarning.swift` template — it owns a `BottomLeftBanner(hoverable: true)`, sets `banner.onHover = { dismiss }`, and calls `banner.show(text:, backgroundColor:<tint>, hoverNudge: .down)` with **no auto-fade timer**, so the card stays until the host hovers it away. Supports a small **stack** when multiple bells arrive.
- **Card copy**: exactly `🔔 [Name] is calling you` (the caller name substituted).
- **New**: A `GET /test/bell` headless test hook (via `TabletHttpServer`) that shows a bell card with a sample name, matching the other `/test/*` preview hooks.

## Capabilities

### New Capabilities
- `bell-ring-receive`: The local WS server accepts `{"type":"bell_ring","caller":"<name>"}` from the connected daemon and fires an `onBellRing(caller)` callback (parsing + callback plumbing, mirroring `emoji-receive`).
- `bell-overlay-card`: The overlay behaviour on a bell — play a bell sound and show a persistent, hover-dismissible bottom-left card reading `🔔 [Name] is calling you`, with stacking for multiple bells and no auto-fade timer.

### Modified Capabilities
<!-- No changes to existing ws-server / emoji-receive / slide-push / session specs; bell handling is additive alongside them. -->

## Impact

- `Sources/VictorAddons/LocalWebSocketServer.swift` — add `var onBellRing: ((String) -> Void)?` (~ the `onEmoji` declarations near line 9) and a `case "bell_ring":` branch in `handleText()` (~ line 192) that reads `caller` and dispatches `onBellRing` on the main queue (like `display_emoji`).
- `Sources/VictorAddons/AppDelegate.swift` — set `wsServer.onBellRing` in the WS wiring block (~ lines 169–194, next to `wsServer.onEmoji`) to play a bell sound and forward the caller to the bell-card controller; construct the controller alongside the other banner owners (~ line 800, next to `silentTranscriptionWarning` / `promptCaptureBanner`).
- New file `Sources/VictorAddons/BellCard.swift` (or similar) — the bell-card controller, copied from `SilentTranscriptionWarning.swift`.
- `Sources/VictorAddons/TabletHttpServer.swift` (+ `AppDelegate` route wiring) — add a `GET /test/bell` hook to preview the card headlessly.
- **Cross-repo dependency**: the daemon must send `bell_ring` — implemented in `training-assistant` change `attention-notifications` (`daemon/bell/router.py` + `send_bell` on `AddonBridgeClient`). Until that ships, this overlay code is dormant (no `bell_ring` ever arrives) but complete and testable via `/test/bell`.
- **Cross-change dependency**: the card shows the caller's **real name**, which depends on the `training-assistant` `participant-real-names` change. Until real names exist, the daemon forwards whatever name the participant currently has (fictional/assigned) and the card shows that.
- **No transport change**: reuses the existing loopback WS server (`ws://127.0.0.1:8765`); `bell_ring` is just a new message type — unknown types are already logged-and-ignored, so older builds tolerate it.
