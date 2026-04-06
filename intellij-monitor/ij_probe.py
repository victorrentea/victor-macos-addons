"""
IntelliJ activity probe.

Polls IntelliJ via osascript every 10 seconds and writes an activity-git
file recording which project/branch/file is open when IntelliJ is frontmost.
"""

from __future__ import annotations

import glob
import os
import subprocess
import threading
import time
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

# ---------------------------------------------------------------------------
# AppleScript to query IntelliJ frontmost status and window title
# ---------------------------------------------------------------------------

_IJ_APPLESCRIPT = (
    'tell application "System Events" to tell process "idea" to '
    'return (frontmost as string) & tab & (title of front window)'
)


# ---------------------------------------------------------------------------
# Project path lookup
# ---------------------------------------------------------------------------

def _lookup_project_path(project_name: str) -> str | None:
    """Find project path in recentProjects.xml by folder name match."""
    pattern = os.path.expanduser(
        "~/Library/Application Support/JetBrains/IntelliJIdea*/options/recentProjects.xml"
    )
    candidates = sorted(glob.glob(pattern), reverse=True)

    for xml_path in candidates:
        try:
            tree = ET.parse(xml_path)
            best_ts = -1
            best_path = None
            for entry in tree.findall(".//entry"):
                key = entry.get("key", "")
                folder_name = Path(key.replace("$USER_HOME$", str(Path.home()))).name
                if folder_name.lower() != project_name.lower():
                    continue
                meta = entry.find(".//RecentProjectMetaInfo")
                if meta is None:
                    continue
                ts_elem = meta.find('option[@name="activationTimestamp"]')
                ts = int(ts_elem.get("value", 0)) if ts_elem is not None else 0
                if ts > best_ts:
                    best_ts = ts
                    best_path = key.replace("$USER_HOME$", str(Path.home()))
            if best_path:
                return best_path
        except Exception:
            continue
    return None


def get_last_used_intellij_project() -> dict | None:
    """Return {url, branch, project, path} for the most recently used IntelliJ project."""
    pattern = os.path.expanduser(
        "~/Library/Application Support/JetBrains/IntelliJIdea*/options/recentProjects.xml"
    )
    candidates = sorted(glob.glob(pattern), reverse=True)

    best_ts = -1
    best_path = None
    for xml_path in candidates:
        try:
            tree = ET.parse(xml_path)
            for entry in tree.findall(".//entry"):
                key = entry.get("key", "")
                if not key:
                    continue
                meta = entry.find(".//RecentProjectMetaInfo")
                if meta is None:
                    continue
                ts_elem = meta.find('option[@name="activationTimestamp"]')
                ts = int(ts_elem.get("value", 0)) if ts_elem is not None else 0
                if ts > best_ts:
                    best_ts = ts
                    best_path = key.replace("$USER_HOME$", str(Path.home()))
        except Exception:
            continue

    if not best_path:
        return None

    project_name = Path(best_path).name

    def _git(cmd):
        try:
            r = subprocess.run(
                ["git", "-C", best_path] + cmd,
                capture_output=True, text=True, timeout=2, check=False,
            )
            return r.stdout.strip() if r.returncode == 0 else ""
        except Exception:
            return ""

    remote_url = _git(["remote", "get-url", "origin"])
    branch = _git(["branch", "--show-current"])

    return {
        "project": project_name,
        "path": best_path,
        "url": remote_url,
        "branch": branch or "unknown",
    }


# ---------------------------------------------------------------------------
# Probe function
# ---------------------------------------------------------------------------

def probe_intellij(timeout: float = 2.0) -> dict | None:
    """Return {url, branch, file, frontmost, project, path} or None."""
    # Step 1: Get window title + frontmost
    try:
        result = subprocess.run(
            ["osascript", "-e", _IJ_APPLESCRIPT],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
        if result.returncode != 0 or not result.stdout.strip():
            return None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None

    parts = result.stdout.strip().split("\t", 1)
    is_frontmost = parts[0].strip() == "true"
    title = parts[1].strip() if len(parts) > 1 else ""
    if not title:
        return None

    # Step 2: Parse title
    # "kafka – WordsTopology.java [kafka-streams]" -> project="kafka", file="WordsTopology.java"
    # "kafka – pom.xml" -> project="kafka", file="pom.xml"
    # "kafka" -> project="kafka", file=""
    project_name = title.split("\u2009\u2013\u2009")[0].split(" \u2013 ")[0].split("[")[0].strip()
    filename = ""
    if " \u2013 " in title:
        after_dash = title.split(" \u2013 ", 1)[1]
        # Remove module bracket suffix: "File.java [module]" -> "File.java"
        filename = after_dash.split(" [")[0].strip()

    if not project_name:
        return None

    # Step 3: Find project path from recentProjects.xml
    project_path = _lookup_project_path(project_name)
    if not project_path:
        return None

    # Step 4: Get git info
    def _git(cmd):
        try:
            r = subprocess.run(
                ["git", "-C", project_path] + cmd,
                capture_output=True, text=True, timeout=2, check=False,
            )
            return r.stdout.strip() if r.returncode == 0 else ""
        except Exception:
            return ""

    remote_url = _git(["remote", "get-url", "origin"])
    branch = _git(["branch", "--show-current"])

    return {
        "project": project_name,
        "path": project_path,
        "url": remote_url,
        "branch": branch or "unknown",
        "file": filename,
        "frontmost": is_frontmost,
    }


# ---------------------------------------------------------------------------
# Monitor class
# ---------------------------------------------------------------------------

class IntelliJMonitor:
    """Polls IntelliJ every 10s, writes activity-git file when frontmost."""

    def __init__(self, output_dir: Path):
        self.output_dir = output_dir
        self._running = False
        self._thread: threading.Thread | None = None
        self._last_line: str | None = None  # avoid writing duplicate consecutive lines

    def start(self):
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._running = False

    def _loop(self):
        while self._running:
            try:
                self._tick()
            except Exception as e:
                print(f"[ij-monitor] error: {e}")
            time.sleep(10)

    def _tick(self):
        state = probe_intellij()
        if state is None or not state.get("frontmost"):
            return  # only track when IntelliJ is frontmost

        url = state.get("url", "")
        branch = state.get("branch", "")
        filename = state.get("file", "")

        if not url:
            return

        # Build line
        now = datetime.now()
        content = f"{url} branch:{branch}"
        if filename:
            content += f" file:{filename}"

        # Skip if same repo/branch/file as last written line
        if content == self._last_line:
            return
        self._last_line = content
        line = f"{now.strftime('%H:%M:%S')} {content}"

        # Append to daily file
        filepath = self.output_dir / f"activity-git-{now.strftime('%Y-%m-%d')}.md"
        self.output_dir.mkdir(parents=True, exist_ok=True)
        with filepath.open("a", encoding="utf-8") as f:
            f.write(line + "\n")


# ---------------------------------------------------------------------------
# CLI entry point (for standalone testing)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    result = probe_intellij()
    if result:
        print(f"Project:   {result['project']}")
        print(f"Path:      {result['path']}")
        print(f"URL:       {result['url']}")
        print(f"Branch:    {result['branch']}")
        print(f"File:      {result['file']}")
        print(f"Frontmost: {result['frontmost']}")
    else:
        print("IntelliJ not running or no window found.")
