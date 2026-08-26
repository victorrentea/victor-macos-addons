"""Live Whisper transcription runner — writes directly to normalized transcript files.

Victor's mic priority: Wireless Mic (DJI Mic Mini, etc.) > XLR > Bose > MacBook
(auto-switches on connect/disconnect)
Audience: FROM Zoom loopback

Uses CoreAudio for device detection (no stale devices) and sounddevice for capture.
"""

import contextlib
import os
import queue
import re
import sys
import threading
import time
import wave
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

_portaudio_lock = threading.Lock()

# Last CoreAudio input-device set we reinitialised PortAudio for. `None` = we
# have not looked yet, so the first check always counts as a change.
_device_snapshot: tuple[str, ...] | None = None


def _portaudio_reinit():
    with _portaudio_lock:
        import sounddevice as sd
        sd._terminate()
        sd._initialize()


def _device_set_changed() -> bool:
    """Did the set of input devices actually change since the last reinit?

    Read from CoreAudio, never from PortAudio: asking PortAudio would need the
    very re-init we are trying to avoid. Errors answer "yes" — a needless
    re-init is survivable, missing a hot-plugged mic is not.
    """
    global _device_snapshot
    try:
        snapshot = tuple(sorted(
            d.get("uid") or d.get("name", "") for d in list_input_devices()
        ))
    except Exception as exc:
        log.error("transcript", f"🎙️ device snapshot failed: {exc}")
        _device_snapshot = None
        return True
    if snapshot == _device_snapshot:
        return False
    _device_snapshot = snapshot
    return True
from coreaudio_devices import (
    list_input_devices,
    register_device_change_callback,
    register_device_alive_callbacks,
)


# ── Logging ──────────────────────────────────────────────────────────────────
_log_callback = (
    None  # optional callable(str) — forwards all transcription logs to the menu
)


def set_error_callback(cb):
    global _log_callback
    _log_callback = cb


class _Log:
    @staticmethod
    def info(component: str, msg: str):
        ts = datetime.now().strftime("%H:%M:%S.%f")[:10]
        print(f"{ts} [{component:<12}] {msg}")
        if _log_callback:
            try:
                _log_callback(f"🎙️ {msg}")
            except Exception:
                pass

    @staticmethod
    def error(component: str, msg: str):
        ts = datetime.now().strftime("%H:%M:%S.%f")[:10]
        print(f"{ts} [{component:<12}] ERROR {msg}")
        if _log_callback:
            try:
                _log_callback(f"🎙️ ERROR {msg}")
            except Exception:
                pass


log = _Log()

# ── Config ───────────────────────────────────────────────────────────────────
_ME_SPEAKER = os.environ.get("WHISPER_ME_SPEAKER", "Victor")
_AUD_SPEAKER = os.environ.get("WHISPER_AUDIENCE_SPEAKER", "Audience")
_MODEL_BALANCED = os.environ.get(
    "WHISPER_MODEL", "mlx-community/whisper-large-v3-turbo"
)
_MODEL_FAST = os.environ.get("WHISPER_MODEL_FAST", _MODEL_BALANCED)
# 12 s chunks with 2 s overlap, and both numbers are measured rather than felt.
#
# mlx-whisper pads every input to a fixed 30 s mel window, so the encoder costs
# the same whether it is handed 2 s of audio or 15 s: measured on this Mac over
# four hours of a real workshop recording, 7.5x more audio costs 1.27x more
# compute (0.79 s at 2 s -> 1.00 s at 15 s). Short chunks were therefore paying
# for a 30 s encoder pass to transcribe five seconds. Going from (6,1) to (12,2)
# halves the number of inference calls for the same speech -- 12 calls per
# minute down to 6, and 49.7% less compute.
#
# The wider overlap is free in the same trade. Nothing merges the overlap at the
# text level, so re-transcribed audio shows up as duplicated words at chunk
# boundaries -- but doubling the overlap while halving the number of boundaries
# is a net win, and monotonically so: boundary duplication measured 12.8% at
# (6,1), 8.3% at (8,1.5), 6.5% at (12,2), 5.5% at (15,2).
#
# One thing NOT to claim here: that long chunks avoid whisper's repetition
# hallucinations (a chunk decoding "Ter Ter Ter..." for 5-10x a normal call's
# cost). On synthetic speech they looked length-dependent; on real audio they
# fire on *true silence* (RMS < 0.001) at every length, and the per-device RMS
# gate in `_cb` already screens that case. Fewer calls per minute still means
# less exposure, but the mechanism is silence, not brevity.
_CHUNK_SEC = float(os.environ.get("WHISPER_CHUNK_SECONDS", "12"))
_OVERLAP_SEC = float(os.environ.get("WHISPER_OVERLAP_SECONDS", "2"))

# Flush a partial buffer once the room goes quiet, instead of waiting for it to
# fill. This is what keeps 12 s chunks from doubling the transcript's tail
# latency: without it the last sentence spoken can sit unemitted for up to a
# full chunk, and `TranscriptSettlePolicy.minWait` (8 s, "longer than a whole
# chunk plus inference") would have had to grow to ~18 s -- turning the ⌘⌃V
# picker from a ~16 s wait into a ~27 s one. With the flush, a keypress after a
# sentence costs 0.6 s of silence detection + at most 5 s of batch collection +
# ~1 s of inference, so the 8 s floor stays honest.
#
# It is also a better cut than the clock: a pause is exactly where no word is
# being sliced in half, so a flushed chunk needs no overlap at all, and it tends
# to hold one utterance by one speaker -- which is what the speaker-identity
# work downstream wants.
_SILENCE_FLUSH_SEC = float(os.environ.get("WHISPER_SILENCE_FLUSH_SECONDS", "0.6"))
_MIN_FLUSH_SEC = float(os.environ.get("WHISPER_MIN_FLUSH_SECONDS", "1.5"))

_SAMPLE_RATE = 16000

