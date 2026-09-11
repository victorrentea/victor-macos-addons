# Audio, Sounds & Bluetooth Output

Everything that ducks, pauses or protects sound on this Mac. NB: Bluetooth here
means the speakers plugged into the laptop's ears — playback hygiene — never
connectivity; the tablet↔Mac transport lives in `tablet.md`.

> **The soundboard moved.** Tablet→Mac sound *routing*, the `SoundsManifest`
> anti-drift hash, the 0.2 s interrupt fade, the Bluetooth wake-up compensation
> and `BluetoothKeepAlive` all went to **`victor-effects`** with the effects
> they belong to, and are documented in
> `victor-effects/docs/sound-routing.md`. Their routes (`/sound/*`,
> `/sounds/manifest`, `/bt-compensation*`) still answer on 55123 — this app
> forwards them (`docs/overlay-effects.md`).

- **Mute 🎶 (auto)** — drops `🔊OS Output` device volume to 1% during Wispr Flow dictation, restores on stop. `CoreAudioManager` runs a single self-rescheduling `DispatchSourceTimer` on a serial `pollQueue`: normal cadence is 300ms; each Mouse 5 press extends a `boostedUntil` deadline by 1s during which the next ticks are scheduled 100ms apart. The Mouse 5 click handler also probes the loopback immediately (~150ms RMS/peak window, thresholds RMS 0.0002 / peak 0.0005) and — if music is playing — does a **speculative mute** without waiting for Wispr's recording state, capturing the current volume into `originalVolume` and setting `kAudioDevicePropertyVolumeScalar` to 0.01. Polls then confirm via `kAudioProcessPropertyIsRunningInput` on `com.electron.wispr-flow.*`. Restore is debounced: on Wispr `1→0` (or on a speculative mute that Wispr never confirms) we wait 1000ms of stable `recording=false` before restoring `originalVolume`; any `recording=true` read inside that window cancels the pending restore (`firstNotRecordingAt = nil`). The loopback check is **not** consulted on restore (a muted device reads silent and would falsely cancel restore). All state (`volumePushedDown`, `originalVolume`, `firstNotRecordingAt`, `boostedUntil`, `nextDeadline`) lives entirely on `pollQueue`, so reads/writes are sequential. Mouse 5 is observed via the event tap and passed through (Wispr still sees it); behavior on other triggers (right Opt-Cmd, hotkey, UI button, VAD, ESC) falls back to the boosted-or-normal poll alone. Caveats: an app crash mid-mute leaves the volume at 1% until next Wispr cycle; a manual volume-slider tweak during dictation is overwritten on restore. **The output-route guard is gone** (2026-08-29). It posted a native notification on each Wispr-start when the default output was not `🔊OS Output`, on the reading that the ducking is then inert. Two things ended it. The JBL boxes now grab the default output the moment they connect, so "not the loopback" became the normal state rather than a drift; and the dictation window now **pauses** Chrome rather than ducking a device, which works whatever the output is. The alert therefore fired on every single dictation to report a fallback that was no longer needed. `OutputDriftPolicy`, its tests, the callback and `/test/wispr-output-drift` went with it; the volume path itself is untouched and still runs when the loopback *is* the default output.

**Pausing the music during dictation (`DictationBridge` + `chrome-extension/`).** The older reflex drops the `🔊OS Output` volume to 1% — which only works while that loopback is the default output, so it went inert the day the JBL boxes started grabbing the output. The replacement pauses instead of ducking, and asks Chrome rather than the hardware. **The edges:** `CoreAudioManager` now registers an `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyProcessObjectList`. Measured on this Mac, Wispr Flow's audio process object is present in that list **only while it is recording** and vanishes when dictation stops — so the list change *is* the edge, pushed by `coreaudiod` with no timer wakeups. The old 300 ms poll is kept purely as a safety net and slowed to **1 s**; the Mouse-5 speculative path stays, because a press is *ahead* of any edge. The `dictationActive` latch is deliberately separate from `volumePushedDown`: pausing needs no loopback probe (the extension knows which tabs are audible), so it survives any output-device choice, and it closes on the same 1 s stable-not-recording debounce so a flicker in Wispr's `isRunningInput` doesn't stutter the music. Note our own live transcription (`org.python.python`) holds `IsRunningInput` **permanently** true — filtering by bundle id in `isWisprRecording` is the only thing keeping it out of the decision. **The transport:** `ChromeBridge` (was `DictationBridge` until the extension grew a second job), a push-only WebSocket on **127.0.0.1:8766**, sending `{type:"dictation", active, seq}`. It does *not* reuse `LocalWebSocketServer` (:8765) because that one's client count is the classroom participant count in the menu bar. It pings every 20 s — an MV3 service worker is torn down after ~30 s idle, and socket traffic resets that timer — and replays the current state to each client on connect, so a worker that *was* torn down mid-dictation learns it still owes a resume. `GET /test/dictation?active=0|1` on :55123 forces the window without dictating. **The Chrome half:** `chrome-extension/` — the **Victor Chrome Addons** extension (load unpacked once per profile); `background.js` owns the socket and dispatches by message type, `dictation-pause.js` is this feature. See [docs/feedback-form.md](feedback-form.md) for the other one. Why it must live in Chrome at all — CoreAudio funnels every tab through a single Chrome audio helper process, so from outside, "Chrome is making sound" is the finest grain obtainable; `chrome.tabs.query({audible: true})` is the per-tab answer. On pause it marks each element it actually stopped (`data-va-dictation-paused`) and on resume plays back **only** those — a tab the user had already paused by hand is left alone. Latch and tab ids live in `chrome.storage.session`, not in a worker variable, for the same teardown reason. **Layering:** the volume-duck path is untouched and still runs; because the pause fires on the Mouse-5 press and the loopback RMS probe ~150 ms later reads the now-silent tabs, the ducking simply no longer triggers for Chrome audio — it stays as the fallback for music from anything that is not Chrome.

