#!/usr/bin/env python3
"""Build Victor's voiceprint from a folder of enrolment WAVs.

    python3 enroll_voiceprint.py \
        --wavs ~/.cache/victor-speaker-corpus/enroll_victor \
        --out  ~/workspace/victor-macos-addons/addons-output \
        --victor-at 0.60 --audience-below 0.35

Run once, then again whenever the microphone changes enough to matter — a
voiceprint is a measurement of a signal path as much as of a voice.

**The thresholds are not guessed here.** They come from calibrating against a
held-out set recorded *months* after the enrolment audio, because that is the
condition this actually runs in. This script refuses to invent them.

The result never goes in the repo: `victor-macos-addons` is public, and a
speaker-verification template is exactly the artefact that defeats speaker
verification. `--out` is the gitignored transcript folder.
"""
from __future__ import annotations

import argparse
import sys
import wave
from datetime import date
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from speaker_id import MIN_SECONDS, SAMPLE_RATE, Thresholds, Voiceprint, cosine, enroll


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        if w.getnchannels() != 1 or w.getframerate() != SAMPLE_RATE:
            raise ValueError(
                f"{path.name}: expected mono {SAMPLE_RATE} Hz, "
                f"got {w.getnchannels()}ch {w.getframerate()} Hz"
            )
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--wavs", type=Path, required=True, help="folder of enrolment WAVs")
    ap.add_argument("--out", type=Path, required=True, help="where voiceprint.npz goes")
    ap.add_argument("--model", type=Path,
                    default=Path(__file__).resolve().parent / "models" / "wespeaker_resnet34_LM.onnx")
    ap.add_argument("--victor-at", type=float, required=True,
                    help="cosine at or above which a segment is Victor (calibrated, not guessed)")
    ap.add_argument("--audience-below", type=float, required=True,
                    help="cosine at or below which a segment is somebody else")
    ap.add_argument("--trim-percentile", type=float, default=10.0,
                    help="drop this %% of enrolment segments furthest from the centroid")
    ap.add_argument("--label", default="unknown", help="what this was enrolled from")
    args = ap.parse_args()

    from speaker_id import SpeakerScorer

    # `model_ready`, not `available`: on a first run there is no voiceprint to
    # load — that is what this script is here to write.
    scorer = SpeakerScorer(args.model, args.out)
    if not scorer.model_ready:
        print(f"cannot load model: {scorer.error}", file=sys.stderr)
        return 1

    wavs = sorted(args.wavs.glob("*.wav"))
    if not wavs:
        print(f"no WAVs in {args.wavs}", file=sys.stderr)
        return 1

    embeddings, used, skipped = [], [], 0
    for w in wavs:
        try:
            audio = read_wav(w)
        except ValueError as exc:
            print(f"  skip {exc}", file=sys.stderr)
            skipped += 1
            continue
        seconds = len(audio) / SAMPLE_RATE
        if seconds < MIN_SECONDS:
            # Enrolling from audio too short to ever be *scored* would shape the
            # voiceprint with samples the live system will always refuse.
            skipped += 1
            continue
        embeddings.append(scorer.embed(audio))
        used.append((w.name, seconds))

    if not embeddings:
        print("nothing usable to enrol from", file=sys.stderr)
        return 1

    stacked = np.vstack(embeddings)
    centroid = enroll(stacked, trim_percentile=args.trim_percentile)

    # Report the spread, because a voiceprint averaged over a contaminated set
    # looks exactly like a good one until it is used. A low 5th percentile means
    # some of those segments were not this speaker.
    sims = np.array([cosine(e, centroid) for e in stacked])
    total_min = sum(s for _, s in used) / 60

    vp = Voiceprint(
        embedding=centroid,
        thresholds=Thresholds(victor_at=args.victor_at, audience_below=args.audience_below),
        meta={
            "enrolled_from": args.label,
            "segments": len(used),
            "minutes": round(total_min, 1),
            "date": date.today().isoformat(),
            "model": args.model.name,
            "trim_percentile": args.trim_percentile,
            "self_similarity_p5": round(float(np.percentile(sims, 5)), 4),
            "self_similarity_median": round(float(np.median(sims)), 4),
        },
    )
    path = vp.save(args.out)

    print(f"enrolled {len(used)} segments ({total_min:.1f} min), skipped {skipped}")
    print(f"  self-similarity  median {np.median(sims):.3f}  "
          f"p5 {np.percentile(sims, 5):.3f}  min {sims.min():.3f}")
    print(f"  thresholds  victor >= {args.victor_at:.3f}  "
          f"audience <= {args.audience_below:.3f}")
    print(f"  wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
