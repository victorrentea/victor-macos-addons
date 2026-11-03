"""🔋 Record on battery, transcribe on AC.

On battery whisper runs in **capture-only** mode (`WHISPER_CAPTURE_ONLY=1`): the
microphones stay open, the 1.8 GB model is never loaded, and each channel's audio
goes to disk. When the charger is back, the full whisper process transcribes that
backlog and slots the lines into the day's transcript **at the minute they were
spoken**, then deletes the audio.

Why not simply keep transcribing on battery: the meeting that started this
(2026-11-03) was missed because whisper stops entirely off AC. Capturing costs an
audio callback and ~32 KB/s of disk per channel; transcribing costs the GPU on
every sentence. The text is only late, never lost.

Three pieces, all here so the runner only wires them:

* `SessionRecorder` — one channel's audio, a file per *continuous* stretch.
* `segment_offline` + `merge_into_transcript` — pure, tested functions.
* `BacklogTranscriber` — the AC-side thread that drains `battery-audio/`.
"""
from __future__ import annotations

import json
import os
import queue
import re
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000
DIR_NAME = "battery-audio"
SUFFIX = ".s16le16k.pcm"
# A jump in the callback clock larger than this starts a new file. Inside one
# file a sample's time is `start + offset / rate`; across a gap (a device reopen,
# a sleep, a stall) that arithmetic would drift, so the gap ends the file.
GAP_SEC = 2.0
_STAMP_RE = re.compile(r"^\[(\d{2}):(\d{2})\]")
MARKER = "--- 🔋 from battery audio ---"


# ── Capture side ─────────────────────────────────────────────────────────────
class SessionRecorder:
    """One channel's battery audio, off the audio thread.

    Same discipline as `_RawRecorder` in the runner — the callback only does a
    non-blocking put, a writer thread owns the disk — with one difference that is
    the whole point: **a file knows when it started**. The name carries the wall
    clock of its first sample, and a sidecar JSON the device and the threshold the
    live gate would have used, so the AC side can cut the audio exactly as the
    live path would have and stamp each line with the minute it was spoken.
    """

    def __init__(self, out_dir: Path, label: str, log=None, queue_blocks: int = 600):
        self._dir = out_dir
        self._label = re.sub(r"[^A-Za-z0-9]+", "-", label).strip("-") or "channel"
        self._log = log
        self._q: queue.Queue = queue.Queue(maxsize=queue_blocks)
        self._running = True
        self._fh = None
        self._path: Path | None = None
        self._start: float | None = None
        self._samples = 0
        self._device: str | None = None
        self.dropped = 0
        self._thread = threading.Thread(
            target=self._supervised, daemon=True, name=f"batt-{self._label}"
        )
        self._thread.start()

    # Called from PortAudio's realtime callback: must not block, must not raise.
    def write(self, block: np.ndarray, device: str, threshold: float, at: float | None = None):
        try:
            self._q.put_nowait((time.time() if at is None else at, block.copy(), device, threshold))
        except BaseException:  # noqa: BLE001 — deliberately everything, see _RawRecorder
            self.dropped += 1

    def _say(self, level: str, msg: str):
        if self._log is not None:
            getattr(self._log, level)("transcript", msg)

    def _supervised(self):
        while self._running:
            try:
                self._loop()
                return
            except BaseException as exc:  # noqa: BLE001
                self._say("error", f"🔋 battery recorder crashed, restarting: {exc!r}")
                time.sleep(1)

    def _loop(self):
        while self._running or not self._q.empty():
            try:
                at, block, device, threshold = self._q.get(timeout=0.5)
            except queue.Empty:
                continue
            self._append(at, block, device, threshold)

    def _append(self, at: float, block: np.ndarray, device: str, threshold: float):
        # `at` is when the callback ran, i.e. when the block *ended*.
        block_start = at - len(block) / SAMPLE_RATE
        expected = None if self._start is None else self._start + self._samples / SAMPLE_RATE
        if (
            self._fh is None
            or device != self._device
            or abs(block_start - expected) > GAP_SEC
        ):
            self._open(block_start, device, threshold)
        clipped = np.clip(block, -1.0, 1.0)
        self._fh.write((clipped * 32767).astype(np.int16).tobytes())
        self._fh.flush()
        self._samples += len(block)

    def _open(self, start: float, device: str, threshold: float):
        self._close()
        self._dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.fromtimestamp(start).strftime("%Y-%m-%dT%H-%M-%S.%f")[:23]
        self._path = self._dir / f"{stamp}-{self._label}{SUFFIX}"
        meta = {"start": start, "label": self._label, "device": device, "threshold": threshold}
        # Sidecar first: a PCM without one would be unreadable, a sidecar
        # without a PCM is just skipped.
        self._path.with_suffix(".json").write_text(json.dumps(meta), encoding="utf-8")
        self._fh = open(self._path, "ab")
        self._start, self._samples, self._device = start, 0, device
        self._say("info", f"🔋 recording on battery → {self._path.name} ({device!r})")

    def _close(self):
        if self._fh is not None:
            try:
                self._fh.close()
            except Exception:  # noqa: BLE001
                pass
            self._fh = None

    def stop(self, timeout: float = 2.0):
        self._running = False
        self._thread.join(timeout)
        self._close()


