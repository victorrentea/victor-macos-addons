"""The decision rule is the whole feature, so it is pinned hard.

The transcript already carried speaker labels once, derived from which input
device happened to be louder, and they were removed on 2026-08-14 because they
were wrong often enough to poison every downstream reader. The thing that makes
this attempt different is not a better model — it is the abstain band. These
tests exist to make sure it cannot quietly disappear.
"""
import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import speaker_id as sid


TH = sid.Thresholds(victor_at=0.60, audience_below=0.35)
LONG = 5.0


class TestThresholds:
    def test_rejects_an_inverted_band(self):
        # Inverted, the "abstain" band becomes an overlap where a score is both
        # Victor and Audience — and the first branch would silently win.
        with pytest.raises(ValueError):
            sid.Thresholds(victor_at=0.3, audience_below=0.7)

    def test_allows_a_degenerate_but_meaningful_zero_width_band(self):
        # Equal thresholds = never abstain. Not what we want, but it is a
        # coherent operating point and the caller may be measuring with it.
        t = sid.Thresholds(victor_at=0.5, audience_below=0.5)
        assert t.abstain_width == 0

    def test_rejects_scores_outside_cosine_range(self):
        with pytest.raises(ValueError):
            sid.Thresholds(victor_at=1.5, audience_below=0.3)


class TestDecide:
    def test_high_score_is_victor(self):
        assert sid.decide(0.81, LONG, TH).label == sid.VICTOR

    def test_low_score_is_audience(self):
        assert sid.decide(0.10, LONG, TH).label == sid.AUDIENCE

    def test_the_middle_says_nothing(self):
        v = sid.decide(0.50, LONG, TH)
        assert v.label is None
        assert not v.is_confident
        assert "abstain" in v.reason

    def test_the_boundaries_are_inclusive_on_both_sides(self):
        assert sid.decide(0.60, LONG, TH).label == sid.VICTOR
        assert sid.decide(0.35, LONG, TH).label == sid.AUDIENCE

    def test_a_short_segment_is_never_labelled_however_confident_it_looks(self):
        # Every model measured sits at 3-5 % EER below ~1.5 s. A 0.99 there is
        # not evidence, and it is exactly the shape of a confidently wrong label.
        v = sid.decide(0.99, 0.4, TH)
        assert v.label is None
        assert "0.4s" in v.reason

    def test_the_duration_gate_is_checked_before_the_score(self):
        assert sid.decide(-1.0, 0.2, TH).label is None

    def test_the_score_is_always_reported_even_when_abstaining(self):
        # The abstain band can only be retuned from scores we kept.
        assert sid.decide(0.5, LONG, TH).score == 0.5
        assert sid.decide(0.99, 0.1, TH).score == 0.99


class TestCosine:
    def test_identical_vectors_score_one(self):
        v = np.array([1.0, 2.0, 3.0], dtype=np.float32)
        assert sid.cosine(v, v) == pytest.approx(1.0, abs=1e-6)

    def test_it_ignores_magnitude(self):
        v = np.array([1.0, 2.0, 3.0], dtype=np.float32)
        assert sid.cosine(v, v * 7) == pytest.approx(1.0, abs=1e-6)

    def test_opposite_vectors_score_minus_one(self):
        v = np.array([1.0, 0.0], dtype=np.float32)
        assert sid.cosine(v, -v) == pytest.approx(-1.0, abs=1e-6)

    def test_a_zero_embedding_is_not_a_score_at_all(self):
        # It must NOT come back as 0.0: that is an ordinary low score, and a low
        # score means Audience — so a failed measurement would become a
        # confident claim that somebody else spoke.
        z = np.zeros(3, dtype=np.float32)
        score = sid.cosine(z, np.array([1.0, 2.0, 3.0], dtype=np.float32))
        assert np.isnan(score)

    def test_an_unusable_embedding_abstains_and_says_why(self):
        z = np.zeros(3, dtype=np.float32)
        v = sid.decide(sid.cosine(z, z), LONG, TH)
        assert v.label is None
        # Not "in abstain band": NaN reaching that branch would be the right
        # answer for the wrong reason, and unreadable in a log.
        assert v.reason == "no usable embedding"

    def test_a_genuine_low_score_still_means_audience(self):
        # Guarding NaN must not have made low scores timid.
        assert sid.decide(0.0, LONG, TH).label == sid.AUDIENCE


