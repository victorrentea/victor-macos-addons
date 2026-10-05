# Displays, Projector & Presentation Detection

- **🖥️ Auto display arrangement (projector workflow, `DisplayArrangementManager`)** — reshapes the displays automatically when a projector / room TV is plugged in or out, so Victor never re-does the venue setup by hand. Detection is `CGDisplayRegisterReconfigurationCallback` (fires on every hot-plug / mode / mirror change), **debounced ~1.2 s** so the hardware settles before we read + apply; the fix is **attempted only once per change** — we act only when the *scene* — `(hasProjector, hasASUS)` — actually changes, so if the set of monitors doesn't change there are **no further layout/mirror changes** (a manual re-layout Victor makes afterwards is left untouched). No self-loop: our own `CGCompleteDisplayConfiguration` callbacks compute the same scene and no-op, plus an `isApplying` guard + 1 s cooldown. Roles are resolved **live, not from a frozen profile** (works with any venue's projector, different EDID each time) by the pure, unit-tested **`DisplayRolePolicy`** (`DisplayRolePolicyTests`) and consult the persisted **`KnownDisplays`** ("mine") set: built-in = **Retina** (`CGDisplayIsBuiltin`); `NSScreen.localizedName` contains "ASUS" = the **ASUS MB166C** travel monitor; any **other known** external (home monitors / TV, added via "Trust current external displays") = a plain extended desktop that is **never mirrored and never disturbed**; anything else external = an **unknown = venue projector / room TV**. Two apply scenarios when an unknown external connects: **(1) projector + ASUS** → the projector *mirrors* the Retina at **1920×1080** ("what's projected to the room"), the **ASUS becomes primary/main** (origin `(0,0)`) on the right, Retina extended to **its left** (origin `-1920,0`); **(2) projector, no ASUS** → the projector simply *mirrors* the Retina (also dropped to 1920×1080), Retina stays main. **Unknown external unplugged** → revert to the standard rig: Retina **main** at its native mode, ASUS (if present) extended to the Retina's **right**. **At-home guard:** if a *known* non-ASUS external (home monitor / TV) is connected we assume Victor's own multi-display layout is set the way he wants and **auto-arrange keeps hands off entirely** (the manual force still overrides) — this also stops a home TV from ever being mirrored at 1080p. Applying is **two Quartz transactions**: phase 1 = display modes + mirror topology (`CGConfigureDisplayWithDisplayMode` + `CGConfigureDisplayMirrorOfDisplay`), phase 2 (~0.6 s later, its own `CGBegin…/CGComplete…`) = origins (`CGConfigureDisplayOrigin` — who is main, who sits where). They **cannot share one transaction**: when the mirror set changes, macOS recomputes the layout after the mirror lands and silently discards the requested origins while still reporting success — the Epson PU100 bug (2026-07), where "mirror + ASUS primary" logged success but the Retina stayed main and the ASUS was parked to the right. No external tools, **no Screen-Recording permission** needed. The Retina's user-normal (native HiDPI) mode is captured the first time we observe a projector-free state and restored verbatim on revert. 1080p is found via `CGDisplayCopyAllDisplayModes` + `kCGDisplayShowDuplicateLowResolutionModes`, preferring a true non-HiDPI 1920×1080 @ 60 Hz. It **does not auto-apply on launch** (only on subsequent changes) so starting the app never reshuffles a happy layout; the menu item **🖥️ Arrange Monitors** (top-level) and `GET /test/projector` force it on demand. On each applied change it flashes an **immediate** (not presence-gated) bottom-left `StatusBanner.showNow` for 8 s describing the new layout (e.g. "🖥️ mirror + ASUS primary", no label after the emoji). **Anonymous displays (the 2026-08-27 room-TV bug):** mirrored displays collapse into a single `NSScreen`, so a **mirror slave has no name at all** — and macOS routinely sweeps whatever is already attached into the new display's mirror set on an HDMI hot-plug. The old resolver called any unnamed external "the projector" and kept only the first one, so when the room TV dragged the ASUS into the mirror set the ASUS was either mistaken for the projector or dropped on the floor; the applied layout came out "Retina main, ASUS mirroring" and Victor re-did it by hand. Now unnamed displays are never guessed at: they are reported as `unidentified` and handled by two layers. **(a) `DisplayNameCache`** remembers every display's `localizedName` keyed by its EDID triple (`CGDisplayVendorNumber/ModelNumber/SerialNumber`, which Quartz answers for mirror slaves too) in `UserDefaults`, so a known monitor is recognised while mirrored and across app restarts — no key is stored when the triple is unusable, to stop two "unknown" monitors lending each other a name. **(b) the un-mirror probe**: if anything is still anonymous, one transaction breaks *every* mirror set (pinning each ex-slave back to its best mode, since breaking a mirror drops it to 800×600), waits 0.9 s for `NSScreen` to repopulate, and re-resolves with `force`. Self-limiting: the probe's re-resolve is what teaches the cache the new display's name, so a given venue screen costs at most one probe ever. The probe is also skipped outright when the anonymous displays are already doing what the projector should — mirroring the Retina, with the ASUS un-mirrored and main (or the Retina main when there is no ASUS) — so a room screen that is already set up right never blinks; in the failure this guards against, the ASUS is neither un-mirrored nor main, so the guard correctly lets the probe run. A **forced** apply (🖥️ Arrange Monitors / `GET /test/projector`) always probes — Victor pressed it precisely because something looks wrong. Verified live on 2026-08-28 against the room TV, which the probe named **`IdeaDisplay`** (EDID `25368-1-0`, serial 0 — hence the unusable-key guard): probe → identify → "mirror + ASUS primary" → verified, in ~5 s. Extra unknown externals are no longer discarded either — they are un-mirrored, pinned and parked to the right. For the **presentation signal** an anonymous slave counts as an unknown external (missing a real room-TV session is worse than arming 😶😶😶 while only the ASUS is mirrored). **Verification (phase 3):** `CGCompleteDisplayConfiguration` reports success for configurations macOS then quietly recomputes, and a display still settling — or flapping, as the ASUS did for two minutes on 2026-08-27 — swallows the origins outright, which nothing used to notice. 1.5 s after each apply the live layout is read back (projector mirroring the Retina? Retina at 1080p? ASUS un-mirrored and `CGMainDisplayID()`?) and re-applied if it isn't what we asked for, up to 3 attempts total, logging the broken invariant in words; it gives up with an error rather than looping. Verification only runs in the few seconds after an apply we performed, so a manual re-layout later is still left alone. Test hook: `GET /test/projector` force-applies now and returns a JSON snapshot (detected displays, resolved scene, 1080p availability).
- **🔴 Presentation detection + aggressive silent-transcription warning (`PresentationDetector` + `SilentTranscriptionWarning`)** — a louder "transcription isn't capturing anything" warning that fires **only while Victor is presenting**. "Presenting" is the OR of two signals: **(a) an unknown external display** connected (a venue projector / room TV — i.e. sharing the desktop to a room; `DisplayArrangementManager.onUnknownExternalChanged`, gated by `KnownDisplays` so the ASUS / trusted home monitors don't count) and **(b) a live meeting** — a meeting app (Zoom/Teams/Webex) **or a browser** (for web Meet/Teams/Webex) actively **capturing the microphone** (`kAudioProcessPropertyIsRunningInput`, polled every 3 s in `MeetingDetector`). An earlier version watched `🎙️TO Zoom`'s `IsRunningSomewhere`, but that virtual device is held open by its driver and reads "running" with **no call** — a permanent false positive; attributing live mic capture to a specific app is the reliable signal, and Whisper's own capture (a Python process) never matches the meeting/browser bundle prefixes. When presenting **and** the transcription file goes stale (`TranscriptionWatcher`, ~3 min no new lines), a **big red persistent banner** showing just **`😶😶😶`** (emoji-only on purpose — the banner is mirrored to the room during a presentation, so explicit words like "Transcription silent!" would alarm the audience; three silence faces on red mean it to Victor and read as innocuous to everyone else; no hover-hint text either) appears **silently** (it used to ring Basso; removed 2026-10-01 — during a call the room hears it, and the red banner is already impossible to miss) and **stays until transcription recovers or the presentation ends** (not the old gentle 5-min "😶" pill, which showed anytime — this is presentation-gated and aggressive). Hovering **snoozes** it for the current stale episode (the pill sinks straight down); it re-arms on recovery / presentation end / transcription restart. Outside a presentation it's completely silent. **`KnownDisplays`** is a **hardcoded, explicit list** of Victor's own displays, matched by case-insensitive name substring (`KnownDisplays.trustedNameSubstrings`, seeded with "ASUS"; edit the array to add home monitors / TV) — there is no dynamic "remember this display" mechanism. The bottom-left overlay (`BottomLeftBanner`) is **scaled ×1.5** (font + box) for presentation visibility. Test hooks: `GET /test/presentation` (JSON: presenting / meetingActive / unknownDisplayPresent + each external's known flag + `trustedNames`), `GET /test/presentation/warn` (force-preview the red banner, auto-dismisses after 6 s).
- **🔊 Zoom share-picker prep (`ZoomSharePrep`)** — ticks **Share sound** and selects the **presenter layout** the instant Zoom's screen-share picker opens, because Zoom forgets both at the start of every meeting and Victor kept starting demos the room couldn't hear. **There is no setting to persist instead.** Verified 2026-08-29 against Zoom Workplace 6.6: the client's own preferences live in `~/Library/Application Support/zoom.us/data/zoomus.enc.db`, a **SQLCipher** file (random header, not `SQLite format 3`) — not editable from outside; `us.zoom.xos.plist` holds nothing about sharing; and the admin mass-deployment domain `us.zoom.config` has **`EnableShareAudio`, which only makes the option *available*, not pre-ticked** (`PresentInMeetingOption=1` does skip the picker but auto-shares the desktop, losing both the window choice *and* the checkbox). Zoom Community confirms "Share sound" is remembered only **within one meeting**. Filed with Zoom as a feature request 2026-08-29 (Help → Give Feedback in the client — `zoom.us/feed` redirects to that article; there is no web form). The picker is fully accessible AppKit: `AXWindow Subrole=AXSystemDialog Title="Share screen window"` → right-hand `AXScrollArea` → `AXCheckBox Description="Share sound" Value=0/1 actions=[AXPress]`, and `AXList Description="Choose a layout"` → `AXRadioButton Description="Choose a layout, <name>"` → nested `AXButton Title="<name>"` for the four layouts **Content only / As background / Over the shoulder / Side by side** (the two that composite the camera **over** the content are "As background" — Victor's choice, the shared screen becomes the backdrop and he is cut out over it — and "Over the shoulder"). Driven **in-process through `AXUIElement`**, on this app's own Accessibility grant, for the same reason as `TerminalTiler`: `osascript` + "System Events" needs a separate Automation grant that breaks after every re-sign, and it could not resolve Zoom's nesting at all — `click (first radio button of window "Presenter layout" whose description contains …)` returned `-1719 Invalid index` against a tree the AX dump showed plainly. **Trigger** is an `AXObserver` on `kAXWindowCreatedNotification` + `kAXFocusedWindowChangedNotification` (re-attached on Zoom launch/quit via `NSWorkspace`), plus a **1.5 s safety poll** for the case where Zoom reuses a window and no notification arrives; both funnel into one serial scan guarded by a rising-edge `dialogWasOpen` flag so the picker is prepared **once per appearance**. The subtree populates asynchronously, so each notification fires a retry ladder at 0.05/0.2/0.5/1.0 s. The checkbox press is **verified, not assumed**: re-read after 120 ms, pressed once more if it didn't land, re-read again. The layouts expose **no** `AXPress` on the radio button (only the nested button) and **no** readable selected state, so the wanted one is simply pressed — a no-op when already active. AX messaging timeout is pinned to **1 s** so a Zoom main thread blocked mid-meeting can't wedge the scan queue. Feedback is **emoji-only**, same reasoning as `😶😶😶`: re-opening the picker during an ongoing share puts it on a screen the room is watching, so it's `🔊✅` for 2.5 s (and **nothing at all** when the box was already ticked — a pill for a no-op is pure noise) and `🔊❌` + Basso for 8 s on the one case that matters, a press that could not be verified. **Opening the picker also starts the share** (`autoPressShare`): the tile for the **built-in Retina** is selected and the green `Share - …` button pressed, in that order — switching tiles re-renders the presenter-layout preview, so the cut-out is placed *after* the screen is chosen and the button *last*, since it closes the picker. The Retina is found by **position in `CGGetActiveDisplayList`** (mirror slaves filtered out, since Zoom collapses a mirrored pair into one tile and the Retina is the master when the venue projector mirrors it): Zoom labels its tiles `Desktop 1…N` and Accessibility ties none of them to a display, so the enumeration order is the only bridge. This matters because **the Retina is not always macOS's main display** — `CGGetActiveDisplayList` starts with the main one, so "Desktop 1" is not reliably the Retina and Zoom's own preselection cannot be trusted. If the built-in isn't found (clamshell, unexpected label) nothing is pressed and Zoom's preselection stands. Escape hatch: **hold ⌥ while opening the picker** and the auto-share is suppressed, for the times a different screen or a single application window is wanted. **Not ⇧** — Zoom's own shortcut for opening the picker is **⇧⌘S**, so a shift-based hatch would be triggered by the very gesture that opens the picker, and non-deterministically at that (it depends on whether the key is still down when the scan reads the modifiers). Caught before the first live test, 2026-08-30. **Verified live 2026-08-30**, driving Zoom through Accessibility only: opening the picker started the share five times out of five, each time on the Retina — Zoom's **`Annotation - Zoom`** window, which covers exactly the shared display, read `(0,0 1728×1117)` every time (that window is the cheap observable for "which screen actually went out"), and the confirm button read `Share - Desktop 1`. The ⌥ hatch is confirmed too, but only became testable once the app logged the modifiers it actually saw: a **synthetic** modifier posted with `CGEventCreateKeyboardEvent` reaches the HID flags state unreliably (the injecting process read ⌥ as held while the app read nothing, on 2 tries out of 3), so the passing run is the one where the log shows `[mods=524288]` alongside "⌥ held → left the picker open". A physically held key has no such ambiguity. ⚠️ **Still unverified: the `Desktop N` ↔ `CGGetActiveDisplayList` ordering itself.** It needs at least two awake displays to distinguish the hypotheses, and the three external monitors had gone to sleep by the time the rest was done — Zoom then offered a single tile. Until it is checked, the risk is confined to a rig where the Retina is *not* macOS's main display; with the Retina main (the ordinary case) every candidate rule agrees on Desktop 1. Test hook: `GET /test/zoom-share` (JSON: zoomRunning / dialogOpen / shareSoundFound / shareSoundOn / presenterLayout / autoPressShare / builtInDesktop) — it also re-arms and re-runs the prep against an open picker. **The camera cut-out is placed too**, into the bottom-right corner of the preview at **a third of its width** — the third thing Zoom forgets every meeting. It is *not* settable through AX: the cut-out is exposed (`AXTabGroup Description="<display name>"` under `Presenter layout preview area`) and its `AXPosition`/`AXSize` read fine, but `AXUIElementIsAttributeSettable` answers **false** for both and `AXUIElementSetAttributeValue` returns **`-25200`** with nothing moving; the composited cut-out on the shared screen itself is not an AX element at all (hit-testing the shared surface returns the *shared app* underneath). So it is a **synthetic `CGEvent` drag** on the preview widget — press, twelve interpolated `leftMouseDragged` steps, release (one jump from press to release is ignored; the widget tracks intermediate motion), with the cursor warped back to where Victor left it. Done **in the picker, before the share starts** — the same widget exists in the floating `Presenter layout` window mid-share, but by then the room is watching the drag. Geometry is never assumed: each drag is followed by re-reading the frames, up to 3 passes, tolerance 4 % of the preview width. Each edge drag changes **one** dimension — the cut-out **crops rather than scales** (measured 191×110 → 128×110 from the left edge) — so width is taken off the **left** edge and height off the **top** edge, keeping the right and bottom edges pinned. Taking the height too is not cosmetic: leave it and the frame stays as tall as Zoom made it while only the width shrinks, so the 16:9 video sits letterboxed inside a squarish box and a visible band opens up **under Victor's head** instead of his video touching the bottom edge. The target ratio is **16:9**, which is also Zoom's own default frame (124×70 = 1.771). Two guards: the placement is skipped while the **left mouse button is down** (Victor mid-drag — including the very click that opened the picker), and because that reason clears by itself the placement, unlike the two presses, is **retried on later scans** (≤4 attempts) instead of being one-shot. Verified 2026-08-29, nothing touched by hand: preview `(1282,315 252×141)` → cut-out `(1448,407 85×48)`, i.e. **85/252 = 0.337** of the width, aspect **85/48 = 1.771** (Zoom's own ratio), right and bottom edges **1 pt** off flush. Two earlier openings of the width-only build reproduced the placement identically (`84×70`, `85×70`) but left the letterbox band that the top-edge drag now removes. Do **not** verify this with `screencapture -R` fed the AX rectangle — the two use different coordinate spaces on a multi-display Retina rig and the capture lands somewhere else entirely; read the frames back through AX instead. Sanity check for which layout is live: **"As background" shows no Wallpaper section** under the layout list, "Over the shoulder" does. **It can be switched off** (2026-09-22): `ZoomSharePrepSettings.isEnabled`, a `UserDefaults` flag behind the **🔊 Zoom Share Prep** checkbox in the 👩🏻‍💻 Extra submenu, default **on**, read on every scan so an untick lands on the next 1.5 s tick rather than at the next launch. The switch exists because everything this class does is a *guess* about intent — sound on, presenter layout, face bottom-right, Retina picked, Share pressed — and the guess is right for a workshop and wrong for every other use of the picker: a different target, **Portion of Screen**, or an agent driving the dialog. In those cases it stops being a helper and becomes a second pair of hands fighting yours, and the ⌥ hatch only covers the openings you remember to hold it for. Found the hard way on 2026-09-22, when it kept re-selecting the full screen under a Codex run that was trying to set up a Portion-of-Screen share.
- **▶️ Zoom join-preview auto-press (`ZoomJoinAutoStart`)** — presses **Join** / **Start** in Zoom's join-preview dialog the instant it appears, so joining a meeting costs one click (the link) instead of two. The dialog is the 640×511 window holding the camera preview, the Audio/Video toggles and the device pickers, titled with the **meeting topic** ("agentic.how #4") — which is exactly why it cannot be matched the way `ZoomSharePrep` matches its picker: there is no constant title. The handle used instead is the **checkbox**, `AXCheckBox Description="Always show this preview when joining"`, whose label is the same for every meeting; the button is then found inside that same window. Dumped from Zoom Workplace 6.6: `AXWindow Subrole=AXStandardWindow Title="<topic>"` → `AXTabGroup` (`AXButton Id=Video`, `AXButton Id=Audio`) + `AXButton Description="Join"` + the checkbox + an ⓘ `AXButton`. Two traps shaped the matching. The confirm button carries its label in **`AXDescription`, not `AXTitle`** — a title search finds nothing at all — and the text depends on the role: **"Join"** for someone else's meeting, **"Start"** for your own (which is what Victor's screenshot showed). Both are accepted, and the match is **exact rather than a prefix**, because the ⓘ button beside the checkbox has the description "Turn off to skip this preview in future meetings. You can turn the preview back on in Settings > Video settings." — a loose "contains preview" search swallows it. **The gate is a setting, and Zoom's own ⓘ points at the wrong pane**: the dialog appears only while **Settings → Meetings & webinars → Join experience → "Show video preview first"** (`AXCheckBox Subrole=AXSwitch`) is on; with it off Zoom joins straight through and this watcher never fires — verified 2026-09-18 from *both* join paths, the `https://…zoom.us/j/…` browser link and a `zoommtg://…action=join` deep link, so it is the setting that decides and not the path. Zoom's Video pane, where the ⓘ sends you, has no such control in 6.6. The label also exists in `Localizable.strings` twice, `LN_Always_Show_Meeting_Preview_770243` (the dialog) and `…_Setting_770243` (the pane) — grepping `plutil -p /Applications/zoom.us.app/Contents/Resources/en.lproj/Localizable.strings` is far faster than walking twelve settings panes by hand, which is how this was eventually found. Mechanics are `ZoomSharePrep`'s, for its reasons: in-process `AXUIElement` on this app's own Accessibility grant (never `osascript`), an `AXObserver` on `kAXWindowCreatedNotification` + `kAXFocusedWindowChangedNotification` re-attached on Zoom launch/quit, a **1.5 s safety poll** for a reused window, a 0.05/0.2/0.5/1.0 s retry ladder because the subtree populates asynchronously, a rising-edge `dialogWasOpen` guard so one appearance means one press, and a **1 s AX messaging timeout** so a Zoom main thread blocked while it connects cannot wedge the scan queue. Escape hatch: **hold ⌥ while the dialog appears** and it is left open, for picking a camera, a microphone or a background by hand — same gesture as the share picker's. No banner: the dialog vanishing *is* the feedback, and unlike `🔊✅` there is nothing a room needs to be told. **Verified live 2026-09-18** against the real `agentic.how #4` room: cold launch → in the meeting in **8.2 s** (dominated by Zoom starting and connecting), and a watchdog polling the AX tree every **0.5 s throughout never once observed the preview window** — the observer press lands ~50 ms after the window is created, before the next sample. Test hook: `GET /test/zoom-join` (JSON: zoomRunning / enabled / previewOpen / topic / confirmButton) — it also re-arms and presses a preview left open.
- **🎥 Layout Zoom (`ZoomMeetingLayout` + `ZoomMeetingLayoutPolicy`, 2026-09-29)** — a top-level menu row, next to 🖥️ Arrange Monitors, that lays a running meeting out on the **monitor sitting on top of the Retina** the way Victor watches a session: the `Zoom Meeting` window fills the left, and a **360 pt** right-hand column holds **Participants** on top and the **Meeting chat** at the bottom (**36 %** of the height), so who is talking and what was just typed are both one glance away. Both numbers are the layout Victor had arranged by hand that afternoon (Participants 350 wide, chat 378 of 1055 tall), read from the live AX frames rather than guessed. "Top monitor" comes from `CGDisplayBounds`: the display whose bottom edge touches the built-in's top edge, widest horizontal overlap wins; with none (no DELL above, clamshell) nothing moves and the banner says `🎥🖥️❓`. The usable area is that screen's `NSScreen.visibleFrame`; since a title bar cannot go under the menu bar, the meeting window is placed first and its read-back top edge corrects the column. The panels are only placeable as **their own windows** (`AXSystemDialog` titled `Participants (N)` / `Meeting chat`): a closed one is opened by pressing Zoom's **View** menu item by its **identifier** (`onManageParticipants:`, `onChat:` — the Cocoa selector, **trailing colon included**; the title flips between *Show* and *Close*, the identifier does not. The first build compared against the bare name, so on 2026-09-30 a meeting with both panels closed came back `no participant window` / `no chat window` and Victor had to open them by hand), a docked one by the "Pop out" button inside the meeting window. The view mode (Gallery / Speaker) is left alone — the hand-made layout was on Gallery. Zoom is then activated and the three windows raised, panels last. Same mechanics as the two bullets above — in-process `AXUIElement`, 1 s messaging timeout — on its own serial queue, since opening a panel is waited for (≤3 s). Feedback is emoji-only on the Retina: `🎥✅`, `🎥❓` (no Zoom / no meeting), `🎥❌` + Basso when a frame did not read back within 6 pt of its target. Test hook: `GET /test/zoom-layout` starts a run and returns the **previous** run's report (the run is too slow to hold the main thread for); `?run=0` only reads it.

## 🔍 Which magnifier style the remote half of the room can actually see (`ZoomLensMode` + `ZoomLensWatch`)

**The finding, measured on 2026-09-22 against `screencapture`, not reasoned about.** macOS's
screen magnifier has three styles, and the style decides whether a Zoom screen share carries
the magnification at all:

| `closeViewZoomMode` | style | where macOS applies it | in the captured frame? |
|---|---|---|---|
| 0 | Full screen | at **scanout**, after the composited frame every capture client reads | **no** |
| 1 | Picture-in-picture | an ordinary **composited window** | **yes** — until the lens is sized to the whole screen, when it degenerates back into the scanout path |
| 2 | Split screen | untested | unknown |

So the room, watching the physical panel, sees every style; people on Zoom see only the PiP
lens. Victor had been magnifying with ⌥+scroll full-screen for years and nobody remote ever
saw it. Proof for style 1 is a retina crop showing the lens border with the magnified cursor
inside it; proof that a screen-sized lens is *not* captured is a frame taken at 2.19× that
shows the plain unmagnified desktop, both menu-bar edges included.

**Three dead ends, each tested, none worth retrying:**

- **`closeViewZoomScreenShareEnabledKey`** — System Settings → Accessibility → Zoom →
  Advanced → "Show zoomed image while screen sharing", added in macOS 15.1 — is for Apple's
  own **Screen Sharing / ARD**, not for ScreenCaptureKit clients. Tested twice: with the
  preference set, and with the private `SLSSetZoomScreenShareOptions(cid, 1)` called directly
  and the connection held alive. `screencapture` returned the unzoomed frame both times. The
  mechanism is real — `UAZoomScreenShareSetEnabled` is `UAPreferencesSetBoolean` followed by
  that SkyLight call, which sends Mach message `0x7477` to WindowServer — it simply does not
  govern this path.
- **No `SCStreamConfiguration` / `SCContentFilter` property** touches the display transform.
  Verified against the installed SDK headers.
- **⌥+scroll cannot be intercepted** while the OS magnifier claims it. A
  `.cgSessionEventTap` at `.headInsertEventTap` saw the ⌥ modifier on **1 of ~333** scroll
  events while the zoom factor climbed 1.0 → 3.3; a `.cghidEventTap` saw it on **0 of 28**.
  The gesture has to be *freed* first — `closeViewScrollWheelToggle = 0`, which **is** read
  live — before any tap of ours could have it.

**What the app does about it.** `ZoomLensWatch` reads `closeViewZoomMode` once a second and
flashes a pill — `🔍 PiP` / `🔍 Full screen` / `🔍 Split` — whenever it changes. **⌥⌘F**
toggles Full screen ↔ PiP (`AX_ZOOM_TOGGLE_FS_AND_PIP`, keyCode 3 + ⌥⌘, from the hotkey table
in `com.apple.universalaccess`), and the two styles are *visually identical* when the lens
covers the screen — same pixels, same magnification, different place in the pipeline. A
toggle with no feedback that silently decides whether half the audience can read the screen
is exactly what the pill is for. The first reading is never announced (it would fire on every
launch) and an unchanged mode says nothing (the key is re-read every second).

**Why polling and not a tap branch:** the numbers above. The magnifier eats its own gestures
upstream of every tap, so a key hook could not see ⌥⌘F; polling also catches the style being
changed from System Settings, which a hook never would. The cost is one preference read per
second, and it is not a workaround — `UAZoomCurrentMode()`, the private call the system uses
itself, disassembles to exactly `UAPreferencesGetInteger` of this same key.

**Lens geometry can be set programmatically (2026-09-23).** `closeViewWindowSize` /
`closeViewWindowPosition` hold it, as `NSKeyedArchiver`-archived `NSValue`s (size, and the
top-left point in global coordinates — the retina sat at `-1920,0` while mirrored to a
projector). Writing them is not enough on its own: neither `killall` nor `kill -9
universalaccessd` makes the lens re-read them. What does is **restarting the zoom engine**:
`UAZoomSetEnabled(false)` then `UAZoomSetEnabled(true)` (private, `UniversalAccessCore`,
~0.7 s apart), after which `UAZoomSetMode(1)` puts it back on PiP. Proven with three sizes in
a row (960×540, 1500×844, then the final one), each showing up exactly in a `screencapture`.
Two traps: `UAZoomSetEnabled` is the **"Use keyboard shortcuts to zoom"** switch
(`closeViewHotkeysEnabled`), so a stray `false` leaves ⌥⌘8 and ⌥+scroll dead until it is set
back; and ⌥⌘- does not leave zoom, ⌥⌘8 does. Why it mattered: switching to a 1920×1080
projector left a lens sized for the retina's own 1725×1080-ish area, i.e. a strip of
unmagnified screen on the right. Set to the screen minus 2 pt per side (1916×1076 at
`-1918,2`). A lens exactly the screen's size is not captured by `screencapture` (see above),
so verify geometry with a deliberately smaller size first.

**Cursor fence while a PiP lens is zoomed in (`ZoomLensCursorFence`, 2026-09-23).** With the
lens magnifying, moving the pointer onto the ASUS drops the magnification: a flicker on the
shared screen. No setting keeps the lens (`closeViewZoomDisplayID` is the full-screen style's
chooser; nothing in `UniversalAccessCore` pins a PiP lens), so the cursor is kept on its screen.
Tested live with Victor's hand on the mouse, in this order:

| attempt | result |
|---|---|
| rewrite `event.location` in an HID tap | **fooled only the apps**: WindowServer draws the physical cursor from HID deltas before any tap; synthetic moves stopped at the edge, the real mouse sailed through (and a logger reading event locations "confirmed" it — same blind spot) |
| + `CGWarpMouseCursorPosition` back | too late, the crossing already happened |
| `SLSSetCursorRegionLock`, `SLSSetZoomForceLockCursorInDisplay` (SkyLight, private) | return 0, hold nothing for a background process |
| `CGAssociateMouseAndMouseCursorPosition(false)` + move the cursor ourselves, clamped | **holds** — but decoupled deltas are **raw**: 16.9 units/event vs 4.0 pt/event coupled (×4.2), no acceleration curve. Unscaled = far too fast; ÷4.2 = felt slow |

Shipped: **decouple only in an 80 pt band along the edges that lead to another display**
(`exitEdges`, computed from the active mirror masters), raw deltas ×1/3.3 inside it,
coupled again 6 pt past the band's inner line. Everywhere else the mouse is native. Gate:
`closeViewZoomMode = 1`, `closeViewZoomedIn = 1`, `closeViewZoomFactor > 1`, polled every
0.1 s; **⌥+scroll back to 1× releases it** and always re-couples. No adjacent display → no
fence. Synthetic input cannot test any of this: while the magnifier is zoomed, posted
`mouseMoved` events do not move the cursor at all.

**The lens geometry is lost on display changes**: after unplugging the projector it came
back as a 90×90 square; refit with the prefs-write + engine-restart recipe above.

### 🔎 The fifth path: our own zoom, in a window (`ShareZoom`, ⌥⇧+scroll, 2026-10-01)

For the meetings where Zoom's unfiltered capture is not an option (another client,
another machine's settings, a share of a single screen that filters anyway), the
magnification is done **by this app, inside a window**, which is the one thing every
capture path carries. Same trade as the 🔍 Pink Panther glass (tile #6 in
`victor-effects`), but full-screen and live:

- **⌥⇧+scroll** zooms in/out on the display under the pointer; back to 1× hides the
  window. Positive delta *after* `ScrollReversal` = closer. The first build copied the
  ⌘-scroll terminal font zoom's sign and came out backwards — that branch maps the
  wheel to ⌘-/⌘= keystrokes, so its sign was never the one to copy. **One notch is
  ×⁴√1.15 ≈ 1.036** (1× → 2× in twenty notches): the first build's ×1.15 was "pași
  prea mari", halved in the log domain, and then halved again the same evening. The
  ceiling is **8×** (80 % of the first build's 10×). The factor eases at 120 Hz and the easing starts
  with the first visible frame, not with the gesture — eased while still invisible it
  was over before anything was on screen. On another display, ⌥⇧+scroll moves the
  zoom there.
- **It pans the way the system magnifier is set up here** (`closeViewPanningMode = 1`,
  "only when the pointer reaches an edge"): the picture stays put while the pointer
  moves inside it and is dragged along only when the pointer pushes an edge; zooming
  is about the pointer (`ShareZoomPolicy.rezoom` / `pan`). The first build kept the
  pointer as the fixed point of the magnification instead, so the whole desktop slid
  under every mouse move — "nu e aceeași experiență".
- **Input is still never remapped.** Edge panning means the desktop point under the
  real pointer is no longer drawn under it, so the **hardware cursor is hidden**
  (`CGDisplayHideCursor` + the `SetsCursorInBackground` connection flag, the
  `CropSelectionOverlay` technique) and a **copy of the system cursor's current shape**
  (`NSCursor.currentSystem`, refreshed at 20 Hz), magnified by the same factor, is
  drawn where that desktop point appears on the glass. A click lands on the real
  pointer's point, which is exactly what the drawn cursor is over. The drawn cursor
  lives in the window, so the share carries it. When the pointer leaves the zoomed
  display the real cursor comes back. Its base size is kept in a property, never read
  back from the layer: the first build did, the layer already held the magnified size,
  and the factor compounded every tick (k, k², k³…) until the 20 Hz shape refresh reset
  it — the cursor pulsed small/big. `cursorFrame` in the test hook now reads 34×46
  (the 17×23 arrow at 2×) on every sample.
  **The Dock gives the real cursor back**: on this Mac it sits on the left,
  auto-hidden, and popping it out (or moving across its icons) made the real arrow
  reappear beside the drawn one — Victor's screenshot, then reproduced on the retina's
  left edge only (top/right/bottom and all four ASUS edges stayed clean). Hiding needs
  **both** `NSCursor.hide()` and `CGDisplayHideCursor`, as the 💓 heartbeat does, and
  the hide is **re-asserted at 4 Hz while the pointer is within 100 pt of any edge and
  for 2 s after**; every hide is counted (`hideDepth`) and undone exactly that many
  times when the zoom ends. Verifying this needs a ScreenCaptureKit capture with
  `showsCursor = true` (it omits a hidden cursor — calibrated with a probe process that
  hid it); `screencapture -C` draws the cursor even while it is hidden and lies.
- **Effects (`victor-effects`) need only the cursor.** Their overlay is at the
  maximum window level, above this panel, so they are drawn unmagnified over the
  zoomed picture — what they look like unzoomed — and screenshot effects photograph
  the zoomed picture. What broke was anything drawn *at the cursor* (💓 heartbeat,
  🔍 glass, whip…): it followed the hidden real pointer. `publishCursor` posts the
  drawn cursor's global position as a distributed notification
  `ro.victorrentea.share-zoom.cursor` (~30 Hz while it moves, 0.5 s keep-alive, empty
  at the end); `VisibleCursor` over there uses it, stale after 1.5 s. Verified with a
  listener: position at zoom start, keep-alives while resting, cleared at 1×.
- **Capture**: `SCStream` of the whole display at 60 fps, `showsCursor = false`,
  filtered with `excludingWindows: [our panel]` — only ours, not the whole app, so the
  banners and the hands-off locks stay in the picture. Frames are `IOSurface`s set
  straight as the layer's `contents`; the zoom is just `contentsRect`. The panel is
  `.screenSaver` level, opaque, click-through, on every Space, invisible until it has
  a frame. It honours `closeViewSmoothImages` (off here → `.nearest`).
- **Startup latency**, measured with `startupMs` in the test hook: the first build
  took **~195 ms** from gesture to picture — ~100 ms for `SCShareableContent` (the
  window list the filter needs) and ~95 ms for the stream's first frame. Now one
  **`Stage` per display** (panel + filter) is built 3 s after launch and after every
  display change — an ordered-out panel *is* listed by `SCShareableContent`, so the
  filter can exclude it before it was ever shown — and the stream **lingers 10 s**
  after a zoom-out. Cold: **78 ms**; zoom again within 10 s: **0 ms**.
- **Not like the system magnifier**: content lags the real screen by a frame or two
  (capture → draw); macOS shows its screen-recording indicator while the stream runs.
- **Verified 2026-10-01** on the ASUS, with synthetic input: `screencapture -D 2` (a
  capture client, i.e. what a share sees) shows the magnified picture the right way up
  with no recursion; moving inside the slice left `contentsRect` untouched, pushing the
  right edge dragged it along (x 0.25 → 0.50); the drawn cursor is where expected.
- ⚠️ **Unverified**: (1) whether the system magnifier also eats ⌥⇧+scroll from a
  physical wheel — it ignores synthetic scrolls altogether, so only a hand can answer
  (the first hand did: it works); (2) whether Zoom draws its *own* remote cursor at the
  real pointer while ours is hidden, which would show the far end two cursors.
- Test hook: `GET /test/share-zoom` (JSON: active / visible / factor / contentsRect /
  streaming / cursorHidden / prepared per display / startupMs), `?factor=N` (1 = off),
  plus `&x=&y=` (global Cocoa points) to pin the focus — the real cursor is then left
  alone.

### ⚠️ ⌥+scroll during a share → "Use ⌥⇧↕ for Zoom" (`ShareZoomHint`, 2026-10-01)

⌥+scroll is the macOS magnifier — the style a share never carries — and ⌥⇧+scroll is
`ShareZoom`, which it does. One finger apart, so the habit wins mid-demo. While Zoom is
sharing, every ⌥+scroll (⌥ alone, no ⇧/⌘/⌃) puts an orange **⚠️ Use ⌥⇧↕ for Zoom**
pill beside the cursor, following it, gone 2.5 s after the last notch. The scroll
itself is not touched: the local zoom still happens.

- **Seen at the HID tap, not the session tap.** `AXVisualSupportAgent` (the magnifier)
  holds an *active* `kCGHIDEventTap` and consumes a physical ⌥+scroll there, so the
  main `EventTapManager` session tap never sees one. A second, scroll-only tap at
  `.cghidEventTap` + `.headInsertEventTap` runs before the magnifier's (confirmed with
  `CGGetEventTapList`: ours listed first) and always passes the event on. It is a
  default (not listen-only) tap because listen-only needs Input Monitoring, which this
  app does not hold; Accessibility covers the default one.
- **"Is Zoom sharing?"** is read off Zoom's on-screen window names
  (`CGWindowListCopyWindowInfo`, cached 1 s). Read from a live share on 2026-10-01
  (Zoom Workplace 6.6): `zoom share toolbar window`, `zoom share statusbar window`
  (layer 97), `Annotation - Zoom` + `zoom annotation entrypoint` (96), none of which
  exist in a meeting without a share. ⚠️ The window list names the owner **`Zoom`**, not
  the process name `zoom.us` — match by pid (`us.zoom.xos`), as `ZoomShareWindows` does.
- **Verified live 2026-10-01**: an empty meeting started and shared through AX, a
  synthetic ⌥+scroll → pill (191×31 by the cursor) + log line `⚠️ ⌥+scroll during a Zoom
  share`; after **Stop share** the same scroll → nothing. The synthetic scroll proves the
  path, not the ordering against the magnifier (it ignores synthetic scrolls): that half
  rests on the tap list, and on the first real ⌥+scroll by hand.

### 🔦 ⇧ + wheel-drag → glass everywhere but one box (`GlassSpotlight`, 2026-10-04)

Victor, by mail: hold ⇧, drag with the wheel pressed, and everything on that screen
except the box goes behind frosted glass; the box's edges melt into the glass rather
than stopping at a line; Esc clears it. *"Copiază-ți controalele din modul în care tai
crop"* — so it is the crop's gesture, read by the crop's code.

- **The keys are `RegionDrag` in victor-mac-kit**, extracted from `CropSelectionOverlay`
  the same day so both overlays drive one value: ⌘ moves the box instead of resizing
  it, the box stays on the screen the drag began on. **No ⌃ square here** (Victor,
  same day: *"n-am nevoie de square"* — ⌃ is passed as never held). The only legend
  is the crop's `⌘ move`, small, white, straight on the glass with no plate behind
  it, brighter while ⌘ is held; **no line on the box's edge** — the cut-out is the
  frame. Only the trigger differs: **⇧ is read at the press and never again**, so it
  can be let go as soon as the drag has started.
- **The tap owns all three halves.** `EventTapManager` swallows the ⇧-middle press,
  every drag and the release (the orphan-up rule), and pushes positions to main on
  arrival — Walkie Talkie's lesson, a 60 Hz timer alone lets the box lag the hand.
  The timer still runs during the drag for ⌘ changes with the mouse at rest. The
  price: ⇧-middle-click does nothing anywhere else. Walkie Talkie never competes:
  all of its wheel gestures need a bare press.
- **After the release the glass stays** (click-through, everything under it still
  works) until **Esc**, which the tap swallows with its release — ⌘/⌃/⌥+Esc are left
  alone. A new ⇧-wheel-drag replaces the box.
- **The glass comes up only once the box covers 5% of the screen** (`revealFraction`),
  already cut — never the whole screen blurred first with the box opening out of
  nothing. From then on it stays up for the rest of the drag, however small the box
  gets again. A drag that never reaches 5% changes nothing: no glass if there was
  none, the previous box if there was one (Victor, 2026-10-04).
- **The glass** is an `NSVisualEffectView` (`.behindWindow`, `.fullScreenUI`) whose
  `maskImage` is `GlassSpotlightMask`: opaque, clear inside the box, and a smoothstep
  ramp over **40 pt outside** it — so nothing inside the box is softened. It is redrawn
  only when the box moves. `GlassSpotlightMaskTests` reads the pixels back.
  - **The mask is a drawing-handler `NSImage`, never a bitmap.** `NSVisualEffectView`
    reads a bitmap mask's pixels as *backing* pixels whatever size the `NSImage`
    claims: on the Retina a 1× mask showed at half size pinned to the top-right corner
    (the hole up, right of and smaller than the drag), and a 2× bitmap did the same.
    Measured 2026-10-04 with three variants side by side; a `CALayer` mask also worked.
  - **The glass is fully opaque past the feather — tried lighter, went back.** The
    effect view's blur radius is not public API, so "less intense" can only mean a
    mask under 1 (`alphaValue` on the view made the glass vanish altogether). At 0.75
    the sharp text leaked through enough to read; Victor, the same day: *"blurează mai
    tare ce nu se vede, trebuie să fie greu de citit"*.
- **ScreenBrush draws on top of the glass.** The panel sits at window level **28**, one
  under ScreenBrush's canvas (**29**, read from `CGWindowListCopyWindowInfo`) — Victor
  annotates what the box frames, and at the first level (`.screenSaver − 1`) the ink
  went under the glass (2026-10-04). Still above the menu bar (24/25) and the Dock;
  the price is that pop-up and context menus (101) now draw over the glass.
- **Both zooms work by where the panel sits**: under `ShareZoom`'s `.screenSaver`
  panel, so `ShareZoom`'s capture contains the glass and magnifies it
  together with what the box frames — exactly what the macOS magnifier (⌥-scroll) does
  to the whole framebuffer. The box is in desktop points in both cases, which is what
  the pointer is in too (neither zoom remaps input), so its corner sits under the
  cursor the room sees. A Zoom share carries it like any window.
- **Why not victor-effects**: that repo is public and cannot depend on the private kit
  the gesture lives in, and `ShareZoom` is in this process.
- Headless: `GET /test/glass-spotlight?x=&y=&w=&h=` (global Cocoa points) puts a box
  up, `?off=1` takes it down, no query reports.

### The fourth path, and the one actually in use: Zoom's unfiltered capture mode

The table above is what **`screencapture` and ScreenCaptureKit** see. Zoom does not always
read the frame the same way. On 2026-09-22 Victor found that turning on the capture option
in **Zoom → Settings → Share Screen → Advanced** that stops Zoom filtering its own windows
out of the shared frame *does* carry a full-screen magnification to the far end — the one
thing nothing else here achieves. (The option's exact label was cut off in the screenshot
this is written from, so it is described by its effect rather than quoted; it is the
capture-mode setting whose whole point is that window filtering is off.)

The trade is in the name: **Zoom's own windows land in the share too** — the floating
control bar, the self-view, the share indicator. Tolerable in this rig, because the retina
is what gets shared and those windows can live on the right-hand screen.

Why this is not a contradiction of the measurements above: filtering windows out of a frame
means Zoom composites the picture itself from a window list, which is a *pre-composite* path
and therefore blind to a transform applied at scanout. With filtering off it takes the
display's picture as the system hands it over — and with `closeViewZoomScreenShareEnabledKey`
set (which it is, since 2026-09-22), that path is exactly the one the macOS 15.1 flag was
built for. The flag was never useless; it simply governs a capture route that ordinary
ScreenCaptureKit clients do not take, which is why `screencapture` kept showing the
unzoomed frame no matter what was toggled.

**Victor's configuration, as of 2026-09-22:** picture-in-picture style with the lens sized
to the whole screen — i.e. visually the full-screen magnifier he has always used — plus
Zoom's unfiltered capture mode, which is what actually carries it. ⌘⌃U and the pill remain
the way to see and change which style is live.


## 🪞 Virtual Desktop — the presenter cut out over the desktop, on an invisible screen (`VirtualDesktop`)

**Why (2026-10-05).** Zoom 7.1.9 hid its screen-share *presenter layouts* ("In front
of content") — the strings are still in the app, the web setting "Screen Sharing
Presenter View" is on at account and user level, yet no picker, toolbar or menu shows
them. macOS's Presenter Overlay was not offered either. Teams never had it. A virtual
*camera* needs a signed CMIO system extension (the $99 Developer Program). A virtual
*display* needs nothing: the private `CGVirtualDisplay` (DeskPad, BetterDisplay),
declared in `Sources/CGVirtualDisplayShim`.

**What it does.** 🪞 Virtual Desktop — a **top-level** row next to 🎥 Layout Zoom —
**turns itself on when Zoom or Teams starts and off when the last of them quits**
(`VirtualDesktopAutoSwitch`, bundle ids `us.zoom.xos`, `com.microsoft.teams`, `…teams2`;
edge-triggered, so a click on the row wins until the next start/quit). It creates a 1x screen
the size of the Retina, vendor `0xF00D`, and fills it with:

- the **Retina, live** through ScreenCaptureKit — 🔎 `ShareZoom`'s magnified picture
  included — with only the silhouette window excluded;
- the **presenter**: Elgato frames scaled to 720p *by the output* (the device format is
  re-pinned, so a call's own feed is untouched), `VNGeneratePersonSegmentationRequest`
  `.balanced`, keyed with `CIBlendWithMask`, **the whole camera frame, uncropped, 16:9**, mirrored,
  **35 % of the screen high**, flush bottom-right. (Iterations the same day: a quarter
  wide portrait 3:4 — too tall; a third wide 4:3, drawn by Victor over a capture — but
  it cropped the frame's sides; now integral and 10 % lower.)

In Teams/Zoom you share that screen. On the Retina Victor sees only a **20 % black
silhouette** (50 % at first — too dark to read through) where the face is (the keyed face's IOSurface used as the mask of a black
layer — no second render), at `.screenSaver + 1`, above `ShareZoom`, which is told to
exclude it (`ShareZoom.alsoExcluded`) so it is not magnified underneath.

**Corner** (`VirtualDesktopCornerPolicy`, tested): the pointer resting **on the shadow
itself** — its pixels' alpha, read from the last keyed face, not the clip's rectangle —
for **3 s** raises a **←** button on the head (top of the silhouette + 18 % of its
height, at the head's centre column; the clip's centre when the 44 pt disc would not
fit wholly on the shadow). It vanishes when the pointer leaves the shadow. A click
**slides** the face bottom-left (0.8 s, linear; opacity 1→0 over the first 12 % of the
way and 0→1 over the last 12 %, so it vanishes, crosses unseen and arrives — the
Retina shadow does the same, in a panel spanning the bottom strip); it comes home **15 s after the pointer leaves the
bottom-right rectangle** (3 s at first: it came back between two glances). The button is a separate non-activating panel, always on
screen at alpha 0 while hidden, so both captures exclude it by id — nobody on the
call sees it. (First cut, same day: the pointer anywhere in the rectangle for 4 s
moved the face on its own — it jumped while Victor was merely reading under it.)

**No overlay lands on it.** Every overlay picks its screens from `NSScreen.physical`
(`PhysicalScreens.swift`), the CoreGraphics lists (terminal tiling, Layout Zoom, the
lens cursor fence) from `physicalDisplayIDs`. The day it went live the keymap, the
banners and the break timer all drew on the invisible screen too — broadcast to the
call, never seen by Victor. Only `VirtualDesktop`, `ShareZoom` and the
`screencapture -D` numbering read the raw list; `PhysicalScreensConventionTests` fails
on any other `NSScreen.screens`.

**Cost** (2026-10-05, prototype, Zoom closed, two on/off alternations of 20 s):
WindowServer 45–48 % → 48–49 % (the invisible screen is nearly free); the process
~27 % of one core and ~150 MB, nearly all of it the segmentation at 30 fps. With Zoom
sharing, WindowServer swings 68–98 % on its own, so measure with Zoom closed.

**Gotchas**
- `NSWindow(contentRect:…, screen:)` takes the rect **relative to that screen**:
  passing `screen.frame` put the first prototype's window on the Retina.
- `DisplayArrangementManager` filters vendor `0xF00D` out, or the virtual screen reads
  as an unknown projector and arms the presentation warning.
- The screen appears in every share picker as one more "Desktop"; the pointer can
  wander onto it past the right-hand monitor.
