"""The silence flush is what makes 12 s chunks safe.

Without it the last sentence spoken sits in a buffer until the buffer fills, so
the transcript's tail latency is a whole chunk — which would force
`TranscriptSettlePolicy.minWait` up from 8 s to ~18 s and turn the ⌘⌃V picker
into a half-minute wait. These tests pin the three things that can silently
break it: that a pause emits, that a short blip does not, and that a flushed
chunk carries no overlap into the next one.
"""
import queue
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import whisper_runner as wr


BLOCK = int(wr._SAMPLE_RATE * 0.1)  # the callback's blocksize


def _channel():
    ch = wr._ChannelCapture(0, "Victor", queue.Queue(), device_name="XLR")
    return ch, ch._current_threshold()


def _feed(ch, seconds: float, amplitude: float):
    """Push `seconds` of constant-amplitude audio through the callback."""
    for _ in range(round(seconds / 0.1)):   # round, not int: 0.6/0.1 is 5.999…
        block = np.full((BLOCK, 1), amplitude, dtype=np.float32)
        ch._cb(block, BLOCK, None, None)


def test_pause_after_speech_flushes_without_waiting_for_a_full_chunk():
    ch, thr = _channel()
    _feed(ch, 3.0, thr * 4)          # 3 s of speech — nowhere near a 12 s chunk
    assert ch._queue.qsize() == 0, "nothing should leave mid-utterance"
    _feed(ch, wr._SILENCE_FLUSH_SEC, 0.0)
    assert ch._queue.qsize() == 1, "the pause should have flushed the buffer"
    _, audio, _ = ch._queue.get()
    assert 3.0 <= len(audio) / wr._SAMPLE_RATE <= 3.0 + wr._SILENCE_FLUSH_SEC + 0.2


def test_flush_carries_no_overlap_into_the_next_chunk():
    # A pause is a cut where no word is being sliced, so re-transcribing the
    # tail would only duplicate text.
    ch, thr = _channel()
    _feed(ch, 3.0, thr * 4)
    _feed(ch, wr._SILENCE_FLUSH_SEC, 0.0)
    assert len(ch._buf) == 0


def test_a_gap_between_words_does_not_flush():
    # Below _MIN_FLUSH_SEC there is nothing worth transcribing, and firing here
    # would shred every utterance into syllables.
    ch, thr = _channel()
    _feed(ch, 0.5, thr * 4)          # shorter than _MIN_FLUSH_SEC
    _feed(ch, wr._SILENCE_FLUSH_SEC * 2, 0.0)
    assert ch._queue.qsize() == 0


def test_brief_silence_does_not_flush():
    ch, thr = _channel()
    _feed(ch, 3.0, thr * 4)
    _feed(ch, wr._SILENCE_FLUSH_SEC / 2, 0.0)   # a breath, not a pause
    assert ch._queue.qsize() == 0


def test_a_full_chunk_still_emits_on_the_clock_with_overlap():
    ch, thr = _channel()
    _feed(ch, wr._CHUNK_SEC, thr * 4)           # continuous speech, no pause
    assert ch._queue.qsize() == 1
    _, audio, _ = ch._queue.get()
    assert len(audio) == ch._chunk
    assert len(ch._buf) == pytest.approx(ch._overlap, abs=BLOCK)


def test_silence_alone_never_emits():
    ch, _ = _channel()
    _feed(ch, wr._CHUNK_SEC * 2, 0.0)
    assert ch._queue.qsize() == 0
