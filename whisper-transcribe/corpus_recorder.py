#!/usr/bin/env python3
"""Utterance-sized WAVs of Victor's own voice, collected all day, for training.

This is the *second* recorder in this process and the difference between the two
is the whole point:

  `_RawRecorder` (in `whisper_runner.py`)   this file
  ───────────────────────────────────────   ─────────────────────────────────
  one headerless PCM per day                one WAV per utterance
  everything, silence included              only what looks like speech
  armed for one session, ~115 MB/h          stands all day, ~2 MB per minute
                                            of speech and nothing while quiet
  a corpus to *study* the gate              a corpus to *train* on

The training corpus needs pairs — audio plus a transcript — and a transcript is
produced per utterance, not per day. Slicing a day-long PCM afterwards is the
same work done later with less information (the thresholds, the device, the
speaker verdict are all here and none of them are in the file). So the cut
happens while the audio is still passing through.

## Why record the whole workday at all

The corpus is stuck. Wispr Flow is the teacher and it keeps its transcripts
forever but prunes its **recordings** after about a week: 12,186 transcripts and
185 recordings on 2026-09-01. Harvesting its database can therefore only ever
collect the last seven days, which caps the corpus at whatever Victor happened
to dictate. Recording the microphone directly inverts that dependency — the
audio is ours and it is kept as long as we like, and the label can be asked for
later, including months later, from a teacher that has long since forgotten it.

What gates it instead is taste, not the clock:

* **A work window** (`Mon-Fri 09:00-17:00` by default). Not a privacy fig leaf —
  it is where the speech is. Evenings and weekends are mostly a quiet room and a
  fan, which cost disk and yield nothing.
* **Speech-likeness**, so a corpus of keyboard clatter is not collected: the same
  per-device RMS gate the transcription already uses, plus a voiced-fraction
  floor and a speech-band energy check that rejects hum, clicks and music.
* **The enrolled voiceprint**, so a room full of people who were not asked is not
  collected either — an utterance the scorer positively attributes to the
  audience is dropped, and only Victor plus the "not saying" band is kept. That
  is also exactly the filter the training data wants: this is a single-speaker
  fine-tune.

## The one rule inherited from `_RawRecorder`

**Never block the audio callback.** `write()` does a non-blocking put onto a
bounded queue and returns; a writer thread does the segmentation, the filtering,
the scoring and the disk I/O. A full queue drops audio and counts it. Losing a
second of corpus costs nothing; stuttering the transcript in front of a room
costs a lot.

Segmentation runs on the writer thread rather than in the callback for the same
reason, and it is safe to move because the queue preserves order: the writer
sees exactly the blocks the callback saw, in the order it saw them.
"""

from __future__ import annotations

import json
import os
import queue
import shutil
import threading
import time
import wave
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000

