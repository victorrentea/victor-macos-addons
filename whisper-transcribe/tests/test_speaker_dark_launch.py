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


def test_the_transcript_carries_the_glyph_but_never_the_score(tmp_path):
    """Labels returned to the transcript on 2026-08-28 — the glyph, and only
    the glyph. A score in the line would invite it to be read as certainty."""
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "salut lume", "🎙️", _Verdict("Victor", 0.88))
    line = _transcript(tmp_path).strip()
    assert line.endswith("] 🎙️ salut lume")
    for forbidden in ("Victor:", "Audience:", "0.88"):
        assert forbidden not in line, f"{forbidden!r} leaked into the transcript"


def test_an_abstention_looks_exactly_like_the_old_unlabelled_line(tmp_path):
    """Not a third glyph. Nobody is claiming anything about this line."""
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "hmm ceva", "🎙️", _Verdict(None, 0.31, "abstain band"))
    assert _transcript(tmp_path).strip().endswith("] hmm ceva")


def test_the_line_survives_with_no_scorer_at_all(tmp_path):
    """The one failure this must never have: losing the transcript along with
    the label."""
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "salut lume", "🎙️", None)
    assert _transcript(tmp_path).strip().endswith("] salut lume")


def test_the_stamp_stays_first_so_the_watchdog_still_counts_speech(tmp_path):
    r = _runner(tmp_path)
    r._on_segment("Victor", "ro", "salut", "🎙️", _Verdict("Audience", 0.05))
    import re

    assert re.match(r"^\[\d\d:\d\d\] ", _transcript(tmp_path).strip())


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


MODEL = Path(__file__).resolve().parent.parent / "models" / "wespeaker_resnet34_LM.onnx"


@pytest.mark.skipif(not MODEL.exists(), reason="embedding model not present")
class TestItActuallyRuns:
    """The happy path, and it is here because its absence cost a whole commit.

    `d013c25` shipped `speaker_id.py` importing a `kaldi_fbank` module that did
    not exist. Every test passed — 57 of them — because every test exercised a
    degraded path, and a degraded path is exactly what a missing import
    produces. The suite proved the feature failed safely without ever noticing
    it could not succeed at all.
    """

    def _tone(self, seconds=4.0, freq=140.0):
        t = np.arange(int(sid.SAMPLE_RATE * seconds)) / sid.SAMPLE_RATE
        return (0.3 * np.sin(2 * np.pi * freq * t)).astype(np.float32)

    def test_the_model_loads_and_embeds(self, tmp_path):
        s = sid.SpeakerScorer(MODEL, tmp_path)
        assert s.model_ready, f"model would not load: {s.error}"
        e = s.embed(self._tone())
        assert e.shape == (256,)
        assert np.isfinite(e).all(), "an all-NaN graph is the CoreML failure mode"
        assert np.linalg.norm(e) > 0

    def test_a_real_scorer_returns_a_real_verdict(self, tmp_path):
        # Enrol from one tone, then score the same tone: whatever the thresholds
        # say, this must produce a Verdict with a finite score — not None, which
        # is what every failure path returns.
        s = sid.SpeakerScorer(MODEL, tmp_path)
        sid.Voiceprint(
            embedding=s.embed(self._tone()),
            thresholds=sid.Thresholds(victor_at=0.6, audience_below=0.3),
            meta={"enrolled_from": "a test tone"},
        ).save(tmp_path)

        s = sid.SpeakerScorer(MODEL, tmp_path)
        assert s.available, f"voiceprint would not load: {s.error}"
        v = s.score(self._tone())
        assert v is not None, "a working scorer must not return the failure value"
        assert np.isfinite(v.score)
        assert v.label == sid.VICTOR, f"scored {v.score} against itself"

    def test_a_different_voice_does_not_score_as_victor(self, tmp_path):
        s = sid.SpeakerScorer(MODEL, tmp_path)
        sid.Voiceprint(
            embedding=s.embed(self._tone(freq=140.0)),
            thresholds=sid.Thresholds(victor_at=0.6, audience_below=0.3),
            meta={"enrolled_from": "a test tone"},
        ).save(tmp_path)
        s = sid.SpeakerScorer(MODEL, tmp_path)
        assert s.score(self._tone(freq=430.0)).label != sid.VICTOR

    def test_a_per_call_failure_disables_instead_of_returning_None_forever(self, tmp_path):
        # Silently returning None on every call made "scoring nothing"
        # indistinguishable from "a quiet room", and would lose a whole
        # dark-launch day while the log said the feature was on.
        s = sid.SpeakerScorer(MODEL, tmp_path)
        sid.Voiceprint(
            embedding=np.ones(7, dtype=np.float32),   # wrong dimension
            thresholds=sid.Thresholds(victor_at=0.6, audience_below=0.3),
            meta={"enrolled_from": "a mismatched model"},
        ).save(tmp_path)
        s = sid.SpeakerScorer(MODEL, tmp_path)
        assert s.available
        assert s.score(self._tone()) is None
        assert s.failed and s.error
        assert not s.available, "it must stop claiming to work"


