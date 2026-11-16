"""Decode .aseprite to raw RGBA frames (no PNG export involved).

Two cel layouts exist in the wild:
  Aseprite <=1.2 : layerIdx(2) x(2) y(2) opacity(1) celType(2) -> w(2) h(2) -> data
  Aseprite >=1.3 : ... celType(2) zIndex(2) reserved(5)      -> w(2) h(2) -> data
Instead of guessing, both candidate offsets are tried and the one whose zlib stream
decompresses to exactly w*h*bytes_per_pixel wins. Cel rows are stored bottom-up.

Usage: python aseprite_decode.py <file.aseprite> [--save-dir DIR] [--prefix name]
"""
import argparse
import os
import struct
import zlib
from PIL import Image

HEADER = 128


def try_cel_data(b, q, chunk_end, depth):
    bpp = depth // 8
    for off in (q + 16, q + 9):
        if off + 4 > chunk_end:
            continue
        cw, ch = struct.unpack_from("<HH", b, off)
        if not (0 < cw <= 4096 and 0 < ch <= 4096):
            continue
        raw = off + 4
        # type 0: raw pixels
        if raw + cw * ch * bpp <= chunk_end:
            blob = b[raw:raw + cw * ch * bpp]
            if len(blob) == cw * ch * bpp and any(blob):
                return cw, ch, blob, "raw"
        # type 2: zlib
        try:
            blob = zlib.decompress(b[raw:chunk_end])
            if len(blob) == cw * ch * bpp:
                return cw, ch, blob, "zlib"
        except zlib.error:
            pass
    return None


def decode(path, verbose=True, flip_rows=False):
    """flip_rows=False matches the files in this project (verified against their PNG
    exports); the Aseprite spec's bottom-up row order would need flip_rows=True."""
    b = open(path, "rb").read()
    _size, magic, nframes, w, h, depth = struct.unpack_from("<IHHHHH", b, 0)
    if magic != 0xA5E0:
        raise ValueError("not an aseprite file")
    bpp = depth // 8
    off = HEADER
    frames = []
    layers, tags = [], []
    for fi in range(nframes):
        csize, ctype = struct.unpack_from("<IH", b, off)
        assert ctype == 0xF1FA, f"frame {fi}: bad chunk type 0x{ctype:X}"
        nchunks = struct.unpack_from("<I", b, off + 12)[0]
        sub = off + 16
        canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        for _ in range(nchunks):
            ssize, stype = struct.unpack_from("<IH", b, sub)
            q = sub + 6
            end = sub + ssize
            if stype == 0x2005:
                _li, cx, cy, _op, celtype = struct.unpack_from("<HhhBH", b, q)
                if celtype in (0, 2):
                    got = try_cel_data(b, q, end, depth)
                    if got:
                        cw, ch, blob, _how = got
                        cel = Image.new("RGBA", (cw, ch))
                        px = cel.load()
                        for row in range(ch):
                            src = ((ch - 1 - row) if flip_rows else row) * cw * bpp
                            for col in range(cw):
                                o = src + col * bpp
                                px[col, row] = (blob[o], blob[o + 1], blob[o + 2],
                                                blob[o + 3] if bpp == 4 else 255)
                        canvas.alpha_composite(cel, (cx, cy))
            elif stype == 0x2004:
                n = struct.unpack_from("<H", b, q + 16)[0]
                layers.append(b[q + 18:q + 18 + n].decode("utf-8", "replace"))
            elif stype == 0x2018:
                try:
                    n = struct.unpack_from("<H", b, q)[0]
                    t = q + 2
                    for _ in range(n):
                        frm, to = struct.unpack_from("<HH", b, t)
                        ln = struct.unpack_from("<H", b, t + 19)[0]
                        tags.append((b[t + 21:t + 21 + ln].decode("utf-8", "replace"), frm, to))
                        t += 21 + ln
                except struct.error:
                    pass   # tag layout varies between Aseprite versions; not needed here
            sub = end
        frames.append(canvas)
        off += csize
    if verbose:
        print(f"{os.path.basename(path)}: canvas {w}x{h} frames={nframes} depth={depth}")
        print(f"  layers: {[l.encode('ascii', 'backslashreplace').decode() for l in layers]}")
        safe = [(n.encode('ascii', 'backslashreplace').decode(), a, b) for n, a, b in tags]
        print(f"  tags  : {safe}")
    return frames, (w, h), tags


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--save-dir")
    ap.add_argument("--prefix", default="frame")
    args = ap.parse_args()
    frames, size, tags = decode(args.file)
    if args.save_dir:
        os.makedirs(args.save_dir, exist_ok=True)
        for i, f in enumerate(frames):
            p = os.path.join(args.save_dir, f"{args.prefix}_{i:02d}.png")
            f.save(p)
        print(f"  saved {len(frames)} frames -> {args.save_dir}")


if __name__ == "__main__":
    main()
