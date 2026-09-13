#!/usr/bin/env python3
"""
cc-session-reap — archives the dead Claude Code sessions that pile up in the
session list on claude.ai/code and in the mobile app's Code tab.

WHY THIS EXISTS
    Every interactive `claude` in a terminal and every session created through
    Remote Control registers a row in that list, and the row stays there for ever.
    The bridge also keeps minting empty `localhost-*` sessions on its own, roughly
    one every 6-20 minutes, which are created and never used. Within days the list
    is unusable (and the web UI only renders the first 50 rows anyway).

    Anthropic has no filter for "disconnected" and no bulk archive:
      anthropics/claude-code#93870  (filter by connection state)
      anthropics/claude-code#93979  (multi-select + bulk archive)
    Until those land, this script is the cleanup.

NO BROWSER NEEDED
    The CLI itself talks to https://api.anthropic.com/v1/code/sessions with the
    OAuth token Claude Code keeps in the login keychain, so plain HTTPS works.
    (claude.ai is the one that needs a real Chrome: its cookies are device-bound
    and Cloudflare 403s curl. api.anthropic.com does not care.)

TOKEN
    Read-only from the keychain item "Claude Code-credentials". The access token
    lives ~1h and is refreshed by any running Claude Code — with claude-rc up
    permanently it is practically always fresh. We deliberately do NOT refresh it
    ourselves: the refresh token may be rotated server-side, and burning it would
    log Victor out of Claude Code. If the token is expired we skip this run and
    try again on the next tick.

POLICY (what gets archived)
    Never, under any circumstance:
      - anything whose connection_status is not exactly "disconnected"
      - anything whose id suffix matches a bridgeSessionId of a live local process
        (belt and braces on top of connection_status; note the API says cse_<suffix>
        while ~/.claude/sessions/<pid>.json says session_<suffix> — same id, and a
        literal comparison would silently match nothing)
    Otherwise archive a disconnected session when either:
      - it is noise: titled `localhost-*`/untitled, or never used at all
        (last_event_at within NEVER_USED_SECONDS of created_at), or
      - it is simply old: last_event_at older than AGE_DAYS (default 3).

USAGE
    cc-session-reap                 archive per the policy above
    cc-session-reap --dry-run       print what it would archive, touch nothing
    cc-session-reap --age-days 7    keep real conversations around for a week
    cc-session-reap --noise-only    only the localhost-*/never-used ones
"""

# /usr/bin/python3 is still 3.9 on this Mac and launchd resolves python3 there, so
# PEP 604 annotations (`dict | None`) must stay unevaluated — hence this import.
from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BASE = "https://api.anthropic.com"
KEYCHAIN_SERVICE = "Claude Code-credentials"
SESSIONS_DIR = Path.home() / ".claude" / "sessions"
LOG = Path.home() / ".cc-session-reap" / "reap.log"
LOG_MAX_BYTES = 2_000_000

AGE_DAYS_DEFAULT = 3
NEVER_USED_SECONDS = 120          # created and never touched again
STUCK_WORKER_HOURS = 6            # a "working" session this stale is a ghost
NOISE_NAME = re.compile(r"^(localhost[-.]|Victor[- ]Mac$|$)")


def log(msg: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    if LOG.exists() and LOG.stat().st_size > LOG_MAX_BYTES:
        LOG.rename(LOG.with_suffix(".log.1"))
    line = f"{datetime.now().strftime('%F %T')} {msg}"
    with LOG.open("a") as fh:
        fh.write(line + "\n")
    print(line, flush=True)


def access_token() -> str:
    """Read the OAuth token out of the keychain. Never writes it back."""
    raw = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True, text=True,
    )
    if raw.returncode != 0:
        raise SystemExit(f"keychain item {KEYCHAIN_SERVICE!r} not readable")
    oauth = json.loads(raw.stdout).get("claudeAiOauth") or {}
    token, expires_at = oauth.get("accessToken"), oauth.get("expiresAt")
    if not token:
        raise SystemExit("no accessToken in the keychain item")
    # 60s of slack so we never start a sweep with a token that dies mid-run
    if expires_at and expires_at / 1000 < time.time() + 60:
        log("token expired — skipping this run (any running Claude Code will refresh it)")
        sys.exit(0)
    return token