class _FakeScorer:
    """Scores by length, so a test can say which piece is whose."""

    def __init__(self, by_seconds):
        self.by_seconds = by_seconds
        self.scored = []

    def score(self, audio, min_seconds=None):
        seconds = round(len(audio) / sid.SAMPLE_RATE, 1)
        self.scored.append((seconds, min_seconds))
        return _Verdict(self.by_seconds.get(seconds, None), 0.5)


def _audio(seconds):
    return np.zeros(int(sid.SAMPLE_RATE * seconds), dtype=np.float32)


def _result(*segments):
    return {
        "text": " ".join(t for _, _, t in segments),
        "segments": [{"start": s, "end": e, "text": t} for s, e, t in segments],
    }


def _chunk_text(result):
    """What the transcriber loop passes alongside `result`. It matters that
    these agree: the transcript is written from the rows, so `_score_speakers`
    refuses to split a chunk whose segments do not join back into its text."""
    return result["text"]


class TestOneVerdictPerWhisperSegment:
    """The mixed chunk is the whole reason this exists.

    A 12 s chunk in a room holds a question from the floor and the answer over
    the top of it often enough (17 % of a measured teaching day) that one
    verdict for the chunk is a verdict about two people.
    """

    def test_each_segment_is_scored_separately(self):
        scorer = _FakeScorer({3.0: "Audience", 4.0: "Victor"})
        res = _result((0.0, 3.0, "și cum facem cu retry-ul?"), (3.0, 7.0, "hai să vedem"))
        rows = wr._score_speakers(scorer, _audio(12), res, _chunk_text(res))
        assert [r[3].label for r in rows] == ["Audience", "Victor"]
        assert [(r[0], r[1]) for r in rows] == [(0.0, 3.0), (3.0, 7.0)]

    def test_a_segment_is_scored_against_the_segment_floor_not_the_chunk_floor(self):
        scorer = _FakeScorer({3.0: "Victor"})
        res = _result((0.0, 3.0, "da"), (3.0, 6.0, "sigur că da"))
        wr._score_speakers(scorer, _audio(12), res, _chunk_text(res))
        assert scorer.scored == [(3.0, sid.SEGMENT_MIN_SECONDS)] * 2

    def test_a_segment_under_the_floor_is_kept_but_not_scored(self):
        """Its words still belong in the transcript; it just gets no name."""
        scorer = _FakeScorer({})
        res = _result((0.0, 1.0, "mhm"), (1.0, 5.0, "spuneam că"))
        rows = wr._score_speakers(scorer, _audio(12), res, _chunk_text(res))
        assert [s for s, _ in scorer.scored] == [4.0]
        assert [r[2] for r in rows] == ["mhm", "spuneam că"]
        assert rows[0][3] is None

    def test_a_hallucinated_segment_gets_no_verdict(self):
        """A hallucinated line has no speaker, and calling a cough somebody
        else is worse than saying nothing about it."""
        scorer = _FakeScorer({})
        res = _result((0.0, 3.0, "Vă mulțumesc!"), (3.0, 7.0, "revenim la subiect"))
        rows = wr._score_speakers(scorer, _audio(12), res, _chunk_text(res))
        assert [s for s, _ in scorer.scored] == [4.0]
        assert rows[0][3] is None and rows[1][3] is not None

    def test_a_chunk_with_no_usable_segments_still_gets_one_verdict(self):
        """Falling silent here would lose the chunk from the dark launch
        entirely, which looks exactly like a quiet room."""
        scorer = _FakeScorer({12.0: "Victor"})
        rows = wr._score_speakers(scorer, _audio(12), {"segments": []}, "ceva")
        assert len(rows) == 1
        assert rows[0][0] is None and rows[0][1] is None
        assert scorer.scored == [(12.0, None)]

    def test_a_decode_that_explodes_into_segments_falls_back_whole(self):
        """The cap drops segments, so the words no longer add up — and a
        missing sentence is worse than a missing label."""
        scorer = _FakeScorer({200.0: "Victor"})
        many = _result(*[(i * 3.0, i * 3.0 + 3.0, f"linia {i}") for i in range(40)])
        rows = wr._score_speakers(scorer, _audio(200), many, _chunk_text(many))
        assert len(rows) == 1 and rows[0][0] is None
        assert rows[0][2] == _chunk_text(many)

    def test_a_mixed_chunk_becomes_two_attributed_transcript_lines(self, tmp_path):
        r = _runner(tmp_path)
        r._on_segment(
            "Victor", "ro", "și cum facem cu retry-ul? hai să vedem", "🎙️",
            [
                (0.0, 3.0, "și cum facem cu retry-ul?", _Verdict("Audience", 0.09)),
                (3.0, 7.0, "hai să vedem", _Verdict("Victor", 0.71)),
            ],
        )
        lines = [l for l in _transcript(tmp_path).splitlines() if l.strip()]
        assert len(lines) == 2
        assert lines[0].endswith("] 👥 și cum facem cu retry-ul?")
        assert lines[1].endswith("] 🎙️ hai să vedem")

    def test_an_unscored_segment_still_gets_its_words_into_the_transcript(self, tmp_path):
        r = _runner(tmp_path)
        r._on_segment(
            "Victor", "ro", "mhm spuneam că", "🎙️",
            [(0.0, 1.0, "mhm", None), (1.0, 5.0, "spuneam că", _Verdict("Victor", 0.7))],
        )
        lines = [l for l in _transcript(tmp_path).splitlines() if l.strip()]
        assert lines[0].endswith("] mhm")
        assert lines[1].endswith("] 🎙️ spuneam că")
        assert len(_verdicts(tmp_path)) == 1

    def test_every_segment_lands_in_the_jsonl_with_its_own_offsets(self, tmp_path):
        r = _runner(tmp_path)
        r._on_segment(
            "Victor", "ro", "întrebare și răspuns", "🎙️",
            [
                (0.0, 3.0, "și cum facem cu retry-ul?", _Verdict("Audience", 0.09)),
                (3.0, 7.0, "hai să vedem", _Verdict("Victor", 0.71)),
            ],
        )
        rows = _verdicts(tmp_path)
        assert [x["label"] for x in rows] == ["Audience", "Victor"]
        assert [x["text"] for x in rows] == ["și cum facem cu retry-ul?", "hai să vedem"]
        assert (rows[0]["start"], rows[0]["end"]) == (0.0, 3.0)

    def test_a_whole_chunk_verdict_carries_no_offsets(self, tmp_path):
        """Their absence is information: this chunk could not be cut finer."""
        r = _runner(tmp_path)
        r._on_segment("Victor", "ro", "ceva", "🎙️", [(None, None, "ceva", _Verdict("Victor", 0.8))])
        row = _verdicts(tmp_path)[0]
        assert "start" not in row and "end" not in row


