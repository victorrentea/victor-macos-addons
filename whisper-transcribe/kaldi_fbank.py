"""Kaldi-compatible log-mel filterbank features in pure numpy.

Bit-comparable drop-in for::

    torchaudio.compliance.kaldi.fbank(
        waveform, num_mel_bins=80, frame_length=25, frame_shift=10, dither=0.0,
        sample_frequency=16000, window_type='hamming', use_energy=False,
        snip_edges=True)

where ``waveform`` is float samples in [-1, 1] scaled by 32768.0, shape [1, N].

Written so that a process feeding a wespeaker/ResNet34 ONNX speaker embedder
does not have to import torch. Only numpy is required.

Every Kaldi-specific choice below was verified line by line against
``torchaudio/compliance/kaldi.py`` rather than against the Kaldi docs, because
several of them are non-obvious and a couple are outright surprising. They are
called out in comments at the point where they matter.
"""

import numpy as np

__all__ = ["fbank", "fbank_cmn", "mel_filterbank", "hamming_window"]

# Kaldi floors the filterbank energies at numeric_limits<float>::epsilon()
# before taking the log -- that is the *float32* epsilon, not float64's, and not
# an arbitrary 1e-10. Getting this wrong only shows up on near-silent frames.
_EPSILON = np.float64(np.finfo(np.float32).eps)  # 1.1920928955078125e-07

_PREEMPH_COEFF = 0.97
_LOW_FREQ = 20.0
_HIGH_FREQ = 0.0  # <= 0 means "offset from Nyquist", i.e. Nyquist itself


def _next_power_of_2(x: int) -> int:
    return 1 if x == 0 else 1 << (x - 1).bit_length()


def hamming_window(window_size: int) -> np.ndarray:
    """Kaldi/HTK Hamming window: symmetric (``periodic=False``), N-1 in the
    denominator.

    This is torch.hamming_window(N, periodic=False, alpha=0.54, beta=0.46).
    numpy's own ``np.hamming`` happens to use the same convention, but scipy's
    default and torch's *default* (periodic=True, which divides by N) do not --
    so this is spelled out explicitly rather than delegated.
    """
    n = np.arange(window_size, dtype=np.float64)
    return 0.54 - 0.46 * np.cos(2.0 * np.pi * n / (window_size - 1))


def _mel_scale(freq):
    # Kaldi's mel: 1127 * ln(1 + f/700). Note the constant is a flat 1127.0,
    # not HTK's 1127.01048 and not the 2595*log10 form.
    return 1127.0 * np.log(1.0 + freq / 700.0)


def _inverse_mel_scale(mel):
    return 700.0 * (np.exp(mel / 1127.0) - 1.0)


def mel_filterbank(
    num_mel_bins: int,
    padded_window_size: int,
    sample_rate: float,
    low_freq: float = _LOW_FREQ,
    high_freq: float = _HIGH_FREQ,
) -> np.ndarray:
    """Kaldi triangular mel filters, shape (num_mel_bins, padded_window_size//2 + 1).

    Differs from librosa's ``mel(htk=False)`` in two ways that both matter:
      * no Slaney area normalisation -- the triangles peak at exactly 1.0;
      * the triangles are defined by *equally mel-spaced bin centres*, with the
        left/right feet sitting on the neighbouring centres.

    The genuinely counterintuitive part: Kaldi builds the bank over only
    ``padded_window_size // 2`` FFT bins (256 for a 512-point FFT) and then
    appends a zero column so it can multiply a 257-bin rfft output. The Nyquist
    bin is therefore *always discarded*, weight zero, for every filter.

    The second surprise, and the reason for all the ``np.float32`` casts below:
    torchaudio builds this bank in **float32**, and ``mel - left_mel`` subtracts
    two values of magnitude ~2840 whose difference is ~32. That catastrophic
    cancellation costs ~4 significant digits, so the float32 bank differs from
    an exact one by ~1.4e-5 *absolute* on weights of order 0.5 -- a hundred
    times more than float32 rounding would suggest. Computing this part in
    float64 is more accurate but LESS faithful, and measurably shifts the
    output, so the float32 arithmetic is reproduced deliberately.
    Every scalar is wrapped in ``np.float32`` because a bare Python/NumPy
    float64 scalar would silently upcast the whole expression.
    """
    assert num_mel_bins > 3, "Must have at least 3 mel bins"
    assert padded_window_size % 2 == 0

    num_fft_bins = padded_window_size // 2  # 256, NOT 257 -- see docstring
    nyquist = 0.5 * sample_rate
    if high_freq <= 0.0:
        high_freq += nyquist

    assert 0.0 <= low_freq < nyquist
    assert 0.0 < high_freq <= nyquist
    assert low_freq < high_freq

    f32 = np.float32
    fft_bin_width = sample_rate / padded_window_size

    # The two cutoffs are converted in float64 (torchaudio uses math.log here)
    # and only then rounded into the float32 grid.
    mel_low = _mel_scale(low_freq)
    mel_high = _mel_scale(high_freq)

    # num_bins + 1 (not + 2) because the outermost triangles spill past the
    # cutoffs -- there are num_bins centres between mel_low and mel_high.
    mel_delta = (mel_high - mel_low) / (num_mel_bins + 1)

    bin_idx = np.arange(num_mel_bins, dtype=f32)[:, None]
    left_mel = f32(mel_low) + bin_idx * f32(mel_delta)
    center_mel = f32(mel_low) + (bin_idx + f32(1.0)) * f32(mel_delta)
    right_mel = f32(mel_low) + (bin_idx + f32(2.0)) * f32(mel_delta)

    # Mel position of each FFT bin centre (bin k sits at k * fft_bin_width Hz),
    # evaluated in float32 exactly as the reference does.
    freq = f32(fft_bin_width) * np.arange(num_fft_bins, dtype=f32)
    mel = (f32(1127.0) * np.log(f32(1.0) + freq / f32(700.0)))[None, :]

    up_slope = (mel - left_mel) / (center_mel - left_mel)
    down_slope = (right_mel - mel) / (right_mel - center_mel)
    # left < center < right always holds (no VTLN warping), so min-then-clamp
    # reproduces the triangle exactly.
    bins = np.maximum(f32(0.0), np.minimum(up_slope, down_slope))

    # Zero column for the Nyquist bin, to line up with rfft's 257 outputs.
    # Upcast to float64 for the projection itself.
    return np.pad(bins, ((0, 0), (0, 1)), mode="constant").astype(np.float64)