**JBL speakers grab the output when they connect (`BluetoothAutoOutput` + `BluetoothAutoOutputPolicy`).** macOS only *sometimes* re-routes to a Bluetooth speaker on connect; when it doesn't, the next soundboard hit plays out of the laptop in front of a room. So the app watches the CoreAudio device list and, when a connected Bluetooth output whose name contains `JBL` (`BluetoothOutput.speakerNameMatch`, shared with the keep-alive) **appears**, writes it into `kAudioHardwarePropertyDefaultOutputDevice`. **No polling, no battery cost:** it is an `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDevices` — `coreaudiod` pushes a callback only when a device actually appears or disappears, which for a BT speaker is exactly the connect/disconnect moment; between events the app schedules no wakeups at all (strictly cheaper than the keep-alive that used to sit next to it, and which now runs in the effects app). A speaker is listed a moment before CoreAudio will accept it as the default output, so the write is attempted immediately and re-verified at **+1 s and +2.5 s**, then given up on — three bounded attempts per connect edge. The trigger is the **appearance edge only**, which is what stops it fighting the user: with the JBL still connected, switching the output by hand to the headphones or to `🔊OS Output` changes no device list, so nothing pulls it back; the snapshot seeded at startup is ignored for the same reason, so relaunching the app never hijacks a chosen output. Devices without output channels are filtered out (a BT headset also registers an input-only HFP device). Pure edge logic + tests: `BluetoothAutoOutputPolicy` / `BluetoothAutoOutputPolicyTests`. ⚠️ Interaction: while the JBL is the default output, the Wispr music-duck above is inert (it needs `🔊OS Output` as default) and will post its drift notification on the next dictation.

## The three sounds this app still plays (`AddonSounds`)

Going over HTTP for these was rejected outright: **"the break is over" must be
audible whatever else is running**, and a gong that depends on a second process
is a gong that will one day not ring. So this app keeps a thin player of its own
and its own `Resources/sounds` symlink into the tablet's assets (dereferenced
into the bundle by `build-app.sh`).

Three callers, and only three:

- **`BreakTimerOverlay`** — the ☕️ break gong: two full strikes at expiry, and
  the interrupt when the watch is closed mid-strike (`stopOverlapping` with
  `fade: 0`, because closing the watch means silence *now*).
- **`LidAwake`** — 💓 `13_heartbeat.mp3` and 🫀 `15_flatline.mp3`.
- **`TrainingEndSequence`** — 🏁 `82_over_and_out.mp3`.

`AddonSounds` deliberately keeps **only** what those three need: `soundURL(for:)`,
`soundDuration`, `play`, `playOverlapping`, `stopOverlapping`, and
`currentBluetoothCompensation` — read from `sound-timing.json`'s
`macBluetoothCompensationMs` as a **file default** (`fileCompensationSeconds`),
clamped to `maxCompensationSeconds`. It does not keep the routed
player, the preempt/fade semantics, the paired-effect lead table or the
pending-visual compensation — those belong to the soundboard, which left.

One accepted consequence: the tablet's **BT wake** slider now only reaches the
effects app, so the gong reads the file default (800 ms) rather than the live
override. It affects the gong's auto-close margin by at most ~1.2 s and nothing
else.

`BluetoothOutput` is kept here in trimmed form — `defaultOutput`,
`outputDevices`, `setDefaultOutput`, `deviceName`, `makeSilentToneWav`,
`playWakeTone`, `speakerNameMatch` — because `BluetoothAutoOutput` and
`SystemOutputVolume` still use it. The keep-alive's continuous-warm half went
with the whip.