# ── Tunables ─────────────────────────────────────────────────────────────────
# Audio kept from *before* the gate opened. Speech starts quietly — a plosive or
# an unstressed first syllable can sit under the RMS threshold — and an utterance
# whose first 200 ms are missing teaches the model to hallucinate a beginning.
PREROLL_SEC = float(os.environ.get("VOICE_CORPUS_PREROLL_SECONDS", "0.35"))
# Silence that closes an utterance. Deliberately longer than the transcriber's
# 0.6 s flush: that one optimises latency (get the words out), this one optimises
# the cut (do not saw a sentence in half at a breath). A comma-length pause is
# ~0.4 s, a sentence boundary ~0.8 s.
HANG_SEC = float(os.environ.get("VOICE_CORPUS_HANG_SECONDS", "0.9"))
# Below this an utterance is a cough, a chair or one word with no context, and a
# fine-tune learns nothing from it while paying full price for the label.
MIN_SEC = float(os.environ.get("VOICE_CORPUS_MIN_SECONDS", "1.2"))
# Above this, cut regardless. Two reasons and the second is the real one: the
# teacher has to dictate every sample back in real time, and a 5-minute monologue
# is a 5-minute Wispr session that can fail as one unit and lose all of it.
MAX_SEC = float(os.environ.get("VOICE_CORPUS_MAX_SECONDS", "30"))
# Fraction of the utterance's blocks that must be above the gate. A long pause
# glued to two words passes the duration test and is still mostly nothing.
MIN_VOICED_RATIO = float(os.environ.get("VOICE_CORPUS_MIN_VOICED", "0.30"))
# Share of the energy that must fall in the speech band (300–3400 Hz). Fan and
# mains hum sit below it, key clicks and rustle spread above it. Measured on
# this mic, ordinary speech lands at 0.6–0.9; a quiet room with a laptop fan at
# 0.1–0.3. 0.45 is comfortably between the two rather than tight against either.
MIN_SPEECH_BAND = float(os.environ.get("VOICE_CORPUS_MIN_SPEECH_BAND", "0.45"))
# ≈ 60 s of slack at 100 ms blocks, same size and same reasoning as the raw
# recorder's: bounded, because an unbounded queue in front of a stalled disk
# grows until the process dies.
QUEUE_BLOCKS = int(os.environ.get("VOICE_CORPUS_QUEUE_BLOCKS", "600"))
# Stop collecting rather than fill the disk. Both numbers are checked; whichever
# bites first wins. The corpus is worth a lot and a Mac with no free space is
# worth nothing.
#
# The floor is set against what this Mac actually has, not against a round
# number: 54 GB free of 926 on 2026-09-11, which is already tight. At the
# measured rate — roughly 2 MB per minute of speech, and a workday holds one to
# two hours of it — 20 GB is on the order of eighty working days, so the cap is
# not the thing that decides how much corpus there is. Moving `VOICE_CORPUS_DIR`
# to an external disk raises both limits by moving the disk they are about.
MAX_CORPUS_GB = float(os.environ.get("VOICE_CORPUS_MAX_GB", "20"))
MIN_FREE_GB = float(os.environ.get("VOICE_CORPUS_MIN_FREE_GB", "30"))

_DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


# ── The work window ──────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Window:
    """When collecting is allowed. Parsed from one string, e.g. `Mon-Fri 09:00-17:00`.

    Kept as a value object with a pure `contains` so the schedule can be tested
    without a clock, an audio device or a disk — the three things that make the
    rest of this file awkward to test.
    """

    days: frozenset[int]  # 0 = Monday, matching `datetime.weekday()`
    start_min: int
    end_min: int
    # `always` is not "days = all, 00:00-24:00" spelled differently: it is the
    # explicit off-switch for the schedule, and it has to be distinguishable in
    # the manifest and the logs from a window that merely happens to be wide.
    always: bool = False

    def contains(self, at: datetime) -> bool:
        if self.always:
            return True
        if at.weekday() not in self.days:
            return False
        minutes = at.hour * 60 + at.minute
        return self.start_min <= minutes < self.end_min

    @staticmethod
    def parse(spec: str) -> "Window":
        """`Mon-Fri 09:00-17:00`, `Mon,Wed 08:00-20:00`, `always`, or `all 0:00-24:00`.

        A spec that does not parse raises. It is tempting to fall back to
        "always" so a typo cannot stop collection — that is the wrong failure:
        a typo would then silently record evenings and weekends. Refusing to
        start is visible; over-recording is not.
        """
        spec = (spec or "").strip()
        if spec.lower() in {"always", "all", "24/7", "*"}:
            return Window(frozenset(range(7)), 0, 24 * 60, always=True)
        try:
            day_part, time_part = spec.split()
        except ValueError as exc:
            raise ValueError(f"window needs '<days> <from>-<to>': {spec!r}") from exc

        days: set[int] = set()
        for piece in day_part.split(","):
            piece = piece.strip().lower()
            if piece in {"all", "*"}:
                days |= set(range(7))
            elif "-" in piece:
                a, b = piece.split("-", 1)
                ia, ib = _DAYS.index(a[:3]), _DAYS.index(b[:3])
                # Wrapping ranges (`Fri-Mon`) are honest input, so walk forward
                # modulo 7 instead of assuming ia <= ib.
                days |= {(ia + k) % 7 for k in range((ib - ia) % 7 + 1)}
            else:
                days.add(_DAYS.index(piece[:3]))
        start, end = (_hhmm(t) for t in time_part.split("-", 1))
        if end <= start:
            raise ValueError(f"window ends before it starts: {spec!r}")
        return Window(frozenset(days), start, end)


