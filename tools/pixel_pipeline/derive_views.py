"""Derive back / side inits FROM the real sprite pixels instead of from a bald puppet.

A back view of this character is mostly the same hair mass + the same dress; the only thing
that must disappear is the face. So: paint the face-region pixels with hair colours and let
img2img refine at low denoise. That keeps the identity (hair silhouette, dress, palette)
instead of inventing a different-looking character.
"""
import importlib.util
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ase = _load("ase", os.path.join(HERE, "aseprite_decode.py"))

SKIN = {(0xFC, 0xD4, 0xC3), (0xF6, 0xE8, 0xE2), (0xE8, 0xC8, 0xB8)}
BLUSH = {(0xF6, 0x89, 0x89)}
EYE = {(0xFF, 0x00, 0x00)}
HAIR = (0x24, 0x75, 0xB5)
HAIR_D = (0x0B, 0x4B, 0x7D)
HAIR_L = (0x7A, 0xAC, 0xE8)


def diag(frames):
    """Where are the skin / eye pixels, so the head region can be isolated safely?"""
    im = frames[0]
    px = im.load()
    rows = {}
    for y in range(32):
        for x in range(32):
            p = px[x, y]
            if p[3] == 0:
                continue
            if p[:3] in SKIN or p[:3] in BLUSH or p[:3] in EYE:
                rows.setdefault(("skin" if p[:3] in SKIN else ("blush" if p[:3] in BLUSH else "eye")), []).append((x, y))
    for kind, pts in rows.items():
        ys = [p[1] for p in pts]
        xs = [p[0] for p in pts]
        print(f"  {kind:5s}: {len(pts):3d} px  y={min(ys)}..{max(ys)}  x={min(xs)}..{max(xs)}")


def derive_back(frame, head_max_y=19):
    """Face pixels inside the head box become hair; everything else is untouched."""
    out = frame.copy()
    px = out.load()
    for y in range(0, head_max_y + 1):
        for x in range(32):
            p = px[x, y]
            if p[3] == 0:
                continue
            c = p[:3]
            if c in EYE:
                px[x, y] = HAIR_D + (255,)
            elif c in BLUSH:
                px[x, y] = HAIR + (255,)
            elif c in SKIN:
                px[x, y] = HAIR + (255,)
    return out


def to_magenta(frame, scale=16):
    big = frame.resize((32 * scale, 32 * scale), Image.NEAREST)
    bg = Image.new("RGBA", big.size, (255, 0, 255, 255))
    bg.alpha_composite(big)
    return bg.convert("RGB")


def main():
    out = os.path.join(HERE, "work", "derived")
    os.makedirs(out, exist_ok=True)
    frames, _, _ = ase.decode(r"E:\素材\aseprite\star1.aseprite", verbose=False)
    print("face pixel layout in the real frame:")
    diag(frames)

    for i, fr in enumerate(frames):
        b = derive_back(fr)
        b.save(os.path.join(out, f"back_f{i}.png"))
        to_magenta(b).save(os.path.join(out, f"back_f{i}_512.png"))
    print("wrote derived back views ->", out)


if __name__ == "__main__":
    main()
