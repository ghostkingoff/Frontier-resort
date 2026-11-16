"""Render arbitrary generated frames through the real 32x32 pipeline for visual review.

Usage: python peek32.py <dir-with-pngs> <out.png> [--cols 4] [--zoom 3]
The point is to judge candidates at the FINAL resolution the game will use, not at 512.
"""
import argparse
import glob
import importlib.util
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("build_sheet", os.path.join(HERE, "build_sheet.py"))
bs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bs)

PALETTE = bs.load_palette(r"E:\素材\aseprite\star1.png")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("indir")
    ap.add_argument("out")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--zoom", type=int, default=3)
    ap.add_argument("--pattern", default="*.png")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.indir, args.pattern)))
    files = [f for f in files if "montage" not in os.path.basename(f)]
    z = 32 * args.zoom
    cells = []
    for p in files:
        cell = bs.process(p, PALETTE, "auto", 60, 130, False, method="box", quant_before=True)
        big = cell.resize((z, z), Image.NEAREST)
        dr = ImageDraw.Draw(big)
        dr.rectangle([0, 0, 90, 12], fill=(0, 0, 0))
        dr.text((2, 2), os.path.basename(p)[:14], fill=(255, 255, 0))
        cells.append(big)
    cols = args.cols
    rows = (len(cells) + cols - 1) // cols
    m = Image.new("RGB", (z * cols, z * rows), (35, 35, 35))
    for i, c in enumerate(cells):
        m.paste(c, ((i % cols) * z, (i // cols) * z))
    m.save(args.out)
    print(f"{len(cells)} frames -> {args.out}  ({m.width}x{m.height})")


if __name__ == "__main__":
    main()
