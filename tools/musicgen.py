#!/usr/bin/env python3
"""Compile Doom MUS into bounded 60 Hz NES APU/MMC5 commands."""
import argparse
import struct
from collections import defaultdict

try:
    import wadlib
except ModuleNotFoundError:
    from tools import wadlib


CPU_HZ = 1789773
MUS_HZ = 140
FRAME_HZ = 60
LOOP_FRAMES = 5760

VOICE_APU_P1 = 0
VOICE_APU_P2 = 1
VOICE_TRI = 2
VOICE_PERC = 3
VOICE_MMC5_P1 = 4
VOICE_MMC5_P2 = 5


def parse_mus(data):
    if len(data) < 16 or data[:4] != b"MUS\x1a":
        raise ValueError("invalid MUS header")
    score_len, score_start, primary, secondary, inst_count, _dummy = \
        struct.unpack_from("<6H", data, 4)
    if score_start < 16 + inst_count * 2 or score_start + score_len > len(data):
        raise ValueError("invalid MUS bounds")
    instruments = list(struct.unpack_from(
        "<" + "H" * inst_count, data, 16)) if inst_count else []
    events = []
    pos = score_start
    end = score_start + score_len
    tick = 0
    order = 0
    finished = False
    while pos < end:
        desc = data[pos]
        pos += 1
        kind = (desc >> 4) & 7
        channel = desc & 15
        last = bool(desc & 0x80)
        a = b = None
        if kind == 0:
            if pos >= end:
                raise ValueError("truncated release")
            a = data[pos] & 0x7F
            pos += 1
        elif kind == 1:
            if pos >= end:
                raise ValueError("truncated play")
            note = data[pos]
            pos += 1
            a = note & 0x7F
            if note & 0x80:
                if pos >= end:
                    raise ValueError("truncated velocity")
                b = data[pos] & 0x7F
                pos += 1
        elif kind in (2, 3):
            if pos >= end:
                raise ValueError("truncated event")
            a = data[pos]
            pos += 1
        elif kind == 4:
            if pos + 2 > end:
                raise ValueError("truncated controller")
            a, b = data[pos], data[pos + 1]
            pos += 2
        elif kind == 6:
            finished = True
        else:
            raise ValueError(f"unsupported MUS event {kind}")
        events.append((tick, order, kind, channel, a, b))
        order += 1
        if finished:
            break
        if last:
            delay = 0
            while True:
                if pos >= end:
                    raise ValueError("truncated MUS delay")
                value = data[pos]
                pos += 1
                delay = (delay << 7) | (value & 0x7F)
                if not value & 0x80:
                    break
            tick += delay
    if not finished:
        raise ValueError("MUS score has no finish event")
    return {
        "events": events,
        "duration_ticks": tick,
        "score_len": score_len,
        "score_start": score_start,
        "primary": primary,
        "secondary": secondary,
        "instruments": instruments,
    }


def tick_to_frame(tick):
    return (3 * tick + 3) // 7


def pulse_period(note, bend=128):
    semitones = (bend - 128) / 64.0
    frequency = 440.0 * (2.0 ** ((note + semitones - 69) / 12.0))
    return max(8, min(0x7FF, round(CPU_HZ / (16.0 * frequency) - 1.0)))


def triangle_period(note):
    frequency = 440.0 * (2.0 ** ((note - 69) / 12.0))
    return max(2, min(0x7FF, round(CPU_HZ / (32.0 * frequency) - 1.0)))


