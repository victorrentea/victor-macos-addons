# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""LGTM (rR4n-0KYeKQ): the burned-in "L G T M" column flies in from the centre.

In the downloaded clip the four orange letters slide in from the left edge,
one after another, at ~43.2 s — small, in the corner, easy to miss from the
back of a room. This re-renders that moment: the whole column appears in the
middle of the frame at FLY_SCALE× its size and travels to the exact spot where
the clip has it, shrinking on the way, and lands on the burned-in letters
pixel for pixel, after which the original frames simply carry on.

How, without the letters as a separate layer:
  * the camera is static there, so the frame just BEFORE the letters arrive is
    a clean plate of that corner — pasted over the corner during the flight,
    it hides the clip's own slide-in;
  * the sprite is the corner of a frame AFTER they settled, keyed against that
    clean plate (|settled − clean| ⇒ alpha), so it carries the clip's own
    orange and outline, not a font that only looks like it.

Reads videos/<id>.orig.mp4 (made from the current mp4 on the first run, so the
edit is never applied twice) and writes videos/<id>.mp4. Audio is copied.

    uv run tools/lgtm-flyin.py
"""
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

VID = "rR4n-0KYeKQ"
VIDEOS = Path(__file__).resolve().parent.parent / "videos"
SRC = VIDEOS / f"{VID}.orig.mp4"
DST = VIDEOS / f"{VID}.mp4"

W, H = 1920, 1080
FPS = 24000 / 1001
SCAN_FROM, SCAN_TO = 42.0, 46.0   # seconds: where the letters arrive
CORNER = (0, 0, 260, 560)         # x0, y0, x1, y1: where they end up (with margin)
FLY_SCALE = 3.0                   # how big they appear in the middle
FLY_SECONDS = 0.9                 # centre → corner


def orange_count(frame: np.ndarray) -> int:
    x0, y0, x1, y1 = CORNER
    c = frame[y0:y1, x0:x1].astype(int)
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    return int(((r > 200) & (g > 90) & (g < 190) & (b < 80)).sum())


def decode():
    p = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(SRC), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        stdout=subprocess.PIPE)
    size = W * H * 3
    while True:
        buf = p.stdout.read(size)
        if len(buf) < size:
            break
        yield np.frombuffer(buf, np.uint8).reshape(H, W, 3)
    p.wait()


def ease_out(p: float) -> float:
    return 1 - (1 - p) ** 3


def main():
    if not SRC.exists():
        shutil.copy2(DST, SRC)
        print(f"kept the download as {SRC.name}")

    # Pass 1: find the arrival (first frame with orange in the corner) and the
    # settle (first frame whose count matches the fully-landed count).
    counts, frames = [], {}
    a, b = int(SCAN_FROM * FPS), int(SCAN_TO * FPS)
    for i, f in enumerate(decode()):
        if i > b:
            break
        if i >= a:
            counts.append((i, orange_count(f)))
            frames[i] = f.copy()
    landed = counts[-1][1]
    t0 = next(i for i, c in counts if c > 30)
    settled = next(i for i, c in counts if c >= landed * 0.97)
    print(f"letters arrive at frame {t0} ({t0 / FPS:.2f}s), settled at {settled} ({settled / FPS:.2f}s)")

    clean = frames[t0 - 1]
    ref = frames[settled + 4]
    x0, y0, x1, y1 = CORNER
    diff = np.abs(ref[y0:y1, x0:x1].astype(int) - clean[y0:y1, x0:x1].astype(int)).sum(axis=2)
    mask = (diff > 60).astype(np.uint8) * 255
    ys, xs = np.nonzero(mask)
    bx0, by0, bx1, by1 = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
    print(f"letter box {bx0},{by0} → {bx1},{by1} ({bx1 - bx0}×{by1 - by0})")
    m = Image.fromarray(mask[by0:by1, bx0:bx1]).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
    sprite = Image.fromarray(ref[y0 + by0:y0 + by1, x0 + bx0:x0 + bx1]).convert("RGBA")
    sprite.putalpha(m)
    sw, sh = sprite.size
    # Final place of the sprite, in frame coordinates.
    fx, fy = x0 + bx0, y0 + by0
    # Never taller than the frame: at 3× a column that tall would lose its ends.
    scale0 = min(FLY_SCALE, H * 0.92 / sh)
    print(f"flying in at {scale0:.2f}×")

    n_fly = round(FLY_SECONDS * FPS)
    assert t0 + n_fly > settled, "the flight must end after the clip's own letters settled"
    patch = clean[y0:y1, x0:x1]

    enc = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", "24000/1001", "-i", "-",
         "-i", str(SRC), "-map", "0:v", "-map", "1:a", "-c:a", "copy",
         "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
         "-movflags", "+faststart", str(DST) + ".tmp.mp4"],
        stdin=subprocess.PIPE)
    for i, f in enumerate(decode()):
        if t0 <= i < t0 + n_fly:
            out = f.copy()
            out[y0:y1, x0:x1] = patch
            p = ease_out((i - t0 + 1) / n_fly)
            s = scale0 + (1 - scale0) * p
            w, h = round(sw * s), round(sh * s)
            cx = W / 2 + (fx + sw / 2 - W / 2) * p
            cy = H / 2 + (fy + sh / 2 - H / 2) * p
            img = Image.fromarray(out).convert("RGBA")
            img.alpha_composite(sprite.resize((w, h), Image.LANCZOS), (round(cx - w / 2), round(cy - h / 2)))
            f = np.asarray(img.convert("RGB"))
        enc.stdin.write(np.ascontiguousarray(f).tobytes())
    enc.stdin.close()
    if enc.wait() != 0:
        sys.exit("encode failed")
    Path(str(DST) + ".tmp.mp4").replace(DST)
    print(f"wrote {DST.name}")


if __name__ == "__main__":
    main()