# ── Pure helpers ─────────────────────────────────────────────────────────────
def segment_offline(
    samples: np.ndarray,
    threshold: float,
    *,
    rate: int = SAMPLE_RATE,
    chunk_sec: float = 12.0,
    overlap_sec: float = 2.0,
    silence_flush_sec: float = 0.6,
    min_flush_sec: float = 1.5,
    block_sec: float = 0.1,
) -> list[tuple[int, np.ndarray]]:
    """Cut a recording the way `_ChannelCapture._cb` cuts live audio.

    Same two exits — the 12 s clock (keeping a 2 s overlap) and a pause after
    enough new speech — and the same RMS gate on what is sent, so a backlog
    reads like the live transcript would have. Returns `(start_sample, audio)`.
    """
    block = max(1, int(rate * block_sec))
    chunk = int(rate * chunk_sec)
    overlap = int(rate * overlap_sec)
    out: list[tuple[int, np.ndarray]] = []

    def emit(start: int, audio: np.ndarray):
        if len(audio) and float(np.sqrt(np.mean(audio**2))) >= threshold:
            out.append((start, audio))

    buf_start = 0  # sample index of buf[0]
    buf_len = 0
    carried = 0
    silent_blocks = 0
    pos = 0
    n = len(samples)
    while pos < n:
        b = samples[pos : pos + block]
        pos += len(b)
        buf_len += len(b)
        while buf_len >= chunk:
            emit(buf_start, samples[buf_start : buf_start + chunk])
            buf_start += chunk - overlap
            buf_len -= chunk - overlap
            carried = overlap
        rms = float(np.sqrt(np.mean(b**2))) if len(b) else 0.0
        silent_blocks = silent_blocks + 1 if rms < threshold else 0
        speech = buf_len - carried - silent_blocks * block
        if silent_blocks * block_sec >= silence_flush_sec and speech >= int(rate * min_flush_sec):
            s = buf_start + carried
            emit(s, samples[s : buf_start + buf_len])
            buf_start += buf_len
            buf_len = 0
            carried = 0
            silent_blocks = 0
    # The end of a file is a pause by definition: flush what is left of it.
    tail = buf_start + carried
    if n - tail >= int(rate * min_flush_sec * 0.5):
        emit(tail, samples[tail:n])
    return out


def _minute(line: str) -> int | None:
    m = _STAMP_RE.match(line)
    return int(m.group(1)) * 60 + int(m.group(2)) if m else None


def merge_into_transcript(existing: list[str], new: list[str], marker: str = MARKER) -> list[str]:
    """Slot stamped `new` lines among `existing` ones, in minute order.

    A new line goes before the first existing stamped line of a *later* minute;
    at the same minute the existing line stays first. Unstamped lines (device
    markers) never move. Each run of inserted lines opens with `marker`, so a
    reader can tell text written live from text recovered later.
    """
    pending = sorted(((_minute(l) or 0, i, l) for i, l in enumerate(new)))
    out: list[str] = []
    in_run = False
    k = 0
    for line in existing:
        m = _minute(line)
        if m is not None:
            while k < len(pending) and pending[k][0] < m:
                if not in_run:
                    out.append(marker)
                    in_run = True
                out.append(pending[k][2])
                k += 1
        out.append(line)
        in_run = False
    if k < len(pending):
        out.append(marker)
        out.extend(p[2] for p in pending[k:])
    return out


# ── AC side ──────────────────────────────────────────────────────────────────
@dataclass
class _Recording:
    pcm: Path
    meta: dict

    @property
    def start(self) -> float:
        return float(self.meta["start"])

    @property
    def end(self) -> float:
        return self.start + self.pcm.stat().st_size / 2 / SAMPLE_RATE


