# Victor macOS Addons

macOS utilities for live training workshops, running on the trainer's Mac.
Single menu bar app (💬 icon) provides all functionality.

**This file is a router, not documentation.** The full docs — every decision, what
was tried and failed, the numbers that were measured — live in `docs/*.md`, split by
feature zone. **Read the zone's doc BEFORE touching its code**; the details there are
load-bearing, not commentary.

## Architecture

- **Single Swift process**: `VictorAddons` is the main application combining menu bar UI and overlay functionality
- **LaunchAgent**: `ro.victorrentea.macos-addons.plist` — starts on login, no KeepAlive
- **Components**: All features run in same process with direct method calls (no IPC needed)
- **Sources**: `Sources/VictorAddons/*.swift` (~94 files); Python sidecars in `whisper-transcribe/`, plus `powerpoint-monitor` / `intellij-monitor`

**Tech**: Swift, AppKit, AVFoundation, Swift Package Manager; Python 3.12 sidecars; `claude -p` on the subscription (sonnet, for the ⌘⌃V distillation)
**Build**: `swift build && swift test`
**Secrets**: `AGENTMAIL_API_KEY` in `~/.training-assistants-secrets.env` (📬 Flux inbox). The two Anthropic keys in that file — `ANTHROPIC_API_KEY` and `WISPR_CLEANUP_ANTHROPIC_API_KEY` — are **out of credit and nothing in this app uses them any more**; they are also why every `claude` launcher here starts with `env -u ANTHROPIC_API_KEY` (an exported dead key shadows the subscription and fails auth).

## Documentation map