class TestHallucinationsWithoutTheirPunctuation:
    """Started mattering when `_is_garbage` began screening whisper segments.

    A segment is cut mid-utterance, so its punctuation is whatever the decoder
    felt like — and the first real mixed chunk this feature ever split came back
    with two segments of "Nu uitați să vă abonați la canalul meu", no "!", which
    the exact-match set let straight through to be scored.
    """

    @pytest.mark.parametrize(
        "text",
        [
            "Nu uitați să vă abonați la canalul meu",
            "Nu uitați să vă abonați la canalul meu!",
            "Să vă mulțumim pentru vizionare",
            "Vă mulțumesc",
            "Thank you",
        ],
    )
    def test_a_known_hallucination_is_caught_either_way(self, text):
        assert wr._is_garbage(text)

    @pytest.mark.parametrize(
        "text",
        [
            "Mă ne vedem la următoarea mea rețetă.",
            "Să nu ne vedem la următoarea mea rețetă!",
            "Nu uitați să vă abonați la canalul meu",
        ],
    )
    def test_a_whole_family_is_caught_by_its_phrase(self, text):
        """Whisper writes the same outro with a different leading word every
        time; collecting the variants one by one is always one behind."""
        assert wr._is_garbage(text)

    @pytest.mark.parametrize(
        "text",
        [
            "Da, corect.",
            "Pleacă default pe all și la domain model.",
            "Ne vedem la următoarea sesiune de curs.",
            "Hai să vedem la următoarea metodă ce se întâmplă.",
        ],
    )
    def test_real_speech_still_gets_through(self, text):
        assert not wr._is_garbage(text)


class TestWhisperPadsEveryInputToThirtySeconds:
    """A decode that found nothing hands back one segment spanning the padded
    window — `end` 29.98 on twelve seconds of audio. That is the decoder
    declining to segment, not a segment."""

    def test_a_span_covering_the_whole_chunk_falls_back_to_one_verdict(self):
        scorer = _FakeScorer({12.0: "Victor"})
        res = _result((0.0, 29.98, "ceva"))
        rows = wr._score_speakers(scorer, _audio(12), res, _chunk_text(res))
        assert len(rows) == 1
        assert rows[0][0] is None and rows[0][1] is None
        assert scorer.scored == [(12.0, None)]

    def test_an_overhanging_end_is_clamped_to_the_audio(self):
        scorer = _FakeScorer({8.0: "Victor"})
        res = _result((0.0, 4.0, "una"), (4.0, 29.98, "alta"))
        rows = wr._score_speakers(scorer, _audio(12), res, _chunk_text(res))
        assert [(r[0], r[1]) for r in rows] == [(0.0, 4.0), (4.0, 12.0)]
