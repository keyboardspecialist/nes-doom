import os
import tempfile
import unittest

from tools.mapconv import build_micro, convert_wad, emit_map


class MapThingTest(unittest.TestCase):
    def test_emit_map_optional_and_grouped_things(self):
        args = build_micro()
        with tempfile.TemporaryDirectory() as tmp:
            empty_path = os.path.join(tmp, "empty.s")
            emit_map(empty_path, *args)
            with open(empty_path) as source:
                empty = source.read()
            self.assertIn("MAP_THING_COUNT = 0", empty)
            self.assertIn("ss_thing_first:", empty)
            self.assertIn("thing_kind:\n    ; empty", empty)

            groups = [[] for _ in args[3]]
            groups[0] = [(0x1234, 0x5678, 2)]
            groups[2] = [(0x9ABC, 0xDEF0, 0), (0x1111, 0x2222, 1)]
            grouped_path = os.path.join(tmp, "grouped.s")
            emit_map(grouped_path, *args, things=groups)
            with open(grouped_path) as source:
                grouped = source.read()
            self.assertIn("MAP_THING_COUNT = 3", grouped)
            self.assertIn("ss_thing_first:\n    .byte $00, $01, $01, $03, $03, $03", grouped)
            self.assertIn("ss_thing_count:\n    .byte $01, $00, $02, $00, $00, $00", grouped)
            self.assertIn("thing_x_lo:\n    .byte $34, $BC, $11", grouped)
            self.assertIn("thing_x_hi:\n    .byte $12, $9A, $11", grouped)
            self.assertIn("thing_y_lo:\n    .byte $78, $F0, $22", grouped)
            self.assertIn("thing_y_hi:\n    .byte $56, $DE, $22", grouped)
            self.assertIn("thing_kind:\n    .byte $02, $00, $01", grouped)

    @unittest.skipUnless(os.path.exists("Doom1.WAD"), "Doom1.WAD not available")
    def test_e1m1_pickups_are_filtered_transformed_and_grouped(self):
        args, _texinfo = convert_wad("Doom1.WAD", "E1M1")
        groups = args[-1]
        self.assertEqual(len(groups), len(args[3]))
        self.assertEqual(sum(map(len, groups)), 16)
        self.assertEqual([sum(thing[2] == kind for group in groups for thing in group)
                          for kind in range(5)], [6, 6, 1, 3, 0])
        self.assertEqual([(i, group) for i, group in enumerate(groups) if group], [
            (9, [(17613, 11162, 2)]),
            (28, [(6144, 11469, 1), (5734, 11469, 1)]),
            (29, [(6861, 10854, 0)]),
            (30, [(6861, 12083, 0)]),
            (32, [(6554, 12493, 0)]),
            (33, [(6554, 10445, 0)]),
            (37, [(10650, 9626, 0)]),
            (41, [(14336, 9626, 0)]),
            (44, [(14336, 11264, 3)]),
            (46, [(11469, 10854, 3)]),
            (51, [(10650, 13107, 1)]),
            (53, [(12186, 13517, 1), (13312, 13517, 3)]),
            (63, [(8704, 10240, 1)]),
            (66, [(8704, 12698, 1)]),
        ])

    @unittest.skipUnless(os.path.exists("Doom1.WAD"), "Doom1.WAD not available")
    def test_full_e1m1_uses_banked_16_bit_geometry(self):
        args, _texinfo = convert_wad("Doom1.WAD", "E1M1", full=True)
        self.assertEqual([len(args[i]) for i in range(5)],
                         [533, 816, 236, 237, 85])
        groups = args[-1]
        self.assertEqual(sum(map(len, groups)), 48)
        self.assertEqual([sum(thing[2] == kind for group in groups for thing in group)
                          for kind in range(5)], [12, 25, 1, 6, 4])
        flattened = [(ss, thing) for ss, group in enumerate(groups) for thing in group]
        self.assertEqual([(i, ss) for i, (ss, thing) in enumerate(flattened)
                          if thing[2] == 4], [(18, 147), (19, 147), (26, 170), (35, 201)])
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "full.s")
            emit_map(path, *args, full=True)
            with open(path) as source:
                full = source.read()
        self.assertIn("SEG_BANK_SPLIT = 682", full)
        self.assertIn('.segment "MAPSEG0"', full)
        self.assertIn('.segment "MAPSEG1"', full)
        self.assertIn('.segment "MAPGEOM"', full)
        self.assertIn("MONSTER_COUNT = 4", full)
        self.assertIn("monster_thing_idx:\n    .byte $12, $13, $1A, $23", full)
        self.assertIn("monster_spawn_ss:\n    .byte $93, $93, $AA, $C9", full)


if __name__ == "__main__":
    unittest.main()
