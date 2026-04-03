"""Live Whisper transcription runner — writes directly to normalized transcript files.

Victor's mic priority: XLR > Bose > MacBook (auto-switches on connect/disconnect)
Audience: FROM Zoom loopback

Uses CoreAudio for device detection (no stale devices) and sounddevice for capture.
"""

import contextlib
import os
import queue
import sys
import threading
import time
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np

# Add parent dir so we can import coreaudio_devices from wispr-flow
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "wispr-flow"))
from coreaudio_devices import list_input_devices, register_device_change_callback


# ── Logging ──────────────────────────────────────────────────────────────────
_log_callback = None  # optional callable(str) — forwards all transcription logs to the menu


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
_ME_SPEAKER   = os.environ.get("WHISPER_ME_SPEAKER",       "Victor")
_AUD_SPEAKER  = os.environ.get("WHISPER_AUDIENCE_SPEAKER", "Audience")
_MODEL        = os.environ.get("WHISPER_MODEL",            "mlx-community/whisper-large-v3-turbo")
_CHUNK_SEC    = float(os.environ.get("WHISPER_CHUNK_SECONDS",      "4"))
_OVERLAP_SEC  = float(os.environ.get("WHISPER_OVERLAP_SECONDS",    "0.5"))
_SAMPLE_RATE  = 16000

_THRESHOLDS = {
    "xlr":      0.018,
    "bose":     0.015,
    "macbook":  0.008,
    "audience": 0.025,
}
_DEFAULT_THRESHOLD = 0.018

_ME_PATTERNS  = ["XLR", "Bose", "MacBook"]
_AUD_PATTERNS = ["From Zoom"]

_HALLUCINATIONS = {
    "thank you.", "thanks for watching.", "thanks.", "you", ".",
    "subtitles by the amara.org community", "www.mooji.org",
    "[music]", "[ music ]", "(music)", "♪", "...",
}

