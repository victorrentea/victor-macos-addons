import sys
import unittest

sys.path.insert(0, "whisper-transcribe")
from dead_input import DigitalSilenceWatch, is_dji_receiver

BLOCK = 0.1  # PortAudio hands whisper 100 ms blocks


def run(watch, peaks, start=1000.0):
    events = []
    for i, p in enumerate(peaks):
        e = watch.feed(p, BLOCK, start + i * BLOCK)
        if e:
            events.append((i, e))
    return events


class DigitalSilenceWatchTests(unittest.TestCase):
    def test_fires_once_after_twenty_seconds_of_exact_zero(self):
        w = DigitalSilenceWatch()
        events = run(w, [0.0] * 400)  # 40 s of zeros
        self.assertEqual(events, [(199, "dead")])  # the 200th block completes 20 s
        self.assertEqual(w.silent_since, 1000.0)  # when the zeros began, not when it fired

    def test_a_quiet_room_never_fires(self):
        # Quiet but not digital silence: tiny noise in the low bits.
        w = DigitalSilenceWatch()
        self.assertEqual(run(w, [1e-6] * 1000), [])

    def test_one_nonzero_block_resets_the_count(self):
        w = DigitalSilenceWatch()
        self.assertEqual(run(w, [0.0] * 190 + [0.01] + [0.0] * 190), [])

    def test_audio_back_reports_alive_and_rearms_for_a_second_death(self):
        w = DigitalSilenceWatch()
        events = run(w, [0.0] * 200 + [0.2] * 10 + [0.0] * 200)
        self.assertEqual([e for _, e in events], ["dead", "alive", "dead"])

    def test_nonzero_without_prior_death_is_not_an_alive_event(self):
        w = DigitalSilenceWatch()
        self.assertEqual(run(w, [0.0] * 50 + [0.3]), [])


class IsDjiReceiverTests(unittest.TestCase):
    DEVICES = [
        {"name": "Wireless Mic Rx", "manufacturer": "DJI Technology Co., Ltd."},
        {"name": "Elgato Wave XLR", "manufacturer": "Elgato Systems"},
    ]

    def test_matches_on_name_and_maker(self):
        self.assertTrue(is_dji_receiver("Wireless Mic Rx", self.DEVICES))

    def test_same_name_other_maker_is_not_the_dji(self):
        other = [{"name": "Wireless Mic Rx", "manufacturer": "Rode"}]
        self.assertFalse(is_dji_receiver("Wireless Mic Rx", other))

    def test_other_devices_are_not_the_dji(self):
        self.assertFalse(is_dji_receiver("Elgato Wave XLR", self.DEVICES))
        self.assertFalse(is_dji_receiver("MacBook Pro Microphone", self.DEVICES))


if __name__ == "__main__":
    unittest.main()