def pending_recordings(folder: Path, settle_sec: float = 5.0) -> list[_Recording]:
    """Every finished battery recording, oldest first.

    `settle_sec` skips a file written to in the last few seconds — on AC nothing
    should be writing here, but a capture-only process that is still flushing
    on its way out must not have its file read half-done.
    """
    d = folder / DIR_NAME
    if not d.is_dir():
        return []
    now = time.time()
    out = []
    for pcm in d.glob(f"*{SUFFIX}"):
        side = pcm.with_suffix(".json")
        try:
            if now - pcm.stat().st_mtime < settle_sec:
                continue
            meta = json.loads(side.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        out.append(_Recording(pcm, meta))
    return sorted(out, key=lambda r: r.start)


def clusters(recs: list[_Recording]) -> list[list[_Recording]]:
    """Group recordings whose time ranges overlap — the two channels of one
    stretch — so the audience echo of Victor's words can be recognised."""
    groups: list[list[_Recording]] = []
    end = -1.0
    for r in recs:
        if groups and r.start <= end + GAP_SEC:
            groups[-1].append(r)
            end = max(end, r.end)
        else:
            groups.append([r])
            end = r.end
    return groups


def remove(rec: _Recording):
    for p in (rec.pcm, rec.pcm.with_suffix(".json")):
        try:
            p.unlink()
        except FileNotFoundError:
            pass


class BacklogTranscriber:
    """Drain `battery-audio/` on AC, one continuous stretch at a time.

    Runs inside the live whisper process so both share one loaded model, and it
    **always yields to live audio**: it only transcribes while the live queue is
    empty, and the model lock (`_transcribe` takes it) keeps the two from calling
    mlx at once. A stretch is committed all at once — lines into the transcript,
    then the audio deleted — so a whisper killed half-way through simply starts
    that stretch over next time, without duplicating a line.
    """

    def __init__(self, folder: Path, live_queue: queue.Queue, transcribe, write_lines,
                 is_garbage, me_label: str, log, poll_sec: float = 60.0):
        self._folder = folder
        self._live = live_queue
        self._transcribe = transcribe
        self._write_lines = write_lines  # callable(day, [lines]) -> None
        self._is_garbage = is_garbage
        self._me = re.sub(r"[^A-Za-z0-9]+", "-", me_label).strip("-")
        self._log = log
        self._poll = poll_sec

    def start(self):
        threading.Thread(target=self._run, daemon=True, name="battery-backlog").start()

    def _run(self):
        while True:
            try:
                self.drain_once()
            except BaseException as exc:  # noqa: BLE001 — never die quietly
                self._log.error("transcript", f"🔋 backlog crashed: {exc!r}")
            time.sleep(self._poll)

    def _wait_for_idle_live(self):
        while self._live.qsize() > 0:
            time.sleep(0.5)

    def drain_once(self) -> int:
        """Transcribe every pending stretch. Returns how many were committed."""
        done = 0
        for group in clusters(pending_recordings(self._folder)):
            self._commit(group)
            done += 1
        return done

    def _commit(self, group: list[_Recording]):
        t0 = time.monotonic()
        items = []  # (abs_time, label, audio)
        for rec in group:
            raw = np.fromfile(rec.pcm, dtype=np.int16).astype(np.float32) / 32767.0
            thr = float(rec.meta.get("threshold", 0.018))
            for start, audio in segment_offline(raw, thr):
                items.append((rec.start + start / SAMPLE_RATE, rec.meta.get("label", ""), audio))
        items.sort(key=lambda x: x[0])
        minutes = sum(r.end - r.start for r in group) / 60
        self._log.info(
            "transcript",
            f"🔋 transcribing battery audio from "
            f"{datetime.fromtimestamp(group[0].start):%H:%M} — {len(group)} file(s), "
            f"{minutes:.1f} min, {len(items)} chunk(s)",
        )
        by_day: dict[str, list[str]] = {}
        prev: dict[str, str] = {}
        recent_me: list[tuple[float, str]] = []
        for at, label, audio in items:
            self._wait_for_idle_live()
            result = self._transcribe(audio, initial_prompt=prev.get(label))
            text = (result.get("text") or "").strip()
            if result.get("language") not in ("ro", "en"):
                result = self._transcribe(audio, language="ro", initial_prompt=prev.get(label))
                text = (result.get("text") or "").strip()
            if not text or self._is_garbage(text):
                continue
            prev[label] = text[-200:]
            if label == self._me:
                recent_me.append((at, text))
            elif any(
                abs(at - t) < 15 and SequenceMatcher(None, text.lower(), s.lower()).ratio() > 0.5
                for t, s in recent_me
            ):
                continue  # the room channel's echo of what the mic already wrote
            when = datetime.fromtimestamp(at)
            by_day.setdefault(when.strftime("%Y-%m-%d"), []).append(f"[{when:%H:%M}] {text}")
        for day, lines in by_day.items():
            self._write_lines(day, lines)
        for rec in group:
            remove(rec)
        n = sum(len(v) for v in by_day.values())
        self._log.info(
            "transcript",
            f"🔋 battery audio transcribed: {n} line(s) in {time.monotonic() - t0:.0f}s, audio deleted",
        )