# Keep a copy of the raw microphone audio on disk. OFF by default — it writes
# ~115 MB per hour and records a room full of people, so it is opt-in per
# session and never a standing behaviour.
#
# It exists because the speaker-identification work has no far-field corpus.
# Every recording that survived is a Zoom mix of *remote* participants; the hard
# case — an audience in the room arriving through Victor's own lavalier — was
# never captured, and the only two hybrid sessions on the calendar were not
# recorded at all. This writes exactly the signal the classifier will see in
# production: same device, same callback, before any gating.
#
# `1` records the mic channel; `all` also records the loopback channel, which in
# a hybrid room is clean ground truth for the remote speakers (the mic is not).
_RECORD_RAW = os.environ.get("WHISPER_RECORD_RAW", "0").strip().lower()
_RECORD_RAW_ON = _RECORD_RAW not in {"0", "false", "no", ""}
_RECORD_RAW_ALL = _RECORD_RAW == "all"
# Bounded on purpose — see `_RawRecorder`. 600 blocks ≈ 60 s of slack.
_RECORD_QUEUE_BLOCKS = int(os.environ.get("WHISPER_RECORD_QUEUE_BLOCKS", "600"))

_BATCH_MAX_WAIT_SEC = float(os.environ.get("WHISPER_BATCH_MAX_WAIT_SECONDS", "5"))
_BATCH_MAX_ITEMS = int(os.environ.get("WHISPER_BATCH_MAX_ITEMS", "4"))
_BATCH_MAX_AUDIO_SEC = float(os.environ.get("WHISPER_BATCH_MAX_AUDIO_SECONDS", "24"))

_ADAPTIVE_QUALITY = os.environ.get("WHISPER_ADAPTIVE_QUALITY", "1").lower() not in {
    "0",
    "false",
    "no",
}
_ADAPTIVE_BACKLOG_HIGH = int(os.environ.get("WHISPER_ADAPTIVE_BACKLOG_HIGH", "6"))
_ADAPTIVE_BACKLOG_LOW = int(os.environ.get("WHISPER_ADAPTIVE_BACKLOG_LOW", "2"))

_THRESHOLDS = {
    "xlr": 0.018,
    "wireless mic": 0.005,  # DJI Mic Mini reports much lower RMS than XLR
    "speakerphone": 0.012,  # Room Speakerphone — far-field room mic with AGC; midrange between bose and wireless
    "bose": 0.015,
    "macbook": 0.008,
    "audience": 0.025,
}
_DEFAULT_THRESHOLD = 0.018

_ME_PATTERNS = ["Wireless Mic", "Room Speakerphone", "XLR", "Bose", "MacBook"]
_AUD_PATTERNS = ["From Zoom"]

_HALLUCINATIONS = {
    # Generic Whisper hallucinations
    "thank you.",
    "thanks for watching.",
    "thanks.",
    "you",
    ".",
    "subtitles by the amara.org community",
    "www.mooji.org",
    "[music]",
    "[ music ]",
    "(music)",
    "♪",
    "...",
    # Romanian YouTube-style hallucinations (silence → Whisper thinks it's a video)
    "să vă mulțumesc pentru vizionare!",
    "să vă mulțumim pentru vizionare!",
    "nu uitați să vă abonați la canal!",
    "nu uitați să vă abonați la canalul meu!",
    "vă mulțumesc!",
    "vă mulțumim!",
    "mulțumesc pentru vizionare!",
    "mulțumim pentru vizionare!",
    "grazie.",
    "grazie!",
}

# Regex: a short syllable/char pattern repeated many times within a single token
# e.g. "iriiriiriiri...", "Tidyidyidyidy...", "doppiriiriiri..."
_CHAR_REPEAT_RE = re.compile(r'(.{2,4})\1{8,}', re.IGNORECASE)


def _is_garbage(text: str) -> bool:
    """Return True if text is a Whisper hallucination or noise that should be dropped."""
    from collections import Counter

    stripped = text.strip()
    if not stripped:
        return True

    lower = stripped.lower()

    # Exact-match known hallucination phrases
    if lower in _HALLUCINATIONS:
        return True

    # Single token that's purely digits or punctuation (e.g. "2", "123", "...")
    words = stripped.split()
    if len(words) == 1 and re.fullmatch(r'[\d\W]+', words[0]):
        return True

    # Character-level repetition inside a word: "iriiriiriiri", "Tidyidyidyidy"
    if _CHAR_REPEAT_RE.search(stripped):
        return True

    # Word/phrase repetition loop (most common Whisper hallucination during silence)
    # Normalize: strip punctuation + lowercase so "da," == "da" == "Da,"
    norm = [re.sub(r'[^\w\u0080-\uffff]', '', w).lower() for w in words]
    norm = [w for w in norm if w]  # drop empty tokens (pure punctuation)
    if len(norm) >= 6:
        counts = Counter(norm)
        top_word, top_count = counts.most_common(1)[0]
        # Short segments need higher dominance (≥80%) to avoid filtering "Da, da, corect."
        threshold = 0.80 if len(norm) < 8 else 0.60
        min_count = 4   if len(norm) < 8 else 5
        if top_count >= min_count and top_count / len(norm) >= threshold:
            return True
    if len(norm) >= 8:
        for n in (2, 3, 4, 5):
            if len(norm) < n * 4:
                continue
            ngrams = [tuple(norm[i:i+n]) for i in range(len(norm) - n + 1)]
            top_ng, top_ng_count = Counter(ngrams).most_common(1)[0]
            if top_ng_count >= 3 and top_ng_count * n / len(norm) >= 0.55:
                return True

    return False

# Short display names for known devices
_DEVICE_SHORT_NAMES = {
    "wireless mic": "🎤",  # DJI Mic Mini reports as "Wireless Mic Rx"
    "speakerphone": "🏛️",  # Room Speakerphone (USB)
    "xlr": "🎙️",
    "bose": "🎧",
    "vic bose": "🎧",
    "macbook": "💻",
}


def _short_device_name(device_name: str) -> str:
    lower = device_name.lower()
    for pattern, short in _DEVICE_SHORT_NAMES.items():
        if pattern in lower:
            return short
    return device_name


# ── Device resolution via CoreAudio ──────────────────────────────────────────
def _normalize_device_name(name: str) -> str:
    # Normalize cross-API naming differences (e.g. "Built-in Microphone (MacBook Pro)")
    return re.sub(r"[^a-z0-9]+", "", name.lower())


