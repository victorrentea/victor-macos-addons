# Live-Session Overlays & Desktop Effects

WebSocket-driven emoji reactions, the join-link banner, and every sound-paired desktop effect.

## Overlay Components (AppDelegate)
Fullscreen overlay and WebSocket integration for live sessions:
- **EmojiAnimator**: receives emoji reactions via WebSocket, animates sprites flying up the screen
- **ButtonBar**: floating button bar for host controls (sound effects, overlay toggle)
- **SoundManager**: plays sound effects (applause, drum roll, etc.) triggered by host
- **OverlayPanel**: transparent always-on-top NSPanel covering full screen
- **JoinLinkBanner**: displays participant join URL at top of screen; auto-hides after 20s with 3s fade-out

Connects to the training-assistant backend via WebSocket at `/ws/__overlay__`.
Receives session lifecycle events (`session_started`, `session_ended`) to enable/disable join link menu item.
- **Interact Link** (menu: `🟢 Interact Link`) — shows participant join URL banner at top of screen (enabled when session active); banner auto-hides after 20s with fade-out animation

**Sound → overlay-effect mapping (Mac-owned).** The tablet no longer decides
which sound triggers which visual effect. On every sound press it fires
`GET /sound/pressed/<file>` and on every stop `GET /sound/stopped/<file>` (bare
filenames), and the Mac looks the effect up in `SoundEffectMap.swift` — the
single source of truth (`onPress: [file → effect]`, `onStop: [file →
effect/stop]`) — then dispatches through the existing `onEffect` switch (reusing
all BT visual-compensation/sync logic). **Changing a mapping or adding a new
effect needs only a Mac rebuild — no tablet redeploy.** The siren
(`02_siren.mp3`) is the one exception: it drives the alarm overlay
(`/alarm/start`,`/alarm/stop`) and stays special-cased on the tablet. Effects
are CALayers on the overlay's `hostLayer`, animated via `CAKeyframeAnimation`
on `contents` from bundled gif frames (`Bundle.module`).

