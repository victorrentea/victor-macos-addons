import sys
import unittest

sys.path.insert(0, "whisper-transcribe")
import whisper_runner as wr


class ParentPidGuardTests(unittest.TestCase):
    def test_required_parent_pid_accepts_valid_integer(self):
        pid = wr._required_parent_pid({"WHISPER_PARENT_PID": "1234"})
        self.assertEqual(pid, 1234)

    def test_required_parent_pid_rejects_missing_value(self):
        with self.assertRaisesRegex(ValueError, "required"):
            wr._required_parent_pid({})

    def test_required_parent_pid_rejects_non_integer(self):
        with self.assertRaisesRegex(ValueError, "integer"):
            wr._required_parent_pid({"WHISPER_PARENT_PID": "abc"})

    def test_required_parent_pid_rejects_pid_one_or_less(self):
        with self.assertRaisesRegex(ValueError, "> 1"):
            wr._required_parent_pid({"WHISPER_PARENT_PID": "1"})


if __name__ == "__main__":
    unittest.main()
