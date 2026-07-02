#!/usr/bin/env python3
"""Download a YouTube video for offline fullscreen playback and register it.

Downloads to the gitignored `videos/<id>.mp4` (H.264/AAC MP4 so AVFoundation can
play it) and upserts `{id, title, startSeconds, file, url}` into
`videos/videos.json` — the manifest the Mac serves to the tablet at GET /videos.

Usage:
    python3 add_video.py --url "<youtube-url>" --start "<sec-or-timestamp>" [--title "..."]
"""
import argparse
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlparse, parse_qs

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# .claude/skills/add-training-video -> repo root is three levels up.
DEFAULT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))


def extract_id(url: str) -> str:
    """Pull the 11-char YouTube video id out of watch/shorts/youtu.be/embed URLs."""
    u = urlparse(url)
    host = (u.hostname or "").lower()
    if host == "youtu.be":
        return u.path.lstrip("/").split("/")[0]
    if "youtube.com" in host or "youtube-nocookie.com" in host:
        parts = [p for p in u.path.split("/") if p]
        if parts and parts[0] in ("shorts", "embed", "v", "live"):
            return parts[1] if len(parts) > 1 else ""
        q = parse_qs(u.query)
        if "v" in q:
            return q["v"][0]
    m = re.search(r"([0-9A-Za-z_-]{11})", url)
    return m.group(1) if m else ""


def parse_seconds(value) -> int:
    """Accept 145, '13s', '1:23' (m:s) or '1:02:03' (h:m:s) -> whole seconds."""
    if value is None:
        return 0
    s = str(value).strip().lower()
    if not s:
        return 0
    if s.endswith("s") and ":" not in s:
        s = s[:-1]
    if ":" in s:
        total = 0
        for part in s.split(":"):
            total = total * 60 + int(part or 0)
        return total
    try:
        return int(float(s))
    except ValueError:
        return 0


def download(url: str, out_base: str, force: bool) -> str:
    """Download to <out_base>.mp4 as H.264/AAC. Returns the final path."""
    final = out_base + ".mp4"
    if os.path.exists(final) and not force:
        print(f"[add_video] already downloaded: {final}", file=sys.stderr)
        return final
    fmt = "bv*[vcodec^=avc1]+ba[acodec^=mp4a]/b[vcodec^=avc1]/b[ext=mp4]/b"
    cmd = [
        "yt-dlp",
        "--no-playlist",
        "-f", fmt,
        "--merge-output-format", "mp4",
        "-o", out_base + ".%(ext)s",
        url,
    ]
    subprocess.run(cmd, check=True)
    if not os.path.exists(final):
        # A progressive stream may have landed with a non-mp4 ext; find it.
        base_dir = os.path.dirname(out_base)
        stem = os.path.basename(out_base)
        for name in os.listdir(base_dir):
            if name.startswith(stem + "."):
                got = os.path.join(base_dir, name)
                raise SystemExit(
                    f"[add_video] expected {final} but got {got}; "
                    "the chosen format was not mp4 (re-run with a different --format)"
                )
        raise SystemExit(f"[add_video] download produced no file for {url}")
    return final


def fetch_title(url: str) -> str:
    try:
        r = subprocess.run(
            ["yt-dlp", "--no-playlist", "--skip-download", "--print", "title", url],
            capture_output=True, text=True, check=True,
        )
        return r.stdout.strip()
    except Exception:
        return ""


def update_manifest(manifest_path: str, entry: dict) -> None:
    data = {"videos": []}
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            data = json.load(f)
    videos = [v for v in data.get("videos", []) if v.get("id") != entry["id"]]
    videos.append(entry)
    data["videos"] = videos
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main() -> int:
    ap = argparse.ArgumentParser(description="Add a training video (download + register).")
    ap.add_argument("--url", required=True)
    ap.add_argument("--start", default="0", help="start second: 145, 13s, 1:23, 1:02:03")
    ap.add_argument("--title", default=None)
    ap.add_argument("--id", default=None, help="override the YouTube id (rarely needed)")
    ap.add_argument("--root", default=None, help="repo root (defaults to this repo)")
    ap.add_argument("--force", action="store_true", help="re-download even if the file exists")
    args = ap.parse_args()

    root = args.root or os.environ.get("VICTOR_ADDONS_ROOT") or DEFAULT_ROOT
    videos_dir = os.path.join(root, "videos")
    os.makedirs(videos_dir, exist_ok=True)
    manifest_path = os.path.join(videos_dir, "videos.json")

    vid = args.id or extract_id(args.url)
    if not vid:
        print(f"[add_video] could not extract a YouTube id from: {args.url}", file=sys.stderr)
        return 2
    seconds = parse_seconds(args.start)

    out_base = os.path.join(videos_dir, vid)
    final = download(args.url, out_base, args.force)
    title = args.title or fetch_title(args.url) or vid

    entry = {
        "id": vid,
        "title": title,
        "startSeconds": seconds,
        "file": os.path.basename(final),
        "url": args.url,
    }
    update_manifest(manifest_path, entry)

    print(json.dumps({"ok": True, **entry, "path": final}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
