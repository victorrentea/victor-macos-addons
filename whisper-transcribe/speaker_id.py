"""Is this segment Victor, somebody else, or too close to call?

**Target-speaker verification with one enrolled speaker — not diarization.**
Diarization asks "how many voices are there and who spoke when", needs
clustering and global state, and can relabel the past when the clusters move.
The question here is narrower and far cheaper: a single enrolled voiceprint, one
cosine per segment, no state, no retroactive edits.

The three-way answer is the whole point, and it comes from a scar. Until
2026-08-14 the transcript carried `Victor 🎙️:` / `Audience:` prefixes derived
from *which input device was louder*, and they were wrong often enough that they
were removed: a label that is wrong half the time is worse than no label,
because every downstream reader — the summarizer, the ⌘⌃V picker, Victor
re-reading his own day — then attributes words to the wrong mouth. So this
abstains. Between the two thresholds it says nothing, and saying nothing is a
correct answer, not a failure.

Nothing here imports torch. The process this runs in holds mlx-whisper on the
GPU at ~1.8 GB and is restarted several times a day; torch would add hundreds of
megabytes and seconds of import time to buy a feature extractor that numpy can
do. See `kaldi_fbank.py`.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000

VICTOR = "Victor"
AUDIENCE = "Audience"

# Two floors, because "too short to trust" and "too short to bother" are
# different lengths.
#
# `MIN_SECONDS` is where a label stops being honest. Measured on Victor's own
# corpus, EER is 1.03 % on 5-10 s segments and 3.6-4.8 % below 5 s, and the
# calibrated band already abstains on 49-74 % of everything under 5 s — so a
# short segment mostly gets refused anyway, and refusing it up front is both
# cheaper and clearer in the log than refusing it after the fact.
MIN_SECONDS = float(os.environ.get("WHISPER_SPEAKER_MIN_SECONDS", "3.0"))

# `EMBED_FLOOR` is where the *measurement* stops being worth taking at all.
# Between the two we still embed and still record the score, because the band
# can only ever be retuned from numbers we kept — the dark launch is collecting
# exactly this population. Below the floor there is nothing to learn.
EMBED_FLOOR = float(os.environ.get("WHISPER_SPEAKER_EMBED_FLOOR", "1.5"))


@dataclass(frozen=True)
class Verdict:
    """`label is None` means "not saying" — the deliberate third answer."""

    label: str | None
    score: float
    reason: str


@dataclass(frozen=True)
class Thresholds:
    """Two numbers, not one.

    A single threshold forces a guess on every segment; two carve out a band in
    the middle where the honest answer is silence. They are calibrated against a
    held-out set recorded *months* after enrolment, because that is the
    condition the live system actually runs in — a voiceprint enrolled once and
    used for years — and not the same-session number, which flatters.
    """

    victor_at: float
    audience_below: float

    def __post_init__(self):
        if not (-1.0 <= self.audience_below <= self.victor_at <= 1.0):
            raise ValueError(
                f"thresholds must satisfy -1 <= audience_below ({self.audience_below})"
                f" <= victor_at ({self.victor_at}) <= 1"
            )


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    """Cosine similarity, or NaN when there is nothing to compare.

    A zero-norm embedding means the model returned nothing usable. The tempting
    shortcut is to call that 0.0 — but 0.0 is a perfectly ordinary *low* score,
    and a low score means `Audience`. That would turn "the measurement failed"
    into a confident claim that somebody else was speaking, which is the exact
    class of error this whole design exists to avoid. NaN is not a score; it
    cannot be mistaken for one, and `decide` abstains on it.
    """
    na, nb = float(np.linalg.norm(a)), float(np.linalg.norm(b))
    if na == 0.0 or nb == 0.0:
        return float("nan")
    return float(np.dot(a, b) / (na * nb))


def decide(score: float, seconds: float, thresholds: Thresholds) -> Verdict:
    """Pure, and deliberately so — this is the rule the whole feature rests on.

    Order matters: the duration gate comes first, because a confident-looking
    score on 0.4 s of audio is exactly the kind of number that is confidently
    wrong.
    """
    if seconds < MIN_SECONDS:
        # Duration first, and the order is load-bearing: a segment below the
        # floor is never scored, so it arrives carrying NaN. Checking finiteness
        # first labelled every routine interjection "no usable embedding" — the
        # exact phrase the startup probe uses for a model returning all-NaN,
        # which would have buried the one signal that means the model is dead.
        return Verdict(None, score, f"only {seconds:.1f}s (< {MIN_SECONDS}s)")
    if not np.isfinite(score):
        # Long enough to score, and the score came back unusable. This cannot be
        # left to fall through: NaN compares False against everything, so it
        # would reach the final branch and be reported as "in abstain band" —
        # the right answer for the wrong reason.
        return Verdict(None, score, "no usable embedding")
    if score >= thresholds.victor_at:
        return Verdict(VICTOR, score, f"{score:.3f} >= {thresholds.victor_at:.3f}")
    if score <= thresholds.audience_below:
        return Verdict(AUDIENCE, score, f"{score:.3f} <= {thresholds.audience_below:.3f}")
    return Verdict(
        None,
        score,
        f"{score:.3f} in abstain band "
        f"({thresholds.audience_below:.3f}..{thresholds.victor_at:.3f})",
    )


@dataclass(frozen=True)
class Voiceprint:
    """An enrolled speaker: one vector, its thresholds, and its provenance.

    The provenance is not decoration. A voiceprint is a measurement of a
    microphone as much as of a voice, so when this starts misfiring the first
    question is always "what was it enrolled from, and when" — and that has to
    be answerable from the file itself, months later, without finding the script
    that made it.

    **It never goes in the repo.** `victor-macos-addons` is public, and a
    speaker-verification template is precisely the artefact that defeats
    speaker verification. It lives beside the transcripts, in the gitignored
    output folder.
    """

    embedding: np.ndarray
    thresholds: Thresholds
    meta: dict

    @staticmethod
    def path(folder: Path) -> Path:
        return folder / "voiceprint.npz"

    @classmethod
    def load(cls, folder: Path) -> "Voiceprint":
        p = cls.path(folder)
        with np.load(p, allow_pickle=False) as z:
            emb = z["embedding"].astype(np.float32)
            meta = json.loads(str(z["meta"]))
        return cls(
            embedding=emb,
            thresholds=Thresholds(
                victor_at=float(meta["victor_at"]),
                audience_below=float(meta["audience_below"]),
            ),
            meta=meta,
        )

    def save(self, folder: Path) -> Path:
        folder.mkdir(parents=True, exist_ok=True)
        meta = dict(self.meta)
        meta["victor_at"] = self.thresholds.victor_at
        meta["audience_below"] = self.thresholds.audience_below
        p = self.path(folder)
        np.savez(p, embedding=self.embedding.astype(np.float32), meta=json.dumps(meta))
        return p


class SpeakerScorer:
    """The live facade: audio in, `Verdict` out — or `None`, always safely.

    Every way this can fail returns `None` and disables itself. It is an
    observer bolted onto a pipeline whose actual job is transcription, and it
    runs during live workshops; a missing model file, a corrupt voiceprint or an
    ONNX version that no longer loads must cost a log line, never a word of
    transcript. `available` says whether it is doing anything at all, because
    "silently scoring nothing" and "scoring and abstaining" look identical from
    the outside and are very different problems.
    """

    def __init__(self, model_path: Path, voiceprint_folder: Path):
        self._session = None
        self._input_name = None
        self._fbank = None
        self.voiceprint: Voiceprint | None = None
        self.error: str | None = None
        # Set when a per-call failure disabled us, to tell "never started" apart
        # from "started and then died".
        self.failed = False
        # The model loads FIRST and the voiceprint separately, because enrolment
        # needs the model in order to *create* the voiceprint. Loading them
        # together made the first run impossible: no voiceprint yet, so the
        # whole constructor aborted, so there was no embedder to enrol with.
        try:
            import onnxruntime as ort  # noqa: PLC0415 — deliberately lazy

            from kaldi_fbank import fbank_cmn

            opts = ort.SessionOptions()
            # Pinned: onnxruntime's default (one thread per core) measured both
            # slower and much noisier at p90 than 4, and this shares a machine
            # with whisper on the GPU and a room full of other work.
            opts.intra_op_num_threads = int(
                os.environ.get("WHISPER_SPEAKER_THREADS", "4")
            )
            opts.inter_op_num_threads = 1
            self._session = ort.InferenceSession(
                str(model_path),
                opts,
                # CoreML's fast path is the GPU, which is exactly the resource
                # whisper is using; measured under contention the GPU path lost
                # 79 % and the CPU/ANE path 7.6 %. So: not the GPU.
                providers=["CoreMLExecutionProvider", "CPUExecutionProvider"],
                provider_options=[{"MLComputeUnits": "CPUAndNeuralEngine"}, {}],
            )
            self._input_name = self._session.get_inputs()[0].name
            self._fbank = fbank_cmn

            # Prove the graph actually computes before trusting it. This is not
            # paranoia: onnxruntime's CoreML EP with `ModelFormat=MLProgram`
            # returns **all-NaN** for this model — no exception, no warning,
            # correct output shape, every element NaN. We do not ask for that
            # format, but the default is the sort of thing a version bump
            # changes, and the failure is invisible: every segment would score
            # NaN, every verdict would abstain, and the feature would look like
            # a quiet room rather than a broken model. One 2 s embedding at
            # startup costs ~40 ms and turns that into a log line.
            probe = self.embed(np.zeros(int(SAMPLE_RATE * 2), dtype=np.float32))
            if not np.isfinite(probe).all():
                raise RuntimeError(
                    "embedding model returned non-finite values on a silent probe "
                    "(a CoreML ModelFormat/EP mismatch does exactly this)"
                )
        except Exception as exc:  # noqa: BLE001 — any failure disables, none propagates
            self.error = f"model: {type(exc).__name__}: {exc}"
            self._session = None
            return

        try:
            self.voiceprint = Voiceprint.load(voiceprint_folder)
        except Exception as exc:  # noqa: BLE001
            # Not fatal, and not always an error: on a first run there is
            # nothing to load yet, and `enroll_voiceprint.py` is about to write
            # the file this failed to find.
            self.error = f"voiceprint: {type(exc).__name__}: {exc}"

    @property
    def model_ready(self) -> bool:
        """Can embed, even with no voiceprint — what enrolment needs."""
        return self._session is not None

    @property
    def available(self) -> bool:
        """Can answer "is this Victor?" — what the live pipeline needs."""
        return self._session is not None and self.voiceprint is not None

    def embed(self, audio: np.ndarray) -> np.ndarray:
        feats = self._fbank(audio)[None, :, :].astype(np.float32)
        return np.asarray(self._session.run(None, {self._input_name: feats})[0][0])

    def score(self, audio: np.ndarray) -> Verdict | None:
        if not self.available:
            return None
        try:
            seconds = len(audio) / SAMPLE_RATE
            if seconds < EMBED_FLOOR:
                # Nothing to learn from audio this short, so do not pay for it.
                return decide(float("nan"), seconds, self.voiceprint.thresholds)
            sim = cosine(self.embed(audio), self.voiceprint.embedding)
            return decide(sim, seconds, self.voiceprint.thresholds)
        except Exception as exc:  # noqa: BLE001
            # Swallowing this silently made "scoring nothing" identical to "a
            # quiet room". A voiceprint enrolled with a different model, say,
            # loads fine and reports `available`, then raises on every single
            # call — and a whole day of dark-launch data is lost while the log
            # says the feature is on. So: say it once, then stop pretending.
            self.error = f"scoring: {type(exc).__name__}: {exc}"
            self.failed = True
            self.voiceprint = None  # `available` goes False; nothing retries
            return None


def enroll(embeddings: np.ndarray, trim_percentile: float = 10.0) -> np.ndarray:
    """Average many embeddings into one voiceprint, dropping the worst tail.

    Enrolment segments come from a real session, so some of them are not what
    they claim: a transcript boundary that clipped in a neighbour's word, a
    stretch where the mic was handed over, laughter. Those pull the centroid
    away from the voice, and the cost is paid on every future comparison, so it
    is worth one extra pass to drop them.

    The rule is deliberately blunt — average, measure each sample against that
    average, discard the lowest `trim_percentile` %, average what is left. It
    beats a median or a medoid here because the contamination is a small
    minority of clearly-wrong samples rather than a heavy tail.
    """
    if embeddings.ndim != 2 or len(embeddings) == 0:
        raise ValueError("enroll expects a non-empty [n, dim] array")

    unit = embeddings / np.maximum(
        np.linalg.norm(embeddings, axis=1, keepdims=True), 1e-12
    )
    centroid = unit.mean(axis=0)
    if len(unit) < 10 or trim_percentile <= 0:
        # Too few to spare any: trimming 10 % of 5 samples is noise, not cleaning.
        return centroid / max(float(np.linalg.norm(centroid)), 1e-12)

    sims = unit @ (centroid / max(float(np.linalg.norm(centroid)), 1e-12))
    keep = sims >= np.percentile(sims, trim_percentile)
    kept = unit[keep] if keep.any() else unit
    trimmed = kept.mean(axis=0)
    return trimmed / max(float(np.linalg.norm(trimmed)), 1e-12)
