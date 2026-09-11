"""The training corpus is only worth what its filter is worth.

Two things are tested here and they are not the same thing:

* the **window** — a pure function of a `datetime`, so it is tested exhaustively
  and without a clock. It is the part most likely to be edited by hand later;
* the **segmentation and the gate** — fed synthetic speech and synthetic noise
  through the real queue and the real writer thread, and judged by what lands on
  disk. Testing `_judge` directly would prove the rules and prove nothing about
  the machine that calls them, which is where the pre-roll, the hangover and the
  tail trim live.
"""

import sys
import time
import wave
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import corpus_recorder as cr  # noqa: E402

SR = cr.SAMPLE_RATE
BLOCK = int(SR * 0.1)


# ── Window ───────────────────────────────────────────────────────────────────
def test_window_weekday_office_hours():
    w = cr.Window.parse("Mon-Fri 09:00-17:00")
    assert w.contains(datetime(2026, 9, 11, 10, 0))  # Friday morning
    assert not w.contains(datetime(2026, 9, 11, 8, 59))
    assert not w.contains(datetime(2026, 9, 11, 17, 0))  # end is exclusive
    assert not w.contains(datetime(2026, 9, 12, 10, 0))  # Saturday


def test_window_accepts_lists_and_wrapping_ranges():
    assert cr.Window.parse("Mon,Wed 08:00-20:00").days == frozenset({0, 2})
    # Fri-Mon is honest input: Fri, Sat, Sun, Mon.
    assert cr.Window.parse("Fri-Mon 09:00-17:00").days == frozenset({4, 5, 6, 0})


def test_window_always_is_distinguishable_from_a_wide_window():
    always = cr.Window.parse("always")
    wide = cr.Window.parse("all 00:00-23:59")
    assert always.always and not wide.always
    assert always.contains(datetime(2026, 9, 13, 3, 0))  # Sunday, 3 a.m.


@pytest.mark.parametrize("spec", ["", "Mon-Fri", "Mon-Fri 17:00-09:00", "Xyz 1-2"])
def test_a_bad_window_refuses_rather_than_falling_back(spec):
    """The tempting fallback is "always", and it is the wrong failure.

    A typo that means "collect nothing" is loud — nothing shows up. A typo that
    means "collect everything" silently records evenings and weekends, which is
    the one outcome this feature promises not to produce.
    """
    with pytest.raises(ValueError):
        cr.Window.parse(spec)


# ── Speech-likeness ──────────────────────────────────────────────────────────
def _speechy(seconds, amp=0.2):
    """Voiced speech is a buzz at 80–250 Hz with harmonics all through the band.

    A pure tone would be the wrong fixture: it has one line in the spectrum and
    would pass or fail the band test for reasons real speech never has.
    """
    t = np.arange(int(SR * seconds)) / SR
    sig = np.zeros_like(t)
    for k, gain in enumerate([0.3, 1.0, 0.9, 0.7, 0.5, 0.3], start=1):
        sig += gain * np.sin(2 * np.pi * 120 * k * t)
    return (amp * sig / np.abs(sig).max()).astype(np.float32)


def _hum(seconds, amp=0.2):
    t = np.arange(int(SR * seconds)) / SR
    return (amp * np.sin(2 * np.pi * 50 * t)).astype(np.float32)


def test_speech_band_separates_voice_from_hum():
    assert cr.speech_band_ratio(_speechy(1.0)) > cr.MIN_SPEECH_BAND
    assert cr.speech_band_ratio(_hum(1.0)) < cr.MIN_SPEECH_BAND


# ── The recorder, end to end ─────────────────────────────────────────────────
class _Clock:
    """A clock that only moves when the test says so.

    The recorder stamps every sample with `datetime.now()` and the window is
    read on every block, so a real clock would make both the filenames and the
    "is it office hours" answer depend on when the suite happens to run.

    `step` exists because a completely frozen clock is its own bug: every sample
    would start in the same millisecond and therefore want the same filename.
    One millisecond per read is enough to keep the stamps apart while staying
    far inside any window under test.
    """

    def __init__(self, at, step_ms=1):
        self.at = at
        self._step = timedelta(milliseconds=step_ms)

    def __call__(self):
        now = self.at
        self.at = self.at + self._step
        return now


