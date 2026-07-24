# Phase 1 — Bell card overlay (receive bell_ring → sound + persistent card)

## 1. WS server: accept bell_ring

- [x] 1.1 Add `var onBellRing: ((String) -> Void)?` to `LocalWebSocketServer.swift` near the other `on*` callbacks (~ line 9).
- [x] 1.2 Add a `case "bell_ring":` branch in `handleText()` (~ line 192): read `caller = json["caller"] as? String ?? "Someone"` and `DispatchQueue.main.async { self?.onBellRing?(caller) }`, mirroring the `display_emoji` handling.
- [x] 1.3 Confirm malformed/unknown messages still log-and-ignore (no crash), keeping existing message types unaffected.

## 2. Bell card controller (copy the SilentTranscriptionWarning template)

- [x] 2.1 Create `Sources/VictorAddons/BellCard.swift` by copying `SilentTranscriptionWarning.swift`: own a `BottomLeftBanner(hoverable: true)`, set `banner.onHover = { [weak self] in self?.dismiss() }`.
- [x] 2.2 Implement `show(caller:)` → `banner.show(text: "🔔 \(caller) is calling you", backgroundColor: <bell tint>, hoverNudge: .down)` with NO auto-fade timer (persistent until hover).
- [x] 2.3 Implement `dismiss()` → `banner.dismissSinking()` (the "put away" gesture), matching the silent-warning snooze exit.
- [x] 2.4 Choose the card tint (distinct from the red silent-warning; proposed warm amber/orange) — confirm at approval (design Open Question: card tint).

## 3. Bell sound

- [x] 3.1 Play a bell sound on each bell — `SoundManager.shared.play("<bell>.mp3")` for a bundled asset, or `NSSound(named:)` for a system sound (mirroring `SilentTranscriptionWarning`'s `NSSound(named: "Basso")`).
- [x] 3.2 Confirm the sound asset + volume at approval (design Open Question: bell sound asset).

## 4. Stacking multiple bells

- [x] 4.1 Support a small stack so a second bell does not overwrite the first (vertical stack of independent cards, cap ~3, or a coalesced "🔔 Ana + Dan are calling you" card) — confirm the model at approval (design Open Question: stacking model).

## 5. AppDelegate wiring

- [x] 5.1 Construct the bell-card controller alongside the other banner owners (~ line 800, next to `silentTranscriptionWarning` / `promptCaptureBanner`).
- [x] 5.2 Set `wsServer.onBellRing = { [weak self] caller in self?.<bellCard>.show(caller: caller) }` in the WS wiring block (~ lines 169–194, next to `wsServer.onEmoji`), playing the sound and showing/stacking the card.

## 6. Headless test hook

- [x] 6.1 Add `GET /test/bell` (optionally `?name=<n>`) in `TabletHttpServer` + `AppDelegate` route wiring (mirroring `/test/group-photo`) to show a bell card with a sample name immediately, bypassing the daemon-connected gate.

## 7. Verification

- [x] 7.1 `swift build && swift test` — add a Swift test for `bell_ring` parsing → `onBellRing(caller)` (present name and missing-name fallback).
- [ ] 7.2 Manual: `GET /test/bell?name=Ana%20Pop` → confirm the card reads `🔔 Ana Pop is calling you` on the right-hand external screen (never the projected retina), plays the sound, persists, and hover-dismisses.
- [ ] 7.3 Manual: send `{"type":"bell_ring","caller":"Dan"}` via `wscat`/`websocat` to `ws://127.0.0.1:8765` → confirm the card + sound end-to-end.
- [ ] 7.4 Manual: fire two bells quickly → confirm both callers are represented (stacking).
- [ ] 7.5 After changes: push to master, `./build-app.sh`, then restart (`pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"`), per repo convention.

<!-- Manual verification tasks (7.2–7.5) require building and running the app. -->

---

# Later stage — NOT part of phase-1 delivery

## 8. Richer bell identity (deferred)

- [ ] 8.1 Carry a per-participant colour/avatar in `bell_ring` (like the emoji `glow`) so stacked cards are visually distinct per caller.

## 9. Host acknowledgement back to the participant (deferred)

- [ ] 9.1 Let the host dismiss a bell with an acknowledgement that flows back to the ringing participant (needs a new overlay → daemon → participant path); out of scope for phase 1.
