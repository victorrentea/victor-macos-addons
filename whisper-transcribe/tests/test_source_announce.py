"""Every device Victor's channel lands on reaches the app, whichever path landed it.

2026-09-28 11:46: the XLR flapped off USB for a second. The device check moved
the channel to the MacBook mic and said so (`VICTOR_SOURCE:💻`); a moment later
the stream errored and the recovery re-resolve in `_ChannelCapture._loop` put it
back on the XLR — silently. Whisper recorded through the XLR for the next hour
and a half while the menu-bar icon kept showing the laptop. The fix announces
from the stream open, which both paths go through, deduped on the glyph.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import whisper_runner as wr


def _runner(tmp_path, monkeypatch):
    runner = wr.WhisperTranscriptionRunner(tmp_path)
    markers: list[str] = []
    monkeypatch.setattr(runner, "_write_to_transcript", markers.append)
    return runner, markers


def _sources(out: str) -> list[str]:
    return [line.split(":", 1)[1] for line in out.splitlines() if line.startswith("VICTOR_SOURCE:")]


def test_the_flap_and_the_silent_recovery_are_both_announced(tmp_path, monkeypatch, capsys):
    runner, markers = _runner(tmp_path, monkeypatch)
    runner._announced_source = "🎙️"  # what start() said

    runner._announce_source("MacBook Pro Microphone")  # device check → Mac
    runner._announce_source("MacBook Pro Microphone")  # the reopen that follows
    runner._announce_source("Elgato Wave XLR")          # recovery re-resolve → XLR

    assert _sources(capsys.readouterr().out) == ["💻", "🎙️"]
    assert markers == [f"--- {wr._ME_SPEAKER} → 💻 ---", f"--- {wr._ME_SPEAKER} → 🎙️ ---"]


def test_reopening_on_the_same_mic_says_nothing(tmp_path, monkeypatch, capsys):
    runner, markers = _runner(tmp_path, monkeypatch)
    runner._announced_source = "🎙️"

    runner._announce_source("Elgato Wave XLR")

    assert _sources(capsys.readouterr().out) == []
    assert markers == []