def _feed(rec, audio, threshold=0.02):
    for i in range(0, len(audio) - BLOCK + 1, BLOCK):
        rec.write(audio[i : i + BLOCK], threshold, "Test Mic")


def _settle(rec, expect, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if rec.kept + rec.dropped >= expect:
            return
        time.sleep(0.02)


def _wavs(root):
    return sorted(Path(root).rglob("*.wav"))


def test_one_utterance_becomes_one_wav(tmp_path):
    clock = _Clock(datetime(2026, 9, 11, 10, 0))
    rec = cr.UtteranceRecorder(
        tmp_path, "Victor", cr.Window.parse("Mon-Fri 09:00-17:00"), clock=clock
    )
    _feed(rec, _speechy(3.0))
    _feed(rec, np.zeros(int(SR * 2.0), dtype=np.float32))  # the pause that closes it
    _settle(rec, 1)

    files = _wavs(tmp_path)
    assert len(files) == 1, f"expected one sample, got {files}"
    with wave.open(str(files[0])) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1
        seconds = w.getnframes() / SR
    # 3 s of speech, the pre-roll is silence so there is none to add, and the
    # trailing pause is trimmed to a quarter-second of tail.
    assert 3.0 <= seconds <= 3.5, seconds
    assert rec.kept == 1


def test_nothing_is_collected_outside_the_work_window(tmp_path):
    clock = _Clock(datetime(2026, 9, 12, 10, 0))  # Saturday
    rec = cr.UtteranceRecorder(
        tmp_path, "Victor", cr.Window.parse("Mon-Fri 09:00-17:00"), clock=clock
    )
    _feed(rec, _speechy(3.0))
    _feed(rec, np.zeros(int(SR * 2.0), dtype=np.float32))
    time.sleep(0.5)
    assert _wavs(tmp_path) == []
    assert rec.kept == 0


def test_hum_at_a_passing_volume_is_still_rejected(tmp_path):
    """The RMS gate alone cannot do this, which is why the band check exists.

    A laptop fan through a sensitive lavalier clears any threshold tuned for
    speech. Without the spectral check this is a day of corpus that costs a day
    of teacher time and teaches the model nothing.
    """
    clock = _Clock(datetime(2026, 9, 11, 10, 0))
    rec = cr.UtteranceRecorder(
        tmp_path, "Victor", cr.Window.parse("Mon-Fri 09:00-17:00"), clock=clock
    )
    _feed(rec, _hum(3.0), threshold=0.02)
    _feed(rec, np.zeros(int(SR * 2.0), dtype=np.float32))
    _settle(rec, 1)
    assert _wavs(tmp_path) == []
    assert rec.dropped == 1 and rec.last_reason.startswith("band")


def test_a_blurt_shorter_than_the_floor_is_dropped(tmp_path):
    clock = _Clock(datetime(2026, 9, 11, 10, 0))
    rec = cr.UtteranceRecorder(
        tmp_path, "Victor", cr.Window.parse("Mon-Fri 09:00-17:00"), clock=clock
    )
    _feed(rec, _speechy(0.4))
    _feed(rec, np.zeros(int(SR * 2.0), dtype=np.float32))
    _settle(rec, 1)
    assert _wavs(tmp_path) == []
    assert rec.dropped == 1 and rec.last_reason.startswith("short")


def test_a_short_pause_does_not_split_a_sentence(tmp_path):
    """Half a comma's worth of silence is inside an utterance, not between two.

    This is the difference from the transcriber's 0.6 s latency flush, and it is
    the reason this recorder does its own segmentation rather than reusing the
    chunks whisper is already emitting.
    """
    clock = _Clock(datetime(2026, 9, 11, 10, 0))
    rec = cr.UtteranceRecorder(
        tmp_path, "Victor", cr.Window.parse("Mon-Fri 09:00-17:00"), clock=clock
    )
    _feed(rec, _speechy(2.0))
    _feed(rec, np.zeros(int(SR * 0.4), dtype=np.float32))
    _feed(rec, _speechy(2.0))
    _feed(rec, np.zeros(int(SR * 2.0), dtype=np.float32))
    _settle(rec, 1)
    assert len(_wavs(tmp_path)) == 1


def test_a_monologue_is_cut_at_the_ceiling(tmp_path):
    clock = _Clock(datetime(2026, 9, 11, 10, 0))
    rec = cr.UtteranceRecorder(
        tmp_path, "Victor", cr.Window.parse("Mon-Fri 09:00-17:00"), clock=clock
    )
    _feed(rec, _speechy(cr.MAX_SEC * 2 + 2))
    _feed(rec, np.zeros(int(SR * 2.0), dtype=np.float32))
    _settle(rec, 3, timeout=15)
    files = _wavs(tmp_path)
    assert len(files) >= 2
    for f in files:
        with wave.open(str(f)) as w:
            assert w.getnframes() / SR <= cr.MAX_SEC + 0.2


def test_a_positive_audience_verdict_drops_the_sample(tmp_path):
    """The only rejection the voiceprint is allowed to make.

    Abstaining must keep the sample: the middle band is "not saying", and
    throwing away everything the scorer will not commit to would quietly drop
    most of a noisy room day — including plenty of Victor.
    """

    class _Scorer:
        def __init__(self, label):
            self.label = label

        def score(self, audio, min_seconds=None):
            return cr.Decision and type(
                "V", (), {"label": self.label, "score": 0.1, "reason": "test"}
            )()

    clock = _Clock(datetime(2026, 9, 11, 10, 0))
    window = cr.Window.parse("Mon-Fri 09:00-17:00")

    them = cr.UtteranceRecorder(
        tmp_path / "them", "Victor", window, scorer=_Scorer("Audience"), clock=clock
    )
    _feed(them, _speechy(3.0))
    _feed(them, np.zeros(int(SR * 2.0), dtype=np.float32))
    _settle(them, 1)
    assert _wavs(tmp_path / "them") == []
    assert them.last_reason.startswith("audience")

    unsure = cr.UtteranceRecorder(
        tmp_path / "unsure", "Victor", window, scorer=_Scorer(None), clock=clock
    )
    _feed(unsure, _speechy(3.0))
    _feed(unsure, np.zeros(int(SR * 2.0), dtype=np.float32))
    _settle(unsure, 1)
    assert len(_wavs(tmp_path / "unsure")) == 1


def test_a_scorer_that_raises_does_not_cost_the_sample(tmp_path):
    class _Broken:
        def score(self, audio, min_seconds=None):
            raise RuntimeError("onnx is unhappy")

    clock = _Clock(datetime(2026, 9, 11, 10, 0))
    rec = cr.UtteranceRecorder(
        tmp_path,
        "Victor",
        cr.Window.parse("Mon-Fri 09:00-17:00"),
        scorer=_Broken(),
        clock=clock,
    )
    _feed(rec, _speechy(3.0))
    _feed(rec, np.zeros(int(SR * 2.0), dtype=np.float32))
    _settle(rec, 1)
    assert len(_wavs(tmp_path)) == 1


def test_every_kept_sample_gets_a_manifest_line(tmp_path):
    import json

    clock = _Clock(datetime(2026, 9, 11, 10, 0))
    rec = cr.UtteranceRecorder(
        tmp_path, "Victor", cr.Window.parse("Mon-Fri 09:00-17:00"), clock=clock
    )
    _feed(rec, _speechy(3.0))
    _feed(rec, np.zeros(int(SR * 2.0), dtype=np.float32))
    _settle(rec, 1)

    lines = (tmp_path / "mic-corpus.jsonl").read_text().splitlines()
    assert len(lines) == 1
    entry = json.loads(lines[0])
    assert entry["source"] == "addons-mic"
    assert entry["device"] == "Test Mic"
    assert entry["wav"] == "2026-09-11/" + entry["id"] + ".wav"
    assert (tmp_path / entry["wav"]).exists()
    assert entry["speech_band"] > cr.MIN_SPEECH_BAND


def test_write_never_raises_into_the_audio_thread(tmp_path):
    """The contract `_RawRecorder` established, restated for this recorder.

    PortAudio's callback runs on a realtime thread; an exception escaping into
    it kills live transcription. A corpus is never worth that, so `write` eats
    everything — here, a queue that has been sabotaged into raising.
    """
    rec = cr.UtteranceRecorder(tmp_path, "Victor", cr.Window.parse("always"))

    class _Exploding:
        def put_nowait(self, item):
            raise BaseException("anything at all")  # noqa: TRY002

    rec._q = _Exploding()
    rec.write(np.zeros(BLOCK, dtype=np.float32), 0.02)  # must not raise