def _names_equivalent(a: str, b: str) -> bool:
    na = _normalize_device_name(a)
    nb = _normalize_device_name(b)
    return bool(na and nb and (na == nb or na in nb or nb in na))


def _parse_pattern_env(var_name: str) -> list[str]:
    raw = os.environ.get(var_name, "").strip()
    if not raw:
        return []
    return [p.strip() for p in raw.split(",") if p.strip()]


_PREFERRED_SOURCE_FILE = os.environ.get("WHISPER_PREFERRED_SOURCE_FILE", "").strip()


def _read_preferred_source() -> str:
    if not _PREFERRED_SOURCE_FILE:
        return ""
    try:
        with open(_PREFERRED_SOURCE_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    except (FileNotFoundError, OSError):
        return ""


def _preferred_source_mtime() -> float:
    """Current mtime of the preference file, or 0.0 when there isn't one."""
    if not _PREFERRED_SOURCE_FILE:
        return 0.0
    try:
        return os.path.getmtime(_PREFERRED_SOURCE_FILE)
    except (FileNotFoundError, OSError):
        return 0.0


def _available_me_short_names() -> list[str]:
    """Return short-emoji names of currently available _ME_PATTERNS devices, in priority order."""
    import sounddevice as sd

    ca_devices = [d for d in list_input_devices() if d["alive"]]
    alive_ca_names = [d["name"] for d in ca_devices]
    seen: set[str] = set()
    available: list[str] = []
    for pattern in _ME_PATTERNS:
        plower = pattern.lower()
        for d in sd.query_devices():
            if d["max_input_channels"] <= 0:
                continue
            sd_name = d["name"]
            if plower not in sd_name.lower():
                continue
            if any(_names_equivalent(sd_name, ca_name) for ca_name in alive_ca_names):
                short = _short_device_name(sd_name)
                if short not in seen:
                    seen.add(short)
                    available.append(short)
                break
    return available


def _resolve_device_coreaudio(patterns: list[str]) -> tuple[int, str] | None:
    """Find the best input device by pattern priority using CoreAudio (no stale devices).
    Returns (sounddevice_index, device_name) or None."""
    import sounddevice as sd

    ca_devices = [d for d in list_input_devices() if d["alive"]]
    if not ca_devices:
        return None

    # Allow hard overrides for deterministic routing.
    # Examples:
    #   WHISPER_ME_DEVICE_HINT="scarlett"
    #   WHISPER_AUDIENCE_DEVICE_HINT="from zoom"
    hint_patterns = []
    preferred = ""
    if patterns is _ME_PATTERNS:
        hint_patterns = _parse_pattern_env("WHISPER_ME_DEVICE_HINT")
        preferred = _read_preferred_source()
    elif patterns is _AUD_PATTERNS:
        hint_patterns = _parse_pattern_env("WHISPER_AUDIENCE_DEVICE_HINT")
    if hint_patterns:
        patterns = hint_patterns + patterns
    if preferred:
        patterns = [preferred] + patterns

    alive_ca_names = [d["name"] for d in ca_devices]

    for pattern in patterns:
        plower = pattern.lower()
        for i, d in enumerate(sd.query_devices()):
            if d["max_input_channels"] <= 0:
                continue
            sd_name = d["name"]
            if plower not in sd_name.lower():
                continue
            if any(_names_equivalent(sd_name, ca_name) for ca_name in alive_ca_names):
                return i, d["name"]

        # Fallback: match against CoreAudio names first, then map back to sounddevice.
        for ca_name in alive_ca_names:
            if plower not in ca_name.lower():
                continue
            for i, d in enumerate(sd.query_devices()):
                if d["max_input_channels"] <= 0:
                    continue
                if _names_equivalent(d["name"], ca_name):
                    return i, ca_name
    return None


# ── Audio capture ────────────────────────────────────────────────────────────
class _RawRecorder:
    """Writes one channel's raw audio to a per-day WAV, off the audio thread.

    The single rule: **never block `_cb`**. PortAudio's callback runs on a
    realtime thread, and a disk that stalls for 50 ms there drops frames from the
    *live* transcription — trading the thing that works for the thing we are only
    collecting. So the callback does a non-blocking put onto a bounded queue and
    a writer thread drains it. When the queue fills, audio is dropped and
    counted: losing a second of corpus costs nothing, stuttering the transcript
    in front of a room costs a lot.
    """

    def __init__(self, out_dir: Path, label: str):
        self._dir = out_dir
        self._label = re.sub(r"[^A-Za-z0-9]+", "-", label).strip("-") or "channel"
        self._q: queue.Queue = queue.Queue(maxsize=_RECORD_QUEUE_BLOCKS)
        self._running = True
        self._dropped = 0
        self._day: str | None = None
        self._fh = None
        threading.Thread(
            target=self._supervised_writer, daemon=True, name=f"rec-{self._label}"
        ).start()

    def write(self, block: np.ndarray) -> None:
        """Called from the audio callback. Must not block and must not raise.

        The bare `except` is the point, not sloppiness: whatever goes wrong in
        here, the one outcome that is unacceptable is an exception escaping into
        PortAudio's realtime thread and killing live transcription for the sake
        of a corpus.
        """
        try:
            self._q.put_nowait(block.copy())
        except queue.Full:
            self._dropped += 1
            if self._dropped % 100 == 1:
                log.error(
                    "transcript",
                    f"🎙️ raw recorder [{self._label}] behind — dropped {self._dropped} blocks",
                )
        except BaseException as exc:  # noqa: BLE001 — deliberately everything
            self._dropped += 1
            if self._dropped % 100 == 1:
                log.error("transcript", f"🎙️ raw recorder write failed: {exc!r}")

    def _supervised_writer(self):
        # Same rule as every other thread here: never die quietly. A recorder
        # that stops is invisible — transcription carries on perfectly.
        while self._running:
            try:
                self._writer_loop()
                return
            except BaseException as exc:  # noqa: BLE001 — deliberately everything
                log.error("transcript", f"🎙️ raw recorder crashed, restarting: {exc!r}")
                time.sleep(2)

    def _writer_loop(self):
        while self._running:
            try:
                block = self._q.get(timeout=1)
            except queue.Empty:
                continue
            day = datetime.now().strftime("%Y-%m-%d")
            if day != self._day:
                self._open_for(day)
            try:
                self._fh.write((block * 32767).astype(np.int16).tobytes())
                self._fh.flush()
            except Exception as exc:
                log.error("transcript", f"🎙️ raw write failed: {exc}")

    def _open_for(self, day: str):
        """Headerless PCM, appended — and both halves of that are deliberate.

        **Appended**, because the heartbeat restarts whisper several times a day
        and a fresh file per run would shatter the day into fragments that no
        longer line up with the transcript's clock.

        **Headerless**, because a WAV cannot do this. Python's `wave` module has
        no append mode at all, and more importantly a WAV only writes its frame
        count on `close()` — while this process is routinely killed outright
        (the quiet-crash handlers `_exit`, the watchdog force-restarts it), which
        would leave a file declaring itself empty. Raw PCM is just bytes: a
        `kill -9` costs the last block and nothing else.

        Read it back with the format that is in the filename:
            ffmpeg -f s16le -ar 16000 -ac 1 -i <file> out.wav
        """
        self._close()
        self._dir.mkdir(parents=True, exist_ok=True)
        path = self._dir / f"{day}-{self._label}.s16le16k.pcm"
        self._fh = open(path, "ab")
        self._day = day
        log.info("transcript", f"🔴 recording raw audio → {path}")

    def _close(self):
        if self._fh:
            try:
                self._fh.close()
            except Exception:
                pass
            self._fh = None

    def stop(self):
        self._running = False
        self._close()


class _ChannelCapture:
    def __init__(
        self,
        device: int,
        label: str,
        tx_queue: queue.Queue,
        device_name: str = "",
        resolve_fn=None,
        recorder: "_RawRecorder | None" = None,
    ):
        self.device = device
        self.label = label
        self.device_name = device_name
        self._resolve_fn = resolve_fn  # callable() -> (idx, name) | None
        self._recorder = recorder
        self._queue = tx_queue
        self._buf = np.zeros(0, dtype=np.float32)
        self._chunk = int(_SAMPLE_RATE * _CHUNK_SEC)
        self._overlap = int(_SAMPLE_RATE * _OVERLAP_SEC)
        self._running = False
        self._stream = None
        # Consecutive below-threshold callback blocks, for the silence flush.
        self._silent_blocks = 0

    def start(self):
        self._running = True
        threading.Thread(
            target=self._supervised_loop, daemon=True, name=f"cap-{self.label}"
        ).start()

    def _supervised_loop(self):
        """Last line of defence: a capture thread must never die quietly.

        Whatever escapes `_loop` — including the errors we haven't thought of —
        gets logged and the loop restarts. A channel that stops capturing is
        invisible from the outside (the process stays alive and the other
        channel keeps working), so "crash loudly and retry" beats any silent
        exit.
        """
        while self._running:
            try:
                self._loop()
                return  # clean exit: _running went false
            except BaseException as exc:  # noqa: BLE001 — deliberately everything
                log.error(
                    "transcript",
                    f"🎙️ [{self.label}] capture loop crashed, restarting: {exc!r}",
                )
                time.sleep(2)

    def stop(self):
        self._running = False
        if self._recorder is not None:
            self._recorder.stop()
        if self._stream:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass

    def switch_device(self, new_idx: int, new_name: str):
        """Switch to a different device (called from device monitor)."""
        old_name = self.device_name
        self.device = new_idx
        self.device_name = new_name
        # Stop current stream — the loop will reopen with new device
        if self._stream:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        self._buf = np.zeros(0, dtype=np.float32)
        log.info("transcript", f"🎙️ [{self.label}] {old_name} → {new_name}")

    def _current_threshold(self) -> float:
        name = self.device_name.lower()
        for pattern, thresh in _THRESHOLDS.items():
            if pattern in name or pattern in self.label.lower():
                return thresh
        return _DEFAULT_THRESHOLD

    def _open(self):
        import sounddevice as sd

        s = sd.InputStream(
            device=self.device,
            channels=1,
            samplerate=_SAMPLE_RATE,
            dtype="float32",
            blocksize=int(_SAMPLE_RATE * 0.1),
            callback=self._cb,
        )
        s.start()
        self._stream = s
        return s

    def _loop(self):
        _consecutive_errors = 0
        while self._running:
            try:
                s = self._open()
                _consecutive_errors = 0
                log.info(
                    "transcript",
                    f"🎙️ [{self.label}] capturing from {self.device_name!r}",
                )
                while self._running and s.active:
                    time.sleep(0.5)
                # Stream ended (device switched or disconnected)
                try:
                    s.stop()
                    s.close()
                except Exception:
                    pass
                if self._running:
                    self._buf = np.zeros(0, dtype=np.float32)
                    time.sleep(0.5)
            except Exception as exc:
                _consecutive_errors += 1
                # Log first error, then every 30th (once per minute at 2s retry)
                if _consecutive_errors == 1 or _consecutive_errors % 30 == 0:
                    log.error(
                        "transcript",
                        f"🎙️ [{self.label}] stream error (x{_consecutive_errors}): {exc}",
                    )
                time.sleep(2)
                # Force PortAudio to reinitialize — recovers from CoreAudio invalid state after reconnect
                try:
                    _portaudio_reinit()
                except Exception:
                    pass
                # MUST be guarded. An exception raised inside an `except` block
                # is not caught by its own `try`: it escapes `_loop`, silently
                # kills this daemon thread, and Python says nothing. That is
                # exactly what used to happen here — `_resolve_fn` calls
                # sd.query_devices(), which raises PortAudioError when another
                # thread is mid-`_terminate()`. Only the Victor channel has a
                # `_resolve_fn`, so only Victor's thread died: the process, the
                # Audience thread and the menu-bar icon all stayed healthy while
                # nothing was transcribed for hours.
                try:
                    if self._resolve_fn:
                        resolved = self._resolve_fn()
                        if resolved:
                            new_idx, new_name = resolved
                            if new_idx != self.device or new_name != self.device_name:
                                log.info(
                                    "transcript",
                                    f"🎙️ [{self.label}] re-resolved: {new_name!r} (idx {new_idx})",
                                )
                            self.device = new_idx
                            self.device_name = new_name
                except Exception as resolve_exc:
                    log.error(
                        "transcript",
                        f"🎙️ [{self.label}] re-resolve failed: {resolve_exc}",
                    )

    def _cb(self, indata, frames, time_info, status):
        """PortAudio callback — must stay cheap; it runs on the audio thread.

        Two ways a chunk leaves here: the buffer fills (the clock), or the room
        goes quiet (the pause). The second one is what makes 12 s chunks safe —
        see `_SILENCE_FLUSH_SEC`.
        """
        block = indata[:, 0]
        # Recorded BEFORE any gating: the corpus needs the silence and the
        # below-threshold audio too, since the gate itself is one of the things
        # the speaker work may want to change.
        if self._recorder is not None:
            self._recorder.write(block)
        self._buf = np.concatenate([self._buf, block])
        threshold = self._current_threshold()

        while len(self._buf) >= self._chunk:
            chunk = self._buf[: self._chunk].copy()
            self._buf = self._buf[self._chunk - self._overlap :]
            self._emit(chunk, threshold)

        # A quiet block only counts once the buffer holds something worth
        # sending; otherwise every gap between two words would fire a flush.
        block_rms = float(np.sqrt(np.mean(block**2)))
        if block_rms < threshold:
            self._silent_blocks += 1
        else:
            self._silent_blocks = 0

        silent_sec = self._silent_blocks * (len(block) / _SAMPLE_RATE)
        # Measure the SPEECH in the buffer, not the buffer. The trailing silence
        # is sitting in `_buf` too, so a half-word followed by a long enough
        # pause would otherwise clear the bar on silence alone and emit a
        # fragment — and once it did, every gap would keep doing it.
        speech_samples = len(self._buf) - self._silent_blocks * len(block)
        if silent_sec >= _SILENCE_FLUSH_SEC and speech_samples >= int(
            _SAMPLE_RATE * _MIN_FLUSH_SEC
        ):
            pending = self._buf.copy()
            # No overlap carried over: the cut is a pause, so there is no word
            # straddling it to protect. Re-transcribing silence only buys
            # duplicated text.
            self._buf = np.zeros(0, dtype=np.float32)
            self._silent_blocks = 0
            self._emit(pending, threshold, why="silence")

    def _emit(self, chunk: np.ndarray, threshold: float, why: str = "full"):
        rms = float(np.sqrt(np.mean(chunk**2)))
        if rms >= threshold:
            tag = _short_device_name(self.device_name)
            self._queue.put((self.label, chunk, tag))
        elif rms > 0.001:  # non-silent but below threshold — log for debugging
            ts = datetime.now().strftime("%H:%M:%S.%f")[:10]
            print(
                f"{ts} [transcript  ] 🎙️ [{self.label}] below threshold ({why}): "
                f"rms={rms:.4f} < {threshold:.4f}"
            )


# ── Transcription thread ────────────────────────────────────────────────────
def _transcribe(audio, language=None, initial_prompt=None, model=None):
    import mlx_whisper

    model = model or _MODEL_BALANCED
    with (
        open(os.devnull, "w") as dev,
        contextlib.redirect_stdout(dev),
        contextlib.redirect_stderr(dev),
    ):
        return mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=model,
            language=language,
            verbose=False,
            condition_on_previous_text=True,
            initial_prompt=initial_prompt,
        )