def api(token: str, path: str, method: str = "GET", body: dict | None = None):
    req = urllib.request.Request(
        BASE + path,
        method=method,
        data=json.dumps(body or {}).encode() if method == "POST" else None,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "anthropic-version": "2023-06-01",
            "anthropic-client-platform": "cli",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30, context=ssl.create_default_context()) as resp:
        payload = resp.read()
        return resp.status, (json.loads(payload) if payload else {})


def all_active_sessions(token: str) -> list[dict]:
    out, cursor, seen = [], None, set()
    while True:
        path = "/v1/code/sessions?limit=100&statuses=active"
        if cursor:
            path += "&cursor=" + urllib.parse.quote(cursor)
        _, page = api(token, path)
        batch = page.get("data") or []
        fresh = [s for s in batch if s.get("id") not in seen]
        out.extend(fresh)
        seen.update(s.get("id") for s in fresh)
        cursor = page.get("next_cursor")
        if not cursor or not fresh:
            return out


def live_local_suffixes() -> set[str]:
    """Bridge ids of claude processes alive on this Mac, compared by id suffix."""
    suffixes = set()
    for f in SESSIONS_DIR.glob("*.json"):
        try:
            pid = int(f.stem)
            os.kill(pid, 0)                      # raises unless the process exists
            bridge = json.loads(f.read_text()).get("bridgeSessionId")
            if bridge:
                suffixes.add(bridge.split("_", 1)[-1])
        except (ValueError, ProcessLookupError, OSError, json.JSONDecodeError):
            continue
    return suffixes


def ts(value: str | None) -> float:
    if not value:
        return 0.0
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def classify(s: dict, protected: set[str], age_days: int, noise_only: bool):
    """Return (archive?, reason). Reason is logged either way."""
    if s.get("connection_status") != "disconnected":
        return False, "connected"
    if s.get("id", "").split("_", 1)[-1] in protected:
        return False, "PROTECTED (live local process)"

    now = time.time()
    title = (s.get("title") or s.get("name") or "").strip()
    created, last = ts(s.get("created_at")), ts(s.get("last_event_at"))
    idle_h = (now - last) / 3600 if last else 1e9

    # a session the server still thinks is working is only reaped once clearly stale
    working = s.get("worker_status") == "running" or s.get("status_bucket") == "working"
    if working and idle_h < STUCK_WORKER_HOURS:
        return False, f"worker still working, idle {idle_h:.1f}h"

    if NOISE_NAME.match(title):
        return True, f"noise title {title!r}"
    if last and created and last - created < NEVER_USED_SECONDS:
        return True, "created and never used"
    if noise_only:
        return False, f"real conversation, idle {idle_h / 24:.1f}d (noise-only mode)"
    if idle_h > age_days * 24:
        return True, f"idle {idle_h / 24:.1f}d > {age_days}d"
    return False, f"real conversation, idle {idle_h / 24:.1f}d"


def main() -> int:
    ap = argparse.ArgumentParser(description="Archive dead Claude Code sessions.")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--age-days", type=int, default=AGE_DAYS_DEFAULT)
    ap.add_argument("--noise-only", action="store_true")
    ap.add_argument("--verbose", action="store_true", help="also log what is kept")
    args = ap.parse_args()

    token = access_token()
    sessions = all_active_sessions(token)
    protected = live_local_suffixes()

    doomed = []
    for s in sessions:
        archive, reason = classify(s, protected, args.age_days, args.noise_only)
        if archive:
            doomed.append((s, reason))
        elif args.verbose:
            log(f"  keep {s.get('id','?')[:16]} {reason}")

    log(f"{len(sessions)} active, {len(protected)} live locally, {len(doomed)} to archive"
        + (" (dry run)" if args.dry_run else ""))

    ok = failed = 0
    for s, reason in doomed:
        title = (s.get("title") or s.get("name") or "")[:48]
        if args.dry_run:
            log(f"  would archive {s['id'][:16]} {title!r} — {reason}")
            continue
        try:
            status, _ = api(token, f"/v1/code/sessions/{s['id']}/archive", "POST")
            ok += 1
            log(f"  archived {s['id'][:16]} {title!r} — {reason}")
        except urllib.error.HTTPError as e:
            failed += 1
            log(f"  FAILED {s['id'][:16]} {title!r} — HTTP {e.code} {e.read()[:200]!r}")
            if failed >= 3:
                log("  three consecutive failures — aborting")
                break
        time.sleep(0.25)

    if not args.dry_run:
        log(f"done: {ok} archived, {failed} failed, {len(sessions) - ok} left active")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
