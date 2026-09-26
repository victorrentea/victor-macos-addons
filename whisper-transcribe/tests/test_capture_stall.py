"""The capture-stall watchdog replaces "the transcript went quiet".

Silence in the transcript cannot tell a dead microphone from an empty room, so
whisper used to be restarted every 10 minutes all night. The watchdog looks at
the one thing that separates the two: PortAudio blocks, which keep arriving in
a silent room and stop only when capture itself is dead.
"""
import queue
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import whisper_runner as wr


BLOCK = int(wr._SAMPLE_RATE * 0.1)


def _channel(label="Victor"):
    return wr._ChannelCapture(0, label, queue.Queue(), device_name="XLR")


def test_a_silent_room_is_not_a_stall():
    ch = _channel()
    ch._last_block_at = 0.0
    ch._cb(np.zeros((BLOCK, 1), dtype=np.float32), BLOCK, None, None)
    assert wr._stalled_channels([ch], time.monotonic()) == []


def test_no_blocks_past_the_limit_is_a_stall():
    ch = _channel()
    now = time.monotonic()
    ch._last_block_at = now - wr._CAPTURE_STALL_SEC - 1
    assert wr._stalled_channels([ch], now) == [ch]


def test_only_the_dead_channel_is_reported():
    # The July failure: one channel dead, the other perfectly healthy.
    me, aud = _channel("Victor"), _channel("Audience")
    now = time.monotonic()
    me._last_block_at = now - wr._CAPTURE_STALL_SEC - 1
    aud._last_block_at = now
    assert wr._stalled_channels([me, aud], now) == [me]


def test_a_new_channel_starts_with_a_full_grace_window():
    ch = _channel()
    assert wr._stalled_channels([ch], time.monotonic()) == []