def _effective_model(mode: str) -> str:
    if mode == "fast" and _MODEL_FAST:
        return _MODEL_FAST
    return _MODEL_BALANCED


def _select_model_mode(current_mode: str, backlog_size: int) -> str:
    if not _ADAPTIVE_QUALITY or _MODEL_FAST == _MODEL_BALANCED:
        return "balanced"

    if current_mode == "fast":
        # Hysteresis: stay fast until we drain close to idle.
        return "fast" if backlog_size > _ADAPTIVE_BACKLOG_LOW else "balanced"

    return "fast" if backlog_size >= _ADAPTIVE_BACKLOG_HIGH else "balanced"


def _merge_adjacent_chunks(batch_items):
    if not batch_items:
        return []

    merged = []
    cur_label, cur_audio, cur_tag = batch_items[0]
    for label, audio, tag in batch_items[1:]:
        if label == cur_label:
            cur_audio = np.concatenate([cur_audio, audio])
            cur_tag = tag
        else:
            merged.append((cur_label, cur_audio, cur_tag))
            cur_label, cur_audio, cur_tag = label, audio, tag
    merged.append((cur_label, cur_audio, cur_tag))
    return merged


def _collect_batch(first_item, tx_queue: queue.Queue):
    items = [first_item]
    total_samples = len(first_item[1])
    overflow = None

    deadline = time.monotonic() + max(0.0, _BATCH_MAX_WAIT_SEC)
    while len(items) < max(1, _BATCH_MAX_ITEMS):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            candidate = tx_queue.get(timeout=remaining)
        except queue.Empty:
            break

        candidate_samples = len(candidate[1])
        if (total_samples + candidate_samples) / _SAMPLE_RATE > _BATCH_MAX_AUDIO_SEC:
            overflow = candidate
            break

        items.append(candidate)
        total_samples += candidate_samples

    return items, overflow


