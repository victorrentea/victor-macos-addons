"""The raw recorder exists to build a far-field corpus during live workshops.

It runs while Victor is teaching, so the properties worth pinning are not "does
it record" but "can it hurt anything": it must never block the audio callback,
never raise into it, never take whisper down when the disk says no, and never
lose a day's audio to a `kill -9` — which is how this process usually dies.
"""
import queue
import sys
import time
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import whisper_runner as wr


BLOCK = int(wr._SAMPLE_RATE * 0.1)
BYTES_PER_BLOCK = BLOCK * 2  # int16


def _block(amplitude: float = 0.2) -> np.ndarray:
    return np.full(BLOCK, amplitude, dtype=np.float32)


def _drain(rec, timeout: float = 3.0):
    """Wait for the writer thread to catch up instead of sleeping blindly."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if rec._q.empty() and rec._fh is not None:
            return
        time.sleep(0.02)
    pytest.fail("writer thread never drained the queue")


def _only_file(tmp_path: Path) -> Path:
    files = list(tmp_path.glob("*.pcm"))
    assert len(files) == 1, f"expected exactly one file, got {[f.name for f in files]}"
    return files[0]


def test_writes_headerless_pcm_named_with_its_own_format(tmp_path):
    rec = wr._RawRecorder(tmp_path, "Victor")
    for _ in range(10):
        rec.write(_block())
    _drain(rec)
    rec.stop()

    path = _only_file(tmp_path)
    assert path.name.endswith("-Victor.s16le16k.pcm"), "the format must be in the name"
    assert path.stat().st_size == 10 * BYTES_PER_BLOCK


def test_samples_survive_the_float_to_int16_round_trip(tmp_path):
    rec = wr._RawRecorder(tmp_path, "Victor")
    rec.write(_block(0.5))
    _drain(rec)
    rec.stop()

    samples = np.frombuffer(_only_file(tmp_path).read_bytes(), dtype=np.int16)
    assert len(samples) == BLOCK
    assert samples.astype(np.float32).mean() / 32767 == pytest.approx(0.5, abs=1e-4)


def test_reopening_the_same_day_appends_instead_of_truncating(tmp_path):
    # The heartbeat restarts whisper several times a day. A fresh file per run
    # would shatter the day into fragments that no longer line up with the
    # transcript's clock.
    for _ in range(2):
        rec = wr._RawRecorder(tmp_path, "Victor")
        for _ in range(5):
            rec.write(_block())
        _drain(rec)
        rec.stop()

    assert _only_file(tmp_path).stat().st_size == 10 * BYTES_PER_BLOCK


def test_bytes_are_on_disk_before_close_so_a_kill_9_keeps_them(tmp_path):
    # This process is routinely killed outright — the quiet-crash handlers call
    # _exit and the watchdog force-restarts it. Nothing may depend on a clean
    # shutdown, which is the whole reason this is not a WAV.
    rec = wr._RawRecorder(tmp_path, "Victor")
    for _ in range(4):
        rec.write(_block())
    _drain(rec)
    assert _only_file(tmp_path).stat().st_size == 4 * BYTES_PER_BLOCK  # no stop() yet
    rec.stop()


def test_write_never_blocks_when_the_queue_is_full(tmp_path):
    # The audio thread is realtime. If the disk stalls, the corpus is what gets
    # dropped — never frames from the live transcription.
    rec = wr._RawRecorder(tmp_path, "Victor")
    rec._running = False
    rec._q = queue.Queue(maxsize=4)
    for _ in range(4):
        rec._q.put_nowait(_block())   # full, and nothing is draining it

    started = time.monotonic()
    for _ in range(50):
        rec.write(_block())
    elapsed = time.monotonic() - started

    assert elapsed < 1.0, "write() must not block on a full queue"
    assert rec._dropped == 50
    rec.stop()


def test_write_does_not_raise_into_the_audio_callback(tmp_path):
    rec = wr._RawRecorder(tmp_path, "Victor")
    rec._running = False
    rec._q = None  # about the worst thing that could plausibly happen
    try:
        rec.write(_block())
    except BaseException as exc:  # noqa: BLE001
        pytest.fail(f"write() raised into the audio thread: {exc!r}")
    assert rec._dropped == 1


def test_a_recorder_that_cannot_start_leaves_whisper_running(tmp_path, monkeypatch):
    monkeypatch.setattr(wr, "_RECORD_RAW_ON", True)

    def explode(*_args, **_kwargs):
        raise OSError("no space left on device")

    monkeypatch.setattr(wr, "_RawRecorder", explode)
    runner = wr.WhisperTranscriptionRunner(tmp_path)
    assert runner._make_recorder("Victor") is None


def test_recording_is_off_unless_asked_for(tmp_path, monkeypatch):
    monkeypatch.setattr(wr, "_RECORD_RAW_ON", False)
    runner = wr.WhisperTranscriptionRunner(tmp_path)
    assert runner._make_recorder("Victor") is None
    assert not (tmp_path / "raw-audio").exists()


def test_channel_capture_records_before_the_silence_gate(tmp_path):
    # Below-threshold audio and silence must reach the file: the gate is one of
    # the things the speaker work may want to change, so the corpus must not
    # have it baked in already.
    rec = wr._RawRecorder(tmp_path, "Victor")
    ch = wr._ChannelCapture(0, "Victor", queue.Queue(), device_name="XLR", recorder=rec)
    quiet = np.zeros((BLOCK, 1), dtype=np.float32)
    for _ in range(10):
        ch._cb(quiet, BLOCK, None, None)
    _drain(rec)
    rec.stop()

    assert ch._queue.qsize() == 0, "silence must not be transcribed"
    assert _only_file(tmp_path).stat().st_size == 10 * BYTES_PER_BLOCK, "but recorded"
