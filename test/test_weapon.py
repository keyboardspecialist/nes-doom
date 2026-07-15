import os
import tempfile
import unittest
from itertools import accumulate
from pathlib import Path

from tools.tilegen import (
    BARREL_EXPLOSION_FRAMES,
    BARREL_EXP_CLASS_HEIGHTS,
    WEAPON_FRAMES,
    WEAPON_PATTERN_BASE,
    WORLD_PATTERN_CAP,
    build_hud,
    build_sprites,
    sprite_tile_byte,
    write_luts,
)
from tools.wadlib import Wad, decode_picture


@unittest.skipUnless(os.path.exists("Doom1.WAD"), "Doom1.WAD not available")
class SpriteTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.patterns, cls.meta = build_sprites("Doom1.WAD")
        cls.hud = build_hud("Doom1.WAD", [], 61)

    @staticmethod
    def pattern_from_tile(tile):
        return (tile >> 1) | ((tile & 1) << 7)

    def weapon_pattern(self, frame, logical_pattern):
        local = logical_pattern - WEAPON_PATTERN_BASE
        self.assertGreaterEqual(local, 0)
        self.assertLess(local, self.meta["weapon_frame_pattern_count"][frame])
        offset = 6 * 1024 + frame * 2 * 1024 + local * 32
        return self.patterns[offset:offset + 32]

    def test_picture_decode_and_four_weapon_frames(self):
        wad = Wad("Doom1.WAD")
        expected_pictures = {
            "PISGA0": (57, 62, -126, -106),
            "PISGB0": (79, 82, -104, -86),
            "PISGC0": (66, 81, -119, -87),
            "PISFA0": (41, 38, -140, -66),
        }
        for name, expected in expected_pictures.items():
            self.assertEqual(decode_picture(wad, name)[:4], expected)
        pixels = decode_picture(wad, "PISGA0")[4]
        self.assertEqual(sum(pixel is not None for row in pixels for pixel in row),
                         2084)
        self.assertEqual(WEAPON_FRAMES, (
            ("PISGA0",),
            ("PISGB0", "PISFA0"),
            ("PISGC0",),
            ("PISGB0",),
        ))

        meta = self.meta
        oam = meta["weapon_oam"]
        self.assertEqual(len(self.patterns), 16384)
        self.assertEqual(meta["world_pattern_count"], 188)
        self.assertLessEqual(meta["world_pattern_count"], WORLD_PATTERN_CAP)
        self.assertEqual(meta["weapon_frame_pattern_count"], [17, 20, 17, 17])
        self.assertEqual(meta["weapon_chr_page_lo"], [6, 8, 10, 12])
        self.assertEqual(meta["weapon_chr_page_hi"], [1, 1, 1, 1])
        self.assertEqual(meta["weapon_frame_first"], [0, 17, 37, 54])
        self.assertEqual(meta["weapon_frame_count"], [17, 20, 17, 17])
        self.assertEqual(meta["weapon_frame_first"], list(accumulate(
            [0] + meta["weapon_frame_count"][:-1])))
        self.assertEqual(max(meta["weapon_frame_count"]), 20)
        self.assertEqual(len(oam), sum(meta["weapon_frame_count"]) * 4)
        self.assertEqual(meta["sprite_palettes"][:4], [0x0F, 0x00, 0x08, 0x27])

        expected_bounds = [
            (96, 144, 112, 159),
            (88, 136, 96, 159),
            (96, 136, 96, 159),
            (88, 136, 96, 159),
        ]
        envelope = [0] * 160
        for frame, (first, count) in enumerate(zip(
                meta["weapon_frame_first"], meta["weapon_frame_count"])):
            records = oam[first * 4:(first + count) * 4]
            scanlines = [0] * 160
            xs, tops, bottoms = [], [], []
            for y, tile, attr, x in zip(records[0::4], records[1::4],
                                        records[2::4], records[3::4]):
                pattern = self.pattern_from_tile(tile)
                self.assertEqual(tile, sprite_tile_byte(pattern))
                self.assertGreaterEqual(pattern, WEAPON_PATTERN_BASE)
                self.assertTrue(any(self.weapon_pattern(frame, pattern)))
                self.assertEqual(attr, 0)
                self.assertGreaterEqual(x, 0)
                self.assertLessEqual(x + 7, 255)
                self.assertGreaterEqual(y + 1, 0)
                self.assertLessEqual(y + 16, 159)
                xs.append(x)
                tops.append(y + 1)
                bottoms.append(y + 16)
                for line in range(y + 1, y + 17):
                    scanlines[line] += 1
            self.assertEqual(
                (min(xs), max(xs), min(tops), max(bottoms)),
                expected_bounds[frame])
            self.assertLessEqual(max(scanlines), 8)
            envelope = [max(a, b) for a, b in zip(envelope, scanlines)]

        self.assertEqual(len(meta["weapon_scan_count"]), 160)
        self.assertEqual(meta["weapon_scan_count"], envelope)
        self.assertEqual(max(envelope), 7)
        self.assertEqual(envelope[:96], [0] * 96)
        self.assertEqual(envelope[96:128], [4] * 32)
        self.assertEqual(envelope[128:144], [6] * 16)
        self.assertEqual(envelope[144:], [7] * 16)

    def test_pattern_mapping_and_world_metasprites(self):
        self.assertEqual([sprite_tile_byte(p) for p in (0, 1, 127, 128, 255)],
                         [0, 2, 254, 1, 255])
        patterns, meta = self.patterns, self.meta
        self.assertEqual(meta["world_kind_meta_base"], [0, 6, 18, 21, 27])
        self.assertEqual(meta["world_kind_frame_mask"], [1, 3, 0, 1, 7])
        self.assertEqual(meta["world_kind_world_h"], [7, 6, 7, 13, 22])
        self.assertEqual(len(meta["world_meta_first"]), 51)
        self.assertEqual(len(meta["world_meta_count"]), 51)

        total = len(meta["world_sprite_tile"])
        self.assertEqual(total, 227)
        self.assertEqual(meta["world_meta_first"],
                         list(accumulate([0] + meta["world_meta_count"][:-1])))
        for name in ("world_sprite_dx", "world_sprite_dy", "world_sprite_attr"):
            self.assertEqual(len(meta[name]), total)
        self.assertTrue(all((v if v < 128 else v - 256) % 8 == 0
                            for v in meta["world_sprite_dx"]))
        self.assertTrue(all((v if v < 128 else v - 256) % 16 == 0
                            for v in meta["world_sprite_dy"]))
        self.assertTrue(all(meta["world_meta_count"]))

        expected_attrs = [1, 2, 3, 0, 0]
        for kind, base in enumerate(meta["world_kind_meta_base"]):
            end = (meta["world_kind_meta_base"] + [51])[kind + 1]
            colors = set()
            for index in range(base, end):
                first = meta["world_meta_first"][index]
                count = meta["world_meta_count"][index]
                self.assertEqual(set(meta["world_sprite_attr"][first:first + count]),
                                 {expected_attrs[kind]})
                for tile in meta["world_sprite_tile"][first:first + count]:
                    pattern = self.pattern_from_tile(tile)
                    data = patterns[pattern * 32:(pattern + 1) * 32]
                    for half in (0, 16):
                        for y in range(8):
                            for x in range(8):
                                color = ((data[half + y] >> (7 - x)) & 1)
                                color |= ((data[half + 8 + y] >> (7 - x)) & 1) << 1
                                if color:
                                    colors.add(color)
            self.assertEqual(colors, {1, 2, 3})

        # Living/initial-death close frames use a real 32px bake. Fallen and
        # corpse frames keep the 16px geometry to stay within scanline limits.
        zombie_base = meta["world_kind_meta_base"][4]
        close_counts = [7, 7, 4, 4, 7, 4, 6, 6]
        for frame in range(8):
            entries = [zombie_base + frame * 3 + scale for scale in (1, 2)]
            slices = []
            for entry in entries:
                first = meta["world_meta_first"][entry]
                count = meta["world_meta_count"][entry]
                slices.append(tuple(tuple(meta[name][first:first + count])
                                    for name in ("world_sprite_dx", "world_sprite_dy",
                                                 "world_sprite_tile", "world_sprite_attr")))
            self.assertEqual(meta["world_meta_count"][entries[1]], close_counts[frame])
            if frame < 5:
                self.assertNotEqual(slices[0], slices[1])
                first = meta["world_meta_first"][entries[1]]
                count = meta["world_meta_count"][entries[1]]
                dys = {value if value < 128 else value - 256
                       for value in meta["world_sprite_dy"][first:first + count]}
                self.assertEqual(dys, {-32, -16})
            else:
                self.assertEqual(slices[0], slices[1])
        for tile in meta["world_sprite_tile"]:
            pattern = self.pattern_from_tile(tile)
            self.assertLess(pattern, meta["pattern_count"])
            self.assertTrue(any(patterns[pattern * 32:(pattern + 1) * 32]))

    def test_barrel_explosion_metasprites(self):
        wad = Wad("Doom1.WAD")
        expected_pictures = {
            "BEXPA0": (23, 32, 10, 28),
            "BEXPB0": (23, 31, 10, 27),
            "BEXPC0": (40, 36, 19, 32),
            "BEXPD0": (56, 50, 27, 46),
            "BEXPE0": (60, 53, 29, 49),
        }
        self.assertEqual(BARREL_EXPLOSION_FRAMES, tuple(expected_pictures))
        self.assertEqual(BARREL_EXP_CLASS_HEIGHTS, (8, 16))
        for name, expected in expected_pictures.items():
            self.assertEqual(decode_picture(wad, name)[:4], expected)

        meta = self.meta
        counts = [(2, 2), (2, 2), (2, 4), (2, 4), (2, 4)]
        flat_counts = [count for frame in counts for count in frame]
        self.assertEqual(meta["barrel_exp_meta_count"], flat_counts)
        self.assertEqual(meta["barrel_exp_meta_first"], list(accumulate(
            [0] + flat_counts[:-1])))
        self.assertEqual(len(meta["barrel_exp_meta_first"]), 10)

        total = sum(flat_counts)
        self.assertEqual(total, 26)
        for name in ("barrel_exp_dx", "barrel_exp_dy", "barrel_exp_tile",
                     "barrel_exp_attr"):
            self.assertEqual(len(meta[name]), total)
        self.assertEqual(set(meta["barrel_exp_attr"]), {0})
        self.assertTrue(all((v if v < 128 else v - 256) % 8 == 0
                            for v in meta["barrel_exp_dx"]))
        self.assertTrue(all((v if v < 128 else v - 256) % 16 == 0
                            for v in meta["barrel_exp_dy"]))

        colors = set()
        referenced_patterns = set()
        for frame in range(len(BARREL_EXPLOSION_FRAMES)):
            for scale in range(len(BARREL_EXP_CLASS_HEIGHTS)):
                index = frame * 2 + scale
                first = meta["barrel_exp_meta_first"][index]
                count = meta["barrel_exp_meta_count"][index]
                self.assertEqual(count, counts[frame][scale])
                for tile in meta["barrel_exp_tile"][first:first + count]:
                    pattern = self.pattern_from_tile(tile)
                    referenced_patterns.add(pattern)
                    self.assertEqual(tile, sprite_tile_byte(pattern))
                    self.assertLess(pattern, meta["pattern_count"])
                    data = self.patterns[pattern * 32:(pattern + 1) * 32]
                    self.assertTrue(any(data))
                    for half in (0, 16):
                        for y in range(8):
                            for x in range(8):
                                color = ((data[half + y] >> (7 - x)) & 1)
                                color |= ((data[half + 8 + y]
                                          >> (7 - x)) & 1) << 1
                                if color:
                                    colors.add(color)
        self.assertEqual(len(referenced_patterns), 26)
        self.assertEqual(colors, {1, 2, 3})

    def test_dynamic_hud_glyphs_and_initial_layout(self):
        tiles, hud_nt, hud_ex, glyph_top, glyph_bottom = self.hud
        self.assertEqual(len(tiles), 132)
        self.assertLessEqual(len(tiles), 256)
        self.assertEqual((len(hud_nt), len(hud_ex)), (160, 160))
        self.assertEqual((len(glyph_top), len(glyph_bottom)), (12, 12))
        self.assertTrue(all(0 <= tile < len(tiles)
                            for tile in glyph_top + glyph_bottom))

        blank = 10
        self.assertFalse(any(tiles[glyph_top[blank]]))
        self.assertFalse(any(tiles[glyph_bottom[blank]]))
        for glyph in list(range(10)) + [11]:
            self.assertTrue(any(tiles[glyph_top[glyph]]))
            self.assertTrue(any(tiles[glyph_bottom[glyph]]))

        fields = (
            (2, (10, 5, 0)),
            (6, (1, 0, 0, 11)),
            (20, (10, 10, 0, 11)),
        )
        field_cells = set()
        for col, glyphs in fields:
            for offset, glyph in enumerate(glyphs):
                for row, table in ((1, glyph_top), (2, glyph_bottom)):
                    cell = row * 32 + col + offset
                    field_cells.add(cell)
                    self.assertEqual(hud_nt[cell], table[glyph])
                    self.assertEqual(hud_ex[cell], 61 | (1 << 6))

        nonblank_tiles = set(glyph_top[:10] + glyph_bottom[:10]
                             + [glyph_top[11], glyph_bottom[11]])
        self.assertTrue(all(index in field_cells
                            for index, tile in enumerate(hud_nt)
                            if tile in nonblank_tiles))

    def test_generated_lut_contract_and_segments(self):
        hud = self.hud[1:]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "luts.s"
            write_luts(path, [], [], 0, [], [], [0] * 16,
                       hud=hud, sprite_meta=self.meta)
            source = path.read_text()

        exports = "\n".join(line for line in source.splitlines()
                            if line.startswith(".export "))
        for symbol in ("hud_glyph_top", "hud_glyph_bottom",
                       "WEAPON_FRAME_COUNT", "WEAPON_SLOT_CAP",
                       "WEAPON_SPRITE_COUNT",
                       "weapon_frame_first", "weapon_frame_count",
                       "weapon_frame_pattern_count", "weapon_chr_page_lo",
                       "weapon_chr_page_hi",
                       "weapon_scan_count", "weapon_oam",
                       "barrel_exp_meta_first", "barrel_exp_meta_count",
                       "barrel_exp_dx", "barrel_exp_dy",
                       "barrel_exp_tile", "barrel_exp_attr"):
            self.assertIn(symbol, exports)
        for symbol in ("WEAPON_FRAME_COUNT", "WEAPON_SLOT_CAP",
                       "WEAPON_SPRITE_COUNT"):
            self.assertIn(f".export {symbol} : absolute", source)
        self.assertIn("WEAPON_FRAME_COUNT = 4", source)
        self.assertIn("WEAPON_SLOT_CAP = 20", source)
        self.assertIn("WEAPON_SPRITE_COUNT = 17", source)
        self.assertIn("WEAPON_PATTERN_BASE = 192", source)
        self.assertIn("WORLD_PATTERN_COUNT = 188", source)

        lut00 = source.index('.segment "LUT00"')
        lut01 = source.index('.segment "LUT01"')
        fixed = source.index('.segment "FIXED"')
        self.assertLess(lut00, source.index("hud_glyph_top:"))
        self.assertLess(source.index("hud_glyph_bottom:"), lut01)
        self.assertLess(lut01, source.index("sprite_palettes:"))
        self.assertLess(source.index("world_sprite_attr:"), fixed)
        for symbol in ("barrel_exp_meta_first", "barrel_exp_meta_count",
                       "barrel_exp_dx", "barrel_exp_dy",
                       "barrel_exp_tile", "barrel_exp_attr"):
            self.assertLess(lut01, source.index(f"{symbol}:"))
            self.assertLess(source.index(f"{symbol}:"), fixed)
        self.assertLess(fixed, source.index("weapon_frame_first:"))
        self.assertLess(fixed, source.index("weapon_scan_count:"))
        self.assertLess(fixed, source.index("weapon_oam:"))


if __name__ == "__main__":
    unittest.main()