# Short display names for known devices
_DEVICE_SHORT_NAMES = {
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
def _resolve_device_coreaudio(patterns: list[str]) -> tuple[int, str] | None:
    """Find the best input device by pattern priority using CoreAudio (no stale devices).
    Returns (sounddevice_index, device_name) or None."""
    import sounddevice as sd
    ca_devices = list_input_devices()
    ca_names = {d["name"] for d in ca_devices if d["alive"]}

    for pattern in patterns:
        for i, d in enumerate(sd.query_devices()):
            if (pattern.lower() in d["name"].lower()
                    and d["max_input_channels"] > 0
                    and d["name"] in ca_names):
                return i, d["name"]
    return None


# ── Audio capture ────────────────────────────────────────────────────────────
class _ChannelCapture:
    def __init__(self, device: int, label: str, tx_queue: queue.Queue,
                 device_name: str = "", resolve_fn=None):
        self.device = device
        self.label = label
        self.device_name = device_name
        self._resolve_fn = resolve_fn  # callable() -> (idx, name) | None
        self._queue = tx_queue
        self._buf = np.zeros(0, dtype=np.float32)
        self._chunk = int(_SAMPLE_RATE * _CHUNK_SEC)
        self._overlap = int(_SAMPLE_RATE * _OVERLAP_SEC)
        self._running = False
        self._stream = None

    def start(self):
        self._running = True
        threading.Thread(target=self._loop, daemon=True).start()

    def stop(self):
        self._running = False
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
            device=self.device, channels=1,
            samplerate=_SAMPLE_RATE, dtype="float32",
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
                log.info("transcript", f"🎙️ [{self.label}] capturing from {self.device_name!r}")
                while self._running and s.active:
                    time.sleep(0.5)
                # Stream ended (device switched or disconnected)
                try:
                    s.stop(); s.close()
                except Exception:
                    pass
                if self._running:
                    self._buf = np.zeros(0, dtype=np.float32)
                    time.sleep(0.5)
            except Exception as exc:
                _consecutive_errors += 1
                # Log first error, then every 30th (once per minute at 2s retry)
                if _consecutive_errors == 1 or _consecutive_errors % 30 == 0:
                    log.error("transcript", f"🎙️ [{self.label}] stream error (x{_consecutive_errors}): {exc}")
                time.sleep(2)
                # Force PortAudio to reinitialize — recovers from CoreAudio invalid state after reconnect
                try:
                    import sounddevice as sd
                    sd._terminate()
                    sd._initialize()
                except Exception:
                    pass
                if self._resolve_fn:
                    resolved = self._resolve_fn()
                    if resolved:
                        new_idx, new_name = resolved
                        if new_idx != self.device or new_name != self.device_name:
                            log.info("transcript", f"🎙️ [{self.label}] re-resolved: {new_name!r} (idx {new_idx})")
                        self.device = new_idx
                        self.device_name = new_name

    def _cb(self, indata, frames, time_info, status):
        self._buf = np.concatenate([self._buf, indata[:, 0]])
        while len(self._buf) >= self._chunk:
            chunk = self._buf[: self._chunk].copy()
            self._buf = self._buf[self._chunk - self._overlap :]
            rms = float(np.sqrt(np.mean(chunk ** 2)))
            threshold = self._current_threshold()
            if rms >= threshold:
                tag = _short_device_name(self.device_name)
                self._queue.put((self.label, chunk, tag))
            elif rms > 0.001:  # non-silent but below threshold — log for debugging
                ts = datetime.now().strftime("%H:%M:%S.%f")[:10]
                print(f"{ts} [transcript  ] 🎙️ [{self.label}] below threshold: rms={rms:.4f} < {threshold:.4f}")


# ── Transcription thread ────────────────────────────────────────────────────
def _transcribe(audio, language=None):
    import mlx_whisper
    with open(os.devnull, "w") as dev, \
         contextlib.redirect_stdout(dev), \
         contextlib.redirect_stderr(dev):
        return mlx_whisper.transcribe(
            audio, path_or_hf_repo=_MODEL,
            language=language, verbose=False,
            condition_on_previous_text=False,
        )


def _transcriber_loop(tx_queue: queue.Queue, on_segment):
    log.info("transcript", "🎙️ Transcription loop started")

    while True:
        try:
            label, audio, device_tag = tx_queue.get(timeout=1)
        except queue.Empty:
            continue
        try:
            result = _transcribe(audio)
            text = result.get("text", "").strip()
            lang = result.get("language", "?")
            if lang not in ("ro", "en"):
                result = _transcribe(audio, language="ro")
                text   = result.get("text", "").strip()
                lang   = "ro"
            if not text or text.lower() in _HALLUCINATIONS:
                continue
            on_segment(label, lang, text, device_tag)
        except Exception as exc:
            log.error("transcript", f"🎙️ Whisper error: {exc}")


# ── Runner ───────────────────────────────────────────────────────────────────
class WhisperTranscriptionRunner:
    """Starts Whisper capture threads and writes segments to normalized files."""

    def __init__(self, output_dir: Path, on_device_change=None):
        self.output_dir = output_dir
        self.enabled    = False
        self._channels: list[_ChannelCapture] = []
        self._on_device_change = on_device_change
        self._me_channel: _ChannelCapture | None = None
        self._unregister_listener = None
        self._recent_victor: list[tuple[float, str]] = []  # (timestamp, text) for dedup

    def start(self):
        tx_queue: queue.Queue = queue.Queue()

        # Victor channel
        resolved = _resolve_device_coreaudio(_ME_PATTERNS)
        if resolved:
            me_idx, me_name = resolved
            log.info("transcript", f"🎙️ Resolved Victor: {me_name!r}")
            self._me_channel = _ChannelCapture(me_idx, _ME_SPEAKER, tx_queue, me_name,
                                               resolve_fn=lambda: _resolve_device_coreaudio(_ME_PATTERNS))
            self._channels.append(self._me_channel)
        else:
            log.error("transcript", f"🎙️ No Victor device found matching {_ME_PATTERNS}")

        # Audience channel
        resolved = _resolve_device_coreaudio(_AUD_PATTERNS)
        if resolved:
            aud_idx, aud_name = resolved
            log.info("transcript", f"🎙️ Resolved Audience: {aud_name!r}")
            self._channels.append(_ChannelCapture(aud_idx, _AUD_SPEAKER, tx_queue, aud_name))
        else:
            log.error("transcript", f"🎙️ No Audience device found matching {_AUD_PATTERNS}")

        if not self._channels:
            log.error("transcript", "🎙️ Whisper disabled — no usable audio devices")
            return

        for ch in self._channels:
            ch.start()

        threading.Thread(
            target=_transcriber_loop,
            args=(tx_queue, self._on_segment),
            daemon=True,
        ).start()

        self.enabled = True

        # Register CoreAudio device change listener
        self._unregister_listener = register_device_change_callback(self._on_device_list_changed)
        log.info("transcript", "🎙️ CoreAudio device change listener registered")

    def _on_device_list_changed(self):
        """Called by CoreAudio when devices are added/removed."""
        if not self._me_channel:
            return
        # Small delay for Bluetooth stabilization
        time.sleep(2)
        try:
            resolved = _resolve_device_coreaudio(_ME_PATTERNS)
            if not resolved:
                return
            best_idx, best_name = resolved
            if best_name != self._me_channel.device_name or best_idx != self._me_channel.device:
                short = _short_device_name(best_name)
                self._me_channel.switch_device(best_idx, best_name)
                self._write_to_transcript(f"--- {_ME_SPEAKER} → {short} ---")
                if self._on_device_change:
                    self._on_device_change()
        except Exception as exc:
            log.error("transcript", f"🎙️ Device change handler error: {exc}")

    def stop(self):
        if self._unregister_listener:
            self._unregister_listener()
        for ch in self._channels:
            ch.stop()

    def _write_to_transcript(self, text: str):
        now = datetime.now()
        day_str = now.strftime("%Y-%m-%d")
        out_file = self.output_dir / f"{day_str} transcription.txt"
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
            ratio = SequenceMatcher(None, text_lower, victor_text.lower().strip()).ratio()
            if ratio > 0.5:
                return True
        return False

    def _on_segment(self, label: str, lang: str, text: str, device_tag: str = ""):
        now  = datetime.now()
        hhmm = now.strftime("%H:%M")

        if label == _ME_SPEAKER:
            # Track Victor's recent text for dedup
            self._recent_victor.append((time.time(), text))
            if device_tag:
                line = f"[{hhmm}] {label} {device_tag}: {text}"
            else:
                line = f"[{hhmm}] {label}: {text}"
        else:
            # Audience — skip if it's an echo of Victor
            if self._is_duplicate_of_victor(text):
                return
            line = f"[{hhmm}] {label}:  {text}"

        self._write_to_transcript(line)

        parts = text.split()
        words = len(parts)
        preview = " ".join(parts[:9])
        dots = " ..." if words > 9 else ""
        ts = datetime.now().strftime("%H:%M:%S.%f")[:10]
        print(f"{ts} [transcript  ] 🎙️{words} words: {preview}{dots}")