def _frame(samples: np.ndarray, window_size: int, window_shift: int) -> np.ndarray:
    """snip_edges=True framing: only whole frames, no padding at either end."""
    num_samples = samples.shape[0]
    if num_samples < window_size:
        return np.empty((0, window_size), dtype=samples.dtype)
    m = 1 + (num_samples - window_size) // window_shift
    return np.lib.stride_tricks.as_strided(
        samples,
        shape=(m, window_size),
        strides=(window_shift * samples.strides[0], samples.strides[0]),
    )


def fbank(
    samples: np.ndarray,
    sample_rate: int = 16000,
    num_mel_bins: int = 80,
    frame_length_ms: float = 25,
    frame_shift_ms: float = 10,
) -> np.ndarray:
    """Log-mel filterbank features, shape [num_frames, num_mel_bins], float32.

    ``samples`` is float audio in [-1, 1], mono, 1-D. It is scaled to the int16
    range internally -- Kaldi recipes feed int16-valued floats, and because the
    log is taken at the very end the scale is *not* a no-op: it shifts every
    output by a constant 2*ln(32768).
    """
    samples = np.asarray(samples, dtype=np.float64).reshape(-1)
    # Kaldi/wespeaker convention: samples live on the int16 scale.
    samples = samples * 32768.0

    window_shift = int(sample_rate * frame_shift_ms * 0.001)  # 160
    window_size = int(sample_rate * frame_length_ms * 0.001)  # 400
    padded_window_size = _next_power_of_2(window_size)  # 512

    frames = _frame(np.ascontiguousarray(samples), window_size, window_shift)
    if frames.shape[0] == 0:
        return np.empty((0, num_mel_bins), dtype=np.float32)
    frames = frames.copy()  # as_strided view shares memory; detach before mutating

    # 1. dither: skipped entirely (dither=0.0).

    # 2. remove_dc_offset: subtract each frame's OWN mean, before windowing and
    #    before preemphasis. Order matters -- doing it after windowing is the
    #    classic silent divergence.
    frames -= frames.mean(axis=1, keepdims=True)

    # 3. Preemphasis y[j] = x[j] - 0.97 * x[j-1], with Kaldi replicating x[0]
    #    at j == 0 rather than assuming a zero to its left. So the first sample
    #    becomes 0.03 * x[0], not x[0].
    prev = np.concatenate([frames[:, :1], frames[:, :-1]], axis=1)
    frames -= _PREEMPH_COEFF * prev

    # 4. Window, then zero-pad on the right out to the FFT size.
    frames *= hamming_window(window_size)

    # 5. Power spectrum: |rfft|^2 (use_power=True -- power, not magnitude).
    spectrum = np.abs(np.fft.rfft(frames, n=padded_window_size)) ** 2

    # 6. Mel projection, then log with the float32-eps floor.
    fb = mel_filterbank(num_mel_bins, padded_window_size, sample_rate)
    mel_energies = spectrum @ fb.T
    mel_energies = np.log(np.maximum(mel_energies, _EPSILON))

    # use_energy=False -> no extra energy column.
    return mel_energies.astype(np.float32)


def fbank_cmn(
    samples: np.ndarray,
    sample_rate: int = 16000,
    num_mel_bins: int = 80,
    frame_length_ms: float = 25,
    frame_shift_ms: float = 10,
) -> np.ndarray:
    """``fbank`` followed by per-utterance cepstral mean normalisation.

    The mean is taken over the TIME axis, so each of the 80 mel channels ends up
    zero-mean across the utterance.
    """
    feats = fbank(samples, sample_rate, num_mel_bins, frame_length_ms, frame_shift_ms)
    if feats.shape[0] == 0:
        return feats
    return (feats - feats.mean(axis=0, keepdims=True)).astype(np.float32)
