"""Autoritative comparison: .aseprite decode vs PNG export, orientation auto-detected.

Reports only differences that a human could ever see:
  alpha_diff  : the pixel's transparency differs            -> real problem
  colour_diff : both opaque, different RGB                  -> real problem
  ghost_diff  : both fully transparent, different RGB       -> invisible, ignore
"""
import importlib.util
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ase", os.path.join(HERE, "aseprite_decode.py"))
ase = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ase)


def visible_diff(a, b):
    pa, pb = a.load(), b.load()
    w, h = a.size
    alpha_d = colour_d = ghost_d = 0
    for y in range(h):
        for x in range(w):
            ca, cb = pa[x, y], pb[x, y]
            if ca[3] != cb[3]:
                alpha_d += 1
            elif ca[3] == 0:
                if ca[:3] != cb[:3]:
                    ghost_d += 1
            elif ca[:3] != cb[:3]:
                colour_d += 1
    return alpha_d, colour_d, ghost_d


def best_orientation(frames, cells):
    """Try both row orders and return (flip, totals)."""
    results = {}
    for flip in (False, True):
        dec, _, _ = ase.decode(frames, verbose=False, flip_rows=flip)
        tot = [0, 0, 0]
        for fr, cell in zip(dec, cells):
            d = visible_diff(fr, cell)
            for i in range(3):
                tot[i] += d[i]
        results[flip] = tot
    return results


def main():
    star_path = r"E:\素材\aseprite\star1.aseprite"
    star_png = Image.open(r"E:\素材\aseprite\star1.png").convert("RGBA")
    print("=== star1.aseprite vs star1.png (alpha / colour / ghost) ===")
    res = best_orientation(star_path, [star_png] * 4)
    for flip, tot in res.items():
        print(f"  flip_rows={flip}: {tot[0]} / {tot[1]} / {tot[2]}")

    walk_path = r"E:\素材\2d\Eris Esra's Character Template 4.1\16x32\16x32 Walk.aseprite"
    sheet = Image.open(r"E:\素材\2d\Eris Esra's Character Template 4.1\16x32\16x32 Walk-Sheet.png").convert("RGBA")
    cells = [sheet.crop(((i % 4) * 32, (i // 4) * 32, (i % 4) * 32 + 32, (i // 4) * 32 + 32)) for i in range(20)]
    print("\n=== walk aseprite vs Walk-Sheet.png, 20 frames ===")
    res2 = best_orientation(walk_path, cells)
    for flip, tot in res2.items():
        print(f"  flip_rows={flip}: {tot[0]} / {tot[1]} / {tot[2]}")

    winner = min(res2, key=lambda f: sum(res2[f][:2]))
    print(f"\n  -> the PNG export is {'FLIPPED' if winner else 'UPRIGHT'} relative to the spec's row order")
    dec, _, _ = ase.decode(walk_path, verbose=False, flip_rows=winner)
    per = [visible_diff(fr, c) for fr, c in zip(dec, cells)]
    worst = max(per, key=lambda d: d[0] + d[1])
    print(f"  worst frame: alpha_diff={worst[0]} colour_diff={worst[1]}")
    if sum(w[0] + w[1] for w in per) == 0:
        print("  ALL 20 FRAMES BIT-IDENTICAL (visible pixels) -> the PNG export is a faithful copy")
    else:
        print("  -> the PNG export differs from the sprite data on visible pixels")


if __name__ == "__main__":
    main()