def _supervised_transcriber_loop(tx_queue: queue.Queue, on_segment):
    """Same rule as the capture threads: never die quietly.

    The batching code around `tx_queue.get` sits outside the per-item try/except
    below, so an unexpected shape (a numpy concat mismatch, say) would kill this
    thread and leave a whisper that captures audio and transcribes nothing —
    indistinguishable from the outside from a healthy one.
    """
    while True:
        try:
            _transcriber_loop(tx_queue, on_segment)
            return
        except BaseException as exc:  # noqa: BLE001 — deliberately everything
            log.error("transcript", f"🎙️ transcriber loop crashed, restarting: {exc!r}")
            time.sleep(2)


def _transcriber_loop(tx_queue: queue.Queue, on_segment):
    log.info("transcript", "🎙️ Transcription loop started")
    # Track last transcribed text per channel for context
    prev_text: dict[str, str] = {}
    model_mode = "balanced"
    carry_item = None

    while True:
        if carry_item is None:
            try:
                first_item = tx_queue.get(timeout=1)
            except queue.Empty:
                continue
        else:
            first_item = carry_item
            carry_item = None

        batch_items, carry_item = _collect_batch(first_item, tx_queue)
        backlog_size = tx_queue.qsize() + (1 if carry_item is not None else 0)

        next_mode = _select_model_mode(model_mode, backlog_size)
        if next_mode != model_mode:
            model_mode = next_mode
            log.info(
                "transcript",
                f"🎙️ adaptive model -> {model_mode} (backlog={backlog_size})",
            )
        model_name = _effective_model(model_mode)

        merged_items = _merge_adjacent_chunks(batch_items)
        if len(batch_items) > 1:
            total_sec = sum(len(audio) for _, audio, _ in batch_items) / _SAMPLE_RATE
            log.info(
                "transcript",
                f"🎙️ batch={len(batch_items)} merged={len(merged_items)} audio={total_sec:.1f}s backlog={backlog_size}",
            )

        try:
            for label, audio, device_tag in merged_items:
                prompt = prev_text.get(label)
                result = _transcribe(audio, initial_prompt=prompt, model=model_name)
                text = result.get("text", "").strip()
                lang = result.get("language", "?")
                if lang not in ("ro", "en"):
                    result = _transcribe(
                        audio, language="ro", initial_prompt=prompt, model=model_name
                    )
                    text = result.get("text", "").strip()
                    lang = "ro"
                if _is_garbage(text):
                    continue
                # Keep last ~200 chars as context for next chunk
                prev_text[label] = text[-200:]
                on_segment(label, lang, text, device_tag)
        except Exception as exc:
            log.error("transcript", f"🎙️ Whisper error: {exc}")