**Lifecycle rule (2026-07): every overlay effect MUST self-terminate at its
sound's length — network stop messages are an optimization, never the only
teardown.** The tablet's `/sound/stopped` → `onStop` chain (and even the
pre-press `/effect/stop-all`) is best-effort: on a flaky venue network the
tablet falls back to the Railway relay and those GETs get lost, which used to
leave looping overlays (star-wars, brother, gangnam, drum-roll) on the desktop
forever. Every `show*` therefore schedules its own authoritative stop —
`trackEffect(duration:)` for one-shots, or an explicit
`asyncAfter(realMp3Duration + 0.3s grace)` for loopers, reading the paired
mp3's length via `AVURLAsset` — **in the silent (`playSound: false`) tablet
path too**, since that's the path real presses take. Self-stop timers are
**identity-guarded** (`activeEffects[key] === layer`, the love-hands pattern)
so an old run's timer can never kill a newer run of the same effect. The one
deliberate exception is the siren's alarm overlay (an unbounded toggle — its
sound loops until explicitly stopped). When adding a new effect, follow this
rule from the start.
- **🩸 Blood drip** (sfx #40 `40_joker.mp3` → `blood-drip`): `blood-drip.gif`
  (white bg made transparent via ImageMagick `-coalesce -fuzz 20% -transparent`,
  full-canvas frames) shown as a blood band pinned to the **top of the screen**
  at full width (aspect-preserved, transparent backdrop over the live screen),
  drips/droplets falling; the ~1.6s loop plays **~1.5× slower**, repeating for
  the joker track (~9.0s) with a 0.25s fade-in and 0.6s fade-out tail.
- **🛰️ Sonar** (sfx #23 `23_radar.mp3` → `sonar`, `showSonar`): a full-screen
  black wash fades in (0→45% over 1s; darker **70% disc** inside the radar
  circle), then a phosphor-green radar **drawn entirely as CALayers** (no gif):
  muted-grey concentric rings + radial spokes; a **conic-gradient sweep arc**
  (bright +x leading edge, fading 100%→0% behind it, masked to the circle) that
  rotates **clockwise**. The sweep carries **ultrasound-style "reception noise"**
  (flickering green/black speckle frames generated in `makeSonarNoiseFrames`,
  masked to the wedge), and a fainter copy of the same noise covers the circle
  interior (background static; outside the circle is just the dark wash). A
  **💩 blip** (3× emoji, green glow) sits at the front's detection angle, hidden
  until found. It is drawn **over the sweep**, not under it — the green front and
  its reception noise used to wash across the find at the exact instant the find
  happens, which is the one moment it must be unmistakable; the wedge passing
  *behind* it now reads as the thing that revealed it. Each detection also
  **zooms it in**: it lands at **2×** and settles to its own size over **1 s**,
  cubic-ease-out so the motion is spent in the first third (it arrives, it
  doesn't creep). The zoom is sampled on the **same keyframe grid and the same
  `detT[di]`** as the opacity flash, so it starts on the exact frame the 💩
  becomes visible; between detections the scale is parked back at 2× ready for
  the next one, and that 1×→2× reset is placed **after** the fade has fully
  finished (`coverT + fadeT`) so it always happens at zero opacity and can never
  be seen. The rotation is **keyframed** (not constant): ~0.5s beep-free
  lead-in, then the front sweeps over the 💩 on **three radar beeps** in the clip
  (clip times 0.104/2.211/3.879s; one full turn between detections). The Mac
  **owns the audio** here — `showSonar(playSound:true)` plays `23_radar.mp3`
  delayed (`soundStartRel` + 0.1s) so the beeps land on the three detections; the
  effect ends (fading out **while still rotating**) the moment the 3rd detection's
  1s fade finishes, so the front never sweeps the 💩 a 4th time unshown. Pure
  formatting/timing is derived up-front from `beepClip`/`detT`/`animEnd`.
  **Trigger:** the effect is driven from the **routed `/sound/play/23_radar.mp3`**
  path (`onSoundPlay` special-cases it → `showSonar(playSound:true)` instead of
  `playTabletSound`), so when the tablet routes its soundboard audio to the Mac,
  the radar press plays the synced SFX **and** the visual with no double audio and
  **no tablet change**. `23_radar.mp3` is therefore intentionally **absent from
  `SoundEffectMap`** (the press path would otherwise double-trigger it). `/test/sonar`
  and `/effect/sonar` call `showSonar` directly for headless testing.
- **💸 Money** (tile #53, repurposed from rain): the Android tile #53 now shows
  a plain **💸 emoji on white** but keeps its asset id `53_rain.mp3` (so the
  routing protocol/manifest are unchanged). `onSoundPlay` **special-cases
  `53_rain.mp3`** (like the radar): it fires `showMoneyRise()` and plays the
  **#57 checkmark "ching"** (`57_checkmark.mp3`) instead of the original rain,
  returning the checkmark's duration. `showMoneyRise` swarms ~16 money emojis
  (`💸💵💰🤑`) **up from the bottom edge to off the top**, swaying + tumbling
  while fading out — **one round per press ("ching")**. It is a fire-and-forget,
  **non-tracked** burst (each emoji layer self-removes), so pressing the tile
  repeatedly **stacks overlapping rounds**. `53_rain.mp3` is intentionally
  **absent from `SoundEffectMap`** so a press = a single ching + single round (no
  double-trigger). `/test/money` and `/effect/money` call `showMoneyRise` directly.
- **🔫 Counter-Strike** (sfx #73 `73_counter_strike.mp3` → `counter-strike`,
  `showCounterStrike`): the two CT operators (a transparent PNG,
  `Resources/counter-strike.png`, **pre-trimmed to its opaque content** so there is
  no transparent margin lifting them off the edge) stand in the **bottom-left
  quarter** of the retina — fitted aspect-preserved inside half-width × half-height,
  anchored at the bottom-left corner, **glued to the bottom screen edge** — snapping
  up into place over 0.18 s. It lives exactly as long as the clip (**duration read
  from the mp3** via `AVURLAsset`, ~1.36 s, falling back to that measured value) and
  fades out over its last 0.3 s. Driven from the **press path** (`SoundEffectMap`),
  so the routed `/sound/play/73_counter_strike.mp3` supplies the audio and the
  visual never double-triggers. `/test/counter-strike` and `/effect/counter-strike`
  fire it silently; the menu item **Counter-Strike 🔫** (Desktop Effects) too.
- **❄️ Snow** (tile #46 `46_michael_buble.mp3` → `snow` / `snow/stop`, `showSnow`):
  **tile #46 IS the Christmas tile** — Michael Bublé's *"It's Beginning to Look a Lot
  Like Christmas"*, snow already falling in its artwork — so pressing it now snows on
  the desktop for the length of the clip (~10.5 s, read off the mp3 via `AVURLAsset`).
  The flakes are **drawn, not emoji** (`snowflakePath`: six spokes, two branch pairs
  each — the least detail that still reads as a snowflake and not an asterisk), white
  stroke with a white glow, because ❄️ renders as the system's blue-tinted glyph and
  what is wanted here is white snow over whatever is on screen. **One number — depth
  0…1 — drives size, fall speed, brightness and sway width together**, so a flake can
  never read as a contradiction (big but distant, tiny but racing); near flakes are
  20 px, bright and cross in ~5 s, far ones 5 px, faint and take ~9.5 s. Each falls
  along a keyframed sine sway plus a net sideways drift, tumbling slowly (only
  `transform.rotation.z` is animated — the size is baked into the path, so nothing
  fights over `transform`), then **lands on the bottom edge and melts** over 1.4 s:
  the descent is the first `landed` fraction of the timeline and the repeated final
  point is the hold. **Every flake enters through the top edge** — none is ever
  dropped in mid-screen, which reads as flakes materialising out of nowhere rather
  than as snow falling. So the opening cascade is stacked *above* the screen instead:
  `snowSeedCount` = 26 flakes released at staggered heights over the top edge, at the
  same constant fall speed (starting higher means entering *later*, never falling
  faster), which fills the sky within ~2 s while each flake still makes the whole
  journey down. Then 16 flakes/s, stopping `snowLastSpawnBeforeEnd` = 1.5 s before the
  clip does — a flake entering the frame just as everything melts reads as a glitch.
  **The snowfall lasts exactly as long as the song**: the melt starts on the clip's
  last moment (an identity-guarded self-stop at `sfxDuration`, which is also the
  lifecycle rule's authoritative teardown) and the desktop is clear a second later.
  The tablet's `/sound/stopped` → `snow/stop` melts it early through the same 1 s
  fade, so stopping the sound stops the snow; pending spawns are cancelled by `clearSnow`,
  which `stopAllActiveEffects` calls explicitly (they live outside `activeEffects`,
  like the spiral hearts'). `/test/snow`, `/test/snow/stop`, `/effect/snow` and the
  menu item **Snow ❄️** fire it silently.
- **⏲️ Microwave** (tile #61, repurposed from "dinner"): a **kitchen timer ticks and
  the microwave's door swings open on the BING**. `61_dinner.mp3` is now a few
  seconds of ticking followed by a bell (the ticking was lifted +12 dB against the
  bell so it survives a room PA; the bell keeps its full dynamic punch), and
  `showMicrowave` puts a translucent (85%) cartoon microwave in the middle of the
  desktop, fitted aspect-preserved inside **80% of the screen**. **The entire point
  is one sync**, so the cue is *measured off the file*, not guessed:
  `EmojiAnimator.microwaveBingOnset` = **2.695 s**, the beginning of the rising
  front toward the peak (peak at 2.700 s) — re-cutting the clip means re-measuring
  that number. The 16 gif frames are **NOT a loop** (frame 0 = closed door, frame
  15 = fully open), so the layer holds frame 0 through the ticking and only then
  runs the swing at the gif's native 25 fps (0.64 s), holding the open door through
  the bell's decay before fading out with it. That fixed **in-clip** offset is why
  the effect **owns its own audio** on the routed `/sound/play` path (the radar's
  pattern) and is deliberately **absent from `SoundEffectMap`**: a separate press
  round-trip cannot be trusted to land on the same millisecond, and mapping both
  would open a second door with no bell behind it. On Bluetooth output the **whole
  visual timeline shifts by the same A2DP compensation** the audio does
  (`clock0 = CACurrentMediaTime() + btComp`), so the door never flies open ahead of
  the sound reaching the speaker. The art (`Resources/microwave.gif`) is cropped to
  its content **symmetrically about the source frame's centre** — minimal, but the
  closed microwave still sits dead-centre and the door keeps room to swing out to
  the left. The tablet thumbnail is the gif's **own first frame** (door shut), so
  the tile shows the "before" of the animation it fires. `/test/microwave`,
  `/effect/microwave` and the **Microwave ⏲️** menu item all fire it **with sound** —
  the one Desktop-Effects item that is not silent, since a soundless microwave
  would just sit there for 2.7 s and then open for no reason.
- **🕳️ Iris close** (tile #31, repurposed from Tarzan): a cinematic "iris out"
  blackout. The Android tile #31 is redrawn as a **black circle
  with a white centre and four inward-pointing arrows** (vector `sfx_31_iris.xml`);
  its own mp3 is a **silent clip** but keeps the asset id `31_tarzan.mp3` (protocol/
  manifest stable). It **stays in `SoundEffectMap`** (`31_tarzan.mp3` → `iris`):
  the **press path** drives the visual, so it isn't double-triggered. **Paired
  sound:** the iris was originally soundless, but to keep **every** tablet
  thumbnail audible on the Mac, `onSoundPlay` now special-cases `31_tarzan.mp3` to
  play the **dramatic gong** (`50_gong.mp3`, ~8.6s ≈ the iris length) — like
  radar/money, the routed play path owns the sound while the press path owns the
  visual. `showIrisClose` itself stays silent (the CALayer effect plays no audio).
  `showIrisClose` overlays a **radial
  `CAGradientLayer`** (square, side = screen diagonal, so the gradient is a true
  circle and location 1.0 lands on the corners) — transparent centre, opaque
  black edge, with a soft transition band. Animating the gradient `locations`
  shrinks the clear hole from the screen-circumscribing circle (nothing hidden)
  to nothing over **5s** (`.easeIn`) — black creeps in **from the corners** and
  swallows the screen. It then **dwells ~1s on full black and auto-fades back out
  over ~1s** to reveal the screen (no second press needed). **Pressing the tile
  again** before that auto-reveal cancels early with a quick (~0.35s) fade
  (`cancelIris`). The effect is deliberately **kept out of `activeEffects`** so
  `stopAllActiveEffects()` (which the tablet fires before *every* press) leaves it
  alone — that's what lets the second press reach `showIrisClose` and toggle
  instead of being wiped + restarted. `/test/iris` and `/effect/iris` call
  `showIrisClose` directly.

- **🙅 Wasn't me** (tile #76 `76_sfx_118.mp3` → `wasnt-me`, `showWasntMe`): a 3D hand
  wagging its index finger "no-no", parked in the **bottom-left (SW) quarter** of the desktop
  for exactly as long as the clip runs, then fading out on its own over the last 0.8 s. The
  art is a 24-frame transparent GIF looping in under a second, so unlike the one-shot overlays
  (cavalry, counter-strike) the frames **repeat forever and the sound decides when it is
  over** — the gesture is a denial held for as long as the denial is being sung, not a thing
  that happens once. Length is read off the mp3 (6.55 s) rather than hardcoded, so a re-cut
  clip stays in sync. It is **centred in the quadrant, not glued to the corner** the way the
  Counter-Strike operators are: those stand on the screen edge, this is a floating hand, and a
  hand jammed into the corner reads as a cropping accident rather than a gesture. Fitted
  aspect-preserved inside **80 %** of the quarter — that margin is what keeps it off both
  screen edges. Head and tail are **one keyframe opacity track**, not two animations, so the
  fade-out can never begin before the fade-in has finished on a short clip.

- **🔫 Minigun** (sfx #22 `22_minigun.mp3` → `bullet-holes`, `showBulletHoles`): the burst
  that punches bullet holes around the cursor now has a **visible shooter**. A pixel-art
  minigun sprite (`Resources/minigun.gif`, 64 frames, transparent, top empty rows cropped)
  sits **flush with the screen's bottom edge** and **slides west–east with the mouse at half
  its travel** (`minigunSpriteMouseFollowRatio = 0.5`): body x = `mouseX / 2`, so swinging the
  crosshair 400 px right hauls the gun 200 px after it, as if you were dragging the weapon
  around to keep it on target. Half-rate is not just "slower" — mapping to `mouseX / 2` keeps
  the gun in the **west half at all times**, so it stays *behind* the bullets it fires however
  far east you aim, and at `mouseX = W/4` it lands exactly on the `W/8` the sprite used to be
  nailed to (the horizontal half of the "north-west sub-sector of the south-west quadrant").
  Vertically it is pinned to `y = 0` rather than floating at `3H/8`. The x update rides the
  **same 60 fps tick as the aiming reticle** (`startMinigunReticle(following:)`) — one timer
  moves both, so the gun can neither lag a frame behind the crosshair nor outlive it; the
  weak `_minigunGunLayer` is cleared in `stopMinigunReticle`, the layer itself being owned by
  the burst container. The art is first-person: the mount runs off the bottom of
  the sprite frame, so floating it shows a sawn-off base hanging in mid-air, while sitting it
  on the edge reads as the gun *rising out of* it (`minigunSpriteSitsOnScreenBottom = false`
  restores the floating placement). From there the barrel lines up with the holes appearing
  out in the middle of the desktop: the gun is **on the bullets' trajectory**, not decoration
  parked in a corner. The sprite is drawn firing **north-west**, so it is **mirrored on the
  X axis** to fire east, into the desktop; `minigunSpriteFacesWest = false` shows it as drawn
  if the other orientation is ever wanted. What gets placed on the tracked x is not the frame
  centre but the **gun body** (`minigunSpriteGunCentre`, the bbox of the pixels opaque in
  *every* frame — receiver and barrel, no muzzle flash, no casings): most of the frame is
  empty sky for the ejected brass, and centring that emptiness would shove the gun off-screen.
  Width is 44 % of the screen *for the whole frame*, which puts the gun body itself at ~20 %
  and lets the casings arc up and to the right over the lower-left of the desktop;
  aspect-preserved, drawn
  with **`.nearest` magnification** — bilinear smoothing at that scale turns the barrels into
  grey mush. The 64-frame loop keeps the source gif's own **0.02 s/frame — 1.28 s a turn**:
  the muzzle flash cycles every 8 frames (~6 flashes/s, a believable cyclic rate) while the
  casings need all 64 to finish their arc, so speeding the loop up would fling the brass out
  at a comic speed. It rides **inside the burst's own container**, so `trackEffect` and a
  cancelling re-press take it down with the holes; the tail's "resorb" shrink pass skips it
  **by identity** (`hole !== gun`) so the gun doesn't implode along with the bullet holes.
  Its opacity is **one keyframe track** (the wasn't-me pattern) with `beginTime` at
  `minigunAimLeadIn`, so during the 0.5 s aiming window only the reticle is on screen, the
  gun appears on the first shot, and it has faded out by the time the last hole is resorbed.

- **🪚 Chainsaw cursor** (tile #18 `18_chainsaw.mp3` → `chainsaw` / `chainsaw/stop`,
  `showChainsawCursor`): for the length of the clip **the mouse pointer IS a running
  chainsaw** — the real cursor is hidden and a 16-frame sprite loops on it, chasing
  `NSEvent.mouseLocation` at 60 fps. It is the third member of the hidden-cursor family
  (💘 spiral-hearts' beating heart, 🔫 minigun's reticle) and follows their rules: it lives
  **outside `activeEffects`** because it owns a follow timer *and* a hidden system cursor,
  so `stopAllActiveEffects` tears it down **explicitly** — a generic sweep would drop the
  layer and leave the desktop with **no visible pointer at all**. The hide is armed through
  `armBackgroundCursorHiding()` (the private `SetsCursorInBackground` flag) so it also
  applies while Victor is in someone else's app, and the unhide is balanced by a single
  `_chainsawHidCursor` flag so a spurious stop can't force the cursor back mid-run.
  - **Art**: `Resources/chainsaw-frames.png`, a **4×4 sprite sheet**, not a gif. The smoke
    puff and the antialiased blade need real **8-bit alpha**, and gif carries 1-bit — a gif
    of this fringes white against a dark desktop. The 16 equal cells are sliced once with
    `cropping(to:)` into a **lazy static** (`chainsawFrames`): a press must be instant
    because the cursor is already moving, so the ~1.7 MP sheet is never re-decoded per
    press. The sheet is quantised to 255 colours (1.8 MB → 329 KB, visually identical at
    450 pt) — palette PNG keeps per-entry alpha, so the soft edges survive.
  - **Anchor**: the layer's `anchorPoint` is the **blade tip** (x ≈ 380/418, y ≈ 115/236
    from the top — the mean of the 16 frames' rightmost saw pixel, excluding the frames
    whose rightmost pixel is flying sawdust). The tip is what lands on the pointer and the
    engine hangs down-left of it, the same relationship the arrow cursor has with its own
    top-left hotspot; centring it instead would put the pointer in the middle of the engine
    block and the saw would read as decoration rather than as the thing doing the pointing.
    Sawdust therefore sprays to the **right of** the hotspot — i.e. out of the cut.
  - **Timing**: 16 frames at **15 fps** (1.07 s rev cycle). It started at 24 fps and read as
    *twitching* — the source frames jitter in position as well as in shape, and at that speed
    the eye tracks the jumps instead of the saw; slowing it turns the same jitter back into
    the heavy vibration a chainsaw at rest actually has. Width **450 pt**, height
    aspect-derived; `zPosition` 9500 so it rides above every other effect (it is the
    pointer). Fade-in is **0.12 s** — the cursor is a thing you are already looking at, and
    a slow fade there reads as lag. The fade-out is 0.25 s and the real cursor comes back
    only **after** it finishes, so the two are never on screen together.
  - **Lifecycle**: length read off `18_chainsaw.mp3` via `AVURLAsset` (~6.09 s, with that
    value as the fallback) and self-stopped at it, **generation-guarded** so an old run's
    timer can't kill a newer one. The lifecycle rule matters more here than anywhere else:
    a lost `/sound/stopped` on a flaky venue network would otherwise leave the desktop with
    no cursor. The tablet's stop still shortens it through `onStop` → `chainsaw/stop`.
    Press path only (`SoundEffectMap`), so the routed `/sound/play/18_chainsaw.mp3` supplies
    the audio and the visual never double-triggers. `/test/chainsaw`, `/test/chainsaw/stop`,
    `/effect/chainsaw` and the menu item **Chainsaw Cursor 🪚** fire it silently.

- **🌈 Rainbow + 🦄 unicorns** (tile #37 `37_rainbow.mp3` → `rainbow` /
  `rainbow/stop`, `showRainbow`): seven translucent bands drawn as a **quarter**-arc —
  the circle's centre is pushed onto the right screen edge, so only the left quarter of
  it is on screen, tucked into the bottom-right corner — smeared in over 2.5 s with a
  `strokeEnd` wiper. The window is **read off the mp3** (13.9 s), not the old 5 s
  default, because the tablet-routed path plays the same clip and used to fade the arc
  ~9 s before the music ended; `stopRainbow()` then fades the container to 0 over 0.8 s.
  Since 2026-08-26 **unicorns hop across it** (`spawnRainbowUnicorns`): seven 🦄 text
  layers, alternating directions, each entering from one edge and bouncing to the other
  along a six-hop quad-curve path (control point at 2× the hop height, so the apex lands
  at 1×), `.paced` so the speed is even along the arcs rather than per-hop. Left→right
  runners are **mirrored** (`CATransform3DMakeScale(-1, 1, 1)`) — the Apple 🦄 glyph
  faces left, and a unicorn running backwards is the first thing the room notices. Each
  fades out at 60 % of its own crossing, i.e. **while the arc is still unrolling**, and
  the departures are spread across the whole window so one or two are in flight at any
  moment instead of a herd leaving together. They are **children of the rainbow
  container**, so they need no tracking of their own: the one identity-guarded
  `activeEffects["rainbow"]` entry tears the whole scene down.

- **💓 Heartbeat + 🐶 dog** (tile #13 `13_heartbeat.mp3`, `showHeartbeat`): the built-in
  Retina is captured and redrawn full-screen, then **bulged under the cursor** in a
  lub-dub keyframe, twice per cycle, with the lens **re-centred on the live mouse
  before every beat** — the screen beats wherever the cursor rests.
  Until 2026-08-27 the beat was a whole-screen `transform.scale` 1.0 → 1.30 → 1.0
  pivoted on the pointer, and that put the *largest* displacement where nobody is
  looking: a corner 1500 pt from the pivot swept ~450 pt per thump, so the periphery
  lurched while the thing under the cursor barely moved — dizzying rather than alive.
  It is now a **`CIBumpDistortion` in `imgLayer.filters`** (`HeartbeatBump`): a convex
  lens over the **40% of the screen area** around the pointer (πr² = 0.40·W·H, ~496 pt
  on the Retina). It started at 10% / ~248 pt; on 2026-08-27 Victor asked for the beat
  to be **twice as big — the size, not the amplitude** — and the size of a disc is how
  wide it reads, so the radius doubled and the area it sits on quadrupled. `inputScale`
  is unchanged at 0 → 0.5 → 0, driven by a keyframe animation on the
  `filters.bump.inputScale` key path — which is why the filter is installed with a
  `name`. Outside its radius the filter is the **identity**, so the periphery is not
  merely moved less, it is not moved at all; what is left of the old zoom is a 2%
  `breatheScale` pivoted at the *centre* (~17 pt of corner travel, versus 270), on the
  same `beginTime` so the two halves cannot drift apart. Measured on screen, not
  assumed: CoreAnimation resolves filter coordinates in **layer points and compensates
  for `contentsScale`**, so the same numbers land identically on a 1x and a 2x display.
  Past `inputScale` ≈ 0.7 the middle of the lens stretches into a fisheye smear. **Driven from the
  routed `/sound/play` path** (`onSoundPlay`), like the radar and the microwave, and
  therefore **out of `SoundEffectMap`** so the press cannot fire it a second time. That
  is what makes it land: the visual used to come off the press while a *separate* HTTP
  request started the audio, and the pulse clock then started from whenever the async
  `screencapture` happened to return — so every zoom sat a few hundred variable ms
  behind its thump. Sound and visual now share one origin, `clock0`, stamped the moment
  the clip is handed to `playTabletSound` (plus `btComp`, which is warm-up silence that
  really does delay the audio). The second half of the fix is **which part of the zoom
  lands on the beat**: the eye reads the *peak* as the hit, so a cycle begins `rise`
  seconds BEFORE its onset and tops out exactly on it — starting the rise on the onset,
  as it did, puts the peak half a pulse late and reads as lag even off a perfect clock.
  `heartbeat_beats.json` holds the **rising edges measured off the clip itself** (20 ms
  RMS envelope, `[lub, dub, lub, dub …]`, 9 pairs), and each pair is now played at its
  own onset instead of on an imposed uniform period. Each cycle's callback is armed
  `heartbeatArmLead` (60 ms) early and only hands CoreAnimation an animation whose
  `beginTime` is already the exact instant, so main-thread jitter never reaches the
  screen; deadlines are absolute and independent, so a beat whose moment has already
  passed is **skipped rather than fired late** — one missing thump is invisible, a whole
  timeline shifted behind the audio is the ugly part. A press **preempts** a running
  heartbeat (`cancelIfRunning`) rather than being swallowed: being swallowed would
  answer the tablet with "no sound" and send it back to local playback, and restarting
  is what `playTabletSound` does to the audio anyway. Since 2026-08-26 a **chihuahua rides on top of it** (`heartbeat-dog.png`,
  `makeHeartbeatDogLayer`), sized to **two thirds** of the aspect-fit of the
  **left half of the screen** (`heartbeatDogScale` — filling that half outright made the
  dog the subject and the beating screen its backdrop, which is the wrong way round),
  centred in the half and bottom-aligned — the photo is cropped at the chest, so letting the body run
  off the bottom edge is what makes it read as a dog leaning into frame rather than a
  sticker floating in mid-air. The asset is the source photo with its background
  flood-filled from the corners to **real alpha** (not a coloured box), so the pulsing
  capture shows through around the fur. **Which photo matters more than the fuzz value**:
  the first attempt cut the dog out of a white studio shot, and a chihuahua's pale ear
  fades into white so gradually that no single threshold separates the two — 10 % chewed
  notches out of the ear, and dropping to 2 % (which spared it) left behind the very
  background it was there to remove. The shot actually shipped sits on flat lavender
  (`#A3ABCF`), nowhere near cream fur, so **8 % is clean at the edges *and* nowhere near
  the ear**. It is **not mirrored**: this photo already faces the way the effect needs
  (muzzle pointing right, i.e. into the screen from the left half) — the flop the
  white-background version needed was a property of that framing, not a rule.
  The dog is a **sibling of the capture layer, not a child**: the pulse animation is
  added to the capture alone, so the screen zooms while the dog stays nailed down.
  Both live inside a **container**, and it is the container that goes into
  `activeEffects` — one tracked unit, so `stopAllActiveEffects()` and `trackEffect`'s
  auto-cleanup tear the pair down together instead of leaving a dog behind. The
  container is also what the debounce and every re-entrancy guard compare against
  (`activeEffects["heartbeat"] === container`), including inside `scheduleHeartbeatPulses`,
  which still animates the capture layer but validates the container. The dog carries **no sound of its
  own** — the whole effect is scored by the one clip the same call started.

  **🐶💨 It bolts from the cursor** (`watchHeartbeatDog` + the pure, unit-tested
  `HeartbeatDogFlee`): land the pointer on the dog and it leaps to the *other* half of
  the screen, turning to face the middle at the apex of the arc so it still looks into
  the screen from either side. That is the joke the effect was missing — the screen is
  having a panic attack around your pointer, and the one thing on it that is alive
  treats the pointer as the thing to run from. Chase it and it keeps bouncing side to
  side. Mechanics worth knowing before touching it: the overlay panel is **click-through
  and receives no mouse events at all**, so the cursor is *polled* (`NSEvent.mouseLocation`,
  20 Hz — well under the reaction time this imitates) for exactly as long as the effect
  lives, and the timer cancels itself the moment this is no longer the active heartbeat,
  so a stop-all never leaves it running. The hit box is **inset 14 % horizontally**: the
  trimmed PNG still carries transparent corners either side of the ears, and bolting
  from a cursor that is visibly beside the dog reads as a bug, not as a scare. After a
  leap the cursor is **ignored for the length of the hop** — otherwise the dog is
  re-startled by the very pointer it is still jumping away from and never lands. The two
  resting positions are just the screen's quarter and three-quarter marks, since the dog
  is centred inside its half — none of this needs to know how wide the dog is. The arc's
  height is proportional to the distance, with a cap that on the retina never binds (a
  full half-screen leap arcs ≈212 pt against a 216 pt cap); the cap is there for other
  overlay shapes.