class TestEnroll:
    def _cluster(self, dim=64, n=100, spread=0.05, seed=0):
        rng = np.random.default_rng(seed)
        base = rng.normal(size=dim)
        base /= np.linalg.norm(base)
        return base, base + rng.normal(scale=spread, size=(n, dim))

    def test_returns_a_unit_vector(self):
        _, xs = self._cluster()
        assert np.linalg.norm(sid.enroll(xs)) == pytest.approx(1.0, abs=1e-5)

    def test_recovers_the_centre_of_a_tight_cluster(self):
        base, xs = self._cluster()
        assert sid.cosine(sid.enroll(xs), base) > 0.99

    def test_outliers_pull_the_untrimmed_average_and_trimming_pulls_it_back(self):
        # Enrolment segments come from a real session: some clipped a
        # neighbour's word, some caught laughter. Those cost us on every future
        # comparison, so one cleaning pass is worth it.
        base, xs = self._cluster(n=90)
        rng = np.random.default_rng(1)
        junk = rng.normal(size=(10, xs.shape[1]))
        contaminated = np.vstack([xs, junk])

        untrimmed = sid.enroll(contaminated, trim_percentile=0)
        trimmed = sid.enroll(contaminated, trim_percentile=20)
        assert sid.cosine(trimmed, base) > sid.cosine(untrimmed, base)

    def test_a_handful_of_samples_is_not_trimmed(self):
        # Dropping 10 % of 5 samples is noise, not cleaning.
        _, xs = self._cluster(n=5)
        assert sid.cosine(sid.enroll(xs, trim_percentile=10),
                          sid.enroll(xs, trim_percentile=0)) == pytest.approx(1.0, abs=1e-6)

    def test_rejects_an_empty_enrolment(self):
        with pytest.raises(ValueError):
            sid.enroll(np.zeros((0, 16), dtype=np.float32))


class TestVoiceprintRoundTrip:
    def test_survives_save_and_load_with_its_thresholds_and_provenance(self, tmp_path):
        # A voiceprint measures a microphone as much as a voice, so "what was
        # this enrolled from, and when" has to be answerable from the file
        # itself months later.
        vp = sid.Voiceprint(
            embedding=np.arange(8, dtype=np.float32),
            thresholds=TH,
            meta={"enrolled_from": "incubyte-0811", "segments": 200, "date": "2026-08-26"},
        )
        vp.save(tmp_path)
        back = sid.Voiceprint.load(tmp_path)

        assert np.allclose(back.embedding, vp.embedding)
        assert back.thresholds == TH
        assert back.meta["enrolled_from"] == "incubyte-0811"
        assert back.meta["segments"] == 200

    def test_it_is_stored_outside_the_repo_next_to_the_transcripts(self, tmp_path):
        # victor-macos-addons is a PUBLIC repo, and a speaker-verification
        # template is exactly the artefact that defeats speaker verification.
        p = sid.Voiceprint.path(tmp_path)
        assert p.parent == tmp_path
        assert p.name == "voiceprint.npz"

    def test_the_saved_file_is_plain_arrays_not_a_pickle(self, tmp_path):
        # allow_pickle=False on load, so nothing here can execute on read.
        vp = sid.Voiceprint(np.ones(4, dtype=np.float32), TH, {"enrolled_from": "x"})
        path = vp.save(tmp_path)
        with np.load(path, allow_pickle=False) as z:
            assert set(z.files) == {"embedding", "meta"}
            assert json.loads(str(z["meta"]))["victor_at"] == TH.victor_at
