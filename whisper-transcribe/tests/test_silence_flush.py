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


def test_a_device_switch_clears_the_silence_counter_with_the_buffer():
    # The two describe the same audio, so they have to be cleared together:
    # `_cb` derives the speech in the buffer as
    # `len(_buf) - _silent_blocks * blocksize`, and a stale count drives that
    # negative — suppressing the flush until somebody speaks again, so the
    # first words after a mic change would wait for a whole 12 s chunk.
    ch, thr = _channel()
    _feed(ch, 2.0, 0.0)                      # 20 silent blocks accumulate
    assert ch._silent_blocks == 20
    ch.switch_device(1, "Wireless Mic")
    assert ch._silent_blocks == 0
    assert len(ch._buf) == 0

    # ...and the flush works immediately on the new device.
    ch, thr = _channel()
    _feed(ch, 3.0, 0.0)
    ch.switch_device(1, "Wireless Mic")
    _feed(ch, 2.0, thr * 4)
    _feed(ch, wr._SILENCE_FLUSH_SEC, 0.0)
    assert ch._queue.qsize() == 1


def test_the_speech_measure_never_lets_silence_alone_trigger_a_flush():
    # The arithmetic can legitimately go negative — more silent blocks than the
    # buffer holds — and negative is the safe direction: it under-reports
    # speech, so it can only ever suppress a flush, never invent one.
    ch, _ = _channel()
    _feed(ch, 30.0, 0.0)
    assert ch._queue.qsize() == 0


def test_silence_alone_never_emits():
    ch, _ = _channel()
    _feed(ch, wr._CHUNK_SEC * 2, 0.0)
    assert ch._queue.qsize() == 0


def test_a_pause_after_a_full_chunk_does_not_re_send_the_overlap():
    """The regression that made this whole mechanism dangerous.

    A clock emit leaves `_overlap` seconds in the buffer, and whisper has just
    transcribed them. Counting those as new speech meant every utterance longer
    than a chunk ended by re-sending its own last two seconds: 12 s of speech
    then a pause emitted 12.0 s and then 2.6 s whose entire speech content was
    already in the file. Nothing merges overlap at the text level, so that
    landed in the transcript as duplicated words — several times per teaching
    hour, because "talk, then pause" is simply how talking works.
    """
    ch, thr = _channel()
    _feed(ch, wr._CHUNK_SEC, thr * 4)        # exactly one full chunk
    _feed(ch, wr._SILENCE_FLUSH_SEC, 0.0)    # then a pause

    emitted = []
    while not ch._queue.empty():
        emitted.append(len(ch._queue.get()[1]) / wr._SAMPLE_RATE)

    assert emitted[0] == pytest.approx(wr._CHUNK_SEC, abs=0.01)
    # Only the pause itself may follow — never the speech already transcribed.
    assert len(emitted) == 1 or emitted[1] <= wr._SILENCE_FLUSH_SEC + 0.11


def test_speech_after_a_full_chunk_still_flushes_but_only_the_new_part():
    ch, thr = _channel()
    _feed(ch, wr._CHUNK_SEC, thr * 4)
    ch._queue.get()                          # drop the clock chunk
    _feed(ch, 3.0, thr * 4)                  # 3 s of genuinely new speech
    _feed(ch, wr._SILENCE_FLUSH_SEC, 0.0)

    assert ch._queue.qsize() == 1
    flushed = len(ch._queue.get()[1]) / wr._SAMPLE_RATE
    # 3 s of new speech plus the pause — and NOT the 2 s of carried overlap.
    assert flushed == pytest.approx(3.0 + wr._SILENCE_FLUSH_SEC, abs=0.15)
