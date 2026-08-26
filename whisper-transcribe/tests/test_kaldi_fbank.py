"""Golden-value regression for the numpy Kaldi filterbank.

The real proof of correctness cannot live here: it compares against
`torchaudio.compliance.kaldi.fbank`, and importing torch is the exact thing
this module exists to avoid (measured: cold import 767 ms → 67 ms, RSS
−178 MB). That verification was done once, out of tree, against 26 real WAVs —
resulting embedding cosine ≥ 0.99999982, and a true error against float64
torchaudio of 3.0e-05, which is **51× smaller than float32 torchaudio's own
error against itself**. The numpy version is closer to the truth than the
oracle it copies.

What belongs here instead is a tripwire: the exact numbers that implementation
produced, pinned. If anyone touches the mel bank, the window, the preemphasis
or the log floor, these move, and moving them silently is the failure mode that
matters — wrong features do not crash, they quietly degrade speaker separation.
"""
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import kaldi_fbank as kf


SR = 16000


def _signal(seconds: float = 2.0) -> np.ndarray:
    """Deterministic noise plus a 220 Hz tone — noise alone exercises the mel
    bank unevenly, and a pure tone alone leaves most bins at the log floor."""
    rng = np.random.default_rng(20260827)
    n = int(SR * seconds)
    t = np.arange(n) / SR
    return (rng.normal(scale=0.05, size=n) + 0.3 * np.sin(2 * np.pi * 220 * t)).astype(
        np.float32
    )


class TestGoldenValues:
    def test_shape_follows_kaldis_snip_edges_arithmetic(self):
        # snip_edges=True: no padding, so frames = 1 + (N - 400) // 160.
        x = _signal(2.0)
        assert kf.fbank(x).shape == (1 + (len(x) - 400) // 160, 80) == (198, 80)

    def test_the_numbers_have_not_moved(self):
        f = kf.fbank(_signal(2.0))
        assert f.dtype == np.float32
        assert float(f.sum()) == pytest.approx(312413.656250, rel=1e-6)
        assert float(f.mean()) == pytest.approx(19.723083, rel=1e-6)
        assert float(f.std()) == pytest.approx(2.753225, rel=1e-6)
        # First and last frames specifically: preemphasis treats sample 0
        # specially (Kaldi replicates x[0] rather than prepending zero), and the
        # tail is where an off-by-one in framing would surface.
        assert np.allclose(f[0, :4], [14.478808, 11.811735, 10.632911, 12.851688], rtol=1e-6)
        assert np.allclose(f[-1, -4:], [23.214298, 23.409143, 23.041216, 22.994083], rtol=1e-6)


class TestCMN:
    def test_it_removes_the_mean_per_mel_bin(self):
        # Cepstral mean normalisation is per-bin over time, not global — and it
        # is not optional: skipping it is what makes wespeaker models score
        # 15.5 % EER instead of 0.73 %, which is how sherpa-onnx 1.13.6 gets it
        # wrong without reporting anything.
        c = kf.fbank_cmn(_signal(2.0))
        assert np.abs(c.mean(axis=0)).max() < 1e-4

    def test_it_only_shifts_and_does_not_rescale(self):
        x = _signal(2.0)
        f, c = kf.fbank(x), kf.fbank_cmn(x)
        assert np.allclose(f - f.mean(axis=0, keepdims=True), c, atol=1e-4)


class TestEdges:
    def test_input_shorter_than_one_frame_yields_no_frames(self):
        assert kf.fbank(np.zeros(100, dtype=np.float32)).shape == (0, 80)

    def test_exactly_one_frame(self):
        assert kf.fbank(np.zeros(400, dtype=np.float32)).shape == (1, 80)

    def test_silence_sits_at_the_log_floor_rather_than_minus_infinity(self):
        f = kf.fbank(np.zeros(SR, dtype=np.float32))
        assert np.isfinite(f).all()
        assert f.min() == f.max()  # every bin floored identically

    def test_output_is_finite_for_a_full_scale_signal(self):
        f = kf.fbank(np.ones(SR, dtype=np.float32))
        assert np.isfinite(f).all()

    def test_it_does_not_mutate_its_input(self):
        # It runs on live audio buffers that the capture path still owns.
        x = _signal(0.5)
        before = x.copy()
        kf.fbank_cmn(x)
        assert np.array_equal(x, before)


def test_it_imports_without_torch():
    # The whole reason this module exists. whisper_runner already holds
    # mlx-whisper on the GPU at ~1.8 GB and is restarted several times a day.
    assert "torch" not in sys.modules, "something pulled torch into the sidecar"
