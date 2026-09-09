# 🏁 End of training

One button that ends the workshop by itself: press 🏁 on the tablet, keep talking, and
when the room has actually gone quiet the Mac runs a finish-line countdown and plays
**"over and out"** (`82_over_and_out.mp3`).

| piece | where |
|---|---|
| the button | `victor-vibe-board`: `main_menu.xml` (`action_training_end`), wired in `MainActivity.onCreateOptionsMenu` |
| the state machine | `TrainingEndSequence.swift` (+ its pure `Policy`, tested in `TrainingEndPolicyTests`) |
| the countdown bar | `ProgressBarOverlay.start(seconds:rider:)` — the ordinary yellow bar, with 🏁 riding its head |
| "is anyone speaking?" | `whisper_runner.py` → `VICTOR_VOICE:<label>` → `WhisperProcessManager.onVoice` |
| the route | tablet `GET /effect/training-end` → `AppDelegate`'s effect switch → `trainingEnd.toggle()` |

## Why it exists

The last minutes of a workshop have no ending. The slides are done, but someone is still
finishing a question, someone else is packing up, and Victor cannot both hold that last
conversation and watch for the moment the room stops. So the decision ("we're done") and
the execution ("…and now we're actually done") are split: he arms it whenever he decides,
from the tablet, and then simply keeps talking. The sequence waits out the tail.

## The two clocks

**Ten seconds of silence** (`Policy.silenceRequired`), then **ten seconds of countdown**
(`Policy.countdown`). Both numbers, and the split itself, are the design:

- The **silence phase** decides *whether* we are ending. A pause for breath mid-sentence is
  a second or two; ten seconds of nothing is not a pause, it is a room that has finished.
  Nothing is drawn during this phase — there is nothing to say yet.
- The **countdown phase** is the *announcement*, drawn as the yellow bar so the room can see
  the session closing and has one last window to speak into.
- A single word during the countdown sends it **all the way back to the silence phase**:
  the bar disappears and a full ten seconds of quiet has to be earned again. Not paused —
  withdrawn. An announcement somebody talks over was wrong, and resuming it from 6 s would
  end the session on a countdown that was contradicted while it ran.

So the shortest possible path from press to "over and out" is 20 s, and a chatty room can
hold it open indefinitely, which is the correct behaviour for both.

## Where "someone spoke" comes from

**Not from a second microphone tap.** `whisper_runner.py` is already listening on both
channels that matter — Victor's XLR/wireless mic and the room feed coming back from Zoom —
and already computes a per-block RMS against a per-device threshold to decide what is worth
transcribing (`docs/transcription.md`). `_report_voice` simply prints `VICTOR_VOICE:<label>`
whenever a block clears that bar; `WhisperProcessManager` parses it like `VICTOR_SOURCE:`
and hands it to `TrainingEndSequence.noteVoice()`.

That means **"the room is quiet" is defined as "whisper has nothing to transcribe"** — same
devices, same thresholds, one definition for the whole app. A second audio tap with its own
gate would have been a second definition, and the two would disagree exactly on the
marginal blocks that decide whether a workshop ends.

Two consequences worth knowing:

- **Throttled to one pulse a second per channel** (`_VOICE_PULSE_SEC`). The callback runs on
  the PortAudio thread and must stay cheap, blocks arrive every 100 ms, and the listener only
  cares *when* someone last spoke — not how often or how loudly. The pulses are deliberately
  **not** logged, unlike every other whisper line.
- **With whisper stopped, the room reads as silent.** Transcription is AC-power-driven; on
  battery no pulses ever arrive, so an armed sequence sees silence from the moment of arming
  and runs its full 20 s. This is the main reason arming is a **toggle**.

## The toggle, and who owns the truth

Pressing 🏁 again calls the whole thing off. It has to be cancellable: arming is otherwise
irreversible from the tablet, and the wait is long, silent and (on battery) not listening to
anything. `/effect/stop-all` disarms it too — "silence everything" must not leave a sequence
armed that would put the bar straight back up.

The **Mac is the authority** on armed/disarmed, because it disarms *itself* when the
countdown runs out. The tablet chip therefore mirrors `trainingEndArmed` off every `/ping`
(`MacLink.trainingEndArmed`) rather than tracking its own presses: a locally-owned flag would
be stuck on "armed" after the session ended, and the next press of a toggle would then **arm**
what it looked like it was cancelling. The press still paints the chip immediately —
pings are 5 s apart and a button that ignores its own press for five seconds feels broken —
and the next ping corrects it if the Mac disagreed. A dropped link clears the chip, same as
`macScreenLocked`.

## The bar, and the flag on it

The countdown reuses `ProgressBarOverlay` unchanged — same full-width yellow fill, same
white seconds-remaining number — with one addition: `rider: "🏁"`, an emoji pinned to the
**leading edge of the fill**, travelling left→right with it. The head is the only part of the
bar the eye tracks, so that is where the finish line belongs; a flag parked at the right end
would just be decoration on the destination.

The rider's `position.x` animation shares the fill's duration, span and linear curve, so the
two cannot drift apart. Its `anchorPoint.x = 1` puts the glyph's right edge on the head —
it stands on the yellow rather than out ahead of it on bare desktop, and comes to rest flush
against the screen edge instead of half off it. The cost is the first fraction of a second,
where the head is still too close to the left edge for the whole glyph to fit; centring it
instead would have cut the flag off at **both** ends of the run.

The sequence does **not** hang its payoff on `ProgressBarOverlay.onComplete`. That bar is
shared with the tablet's 3s/5s/7s/10s timers, and a 3s press landing mid-countdown would
otherwise inherit "over and out". The sequence's own 0.1 s tick is the single authority on
when the countdown is over, so there is no second clock to race — the worst the sound can
lag the fill reaching the right edge is one tick, which is well under the bar's own fade.
The sequence retires itself **before** playing, too: "over and out" comes out of the speakers
loudly enough for the mic to hear it, and a still-armed sequence would take its own sound
for the room talking.
