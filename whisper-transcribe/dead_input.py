"""The DJI transmitter is dead, and the receiver is still on USB.

2026-09-26: the DJI Mic Mini transmitter (the clip-on, radio to the receiver)
died after ~5 h of teaching and Victor carried on talking into nothing. The Mac
only sees the **receiver** (`Wireless Mic Rx`, `DJI Technology Co., Ltd.`), and
the receiver does not disappear when its transmitter does: it stays a perfectly
healthy input that delivers **exact zeros**. Nothing else in this process can
see that — blocks still arrive every 100 ms, so `_capture_stall_watchdog` is
satisfied, and a zero block is merely "below threshold" to the transcription.

The signal is the one a working microphone chain does not produce: **digital
silence**, peak == 0.0 over a whole window. A quiet room is not that — a
lavalier, its radio link and the receiver's converter always leave noise in the
low bits — so this watch does not compare against a threshold at all: a single
non-zero sample resets it. (Unmeasured on the DJI itself: whether its noise
cancelling ever gates a quiet room to hard zeros. If it does, 20 s of him not talking
would raise a false alarm; the raise and the resume are both logged, so the
first one will show which it was.)

Scope: only while the resolved input is the DJI receiver (`is_dji_receiver`).
The XLR, the Stage speakerphone and the built-in mic have no "receiver alive,
transmitter gone" state; a digital-zero stream from them is a different bug with
a different cure, and alarming on it would teach Victor to ignore the alarm.

What it cannot see: a transmitter that is on but *muted*, or a receiver whose
DJI noise gate ever outputs hard zeros for 20 s of a lecture — neither has been
observed. The receiver itself also reports "no transmitter linked" and a battery
gauge over its vendor USB interface (see `tools/dji-rx-status.py`); that is the
better signal and the next step once it has been run against the hardware.
"""

from __future__ import annotations

# How long the input must be exactly zero before the alarm goes up.
#
# 20 s: long enough that no pause in speech, no sentence-long silence while he
# types, and no transmitter re-link (a couple of seconds) can trip it — those
# are never *bit-exact* zero anyway, so the window only has to cover the rare
# case where the receiver hard-mutes briefly (reconnecting, gain dial turned).
# Short enough that Victor learns it within a sentence or two of the next thing
# he says: a whole minute is a paragraph of the lesson lost to the recording,
# and on 2026-09-26 he did not notice for far longer than that.
WINDOW_SECONDS = 20.0


class DigitalSilenceWatch:
    """Fires once per unbroken run of exact-zero audio longer than `window`.

    Pure and clock-injected so it can be tested without a microphone. Fed one
    block at a time from the PortAudio callback; must stay cheap.
    """

    def __init__(self, window: float = WINDOW_SECONDS):
        self.window = window
        self._zero_seconds = 0.0
        self._started_at: float | None = None
        self._fired = False

    @property
    def fired(self) -> bool:
        return self._fired

    def feed(self, peak: float, block_seconds: float, now: float) -> str | None:
        """Account one block; return an event, or None.

        `"dead"` once the zeros have lasted `window` seconds (then never again
        until the audio comes back), `"alive"` on the first non-zero block after
        a `"dead"` — which is also what re-arms the watch, so a transmitter that
        comes back and dies again alarms a second time.
        """
        if peak != 0.0:
            was_fired = self._fired
            self._zero_seconds = 0.0
            self._started_at = None
            self._fired = False
            return "alive" if was_fired else None
        if self._started_at is None:
            self._started_at = now
        self._zero_seconds += block_seconds
        if not self._fired and self._zero_seconds >= self.window:
            self._fired = True
            return "dead"
        return None

    @property
    def silent_since(self) -> float | None:
        """Wall-clock time of the first zero block of the current run."""
        return self._started_at


def is_dji_receiver(name: str, devices: list[dict]) -> bool:
    """True when `name` is the DJI Mic receiver, matched on name AND maker.

    The same rule as walkie-talkie's `InputDevice`: the receiver is a generic
    `Wireless Mic Rx`, and only the CoreAudio manufacturer says DJI. `devices`
    is `coreaudio_devices.list_input_devices()`; the sounddevice name and the
    CoreAudio name can differ in spacing, hence the loose comparison.
    """
    lname = name.lower()
    if "wireless mic" not in lname:
        return False
    norm = "".join(ch for ch in lname if ch.isalnum())
    for d in devices:
        dn = "".join(ch for ch in d.get("name", "").lower() if ch.isalnum())
        if dn and (dn in norm or norm in dn) and "dji" in d.get("manufacturer", "").lower():
            return True
    return False
