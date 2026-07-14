import os
import hashlib
import unittest

from tools.tilegen import build_weapon
from tools.wadlib import Wad, decode_picture


@unittest.skipUnless(os.path.exists("Doom1.WAD"), "Doom1.WAD not available")
class WeaponSpriteTest(unittest.TestCase):
    def test_picture_decode_and_sprite_budget(self):
        width, height, left, top, pixels = decode_picture(Wad("Doom1.WAD"),
                                                          "PISGA0")
        self.assertEqual((width, height, left, top), (57, 62, -126, -106))
        self.assertEqual(sum(pixel is not None for row in pixels for pixel in row),
                         2084)

        bank, oam = build_weapon("Doom1.WAD")
        self.assertEqual(len(bank), 4096)
        self.assertEqual(len(oam), 36 * 4)
        self.assertEqual(max(oam[1::4]) + 1, 36)
        self.assertEqual(sum(any(bank[i:i + 16])
                             for i in range(0, len(bank), 16)), 36)
        self.assertEqual(hashlib.sha256(bank + bytes(oam)).hexdigest(),
                         "5a4956f70805f7234b56c2de0d6a9222c8f5da192caf02ec3431240f815c0c9b")

        scanlines = [0] * 160
        for y, tile, attr, x in zip(oam[0::4], oam[1::4],
                                    oam[2::4], oam[3::4]):
            self.assertLess(tile, 64)
            self.assertEqual(attr, 0)
            self.assertGreaterEqual(x, 104)
            self.assertLessEqual(x, 144)
            self.assertGreaterEqual(y + 1, 96)
            self.assertLessEqual(y + 8, 159)
            for line in range(y + 1, y + 9):
                scanlines[line] += 1
        self.assertEqual(max(scanlines), 6)


if __name__ == "__main__":
    unittest.main()