| doc | covers |
|---|---|
| [docs/transcription.md](docs/transcription.md) | 💬 Whisper live transcription (AC-power-driven), heartbeat + output watchdog, 🎙️ "Ce tocmai am spus" picker (⌘⌃V, `TranscriptDistiller`), the `whisper-transcribe` Python engine (PortAudio discipline, supervised threads, quiet crashes) |
| [docs/keyboard-overlays.md](docs/keyboard-overlays.md) | ⌨️ hold-to-see cheat-sheets (`KeymapOverlay`): ⌥ / ⌥⇧ emoji sheet + ⌘⌃ shortcut sheet, pictograms, accents, sync tests |
| [docs/hotkeys-launchers.md](docs/hotkeys-launchers.md) | 🤖 terminals ⌘⌃C/Q/T + quarter placement + tiling, 📝 ⌘⌃N notes doc, 📕⌘⌃K / 📧⌘⌃G / 📅⌘⌃L openers, ✉️ ⌘⌃M TO DO mail (`GmailCompose`), 📋 ⌘⌃Z/E/R snippet paste, 🎧 ⌘⌃F focus playlist (`FocusPlaylist`), 🎯 ⌘⌃D Walkie Talkie bind, ⌘⌃⌥D dark mode, Wheel×2 re-paste, 🔎 Cmd+scroll terminal font zoom (`TerminalZoomSizeLock`) |
| [docs/session-notes.md](docs/session-notes.md) | 📝 ⌘⌃S selection-or-clipboard → notes (`SessionNotesAppender`), ⌃⌥V, bottom-left notes pills: markers, rising/sinking exits, `HoverMotionGate` |
| [docs/audio-sounds.md](docs/audio-sounds.md) | Mute 🎶 during Wispr dictation (`CoreAudioManager`), pauza muzicii din Chrome pe durata dictării (`ChromeBridge` :8766 + `chrome-extension/`, fronturi din listener-ul pe lista de procese audio), tablet→Mac sound routing + `SoundsManifest` anti-drift, **Bluetooth speakers**: BT wake-up compensation (`BluetoothOutput`) and `BluetoothKeepAlive` (keeps the laptop's JBL boxes out of standby so sound starts aren't clipped — audio, not networking), `BluetoothAutoOutput` (the JBL boxes take over the default output the moment they connect, via a no-polling CoreAudio device-list listener) |
| [docs/screenshots.md](docs/screenshots.md) | 📸 ⌃P screenshot: tap = full screen, hold = crosshair crop; flash geometry, retention policy, cursor marker in filename |
| [docs/break-timer.md](docs/break-timer.md) | ☕️ Break countdown overlay (seven-segment watch, country picker, fullscreen break screen, `ScreenBlackout`), ☕ coffee hold-charge → start/shorten break, 📸 Group Photo prompt |
| [docs/summaries.md](docs/summaries.md) | ☕️→📝 break-summary delta (`BreakSummaryLauncher` + `summarize-on-break.sh`), 📝 wrap-up offer at 16:45/17:15 (`SummaryReminder`) |
| [docs/flux-email-agent.md](docs/flux-email-agent.md) | 📬 AgentMail inbox poller (`FluxInboxPoller` + `FluxMailPolicy`), 📬 menu item, 📬→🤖 email agent (`FluxAgentLauncher` + `flux-agent.sh`) — **read the security posture before changing anything** |
| [docs/hotspot-fallback.md](docs/hotspot-fallback.md) | 📶 asks the phone for its hotspot when the Mac is offline: RFCOMM signal, the Samsung routine, why not Bluetooth-connected, the home geofence |
| [docs/tablet.md](docs/tablet.md) | Tablet ↔ Mac transport (USB/LAN/mDNS/Railway relay), 🎬 video playback (IINA orchestration), 🔌📶→🤖 LaunchBreak auto-deploy on USB *or WiFi* (`AndroidAppDeployer`, `WirelessTabletLink`), 📱 phone low-battery mirror (`PhoneBatteryMonitor`) |
| [docs/displays-projector.md](docs/displays-projector.md) | 🖥️ auto display arrangement (`DisplayArrangementManager`, `KnownDisplays`), 🔴 presentation detection + aggressive 😶😶😶 silent-transcription warning |
| [docs/overlay-effects.md](docs/overlay-effects.md) | `EmojiAnimator` / `ButtonBar` / `SoundManager` / `OverlayPanel` / `JoinLinkBanner` + WebSocket, 🟢 Interact Link, sound→effect map (`SoundEffectMap`), the self-termination lifecycle rule, and every desktop effect (🩸 blood, 🛰️ sonar, 💸 money, 🔫 counter-strike, ❄️ snow, ⏲️ microwave, 🕳️ iris) |
| [docs/feedback-form.md](docs/feedback-form.md) | 📝 formularul de feedback pe FreeOnlineSurveys: intrarea de meniu sub 🟢 Interact Link, comanda pe `ChromeBridge`, automatizarea din extensia Chrome, `/feedback-form/publish` + `/link/publish` + `/link/hide` + `/session/name` |
| [docs/hands-off.md](docs/hands-off.md) | ✋ the frame an agent raises while it drives the GUI (`/hands-off/*` HTTP API) |
| [docs/activity-monitors.md](docs/activity-monitors.md) | powerpoint-monitor, intellij-monitor (Python sidecars feeding the daemon) |
| [docs/menu-bar.md](docs/menu-bar.md) | menu philosophy (the menu is not a second cheat-sheet — removed rows), ☠️ Kill port, 🔥 Whip Agent item + banner chip layout, ⏱️ Resumed row colouring |
| [docs/testing.md](docs/testing.md) | all headless `GET /test/*` hooks on `127.0.0.1:55123` (`TabletHttpServer`) + `./test-transcription-control.sh` — check here before testing anything by clicking |
| [docs/deployment.md](docs/deployment.md) | `build-app.sh`, LaunchAgent install, stable code-signing identity, Accessibility grants, single-instance lock, reopen-replaces-it (`AppRelaunch`), `TerminalTiler` AX note |

## Rules that apply everywhere

- After any code change in this project, always: push to master (`git push`), run `./build-app.sh`, then restart the app (`pkill -f "Victor Addons"; open "/Applications/Victor Addons.app"`).
- After any significant design, architecture, or deployment change, proactively offer to save the decision to memory for future conversations.
- **Testing during a live workshop is fine — don't hold back.** Victor doesn't mind app restarts or transcription gaps mid-session. The only constraint: the **built-in retina display is what's projected to the room**, so do any *visual* testing (overlays, screenshots) on the **right-hand external screen** instead — never put test UI on the projected retina display. (Note: the ☕️ Break overlay's `defaultFrame()` always opens on the retina by design; drag it to the right monitor, or screenshot the right screen, when verifying during a session.)
- When documenting a change, edit the matching `docs/*.md` zone file — this index only routes.

## Related

- Backend repo: `training-assistant` (FastAPI, provides WebSocket server)
- The `start.sh` in training-assistant also builds and launches the desktop-overlay during workshop sessions
- Transcription output is consumed by training-assistant daemon for summaries and quizzes
