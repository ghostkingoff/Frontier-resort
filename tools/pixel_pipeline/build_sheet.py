"""Assemble the final 128x128 walk.png and 128x32 idle.png from generated frames.

Pipeline per frame:
  alpha binarise -> crop to content -> nearest-resize to fit a 30x30 box
  -> quantise to the project palette -> paste bottom-aligned / horizontally centred

Sheet layout (hard requirement from docs/素材清单.md, code hardcodes it):
  walk.png 128x128 : 4 cols x 4 rows, col = direction (0 down, 1 up, 2 left, 3 right), row = walk frame
  idle.png 128x32  : 4 cols x 1 row, col = direction in the same order

Usage:
  python build_sheet.py --frames <dir> --palette-source star1.png --out <dir>
Frames expected inside <dir>:
  walk_down_f1..f4.png, walk_up_f1..f4.png, walk_left_f1..f4.png, walk_right_f1..f4.png
  idle_down.png, idle_up.png, idle_left.png, idle_right.png
"""
import argparse
import os
from collections import Counter
from PIL import Image

CELL = 32
MAX_CONTENT = 30      # 1px transparent margin on every side
BASELINE = 30         # content bottom row (inclusive) inside the 32px cell
ALPHA_CUT = 128


def load_palette(src):
    im = Image.open(src).convert("RGBA")
    counts = Counter(p for p in im.getdata() if p[3] >= ALPHA_CUT)
    return [c[:3] for c, _ in counts.most_common()]


def nearest(palette, rgb):
    best, bestd = palette[0], 1 << 30
    r, g, b = rgb
    for pr, pg, pb in palette:
        d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
        if d < bestd:
            bestd, best = d, (pr, pg, pb)
    return best


def binarise(im):
    im = im.convert("RGBA")
    px = im.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            px[x, y] = (r, g, b, 255) if a >= ALPHA_CUT else (0, 0, 0, 0)
    return im


def dist(c1, c2):
    return abs(c1[0] - c2[0]) + abs(c1[1] - c2[1]) + abs(c1[2] - c2[2])


def detect_bg(im):
    """Guess the flat background colour from the four corners.

    Returns None when the corners are already transparent or inconsistent -- in that case
    the image already carries an alpha channel and must not be colour-keyed (keying a
    transparent-black corner would eat the sprite's dark outline).
    """
    w, h = im.size
    px = im.load()
    pts = [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2)]
    if any(px[x, y][3] == 0 for x, y in pts):
        return None
    cols = [px[x, y][:3] for x, y in pts]
    ref = cols[0]
    if all(dist(c, ref) < 60 for c in cols):
        return ref
    return None


def key_background(im, bg, tol=60, halo_tol=130):
    """Drop the background key colour, then clean the 1px halo of blended key pixels."""
    im = im.convert("RGBA")
    w, h = im.size
    px = im.load()
    if bg is None:
        return im
    removed = set()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0 or dist((r, g, b), bg) <= tol:
                px[x, y] = (0, 0, 0, 0)
                removed.add((x, y))
    # halo pass: key-tinted pixels touching a removed pixel
    halo = []
    for (x, y) in list(removed):
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < w and 0 <= ny < h and (nx, ny) not in removed:
                    r, g, b, a = px[nx, ny]
                    if a and dist((r, g, b), bg) <= halo_tol:
                        halo.append((nx, ny))
    for (x, y) in halo:
        px[x, y] = (0, 0, 0, 0)
    return im


def despeckle(im):
    """Remove opaque pixels with no opaque 4-neighbour (diffusion confetti)."""
    w, h = im.size
    px = im.load()
    kill = []
    for y in range(1, h - 1):
        for x in range(1, w - 1):
            if px[x, y][3] == 0:
                continue
            n = sum(1 for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)) if px[x + dx, y + dy][3] > 0)
            if n == 0:
                kill.append((x, y))
    for (x, y) in kill:
        px[x, y] = (0, 0, 0, 0)
    return im


def content_box(im):
    return im.getbbox()


def quantise(im, palette):
    """Map every opaque pixel to the nearest palette colour."""
    im = im.convert("RGBA")
    px = im.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a:
                qr, qg, qb = nearest(palette, (r, g, b))
                px[x, y] = (qr, qg, qb, 255)
    return im


