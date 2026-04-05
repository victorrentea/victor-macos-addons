"""Probes PowerPoint via osascript and writes an activity-slides file."""

import os
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

_PPT_NO_APP = "__NO_PPT__"
_PPT_NO_PRESENTATION = "__NO_PRESENTATION__"
_PPT_SLIDE_UNKNOWN = "__SLIDE_UNKNOWN__"

_PPT_APPLESCRIPT = """
if application "Microsoft PowerPoint" is not running then
    return "__NO_PPT__"
end if

tell application "Microsoft PowerPoint"
    if (count of presentations) is 0 then
        return "__NO_PRESENTATION__"
    end if

    set presentationName to name of active presentation
    set slideNumber to 1
    set isPresenting to "false"

    try
        if (count of slide show windows) > 0 then
            set isPresenting to "true"
            set slideNumber to current show position of slide show view of slide show window 1
        else
            try
                set slideNumber to slide index of slide of view of active window
            on error
                try
                    set slideNumber to slide index of slide of view of document window 1
                on error
                    set slideNumber to "__SLIDE_UNKNOWN__"
                end try
            end try
        end if
    on error
        set slideNumber to "__SLIDE_UNKNOWN__"
    end try

    set isFrontmost to "false"
    tell application "System Events"
        try
            set isFrontmost to (frontmost of application process "Microsoft PowerPoint") as string
        end try
    end tell

    return presentationName & tab & isPresenting & tab & (slideNumber as string) & tab & isFrontmost
end tell
""".strip()


def _format_duration(seconds: float) -> str:
    """Format seconds into human-readable duration: '3s', '15s', '1m5s', '2m30s'."""
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    m, s = divmod(s, 60)
    return f"{m}m{s}s" if s else f"{m}m"


def _coerce_slide_number(value) -> int:
    raw = str(value or "").strip()
    if not raw or raw.lower() == "missing value" or raw == _PPT_SLIDE_UNKNOWN:
        return 1
    try:
        return max(1, int(raw))
    except (TypeError, ValueError):
        return 1


def _parse_output(raw: str) -> dict | None:
    text = (raw or "").strip()
    if not text or text in {_PPT_NO_APP, _PPT_NO_PRESENTATION}:
        return None
    parts = text.split("\t")
    if len(parts) < 2:
        return None
    presentation = parts[0].strip()
    if not presentation:
        return None
    is_presenting = parts[1].strip() == "true" if len(parts) >= 3 else False
    slide_number = _coerce_slide_number(parts[2].strip()) if len(parts) >= 3 else _coerce_slide_number(parts[1].strip())
    return {"presentation": presentation, "slide": slide_number, "presenting": is_presenting}


def probe_powerpoint(timeout: float = 5.0) -> dict | None:
    """Run AppleScript to probe PowerPoint state. Returns None if PPT is not running."""
    try:
        result = subprocess.run(
            ["osascript", "-e", _PPT_APPLESCRIPT],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, Exception):
        return None
    if result.returncode != 0:
        return None
    return _parse_output(result.stdout)


class PowerPointMonitor:
    """Polls PowerPoint every 3s, writes activity-slides file."""

    def __init__(self, output_dir: Path, slide_callback=None):
        self.output_dir = output_dir
        self._slide_callback = slide_callback
        self._running = False
        self._thread = None
        # In-memory state
        self._current_deck: str | None = None
        self._current_slide: int = 1
        self._current_presenting: bool = False
        self._slide_durations: dict[int, float] = {}  # slide_num -> seconds (insertion-ordered)
        self._last_probe_time: float = 0
        self._line_start_time: str = ""  # HH:MM:SS when this deck line started

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
                print(f"[ppt-monitor] error: {e}")
            time.sleep(3)

    def _tick(self):
        state = probe_powerpoint()
        now = time.time()

        if state is None:
            # PowerPoint not running — leave file unchanged, stop accumulating time
            self._last_probe_time = 0
            return

        deck = state["presentation"]
        slide = state["slide"]

        # Accumulate time on previous slide
        if self._last_probe_time > 0 and self._current_deck:
            elapsed = now - self._last_probe_time
            self._slide_durations[self._current_slide] = self._slide_durations.get(self._current_slide, 0) + elapsed

        # Deck changed?
        if deck != self._current_deck:
            if self._current_deck:
                self._write_file()  # finalize previous deck line
            # Start new deck
            self._current_deck = deck
            self._current_slide = slide
            self._current_presenting = state["presenting"]
            self._slide_durations = {}
            self._line_start_time = datetime.now().strftime("%H:%M:%S")
            self._notify_slide_change()
        elif slide != self._current_slide or state["presenting"] != self._current_presenting:
            self._current_slide = slide
            self._current_presenting = state["presenting"]
            self._notify_slide_change()

        self._current_slide = slide
        self._current_presenting = state["presenting"]
        self._last_probe_time = now
        self._write_file()

    def _notify_slide_change(self) -> None:
        if self._slide_callback and self._current_deck:
            try:
                self._slide_callback({
                    "type": "slide",
                    "deck": self._current_deck,
                    "slide": self._current_slide,
                    "presenting": self._current_presenting,
                })
            except Exception as e:
                print(f"[ppt-monitor] slide_callback error: {e}")

    def _write_file(self):
        if not self._current_deck:
            return

        filepath = self.output_dir / f"activity-slides-{datetime.now().strftime('%Y-%m-%d')}.md"
        self.output_dir.mkdir(parents=True, exist_ok=True)

        # Read existing lines
        lines = []
        if filepath.exists():
            lines = filepath.read_text(encoding="utf-8").splitlines()

        # Strip our current activity line (last line if it matches our deck)
        if lines and lines[-1].startswith(self._line_start_time):
            lines = lines[:-1]

        # Build activity line
        timings = []
        for slide_num, secs in self._slide_durations.items():
            if secs >= 0.5:  # only include slides with meaningful time
                timings.append(f"s{slide_num}:{_format_duration(secs)}")

        activity_line = f"{self._line_start_time} {self._current_deck}"
        if timings:
            activity_line += " - " + ", ".join(timings)

        lines.append(activity_line)

        filepath.write_text("\n".join(lines) + "\n", encoding="utf-8")
