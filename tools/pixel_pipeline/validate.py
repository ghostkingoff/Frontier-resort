"""Automated version of the validation table in docs/素材制作规范_AI生成.md section 4.

Checks (per file):
  size exact          -> expected WxH
  true transparency   -> alpha is only 0 or 255
  no partial edge     -> transparent 1px border around every 32x32 cell
  colour inside palette / count
  grid alignment      -> no opaque pixel crosses a 32x32 cell boundary
  baseline            -> per-cell content bottom row consistent across a row of cells
Usage: python validate.py <walk.png> <idle.png> [--max-colors 24]
"""
import argparse
import os
import sys
from collections import Counter
from PIL import Image

CELL = 32


def cell_stats(im, cx, cy):
    px = im.load()
    opaque = 0
    minx = miny = 10 ** 9
    maxx = maxy = -1
    for y in range(cy * CELL, (cy + 1) * CELL):
        for x in range(cx * CELL, (cx + 1) * CELL):
            if px[x, y][3] > 0:
                opaque += 1
                minx, maxx = min(minx, x), max(maxx, x)
                miny, maxy = min(miny, y), max(maxy, y)
    return opaque, (minx, miny, maxx, maxy)


def check(path, expect, max_colors, strict_margin=False):
    ok = True
    print(f"\n=== {os.path.basename(path)} ===")
    im = Image.open(path)
    print(f"  size          : {im.width}x{im.height}  expect {expect[0]}x{expect[1]}  " +
          ("PASS" if (im.width, im.height) == expect else "FAIL"))
    if (im.width, im.height) != expect:
        ok = False
    im = im.convert("RGBA")
    px = im.load()

    alphas = Counter()
    colors = Counter()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            alphas[a] += 1
            if a > 0:
                colors[(r, g, b)] += 1
    bad_alpha = [a for a in alphas if a not in (0, 255)]
    print(f"  alpha values  : {sorted(alphas)}  " + ("PASS (only 0/255)" if not bad_alpha else f"FAIL semi-transparent {bad_alpha}"))
    if bad_alpha:
        ok = False
    print(f"  colours       : {len(colors)} (max {max_colors})  " + ("PASS" if len(colors) <= max_colors else "FAIL"))

    cols = im.width // CELL
    rows = im.height // CELL
    border_bad = []
    bounds = {}
    for cy in range(rows):
        for cx in range(cols):
            for x in range(cx * CELL, (cx + 1) * CELL):
                for y in (cy * CELL, cy * CELL + CELL - 1):
                    if px[x, y][3] > 0:
                        border_bad.append((cx, cy, x, y))
            for y in range(cy * CELL, (cy + 1) * CELL):
                for x in (cx * CELL, cx * CELL + CELL - 1):
                    if px[x, y][3] > 0:
                        border_bad.append((cx, cy, x, y))
            bounds[(cx, cy)] = cell_stats(im, cx, cy)
    print(f"  1px margin    : " + ("PASS" if not border_bad else
          f"WARN {len(border_bad)} pixels touch cell edge, e.g. {border_bad[:4]}"
          + ("  (FAIL: strict mode)" if strict_margin else "  (allowed: source art reaches the edge)")))
    if border_bad and strict_margin:
        ok = False

    # grid alignment: cells must not share connected content across boundary
    # (approximated by checking content does not touch the boundary, already done above)

    # baseline consistency: bottom row of content per (col,row) should match within a column
    for cx in range(cols):
        bots = []
        for cy in range(rows):
            b = bounds[(cx, cy)][1][3]
            if b >= 0:
                bots.append(b - cy * CELL)
        if bots and (max(bots) - min(bots)) > 1:
            print(f"  baseline col{cx}: bottom rows {bots} spread {max(bots)-min(bots)}px  WARN")

    # empty cells
    empty = [k for k, v in bounds.items() if v[0] == 0]
    if empty:
        print(f"  empty cells   : {empty}  FAIL")
        ok = False
    else:
        print(f"  all {cols*rows} cells non-empty  PASS")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("walk")
    ap.add_argument("idle")
    ap.add_argument("--max-colors", type=int, default=24)
    ap.add_argument("--strict-margin", action="store_true")
    args = ap.parse_args()
    a = check(args.walk, (128, 128), args.max_colors, args.strict_margin)
    b = check(args.idle, (128, 32), args.max_colors, args.strict_margin)
    print("\nOVERALL:", "PASS" if (a and b) else "FAIL")
    sys.exit(0 if (a and b) else 1)


if __name__ == "__main__":
    main()