def _hhmm(text: str) -> int:
    h, _, m = text.strip().partition(":")
    return int(h) * 60 + int(m or 0)


# ── Speech-likeness ──────────────────────────────────────────────────────────
def speech_band_ratio(audio: np.ndarray) -> float:
    """Share of the energy between 300 and 3400 Hz — the telephone band.

    Cheap (one rfft on a few seconds, single-digit milliseconds) and it separates
    the two things the RMS gate cannot: a fan or mains hum, whose energy is all
    below 300 Hz and which a sensitive mic reports as a perfectly respectable
    RMS, and clicks and rustle, whose energy is spread far above the band.
    """
    if len(audio) < 256:
        return 0.0
    spectrum = np.abs(np.fft.rfft(audio * np.hanning(len(audio)))) ** 2
    freqs = np.fft.rfftfreq(len(audio), 1.0 / SAMPLE_RATE)
    total = float(spectrum.sum())
    if total <= 0.0:
        return 0.0
    band = float(spectrum[(freqs >= 300.0) & (freqs <= 3400.0)].sum())
    return band / total


@dataclass
class Utterance:
    """One candidate sample, assembled block by block on the writer thread."""

    started_at: datetime
    blocks: list[np.ndarray] = field(default_factory=list)
    voiced_blocks: int = 0
    total_blocks: int = 0
    threshold: float = 0.0

    def audio(self) -> np.ndarray:
        return (
            np.concatenate(self.blocks) if self.blocks else np.zeros(0, dtype=np.float32)
        )

    @property
    def seconds(self) -> float:
        return sum(len(b) for b in self.blocks) / SAMPLE_RATE

    @property
    def voiced_ratio(self) -> float:
        return self.voiced_blocks / self.total_blocks if self.total_blocks else 0.0


@dataclass(frozen=True)
class Decision:
    """Why a finished utterance was kept or dropped — written into the manifest.

    Dropped samples are counted and their reasons logged rather than thrown away
    silently, because the filter is the part of this most likely to be wrong: a
    day that collects nothing and a day with nobody in the room look identical
    from the outside unless the rejections are visible.
    """

    keep: bool
    reason: str


