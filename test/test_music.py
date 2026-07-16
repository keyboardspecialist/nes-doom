import os
import struct
import tempfile
import unittest
from collections import Counter
from pathlib import Path

from tools.musicgen import (
    LOOP_FRAMES,
    compile_score,
    parse_mus,
    tick_to_frame,
    write_assembly,
)
from tools.wadlib import Wad


def synthetic_mus(score):
    return (b"MUS\x1a" + struct.pack("<6H", len(score), 16, 1, 0, 0, 0)
            + score)


class MusParserTest(unittest.TestCase):
    def test_events_velocity_and_delay(self):
        # Program 30, note 60/velocity 100, delay 140, release, finish.
        score = bytes((0x40, 0, 30, 0x90, 0x80 | 60, 100,
                       0x81, 0x0C, 0x00, 60, 0x60))
        mus = parse_mus(synthetic_mus(score))
        self.assertEqual(mus["duration_ticks"], 140)
        self.assertEqual([event[2] for event in mus["events"]], [4, 1, 0, 6])
        self.assertEqual(mus["events"][1][4:6], (60, 100))
        self.assertEqual(tick_to_frame(140), 60)

    def test_rejects_invalid_data(self):
        for data in (b"", b"MUS\x1a", synthetic_mus(bytes((0x90, 0xBC)))):
            with self.assertRaises(ValueError):
                parse_mus(data)


@unittest.skipUnless(os.path.exists("Doom1.WAD"), "Doom1.WAD not available")
class E1M1MusicTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mus = parse_mus(Wad("Doom1.WAD").lump("D_E1M1"))
        cls.compiled = compile_score(cls.mus)

    def test_score_contract(self):
        mus = self.mus
        self.assertEqual((mus["score_len"], mus["score_start"]), (17237, 46))
        self.assertEqual((mus["primary"], mus["secondary"]), (3, 0))
        self.assertEqual(mus["duration_ticks"], 13440)
        self.assertEqual(tick_to_frame(mus["duration_ticks"]), LOOP_FRAMES)
        counts = Counter(event[2] for event in mus["events"])
        self.assertEqual(counts, {0: 2332, 1: 2332, 2: 1146, 4: 15, 6: 1})
        self.assertEqual(mus["instruments"],
                         [29, 30, 34, 136, 138, 140, 141, 145, 146,
                          147, 149, 150, 151, 153, 157])

    def test_bounded_hardware_stream(self):
        compiled = self.compiled
        self.assertEqual(len(compiled["records"]), 2045)
        self.assertEqual(len(compiled["stream"]), 7259)
        self.assertEqual(compiled["bank_bytes"], 7985)
        self.assertLessEqual(compiled["bank_bytes"], 8192)
        self.assertEqual(max(count for _frame, _data, count in compiled["records"]), 6)
        self.assertEqual({voice: len(states) for voice, states in compiled["tables"].items()},
                         {0: 79, 1: 81, 2: 6, 4: 70, 5: 120})
        self.assertEqual(compiled["recipes"],
                         [(2, 0x18), (4, 0x48), (4, 0x68), (6, 0x28),
                          (7, 0x38), (12, 0x38), (15, 0x28)])
        self.assertTrue(all(period < 0x80 for period, _length
                            in compiled["recipes"]))

        frames = [frame for frame, _data, _count in compiled["records"]]
        gaps = [b - a for a, b in zip(frames, frames[1:])]
        gaps.append(LOOP_FRAMES - frames[-1] + frames[0])
        self.assertTrue(all(1 <= gap <= 255 for gap in gaps))
        self.assertEqual(sum(gaps), LOOP_FRAMES)

    def test_deterministic_noise_only_assembly(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.s"
            second = Path(directory) / "second.s"
            write_assembly(first, self.compiled)
            write_assembly(second, compile_score(self.mus))
            source = first.read_bytes()
            self.assertEqual(source, second.read_bytes())
        self.assertIn(b'.segment "MUSIC0"', source)
        self.assertNotIn(b'DPCM', source)
        self.assertIn(b"MUSIC_BANK_BYTES = 7985", source)


if __name__ == "__main__":
    unittest.main()