def mode_downscale(im, out_w, out_h, palette, alpha_cut=0.5):
    """Pixel-art downscale: each output pixel = the most common palette colour in its block.

    A box/bilinear downscale invents in-between colours and makes soft edges (the "pixel
    fidelity is wrong" problem). Taking the block's modal palette colour keeps every output
    pixel flat and hard-edged, which is what a 32x32 sprite sheet needs.
    """
    src = im.convert("RGBA")
    w, h = src.size
    px = src.load()
    out = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 0))
    dst = out.load()
    for oy in range(out_h):
        y0, y1 = int(oy * h / out_h), max(int(oy * h / out_h) + 1, int((oy + 1) * h / out_h))
        for ox in range(out_w):
            x0, x1 = int(ox * w / out_w), max(int(ox * w / out_w) + 1, int((ox + 1) * w / out_w))
            counts = {}
            opaque = 0
            total = 0
            for y in range(y0, min(y1, h)):
                for x in range(x0, min(x1, w)):
                    total += 1
                    p = px[x, y]
                    if p[3] < ALPHA_CUT:
                        continue
                    opaque += 1
                    q = nearest(palette, p[:3])
                    counts[q] = counts.get(q, 0) + 1
            if total and opaque / total >= alpha_cut and counts:
                dst[ox, oy] = max(counts.items(), key=lambda kv: kv[1])[0] + (255,)
    return out


def process(path, palette, bg="auto", key_tol=60, halo_tol=130, do_despeckle=False,
            method="box", quant_before=True):
    raw = Image.open(path).convert("RGBA")
    # already-final-size art (e.g. the real 32x32 pixels out of an .aseprite) passes through
    # untouched: it carries its own internal alignment, so no crop / no baseline shift
    if raw.width <= CELL and raw.height <= CELL:
        im = quantise(raw, palette) if quant_before else raw
        cell_im = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
        cell_im.alpha_composite(im, ((CELL - im.width) // 2, (CELL - im.height) // 2))
        return cell_im

    im = raw
    bgc = None
    if bg == "auto":
        bgc = detect_bg(im)
    elif bg != "none":
        bgc = tuple(int(bg[i:i + 2], 16) for i in (0, 2, 4))
    if bgc:
        im = key_background(im, bgc, key_tol, halo_tol)
    if do_despeckle:
        im = despeckle(im)
    im = binarise(im)
    box = content_box(im)
    if box is None:
        raise SystemExit(f"frame has no opaque pixels after keying: {path} (bg={bgc})")
    im = im.crop(box)
    w, h = im.size
    scale = min(MAX_CONTENT / w, MAX_CONTENT / h)
    nw, nh = max(1, min(MAX_CONTENT, round(w * scale))), max(1, min(MAX_CONTENT, round(h * scale)))
    if method == "mode":
        im = mode_downscale(im, nw, nh, palette)
    else:
        if quant_before:
            im = quantise(im, palette)
        im = im.resize((nw, nh), Image.BOX if method == "box" else Image.NEAREST)

    cell_im = Image.new("RGBA", (CELL, CELL), (0, 0, 0, 0))
    ox = (CELL - nw) // 2
    oy = BASELINE - nh + 1
    if oy < 1:
        oy = 1
    cell_im.paste(im, (ox, oy), im)
    return quantise(cell_im, palette)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", required=True)
    ap.add_argument("--palette-source", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--bg", default="auto", help="auto | none | RRGGBB key colour")
    ap.add_argument("--key-tol", type=int, default=60)
    ap.add_argument("--halo-tol", type=int, default=130)
    ap.add_argument("--despeckle", action="store_true")
    ap.add_argument("--method", choices=["box", "nearest", "mode"], default="mode")
    ap.add_argument("--no-quant-before", action="store_true")
    args = ap.parse_args()
    kw = dict(method=args.method, quant_before=not args.no_quant_before)

    palette = load_palette(args.palette_source)
    os.makedirs(args.out, exist_ok=True)
    print(f"palette ({len(palette)} colours): " + ", ".join("#%02X%02X%02X" % c for c in palette))

    dirs = ["down", "up", "left", "right"]

    def fpath(name):
        p = os.path.join(args.frames, name)
        if not os.path.exists(p):
            raise SystemExit(f"missing frame: {p}")
        return p

    walk = Image.new("RGBA", (CELL * 4, CELL * 4), (0, 0, 0, 0))
    for col, d in enumerate(dirs):
        for row in range(4):
            p = fpath(f"walk_{d}_f{row+1}.png")
            bgc = detect_bg(Image.open(p).convert("RGBA")) if args.bg == "auto" else args.bg
            print(f"  {os.path.basename(p):<22} bg={bgc}")
            cell_im = process(p, palette, args.bg, args.key_tol, args.halo_tol, args.despeckle, **kw)
            walk.paste(cell_im, (col * CELL, row * CELL), cell_im)
    walk_path = os.path.join(args.out, "walk.png")
    walk.save(walk_path)
    print("wrote", walk_path, walk.size)

    idle = Image.new("RGBA", (CELL * 4, CELL), (0, 0, 0, 0))
    for col, d in enumerate(dirs):
        cell_im = process(fpath(f"idle_{d}.png"), palette, args.bg, args.key_tol, args.halo_tol, args.despeckle, **kw)
        idle.paste(cell_im, (col * CELL, 0), cell_im)
    idle_path = os.path.join(args.out, "idle.png")
    idle.save(idle_path)
    print("wrote", idle_path, idle.size)


if __name__ == "__main__":
    main()
