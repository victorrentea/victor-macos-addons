"""Speaker verdicts must never reach the transcript, and must never break it.

Labels lived in the transcript once and were removed on 2026-08-14 for being
wrong too often. The way back in is to be measured against a day of real audio
while costing that day nothing — which only works if the wiring is incapable of
writing a label into the transcript, and incapable of dropping a transcript line
when the scorer misbehaves.
"""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import speaker_id as sid
import whisper_runner as wr


class _Verdict:
    def __init__(self, label, score, reason="because"):
        self.label, self.score, self.reason = label, score, reason


def _runner(tmp_path):
    return wr.WhisperTranscriptionRunner(tmp_path)


def _transcript(tmp_path) -> str:
    files = list(tmp_path.glob("*-transcription.txt"))
    return files[0].read_text(encoding="utf-8") if files else ""


def _verdicts(tmp_path) -> list[dict]:
    files = list(tmp_path.glob("*-speakers.jsonl"))
    if not files:
        return []
    return [json.loads(l) for l in files[0].read_text(encoding="utf-8").splitlines() if l]


def test_the_transcript_line_is_unchanged_when_a_verdict_exists(tmp_path):
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "salut lume", "🎙️", _Verdict("Victor", 0.88))
    line = _transcript(tmp_path).strip()
    assert line.endswith("] salut lume")
    for forbidden in ("Victor:", "Audience:", "0.88", "🗣️"):
        assert forbidden not in line, f"{forbidden!r} leaked into the transcript"


def test_the_verdict_lands_in_its_own_file(tmp_path):
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "salut lume", "🎙️", _Verdict("Audience", 0.11, "low"))
    rows = _verdicts(tmp_path)
    assert len(rows) == 1
    assert rows[0]["label"] == "Audience"
    assert rows[0]["score"] == 0.11
    assert rows[0]["reason"] == "low"
    assert rows[0]["text"] == "salut lume"


def test_an_abstention_is_recorded_too_not_dropped(tmp_path):
    # The abstain band can only ever be retuned from the scores we kept, so the
    # "said nothing" cases are the ones most worth writing down.
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "hmm", "🎙️", _Verdict(None, 0.47, "in abstain band"))
    rows = _verdicts(tmp_path)
    assert len(rows) == 1
    assert rows[0]["label"] is None
    assert rows[0]["score"] == 0.47


def test_a_nan_score_is_written_as_null_not_as_invalid_json(tmp_path):
    # json.dumps(float('nan')) emits a bare NaN, which is not JSON and which
    # json.loads only accepts by accident — a reader in any other language
    # would choke on the file months from now.
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "x y z", "🎙️", _Verdict(None, float("nan"), "no usable embedding"))
    raw = list(tmp_path.glob("*-speakers.jsonl"))[0].read_text()
    assert "NaN" not in raw
    assert json.loads(raw.strip())["score"] is None


def test_no_verdict_file_is_created_when_scoring_is_off(tmp_path):
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "salut", "🎙️")
    assert _transcript(tmp_path).strip().endswith("] salut")
    assert not list(tmp_path.glob("*-speakers.jsonl"))


def test_a_verdict_that_explodes_while_being_written_does_not_lose_the_line(tmp_path):
    class Exploding:
        label = "Victor"
        reason = "fine"

        @property
        def score(self):
            raise RuntimeError("boom")

    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "important sentence", "🎙️", Exploding())
    assert "important sentence" in _transcript(tmp_path)


class TestScorerDegradesToNothing:
    def test_a_missing_model_disables_rather_than_raises(self, tmp_path):
        s = sid.SpeakerScorer(tmp_path / "nope.onnx", tmp_path)
        assert not s.available
        assert s.error
        assert s.score(np.zeros(16000 * 3, dtype=np.float32)) is None

    def test_a_missing_voiceprint_disables_rather_than_raises(self, tmp_path):
        (tmp_path / "nope.onnx").write_bytes(b"not a model")
        s = sid.SpeakerScorer(tmp_path / "nope.onnx", tmp_path)
        assert not s.available

    def test_the_runner_gets_none_and_carries_on(self, tmp_path, monkeypatch):
        monkeypatch.setattr(wr, "_SPEAKER_ID_ON", True)
        monkeypatch.setattr(wr, "_SPEAKER_MODEL", tmp_path / "absent.onnx")
        assert wr._make_speaker_scorer(tmp_path) is None

    def test_it_is_off_unless_asked_for(self, tmp_path):
        assert wr._make_speaker_scorer(tmp_path) is None