# ── Runner ───────────────────────────────────────────────────────────────────
class WhisperTranscriptionRunner:
    """Starts Whisper capture threads and writes segments to normalized files."""

    def __init__(self, output_dir: Path, on_device_change=None):
        self.output_dir = output_dir
        self.enabled = False
        self._channels: list[_ChannelCapture] = []
        self._on_device_change = on_device_change
        self._me_channel: _ChannelCapture | None = None
        self._unregister_listener = None
        self._unregister_alive_listener = None
        self._recent_victor: list[tuple[float, str]] = []  # (timestamp, text) for dedup
        # Seed from the file's REAL mtime. Starting at 0.0 meant the watcher's
        # very first poll always saw "changed" — a phantom source switch ~1s
        # into every single run, which called _check_best_device() and tore
        # PortAudio down underneath two streams that had just opened. That one
        # line is what produced the paired `Invalid stream pointer [-9988]`
        # errors on every start, and the double-frees that crashed Python.
        self._pref_watch_mtime: float = _preferred_source_mtime()
        self._device_check_event = threading.Event()

    def _make_recorder(self, label: str) -> "_RawRecorder | None":
        if not _RECORD_RAW_ON:
            return None
        try:
            return _RawRecorder(self.output_dir / "raw-audio", label)
        except Exception as exc:
            # Recording is a nice-to-have for a corpus; transcription is the job.
            # A recorder that cannot start must never take whisper down with it.
            log.error("transcript", f"🎙️ raw recorder disabled: {exc}")
            return None

    def start(self):
        tx_queue: queue.Queue = queue.Queue()

        # Victor channel
        resolved = _resolve_device_coreaudio(_ME_PATTERNS)
        if resolved:
            me_idx, me_name = resolved
            log.info("transcript", f"🎙️ Resolved Victor: {me_name!r}")
            print(f"VICTOR_SOURCE:{_short_device_name(me_name)}", flush=True)
            self._me_channel = _ChannelCapture(
                me_idx,
                _ME_SPEAKER,
                tx_queue,
                me_name,
                resolve_fn=lambda: _resolve_device_coreaudio(_ME_PATTERNS),
                recorder=self._make_recorder(_ME_SPEAKER),
            )
            self._channels.append(self._me_channel)
        else:
            log.error("transcript", f"🎙️ No Victor device found matching {_ME_PATTERNS}")

        # Audience channel
        resolved = _resolve_device_coreaudio(_AUD_PATTERNS)
        if resolved:
            aud_idx, aud_name = resolved
            log.info("transcript", f"🎙️ Resolved Audience: {aud_name!r}")
            self._channels.append(
                _ChannelCapture(
                    aud_idx,
                    _AUD_SPEAKER,
                    tx_queue,
                    aud_name,
                    recorder=(
                        self._make_recorder(_AUD_SPEAKER) if _RECORD_RAW_ALL else None
                    ),
                )
            )
        else:
            log.error(
                "transcript", f"🎙️ No Audience device found matching {_AUD_PATTERNS}"
            )

        if not self._channels:
            log.error("transcript", "🎙️ Whisper disabled — no usable audio devices")
            return

        for ch in self._channels:
            ch.start()

        threading.Thread(
            target=_supervised_transcriber_loop,
            args=(tx_queue, self._on_segment),
            daemon=True,
            name="transcriber",
        ).start()

        self.enabled = True

        # Drains device-change notifications off CoreAudio's own thread.
        threading.Thread(
            target=self._device_check_worker, daemon=True, name="device-check"
        ).start()

        # Register CoreAudio device change listener (fires for USB/new devices)
        self._unregister_listener = register_device_change_callback(
            self._on_device_list_changed
        )
        # Register per-device alive listeners (fires for Bluetooth connect/disconnect)
        self._unregister_alive_listener = register_device_alive_callbacks(
            self._on_device_list_changed
        )
        log.info("transcript", "🎙️ CoreAudio device listeners registered")

        # Emit initial availability snapshot for the menu bar UI.
        self._emit_available()

        # Poll preference file for menu-driven source switches.
        if _PREFERRED_SOURCE_FILE:
            threading.Thread(
                target=self._watch_preference_file, daemon=True
            ).start()

    def _on_device_list_changed(self):
        """Called by CoreAudio when devices are added/removed.

        This runs ON COREAUDIO'S OWN NOTIFICATION QUEUE (the ctypes listeners in
        coreaudio_devices.py invoke us directly), so it must return immediately
        and touch nothing audio-related. The old code did the opposite: it slept
        2s and then called Pa_Terminate() right there, while CoreAudio held its
        locks — visible in the crash reports as a double-free on the
        `HALC_ProxyNotification Call Listener Queue`.

        It also has to COALESCE. One dock or projector plug fires the listener
        once per input device, and each of those used to spawn its own teardown;
        the worker below collapses a burst into a single check.
        """
        self._device_check_event.set()

    def _device_check_worker(self):
        while True:
            self._device_check_event.wait()
            # Bluetooth needs a moment to settle, and the wait doubles as the
            # coalescing window: everything that fires during it is one check.
            time.sleep(2)
            self._device_check_event.clear()
            try:
                self._check_best_device()
            except Exception as exc:
                log.error("transcript", f"🎙️ device check failed: {exc}")

    def _check_best_device(self, delay: float = 0):
        if not self._me_channel:
            return
        if delay:
            time.sleep(delay)
        try:
            # PortAudio caches its device list at import time and never sees USB
            # devices plugged in afterwards (e.g. DJI Mic Mini hot-plug), so a
            # re-init is the only way sd.query_devices() sees a hot-plugged mic.
            #
            # But re-init is `Pa_Terminate()` — process-global, it closes BOTH
            # channels' live streams — so it may only run when the device set
            # ACTUALLY changed. Firing it unconditionally on every device check
            # (and every phantom preference event) is what tore down healthy
            # streams several times an hour. CoreAudio's own list is the source
            # of truth here and needs no PortAudio call to read.
            if _device_set_changed():
                try:
                    _portaudio_reinit()
                except Exception as exc:
                    log.error("transcript", f"PortAudio refresh failed: {exc}")
            resolved = _resolve_device_coreaudio(_ME_PATTERNS)
            best_idx, best_name = resolved if resolved else (None, None)
            log.info(
                "transcript",
                f"🎙️ device check: best={best_name!r} current={self._me_channel.device_name!r}",
            )
            if not resolved:
                return
            if (
                best_name != self._me_channel.device_name
                or best_idx != self._me_channel.device
            ):
                short = _short_device_name(best_name)
                self._me_channel.switch_device(best_idx, best_name)
                self._write_to_transcript(f"--- {_ME_SPEAKER} → {short} ---")
                print(f"VICTOR_SOURCE:{short}", flush=True)
                if self._on_device_change:
                    self._on_device_change()
            # Always re-emit availability — device-list change may have toggled
            # available sources without changing the active one.
            self._emit_available()
        except Exception as exc:
            log.error("transcript", f"🎙️ Device change handler error: {exc}")

    def _emit_available(self):
        try:
            avail = _available_me_short_names()
            print(f"VICTOR_AVAILABLE:{','.join(avail)}", flush=True)
        except Exception as exc:
            log.error("transcript", f"🎙️ availability emit failed: {exc}")

    def _watch_preference_file(self):
        # Polls _PREFERRED_SOURCE_FILE for menu-driven source switches.
        # Whenever its mtime changes, re-run device resolution so the new
        # preferred pattern is applied without restarting whisper.
        while True:
            try:
                time.sleep(1)
                try:
                    mtime = os.path.getmtime(_PREFERRED_SOURCE_FILE)
                except (FileNotFoundError, OSError):
                    continue
                if mtime != self._pref_watch_mtime:
                    self._pref_watch_mtime = mtime
                    log.info(
                        "transcript",
                        f"🎙️ preferred source changed → {_read_preferred_source()!r}",
                    )
                    self._check_best_device()
            except Exception as exc:
                log.error("transcript", f"🎙️ preference watcher error: {exc}")

    def stop(self):
        if self._unregister_listener:
            self._unregister_listener()
        if self._unregister_alive_listener:
            self._unregister_alive_listener()
        for ch in self._channels:
            ch.stop()

    def _write_to_transcript(self, text: str):
        now = datetime.now()
        day_str = now.strftime("%Y-%m-%d")
        out_file = self.output_dir / f"{day_str}-transcription.txt"
        self.output_dir.mkdir(parents=True, exist_ok=True)
        with out_file.open("a", encoding="utf-8") as f:
            f.write(text + "\n")

    def _is_duplicate_of_victor(self, text: str) -> bool:
        """Check if audience text is a near-duplicate of recent Victor text."""
        now = time.time()
        # Clean old entries (older than 15 seconds)
        self._recent_victor = [(t, s) for t, s in self._recent_victor if now - t < 15]
        # Check similarity with recent Victor segments
        text_lower = text.lower().strip()
        for _, victor_text in self._recent_victor:
            ratio = SequenceMatcher(
                None, text_lower, victor_text.lower().strip()
            ).ratio()
            if ratio > 0.5:
                return True
        return False

    def _on_segment(self, label: str, lang: str, text: str, device_tag: str = ""):
        now = datetime.now()
        hhmm = now.strftime("%H:%M")

        # NO SPEAKER PREFIX, no mic glyph — just `[HH:MM] text`.
        #
        # The two channels do not separate two speakers. The room's audio and
        # the mic pick each other up, so both channels hear *everyone*: whoever
        # happened to be louder on that chunk decided whether a sentence was
        # filed under `Victor 🎙️:` or `Audience:`. A label that is wrong half
        # the time is worse than no label — it invites every downstream reader
        # (the summarizer, the ⌘⌃V picker, Victor himself) to attribute words
        # to the wrong mouth. The channels stay separate for *capture* (two
        # devices, two threads, the echo dedup below); they just no longer
        # claim to know who spoke.
        #
        # The `[HH:MM] ` stamp is load-bearing and stays: `TranscriptActivity`
        # counts only stamped lines as speech, which is what keeps the whisper
        # watchdog from mistaking a `--- Victor → 💻 ---` device marker for
        # somebody talking.
        if label == _ME_SPEAKER:
            # Still tracked, purely so the audience channel can recognise an
            # echo of what this channel just wrote and drop it.
            self._recent_victor.append((time.time(), text))
        elif self._is_duplicate_of_victor(text):
            return

        self._write_to_transcript(f"[{hhmm}] {text}")

        parts = text.split()
        words = len(parts)
        preview = " ".join(parts[:9])
        dots = " ..." if words > 9 else ""
        ts = datetime.now().strftime("%H:%M:%S.%f")[:10]
        print(f"{ts} [transcript  ] 🎙️{words} words: {preview}{dots}")


