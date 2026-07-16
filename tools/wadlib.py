"""Minimal WAD reader: lump directory, map lumps, texture composition."""
import struct


class Wad:
    def __init__(self, path):
        with open(path, "rb") as source:
            self.data = source.read()
        ident, n, diroff = struct.unpack_from("<4sII", self.data, 0)
        assert ident in (b"IWAD", b"PWAD"), "not a WAD"
        self.dir = []
        for i in range(n):
            off, size, name = struct.unpack_from("<II8s", self.data, diroff + 16 * i)
            self.dir.append((name.rstrip(b"\0").decode(), off, size))
        self.index = {}
        for i, (name, _, _) in enumerate(self.dir):
            self.index.setdefault(name, i)

    def lump(self, name, after=None):
        start = 0 if after is None else after + 1
        for i in range(start, len(self.dir)):
            if self.dir[i][0] == name:
                _, off, size = self.dir[i]
                return self.data[off:off + size]
        raise KeyError(name)

    def map_lumps(self, mapname):
        i = self.index[mapname]
        out = {}
        for j in range(i + 1, i + 11):
            name, off, size = self.dir[j]
            out[name] = self.data[off:off + size]
        return out


def parse_map(wad, mapname):
    lumps = wad.map_lumps(mapname)
    m = {}
    m["vertexes"] = [struct.unpack_from("<hh", lumps["VERTEXES"], i * 4)
                     for i in range(len(lumps["VERTEXES"]) // 4)]
    m["linedefs"] = [struct.unpack_from("<HHHHHhh", lumps["LINEDEFS"], i * 14)
                     for i in range(len(lumps["LINEDEFS"]) // 14)]
    m["sidedefs"] = []
    for i in range(len(lumps["SIDEDEFS"]) // 30):
        xo, yo, up, lo, mid, sec = struct.unpack_from("<hh8s8s8sH", lumps["SIDEDEFS"], i * 30)
        m["sidedefs"].append((xo, yo,
                              up.rstrip(b"\0").decode(),
                              lo.rstrip(b"\0").decode(),
                              mid.rstrip(b"\0").decode(), sec))
    m["segs"] = [struct.unpack_from("<HHhHHh", lumps["SEGS"], i * 12)
                 for i in range(len(lumps["SEGS"]) // 12)]
    m["ssectors"] = [struct.unpack_from("<HH", lumps["SSECTORS"], i * 4)
                     for i in range(len(lumps["SSECTORS"]) // 4)]
    # node: x,y,dx,dy, right bbox (4h), left bbox (4h), right child, left child
    m["nodes"] = [struct.unpack_from("<hhhh4h4hHH", lumps["NODES"], i * 28)
                  for i in range(len(lumps["NODES"]) // 28)]
    m["sectors"] = []
    m["sector_flats"] = []
    m["sector_specials"] = []
    for i in range(len(lumps["SECTORS"]) // 26):
        f, c, ft, ct, light, spec, tag = struct.unpack_from("<hh8s8shhh", lumps["SECTORS"], i * 26)
        m["sectors"].append((f, c, light))
        m["sector_flats"].append((ft.rstrip(b"\0").decode(),
                                  ct.rstrip(b"\0").decode()))
        m["sector_specials"].append((spec, tag))
    m["things"] = [struct.unpack_from("<hhHHH", lumps["THINGS"], i * 10)
                   for i in range(len(lumps["THINGS"]) // 10)]
    m["reject"] = lumps.get("REJECT", b"")
    return m


def playpal(wad):
    pal = wad.lump("PLAYPAL")[:768]
    return [(pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]) for i in range(256)]


def _patch_names(wad):
    d = wad.lump("PNAMES")
    n = struct.unpack_from("<I", d, 0)[0]
    return [d[4 + i * 8:4 + i * 8 + 8].rstrip(b"\0").decode().upper() for i in range(n)]


def _draw_picture(wad, name, img, w, h, ox, oy):
    """Blit Doom picture-format lump into img (list of columns) at (ox,oy)."""
    try:
        d = wad.lump(name)
    except KeyError:
        return
    pw, ph, _, _ = struct.unpack_from("<hhhh", d, 0)
    colofs = [struct.unpack_from("<I", d, 8 + 4 * i)[0] for i in range(pw)]
    for x in range(pw):
        dx = ox + x
        if not (0 <= dx < w):
            continue
        p = colofs[x]
        while d[p] != 0xFF:
            top, length = d[p], d[p + 1]
            for i in range(length):
                y = oy + top + i
                if 0 <= y < h:
                    img[dx][y] = d[p + 3 + i]
            p += 4 + length
    return


def decode_picture(wad, name):
    """Decode a Doom picture lump to row-major palette indices or None."""
    d = wad.lump(name)
    width, height, left, top = struct.unpack_from("<hhhh", d, 0)
    pixels = [[None] * width for _ in range(height)]
    for x in range(width):
        pos = struct.unpack_from("<I", d, 8 + 4 * x)[0]
        while d[pos] != 0xFF:
            y0, length = d[pos], d[pos + 1]
            for i in range(length):
                y = y0 + i
                if y < height:
                    pixels[y][x] = d[pos + 3 + i]
            pos += 4 + length
    return width, height, left, top, pixels


def compose_texture(wad, texdefs, pnames, name):
    """Return (width, height, img[x][y] palette indices) for a TEXTURE1 name."""
    td = texdefs[name.upper()]
    w, h, patches = td
    img = [[0] * h for _ in range(w)]
    for (ox, oy, pidx) in patches:
        _draw_picture(wad, pnames[pidx], img, w, h, ox, oy)
    return w, h, img


def texture_defs(wad):
    """TEXTURE1 (+TEXTURE2 if present) -> {name: (w, h, [(ox,oy,patchidx)])}"""
    defs = {}
    for lumpname in ("TEXTURE1", "TEXTURE2"):
        try:
            d = wad.lump(lumpname)
        except KeyError:
            continue
        n = struct.unpack_from("<I", d, 0)[0]
        offs = [struct.unpack_from("<I", d, 4 + 4 * i)[0] for i in range(n)]
        for off in offs:
            name = d[off:off + 8].rstrip(b"\0").decode().upper()
            w, h = struct.unpack_from("<hh", d, off + 12)
            pc = struct.unpack_from("<h", d, off + 20)[0]
            patches = []
            for i in range(pc):
                ox, oy, pidx = struct.unpack_from("<hhh", d, off + 22 + 10 * i)
                patches.append((ox, oy, pidx))
            defs[name] = (w, h, patches)
    return defs
