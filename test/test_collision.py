import unittest

import os

from tools.mapconv import build_micro, convert_wad, line_blocks


class CollisionMetadataTest(unittest.TestCase):
    def test_wad_portal_clearance_and_direction(self):
        self.assertTrue(line_blocks(0, 0, 128))
        self.assertTrue(line_blocks(1, 0, 128, 0, 128))
        self.assertTrue(line_blocks(0, 0, 128, 0, 32))
        self.assertFalse(line_blocks(0, 0, 128, 16, 128))
        self.assertTrue(line_blocks(0, 0, 128, 32, 128))
        self.assertFalse(line_blocks(0, 64, 192, 0, 128))  # large drop

    def test_micro_segs_pack_blocking_bit(self):
        _verts, segs, _nodes, _ss, _sectors, *_rest = build_micro()
        self.assertTrue(any(seg[4] & 0x80 for seg in segs))
        self.assertTrue(any(not seg[4] & 0x80 for seg in segs))
        self.assertTrue(all((seg[4] & 0x7F) < 16 for seg in segs))

    @unittest.skipUnless(os.path.exists("Doom1.WAD"), "Doom1.WAD not available")
    def test_e1m1_manual_doors_are_annotated(self):
        trimmed, _ = convert_wad("Doom1.WAD", "E1M1")
        full, _ = convert_wad("Doom1.WAD", "E1M1", full=True)
        self.assertEqual(trimmed[10], [(3, 0, 27)])
        self.assertEqual(len(trimmed[11]), 2)
        self.assertEqual(full[10], [
            (4, 0, 27), (68, -10, 18), (76, -10, 18), (81, -10, 18)
        ])
        self.assertEqual(len(full[11]), 8)
        self.assertEqual(sorted(use[2] for use in full[11]), [0, 0, 1, 1, 2, 2, 3, 3])
        self.assertEqual(sum(bool(seg[4] & 0x70) for seg in trimmed[1]), 4)
        self.assertEqual(sum(bool(seg[4] & 0x70) for seg in full[1]), 16)
        self.assertTrue(all((seg[4] & 0x0F) < 16 for seg in full[1]))


if __name__ == "__main__":
    unittest.main()
