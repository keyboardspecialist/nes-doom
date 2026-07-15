import math
import unittest

from tools.tablegen import atan_log_table, log2_mantissa_table


LOG2_MANT = log2_mantissa_table()
ATAN_LOG = atan_log_table()


def base_angle(minimum, maximum):
    """Model the first-octant lookup in src/math.s; None means close fallback."""
    if maximum < 256:
        return None
    while maximum < 0x8000:
        minimum <<= 1
        maximum <<= 1
    if minimum < 0x0100:
        return 0
    exponent = 0
    while minimum < 0x8000:
        minimum <<= 1
        exponent += 1
    difference = (16 * exponent + LOG2_MANT[(maximum >> 8) - 128]
                  - LOG2_MANT[(minimum >> 8) - 128])
    return 0 if difference >= len(ATAN_LOG) else ATAN_LOG[difference]


def ideal_base(minimum, maximum):
    value = math.atan(minimum / maximum) * 128 / math.pi
    return math.floor(value + 0.5)


def atan2_model(dx, dy):
    minimum, maximum = sorted((abs(dx), abs(dy)))
    angle = base_angle(minimum, maximum)
    if angle is None:
        return None
    if abs(dy) > abs(dx):
        angle = 64 - angle
    if dx >= 0 and dy >= 0:
        return angle
    if dx >= 0:
        return (-angle) & 0xFF
    if dy >= 0:
        return (128 - angle) & 0xFF
    return (128 + angle) & 0xFF


class AtanLookupTest(unittest.TestCase):
    def test_table_sizes_and_ranges(self):
        self.assertEqual(len(LOG2_MANT), 128)
        self.assertEqual(len(ATAN_LOG), 102)
        self.assertEqual(LOG2_MANT[0], 0)
        self.assertEqual(LOG2_MANT[-1], 16)
        self.assertEqual(ATAN_LOG[0], 32)
        self.assertEqual(ATAN_LOG[-1], 1)

    def test_close_fallback_and_axes(self):
        self.assertIsNone(atan2_model(255, 0))
        self.assertIsNone(atan2_model(-255, -255))
        self.assertEqual(atan2_model(256, 0), 0)
        self.assertEqual(atan2_model(0, 256), 64)
        self.assertEqual(atan2_model(-256, 0), 128)
        self.assertEqual(atan2_model(0, -256), 192)
        self.assertEqual(atan2_model(32767, 32767), 32)
        self.assertEqual(atan2_model(-32768, -32768), 160)

    def test_first_octant_error_is_at_most_one_bam_unit(self):
        # Exhaust the sensitive near range, then sample every ratio across the
        # full signed magnitude domain. One BAM-high unit is 1.40625 degrees.
        for maximum in range(256, 1025):
            for minimum in range(maximum + 1):
                self.assertLessEqual(
                    abs(base_angle(minimum, maximum)
                        - ideal_base(minimum, maximum)), 1)
        for maximum in range(1025, 32769, 31):
            for ratio in range(513):
                minimum = maximum * ratio // 512
                self.assertLessEqual(
                    abs(base_angle(minimum, maximum)
                        - ideal_base(minimum, maximum)), 1)

    def test_direct_mapped_high_vertex_tags_do_not_alias(self):
        cache = [None] * 8

        def store(index, value):
            cache[(index & 0xFF ^ index >> 8) & 7] = (index, value)

        def load(index):
            entry = cache[(index & 0xFF ^ index >> 8) & 7]
            return entry[1] if entry and entry[0] == index else None

        store(0x0100, 17)
        self.assertEqual(load(0x0100), 17)
        store(0x0108, 23)  # same slot, different full tag
        self.assertIsNone(load(0x0100))
        self.assertEqual(load(0x0108), 23)
        store(0xFFFF, 31)
        self.assertEqual(load(0xFFFF), 31)


if __name__ == "__main__":
    unittest.main()