def _watch_parent(ppid: int) -> None:
    """Poll until the parent process (the Swift addon) is gone.

    When the parent dies for any reason (clean quit, crash, SIGKILL) the OS
    re-parents this process to launchd (PID 1), so os.getppid() changes.
    We then exit immediately to avoid accumulating orphan Whisper processes.
    """
    import time as _time

    while True:
        _time.sleep(2)
        if os.getppid() != ppid:
            try:
                print(
                    f"{__import__('datetime').datetime.now().strftime('%H:%M:%S.%f')[:10]} "
                    f"[sentinel    ] Parent {ppid} gone — exiting",
                    flush=True,
                )
            except Exception:
                pass
            os._exit(0)


def _required_parent_pid(env: dict[str, str]) -> int:
    raw = env.get("WHISPER_PARENT_PID", "").strip()
    if not raw:
        raise ValueError("WHISPER_PARENT_PID is required")
    try:
        pid = int(raw)
    except ValueError as exc:
        raise ValueError(f"WHISPER_PARENT_PID must be an integer, got {raw!r}") from exc
    if pid <= 1:
        raise ValueError(f"WHISPER_PARENT_PID must be > 1, got {pid}")
    return pid


def _install_quiet_death_handlers(runner_ref: dict) -> None:
    """Make this process die *quietly*, in both senses.

    1. **SIGTERM/SIGINT** — the Swift side stops us on every battery switch and
       every redeploy. Without a handler that lands wherever the interpreter
       happens to be, and CPython's shutdown then tears PortAudio down through
       `atexit` while audio callbacks are still live. `os._exit(0)` after a
       best-effort `runner.stop()` skips all of that. (The parent sentinel has
       always used this pattern, which is why it never crashed.)

    2. **SIGABRT/SIGSEGV/SIGBUS** — when PortAudio *does* still blow up, the
       interpreter we run under is `Python.app`, a bundled GUI app, so macOS
       greets the audience with a "Python quit unexpectedly" modal — mid-talk,
       on the projector. Dying by exit *status* instead of by uncaught signal
       produces no crash report and therefore no dialog.

       The trade-off is deliberate: we lose the `.ips` file. `faulthandler`
       cannot be combined with this — it refuses to `register()` fatal signals
       ("use enable() instead"), and `enable()` re-raises with the DEFAULT
       action rather than chaining, which is exactly the dialog we are removing.
       What we keep instead is everything Python already logged on its way down,
       plus `threading.excepthook` and the supervised loops, which now catch the
       failures that used to be invisible. Set
       `WHISPER_QUIET_CRASH=0` to get the crash reports back.
    """
    import ctypes
    import signal

    def _graceful_exit(_signum, _frame):
        runner = runner_ref.get("runner")
        if runner is not None:
            try:
                runner.stop()
            except Exception:
                pass
        os._exit(0)

    signal.signal(signal.SIGTERM, _graceful_exit)
    signal.signal(signal.SIGINT, _graceful_exit)

    if os.environ.get("WHISPER_QUIET_CRASH", "1") != "1":
        print("[sentinel    ] quiet-crash disabled — macOS will show the crash dialog", flush=True)
        return

    try:
        libc = ctypes.CDLL(None)
        # Handler addresses are 64-bit; the default c_int signature would
        # silently truncate them and install garbage.
        libc.signal.argtypes = [ctypes.c_int, ctypes.c_void_p]
        libc.signal.restype = ctypes.c_void_p
        # `_exit` is async-signal-safe; a Python-level handler is not, and would
        # deadlock here — SIGABRT from libmalloc arrives holding the malloc lock.
        # It gets called with the signal number as its status argument, which is
        # precisely the "died by status, not by signal" we are after.
        quiet = ctypes.cast(libc._exit, ctypes.c_void_p).value
        for sig in (signal.SIGABRT, signal.SIGSEGV, signal.SIGBUS):
            libc.signal(sig, quiet)
        print("[sentinel    ] quiet-crash handlers armed (no macOS crash dialog)", flush=True)
    except Exception as exc:  # never let hardening break startup
        print(f"[sentinel    ] quiet-crash handlers unavailable: {exc}", flush=True)


if __name__ == "__main__":
    import sys
    from pathlib import Path

    try:
        parent_pid = _required_parent_pid(os.environ)
    except ValueError as exc:
        ts = datetime.now().strftime("%H:%M:%S.%f")[:10]
        print(f"{ts} [sentinel    ] ERROR {exc}", flush=True)
        raise SystemExit(2)

    import threading

    # A dying thread is the failure mode that cost us a whole day of transcript:
    # Python's default is to print to stderr, which the Swift side used to
    # discard. Route it through our own logger so it can never be invisible again.
    def _thread_died(args):
        log.error(
            "transcript",
            f"🎙️ thread {getattr(args.thread, 'name', '?')} died: {args.exc_value!r}",
        )

    threading.excepthook = _thread_died

    threading.Thread(
        target=_watch_parent, args=(parent_pid,), daemon=True, name="sentinel"
    ).start()

    folder = Path(
        os.environ.get(
            "TRANSCRIPTION_FOLDER",
            "/Users/victorrentea/workspace/victor-macos-addons/addons-output",
        )
    )
    runner_ref: dict = {}
    _install_quiet_death_handlers(runner_ref)

    runner = WhisperTranscriptionRunner(folder)
    runner_ref["runner"] = runner
    runner.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        runner.stop()