def pulse_volume(velocity, channel_volume):
    value = (15 * velocity * channel_volume + 127 * 127 // 2) // (127 * 127)
    return max(1, min(15, value))


def _percussion_recipe(notes):
    note_set = {note for note, _velocity, _order in notes}
    snare = bool(note_set & {38, 40})
    kick = 36 in note_set
    tom = bool(note_set & {41, 45, 47, 50})
    crash = bool(note_set & {49, 57})
    ride = 51 in note_set
    bell = 53 in note_set
    hat = 46 in note_set

    if crash:
        noise = 0x04
        length = 0x68
    elif snare:
        noise = 0x07
        length = 0x38
    elif kick:
        noise = 0x0F
        length = 0x28
    elif tom:
        noise = 0x0C
        length = 0x38
    elif bell:
        noise = 0x06
        length = 0x28
    elif ride:
        noise = 0x04
        length = 0x48
    elif hat:
        noise = 0x02
        length = 0x18
    else:
        noise = 0
        length = 0
    velocity = max((velocity for _note, velocity, _order in notes), default=0)
    volume = min(12, (15 * velocity + 63) // 127) if noise else 0
    return (noise, length), volume


def compile_score(mus):
    frame_events = defaultdict(list)
    for event in mus["events"]:
        frame_events[tick_to_frame(event[0])].append(event)

    channel_volume = [127] * 16
    last_velocity = [127] * 16
    bend = [128] * 16
    slots = {0: [None, None], 1: [None, None], 2: [None]}
    voice_map = {0: (VOICE_APU_P1, VOICE_MMC5_P1),
                 1: (VOICE_APU_P2, VOICE_MMC5_P2),
                 2: (VOICE_TRI,)}
    changes = defaultdict(dict)
    percussion = defaultdict(list)

    for frame in sorted(frame_events):
        for _tick, order, kind, channel, a, b in frame_events[frame]:
            if frame >= LOOP_FRAMES:
                continue
            if kind == 4:
                if a == 3:
                    channel_volume[channel] = b
                    if channel in slots:
                        for index, active in enumerate(slots[channel]):
                            if active is not None and channel != 2:
                                note, velocity = active
                                period = pulse_period(note, bend[channel])
                                volume = pulse_volume(velocity, b)
                                changes[frame][voice_map[channel][index]] = \
                                    ((period, volume), False)
                continue
            if kind == 2:
                bend[channel] = a
                if channel in (0, 1):
                    for index, active in enumerate(slots[channel]):
                        if active is not None:
                            note, velocity = active
                            state = (pulse_period(note, a),
                                     pulse_volume(velocity, channel_volume[channel]))
                            changes[frame][voice_map[channel][index]] = (state, False)
                continue
            if kind == 1:
                if b is not None:
                    last_velocity[channel] = b
                velocity = last_velocity[channel]
                if channel == 15:
                    percussion[frame].append((a, velocity, order))
                    continue
                if channel not in slots:
                    continue
                try:
                    index = slots[channel].index(None)
                except ValueError as exc:
                    raise ValueError(f"channel {channel} exceeds allocated polyphony") from exc
                slots[channel][index] = (a, velocity)
                if channel == 2:
                    state = (triangle_period(a),)
                else:
                    state = (pulse_period(a, bend[channel]),
                             pulse_volume(velocity, channel_volume[channel]))
                changes[frame][voice_map[channel][index]] = (state, True)
                continue
            if kind == 0 and channel in slots:
                index = next((i for i, active in enumerate(slots[channel])
                              if active is not None and active[0] == a), None)
                if index is None:
                    raise ValueError(f"release of inactive note {a} on channel {channel}")
                slots[channel][index] = None
                changes[frame][voice_map[channel][index]] = (None, False)

    recipes = set()
    percussion_states = {}
    for frame, notes in percussion.items():
        recipe, volume = _percussion_recipe(notes)
        recipes.add(recipe)
        percussion_states[frame] = (recipe, volume)
    recipe_list = sorted(recipes)
    if len(recipe_list) > 16:
        raise ValueError("percussion requires more than 16 recipes")
    recipe_ids = {recipe: index for index, recipe in enumerate(recipe_list)}
    for frame, (recipe, volume) in percussion_states.items():
        changes[frame][VOICE_PERC] = ((recipe_ids[recipe], volume), True)

    # A canonical all-off record makes cold start and the whole-score loop equal.
    for voice in (VOICE_APU_P1, VOICE_APU_P2, VOICE_TRI,
                  VOICE_MMC5_P1, VOICE_MMC5_P2):
        changes[0].setdefault(voice, (None, False))

    pulse_voices = (VOICE_APU_P1, VOICE_APU_P2, VOICE_MMC5_P1, VOICE_MMC5_P2)
    state_lists = {}
    state_ids = {}
    for voice in pulse_voices:
        states = sorted({state for frame in changes.values()
                         if voice in frame for state, _retrig in [frame[voice]]
                         if state is not None})
        state_lists[voice] = [None] + states
        state_ids[voice] = {state: index + 1 for index, state in enumerate(states)}
        if len(state_lists[voice]) > 128:
            raise ValueError(f"voice {voice} needs too many states")
    tri_states = sorted({state for frame in changes.values()
                         if VOICE_TRI in frame
                         for state, _retrig in [frame[VOICE_TRI]] if state is not None})
    state_lists[VOICE_TRI] = [None] + tri_states
    state_ids[VOICE_TRI] = {state: index + 1 for index, state in enumerate(tri_states)}

    records = []
    frames = sorted(changes)
    for index, frame in enumerate(frames):
        updates = changes[frame]
        mask = sum(1 << voice for voice in updates)
        next_frame = frames[index + 1] if index + 1 < len(frames) else LOOP_FRAMES + frames[0]
        gap = next_frame - frame
        if not 1 <= gap <= 255:
            raise ValueError(f"record gap {gap} is not encodable")
        encoded = bytearray()
        delay_code = gap - 1 if gap <= 3 else 3
        encoded.append((delay_code << 6) | mask)
        if gap > 3:
            encoded.append(gap)
        for voice in range(6):
            if not mask & (1 << voice):
                continue
            state, retrigger = updates[voice]
            if voice == VOICE_PERC:
                recipe, volume = state
                encoded.append((volume << 4) | recipe)
            else:
                state_index = 0 if state is None else state_ids[voice][state]
                encoded.append(state_index | (0x80 if retrigger and state_index else 0))
        records.append((frame, bytes(encoded), len(updates)))

    stream = b"".join(record for _frame, record, _count in records)
    tables = {}
    for voice in pulse_voices:
        tables[voice] = [(0, 0)] + [(period & 0xFF,
                                     ((volume & 15) << 3) | (period >> 8))
                                    for period, volume in state_lists[voice][1:]]
    tables[VOICE_TRI] = [(0, 0)] + [(period & 0xFF, period >> 8)
                                          for (period,) in state_lists[VOICE_TRI][1:]]
    total = len(stream) + sum(len(values) * 2 for values in tables.values()) \
        + len(recipe_list) * 2
    if total > 8192:
        raise ValueError(f"compiled music bank is {total} bytes")
    return {
        "stream": stream,
        "records": records,
        "tables": tables,
        "recipes": recipe_list,
        "bank_bytes": total,
        "loop_frames": LOOP_FRAMES,
    }


def _write_bytes(out, label, values):
    out.write(f"{label}:\n")
    for offset in range(0, len(values), 16):
        out.write("    .byte " + ", ".join(
            f"${value:02X}" for value in values[offset:offset + 16]) + "\n")


def write_assembly(path, compiled):
    names = {VOICE_APU_P1: "apu_p1", VOICE_APU_P2: "apu_p2",
             VOICE_TRI: "tri", VOICE_MMC5_P1: "mmc5_p1",
             VOICE_MMC5_P2: "mmc5_p2"}
    with open(path, "w") as out:
        out.write("; GENERATED by tools/musicgen.py - do not edit\n")
        out.write(".export music_stream, music_stream_end\n")
        for name in names.values():
            out.write(f".export music_{name}_lo, music_{name}_meta\n")
        out.write(".export music_noise_period, music_noise_length\n")
        out.write(".export MUSIC_BANK_BYTES : absolute\n")
        out.write(f"MUSIC_BANK_BYTES = {compiled['bank_bytes']}\n")
        out.write('.segment "MUSIC0"\n')
        _write_bytes(out, "music_stream", compiled["stream"])
        out.write("music_stream_end:\n")
        for voice in (VOICE_APU_P1, VOICE_APU_P2, VOICE_TRI,
                      VOICE_MMC5_P1, VOICE_MMC5_P2):
            values = compiled["tables"][voice]
            _write_bytes(out, f"music_{names[voice]}_lo", [value[0] for value in values])
            _write_bytes(out, f"music_{names[voice]}_meta", [value[1] for value in values])
        _write_bytes(out, "music_noise_period", [value[0] for value in compiled["recipes"]])
        _write_bytes(out, "music_noise_length", [value[1] for value in compiled["recipes"]])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wad", required=True)
    parser.add_argument("--lump", default="D_E1M1")
    parser.add_argument("-o", "--out", required=True)
    args = parser.parse_args()
    wad = wadlib.Wad(args.wad)
    mus = parse_mus(wad.lump(args.lump))
    compiled = compile_score(mus)
    write_assembly(args.out, compiled)
    print(f"music: {len(mus['events'])} events, {mus['duration_ticks']} ticks, "
          f"{len(compiled['records'])} records, {compiled['bank_bytes']} bytes")


if __name__ == "__main__":
    main()
