"""Pixel-level comparison: .aseprite source of truth vs the PNG exports used so far.

Answers the question "was the reference PNG blurry / different from the real sprite data?"
Q: for every frame, are the two images pixel-identical? If not, how many pixels differ and
by how much (max channel delta)?
"""
import argparse
import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ase", os.path.join(HERE, "aseprite_decode.py"))
ase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ase)

from PIL import Image


def diff(im_a, im_b, label):
    if im_a.size != im_b.size:
        print(f"{label}: SIZE DIFFERS {im_a.size} vs {im_b.size}")
        return
    pa, pb = im_a.convert("RGBA").load(), im_b.convert("RGBA").load()
    w, h = im_a.size
    ndiff = 0
    maxd = 0
    worst = None
    for y in range(h):
        for x in range(w):
            a, b = pa[x, y], pb[x, y]
            d = max(abs(a[i] - b[i]) for i in range(4))
            if d:
                ndiff += 1
                if d > maxd:
                    maxd, worst = d, (x, y, a, b)
    total = w * h
    verdict = "IDENTICAL" if ndiff == 0 else f"{ndiff}/{total} pixels differ ({100.0*ndiff/total:.2f}%), max channel delta {maxd}"
    print(f"{label}: {verdict}")
    if worst:
        print(f"    worst pixel at {worst[0]},{worst[1]}: aseprite={worst[2]} png={worst[3]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--star-ase", required=True)
    ap.add_argument("--star-png", required=True)
    ap.add_argument("--walk-ase", required=True)
    ap.add_argument("--walk-png", required=True)
    args = ap.parse_args()

    sa, _, _ = ase.decode(args.star_ase, verbose=True)
    wa, _, _ = ase.decode(args.walk_ase, verbose=True)

    print("\n=== star1.aseprite vs star1.png ===")
    sp = Image.open(args.star_png)
    print(f"  star1.png size: {sp.size}   aseprite frame size: {sa[0].size}")
    # the png may be frame 0, or a different frame entirely: try all
    best = None
    for i, fr in enumerate(sa):
        if fr.size != sp.size:
            print(f"  frame {i}: size mismatch")
            continue
        pa, pb = fr.load(), sp.convert("RGBA").load()
        n = sum(1 for y in range(32) for x in range(32) if pa[x, y] != pb[x, y])
        print(f"  frame {i}: {n} pixels differ")
        if best is None or n < best[1]:
            best = (i, n)
    if best:
        print(f"  -> closest aseprite frame = {best[0]} with {best[1]} differing pixels")
        diff(sa[best[0]], sp, f"  frame {best[0]} vs star1.png")

    print("\n=== 16x32 Walk.aseprite vs 16x32 Walk-Sheet.png ===")
    wp = Image.open(args.walk_png).convert("RGBA")
    print(f"  sheet {wp.size}, aseprite canvas {wa[0].size}, frames {len(wa)}")
    cols = wp.width // wa[0].width if wa[0].width else 0
    nd = 0
    for i, fr in enumerate(wa):
        cx, cy = (i % cols) * 32, (i // cols) * 32
        cell = wp.crop((cx, cy, cx + 32, cy + 32))
        pa, pb = fr.load(), cell.load()
        n = sum(1 for y in range(32) for x in range(32) if pa[x, y] != pb[x, y])
        if n:
            nd += 1
            print(f"  frame {i} (col {i%cols} row {i//cols}): {n} pixels differ")
    if nd == 0:
        print("  ALL 20 frames IDENTICAL between aseprite and the PNG sheet")


if __name__ == "__main__":
    main()
