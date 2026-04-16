import sys
import unittest

import numpy as np

sys.path.insert(0, "whisper-transcribe")
import whisper_runner as wr


class AdaptiveBatchingTests(unittest.TestCase):
    def setUp(self):
        self._orig_adaptive = wr._ADAPTIVE_QUALITY
        self._orig_fast = wr._MODEL_FAST
        self._orig_balanced = wr._MODEL_BALANCED
        wr._ADAPTIVE_QUALITY = True
        wr._MODEL_BALANCED = "balanced-model"
        wr._MODEL_FAST = "fast-model"

    def tearDown(self):
        wr._ADAPTIVE_QUALITY = self._orig_adaptive
        wr._MODEL_FAST = self._orig_fast
        wr._MODEL_BALANCED = self._orig_balanced

    def test_model_switches_to_fast_when_backlog_is_high(self):
        mode = wr._select_model_mode(current_mode="balanced", backlog_size=99)
        self.assertEqual(mode, "fast")

    def test_model_stays_fast_in_hysteresis_band(self):
        mode = wr._select_model_mode(current_mode="fast", backlog_size=4)
        self.assertEqual(mode, "fast")

    def test_model_switches_back_to_balanced_when_backlog_is_low(self):
        mode = wr._select_model_mode(current_mode="fast", backlog_size=0)
        self.assertEqual(mode, "balanced")

    def test_merge_adjacent_chunks_keeps_speaker_order(self):
        batch = [
            ("Victor", np.array([1.0, 2.0], dtype=np.float32), "🎙️"),
            ("Victor", np.array([3.0], dtype=np.float32), "🎙️"),
            ("Audience", np.array([10.0], dtype=np.float32), "🔊"),
            ("Victor", np.array([4.0], dtype=np.float32), "🎙️"),
        ]

        merged = wr._merge_adjacent_chunks(batch)

        self.assertEqual(len(merged), 3)
        self.assertEqual(merged[0][0], "Victor")
        np.testing.assert_array_equal(
            merged[0][1], np.array([1.0, 2.0, 3.0], dtype=np.float32)
        )
        self.assertEqual(merged[1][0], "Audience")
        self.assertEqual(merged[2][0], "Victor")


if __name__ == "__main__":
    unittest.main()
