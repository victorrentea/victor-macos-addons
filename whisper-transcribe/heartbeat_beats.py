"""Pre-analyze heartbeat.mp3 and write per-beat timestamps as JSON.

The Mac heartbeat zoom effect drives its scale-pulses from this JSON. Run once
when the audio file changes; commit the output.

Pipeline: ffmpeg decodes MP3 → mono float32 PCM on stdout → numpy RMS envelope
→ local-maxima peak picking → list of timestamps in seconds.

Usage:
    python3 heartbeat_beats.py

Inputs and outputs are pinned to repo paths so the script has no arguments.
"""

import json
import subprocess
import sys
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
AUDIO_PATH = Path.home() / "workspace/victor-android/app/src/main/assets/heartbeat.mp3"
OUTPUT_PATH = REPO_ROOT / "Sources/VictorAddons/Resources/heartbeat_beats.json"

SAMPLE_RATE = 22_050
FRAME_MS = 10
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000

# Peak picking
MIN_BEAT_GAP_S = 0.18
PEAK_REL_THRESHOLD = 0.35  # peak must be ≥ this fraction of the global RMS max
DROP_BEFORE_S = 0.20       # beats earlier than this collide with screencapture latency


def decode_mono_float32(path: Path, sample_rate: int) -> np.ndarray:
    cmd = [
        "ffmpeg", "-v", "error", "-i", str(path),
        "-f", "f32le", "-ac", "1", "-ar", str(sample_rate), "-",
    ]
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


def rms_envelope(samples: np.ndarray, frame: int) -> np.ndarray:
    n = (len(samples) // frame) * frame
    framed = samples[:n].reshape(-1, frame)
    return np.sqrt((framed ** 2).mean(axis=1))


def pick_peaks(envelope: np.ndarray, frame_seconds: float) -> list[float]:
    if envelope.size == 0:
        return []
    threshold = envelope.max() * PEAK_REL_THRESHOLD
    min_gap_frames = max(1, int(MIN_BEAT_GAP_S / frame_seconds))

    beats: list[float] = []
    last_peak_idx = -min_gap_frames - 1
    for i in range(1, len(envelope) - 1):
        if envelope[i] < threshold:
            continue
        if envelope[i] <= envelope[i - 1] or envelope[i] < envelope[i + 1]:
            continue
        if i - last_peak_idx < min_gap_frames:
            # Replace the previous peak if this one is louder
            if envelope[i] > envelope[last_peak_idx]:
                beats[-1] = i * frame_seconds
                last_peak_idx = i
            continue
        beats.append(i * frame_seconds)
        last_peak_idx = i

    return [round(t, 3) for t in beats if t >= DROP_BEFORE_S]


def main() -> int:
    if not AUDIO_PATH.exists():
        print(f"audio not found: {AUDIO_PATH}", file=sys.stderr)
        return 1

    samples = decode_mono_float32(AUDIO_PATH, SAMPLE_RATE)
    duration_s = len(samples) / SAMPLE_RATE
    envelope = rms_envelope(samples, FRAME_SAMPLES)
    beats = pick_peaks(envelope, FRAME_MS / 1000.0)

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(beats) + "\n")

    print(f"audio: {AUDIO_PATH.name}  duration: {duration_s:.2f}s")
    print(f"beats: {len(beats)} → {OUTPUT_PATH.relative_to(REPO_ROOT)}")
    print(f"timestamps: {beats}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
