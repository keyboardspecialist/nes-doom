import unittest

from tools.mapconv import vertical_phase
from tools.tilegen import projected_half_phase


class VerticalPhaseTest(unittest.TestCase):
    def test_doom_pegging_anchors(self):
        args = (0, 120, 24, 96, 64, 8)
        self.assertEqual(vertical_phase("solid", *args, 0), 32)
        self.assertEqual(vertical_phase("solid", *args, 0x0010), 64)
        self.assertEqual(vertical_phase("upper", *args, 0x0008), 32)
        self.assertEqual(vertical_phase("upper", *args, 0), 192)
        self.assertEqual(vertical_phase("lower", *args, 0), 32)
        self.assertEqual(vertical_phase("lower", *args, 0x0010), 160)

    def test_negative_offset_and_non_power_of_two_period(self):
        phase = vertical_phase("solid", 0, 96, 0, 0, 72, -17, 0)
        self.assertEqual(phase, 55 * 256 // 72)

    def test_rejects_unknown_wall_kind(self):
        with self.assertRaises(ValueError):
            vertical_phase("middle", 0, 0, 0, 0, 64, 0, 0)

    def test_half_row_phase_is_view_independent(self):
        for height in (12, 14):
            for phase in range(256):
                row, half = projected_half_phase(phase, height)
                self.assertGreaterEqual(row, 0)
                self.assertLess(row, height)
                self.assertIn(half, (0, 1))
                expected = ((phase * height + 64) % (height * 256)) // 128
                self.assertEqual((row << 1) | half, expected)


if __name__ == "__main__":
    unittest.main()