class UtteranceRecorder:
    """Segments one channel into utterance WAVs. Fed from the audio callback.

    `scorer` is an optional `speaker_id.SpeakerScorer`. When present, an
    utterance the voiceprint positively attributes to the audience is dropped
    and everything else — Victor, and the deliberate "not saying" middle band —
    is kept with the verdict recorded. When absent, everything that passes the
    acoustic filters is kept and the log says so once, loudly: a silently
    disabled speaker filter is how a room ends up in a training set.
    """

    def __init__(
        self,
        root: Path,
        label: str,
        window: Window,
        scorer=None,
        log=None,
        me_speaker: str = "Victor",
        audience_speaker: str = "Audience",
        clock=datetime.now,
    ):
        self._root = Path(root)
        self._label = label
        self._window = window
        self._scorer = scorer
        self._log = log
        self._me = me_speaker
        self._audience = audience_speaker
        self._clock = clock

        self._q: queue.Queue = queue.Queue(maxsize=QUEUE_BLOCKS)
        self._running = True
        self._dropped_blocks = 0
        self._current: Utterance | None = None
        self._silent_blocks = 0
        self._preroll: list[np.ndarray] = []
        self._device = ""

        # Counters the menu bar and the log read; the app only ever asks for
        # totals, so a plain int under the GIL is enough and a lock is not.
        self.kept = 0
        self.dropped = 0
        self.bytes_written = 0
        self.last_reason = ""
        self._budget_ok = True
        self._budget_checked = 0.0
        self._last_window_state: bool | None = None

        self._root.mkdir(parents=True, exist_ok=True)
        self._manifest = self._root / "mic-corpus.jsonl"
        threading.Thread(
            target=self._supervised_writer, daemon=True, name=f"corpus-{label}"
        ).start()

    # ── audio thread ─────────────────────────────────────────────────────────
    def write(self, block: np.ndarray, threshold: float, device: str = "") -> None:
        """Called from PortAudio's realtime callback. Must not block, must not raise.

        The bare `except BaseException` is the contract, not sloppiness: whatever
        goes wrong in here, the one unacceptable outcome is an exception escaping
        into the audio thread and killing live transcription for the sake of a
        corpus.
        """
        try:
            self._q.put_nowait((block.copy(), threshold, device))
        except queue.Full:
            self._dropped_blocks += 1
            if self._dropped_blocks % 100 == 1:
                self._say(
                    "error",
                    f"🎓 corpus [{self._label}] behind — dropped {self._dropped_blocks} blocks",
                )
        except BaseException as exc:  # noqa: BLE001 — deliberately everything
            self._dropped_blocks += 1
            if self._dropped_blocks % 100 == 1:
                self._say("error", f"🎓 corpus write failed: {exc!r}")

    def stop(self) -> None:
        self._running = False
        # A sample in progress when whisper is stopped is still a sample: flush
        # it rather than lose it. `stop()` runs on a normal thread, so the disk
        # I/O here is allowed.
        try:
            self._close_utterance()
        except Exception:
            pass

    # ── writer thread ────────────────────────────────────────────────────────
    def _supervised_writer(self):
        while self._running:
            try:
                self._writer_loop()
                return
            except BaseException as exc:  # noqa: BLE001
                self._say("error", f"🎓 corpus recorder crashed, restarting: {exc!r}")
                time.sleep(2)

    def _writer_loop(self):
        blocksize = int(SAMPLE_RATE * 0.1)
        preroll_blocks = max(1, int(PREROLL_SEC * SAMPLE_RATE / blocksize))
        hang_blocks = max(1, int(HANG_SEC * SAMPLE_RATE / blocksize))
        max_samples = int(MAX_SEC * SAMPLE_RATE)

        while self._running:
            try:
                block, threshold, device = self._q.get(timeout=1)
            except queue.Empty:
                # A pause long enough to empty the queue is also a pause long
                # enough to end an utterance — otherwise the last sentence of the
                # day sits in memory until whisper restarts.
                if self._current is not None:
                    self._close_utterance()
                continue

            if device:
                self._device = device
            now = self._clock()
            if not self._window.contains(now):
                self._note_window(False, now)
                if self._current is not None:
                    self._close_utterance()
                self._preroll.clear()
                continue
            self._note_window(True, now)
            if not self._within_budget():
                continue

            rms = float(np.sqrt(np.mean(block**2)))
            voiced = rms >= threshold

            if self._current is None:
                if voiced:
                    self._current = Utterance(started_at=now, threshold=threshold)
                    # The pre-roll is audio that was *below* the gate, so it is
                    # counted in `total_blocks` — it is part of the sample and
                    # the voiced ratio must not be flattered by hiding it.
                    for pre in self._preroll:
                        self._current.blocks.append(pre)
                        self._current.total_blocks += 1
                    self._preroll.clear()
                    self._silent_blocks = 0
                else:
                    self._preroll.append(block)
                    if len(self._preroll) > preroll_blocks:
                        self._preroll.pop(0)
                    continue

            u = self._current
            u.blocks.append(block)
            u.total_blocks += 1
            if voiced:
                u.voiced_blocks += 1
                self._silent_blocks = 0
            else:
                self._silent_blocks += 1

            if self._silent_blocks >= hang_blocks:
                self._close_utterance()
            elif sum(len(b) for b in u.blocks) >= max_samples:
                # A forced cut lands mid-word by definition. Keep it: whisper and
                # Wispr both handle a clipped edge far better than the corpus
                # handles a missing half-minute, and the teacher transcribes the
                # same clipped audio the student will see.
                self._close_utterance(forced=True)

    def _note_window(self, inside: bool, now: datetime) -> None:
        """Say it once per transition, not once per block."""
        if inside == self._last_window_state:
            return
        self._last_window_state = inside
        if self._window.always:
            return
        self._say(
            "info",
            f"🎓 corpus [{self._label}] {'collecting' if inside else 'outside the work window'}"
            f" ({now:%a %H:%M})",
        )

    def _within_budget(self) -> bool:
        """Checked every few minutes, not once a block.

        `disk_usage` is a syscall and the corpus walk behind it touches every WAV
        ever collected; at 100 ms blocks this question arrives 36,000 times an
        hour and the answer changes about twice a day.
        """
        now = time.monotonic()
        if now - self._budget_checked < 300:
            return self._budget_ok
        self._budget_checked = now
        was_ok = self._budget_ok
        try:
            free_gb = shutil.disk_usage(self._root).free / 1e9
            used_gb = _tree_bytes(self._root) / 1e9
            self._budget_ok = free_gb >= MIN_FREE_GB and used_gb <= MAX_CORPUS_GB
            if was_ok and not self._budget_ok:
                self._say(
                    "error",
                    f"🎓 corpus paused — {used_gb:.1f} GB collected, {free_gb:.1f} GB free "
                    f"(limits {MAX_CORPUS_GB:.0f} / {MIN_FREE_GB:.0f} GB). "
                    f"Point VOICE_CORPUS_DIR at another disk to resume.",
                )
            elif not was_ok and self._budget_ok:
                self._say("info", "🎓 corpus resumed — space is back")
        except Exception as exc:  # noqa: BLE001
            # Not knowing the free space is not a reason to stop collecting.
            self._say("error", f"🎓 corpus budget check failed: {exc}")
            self._budget_ok = True
        return self._budget_ok

    # ── judging and writing one sample ───────────────────────────────────────
    def _close_utterance(self, forced: bool = False) -> None:
        u, self._current = self._current, None
        self._silent_blocks = 0
        if u is None:
            return
        audio = u.audio()
        # The trailing silence that ended the utterance is not part of it. Keep
        # one hang-time's worth of tail off the file: it costs disk, it dilutes
        # the voiced ratio of anything measured later, and a trailing second of
        # room tone is exactly the thing that makes a teacher ASR hallucinate a
        # final word.
        keep_tail = int(0.25 * SAMPLE_RATE)
        trim = max(0, int(self._silent_tail_samples(u)) - keep_tail)
        if trim:
            audio = audio[: len(audio) - trim]

        decision, verdict = self._judge(u, audio)
        if not decision.keep:
            self.dropped += 1
            self.last_reason = decision.reason
            return
        try:
            self._persist(u, audio, verdict, forced)
        except Exception as exc:  # noqa: BLE001
            self._say("error", f"🎓 corpus write failed: {exc}")

    @staticmethod
    def _silent_tail_samples(u: Utterance) -> int:
        # The hang counter is reset by `_close_utterance`, so recompute the tail
        # from the blocks themselves — they are the only thing that still knows.
        tail = 0
        for block in reversed(u.blocks):
            if float(np.sqrt(np.mean(block**2))) >= u.threshold:
                break
            tail += len(block)
        return tail

    def _judge(self, u: Utterance, audio: np.ndarray):
        seconds = len(audio) / SAMPLE_RATE
        if seconds < MIN_SEC:
            return Decision(False, f"short {seconds:.1f}s"), None
        if u.voiced_ratio < MIN_VOICED_RATIO:
            return Decision(False, f"voiced {u.voiced_ratio:.2f}"), None
        band = speech_band_ratio(audio)
        if band < MIN_SPEECH_BAND:
            return Decision(False, f"band {band:.2f}"), None

        verdict = None
        if self._scorer is not None:
            try:
                verdict = self._scorer.score(audio)
            except Exception as exc:  # noqa: BLE001
                self._say("error", f"🎓 corpus speaker scoring failed: {exc}")
        if verdict is not None and getattr(verdict, "label", None) == self._audience:
            # The only positive rejection. Everything else — Victor, and the
            # band where the voiceprint declines to say — is kept, with the
            # verdict in the manifest so a later pass can be stricter without
            # re-recording anything.
            return Decision(False, f"audience {verdict.score:.2f}"), verdict
        return Decision(True, "ok"), verdict

    def _persist(self, u: Utterance, audio: np.ndarray, verdict, forced: bool) -> None:
        day = u.started_at.strftime("%Y-%m-%d")
        stem = "%s-mic%03d" % (
            u.started_at.strftime("%H-%M-%S"),
            u.started_at.microsecond // 1000,
        )
        day_dir = self._root / day
        day_dir.mkdir(parents=True, exist_ok=True)
        wav_path = day_dir / f"{stem}.wav"
        # Two utterances can share a start stamp — a forced cut at the ceiling
        # hands the next one a start time in the same millisecond, and so does a
        # whisper restart that lands inside one. Overwriting would lose a sample
        # *and* leave the manifest claiming two rows for one file, so step the
        # name instead of clobbering.
        bump = 0
        while wav_path.exists():
            bump += 1
            stem = "%s-mic%03d+%d" % (
                u.started_at.strftime("%H-%M-%S"),
                u.started_at.microsecond // 1000,
                bump,
            )
            wav_path = day_dir / f"{stem}.wav"

        # Clip, do not wrap. PortAudio's float32 is not bounded to ±1.0 and
        # `.astype(np.int16)` wraps on overflow — 1.2 becomes −26216, a
        # polarity-flipped spike that is inaudible in the live path and corrupts
        # exactly the loud speech this corpus exists to collect.
        pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16)
        # Write beside the target and rename: a WAV only gets its frame count on
        # close, and this process is routinely killed outright (the quiet-crash
        # handlers call `_exit`, the watchdog force-restarts it). A half-written
        # file under a `.part` name is obvious rubbish; a half-written file under
        # the real name is a corpus sample that lies about its length.
        part = wav_path.with_suffix(".wav.part")
        with wave.open(str(part), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SAMPLE_RATE)
            w.writeframes(pcm.tobytes())
        os.replace(part, wav_path)

        entry = {
            "id": stem,
            "source": "addons-mic",
            "ts": u.started_at.astimezone().isoformat(timespec="seconds"),
            "wav": f"{day}/{stem}.wav",
            "seconds": round(len(audio) / SAMPLE_RATE, 3),
            "channel": self._label,
            "device": self._device,
            "rms_threshold": round(u.threshold, 5),
            "voiced_ratio": round(u.voiced_ratio, 3),
            "speech_band": round(speech_band_ratio(audio), 3),
            "forced_cut": forced,
            "speaker": getattr(verdict, "label", None) if verdict else None,
            "speaker_score": (
                round(float(verdict.score), 4)
                if verdict is not None and verdict.score == verdict.score  # not NaN
                else None
            ),
        }
        # Append-only and one JSON object per line, so the ingester on the other
        # side can read it while this side is still writing, and a `kill -9`
        # costs at most the last line rather than the manifest.
        with open(self._manifest, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")

        self.kept += 1
        self.bytes_written += wav_path.stat().st_size

    def _say(self, level: str, msg: str) -> None:
        if self._log is not None:
            getattr(self._log, level, self._log.info)("transcript", msg)
        else:
            print(f"[corpus] {msg}", flush=True)


def _tree_bytes(root: Path) -> int:
    total = 0
    for path in root.rglob("*.wav"):
        try:
            total += path.stat().st_size
        except OSError:
            pass
    return total
