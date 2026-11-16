"""Derive a side view from the real front pixels (no diffusion at all).

At 32x32 a chibi profile is mostly the same hair mass; what makes it read as a profile is
(a) the face patch sitting against the leading edge of the head and (b) only one eye showing.
Both are pixel operations, so the result keeps the source art's exact palette and shapes.
"""
import os
import sys
from PIL import Image

REAL = r"E:\godot\模拟经营类\tools\pixel_pipeline\work\real\real_f0.png"
OUT = r"E:\godot\模拟经营类\tools\pixel_pipeline\work\derived"

SKIN = {(0xFC, 0xD4, 0xC3), (0xF6, 0xE8, 0xE2)}
BLUSH = {(0xF6, 0x89, 0x89)}
HAIR = {(0x24, 0x75, 0xB5), (0x0B, 0x4B, 0x7D), (0x7A, 0xAC, 0xE8)}
HAIR_MID = (0x24, 0x75, 0xB5)
HAIR_DARK = (0x0B, 0x4B, 0x7D)

# the face patch measured from the real sprite
FACE_X0, FACE_X1 = 12, 20
FACE_Y0, FACE_Y1 = 12, 19
EYE_ROWS = {15}          # eye pixels live on this row
FLOWER_X0, FLOWER_Y0 = 17, 6   # keep the flower where it is


def is_face(c):
    return c in SKIN or c in BLUSH or c == (0xFF, 0x00, 0x00)


def is_eye(c):
    return c == (0xFF, 0x00, 0x00)


def derive_side(frame, dx=-4, drop_far_eye=True, label=""):
    """dx: how far left the face patch moves. drop_far_eye: keep only the leading eye."""
    out = frame.copy()
    px = out.load()
    # 1) snapshot the face patch
    patch = {}
    for y in range(FACE_Y0, FACE_Y1 + 1):
        for x in range(FACE_X0, FACE_X1 + 1):
            p = px[x, y]
            if p[3] and is_face(p[:3]):
                patch[(x, y)] = p
    # 2) erase the face: fill with hair (dark on the outline-adjacent seam is unnecessary here)
    for (x, y), p in patch.items():
        px[x, y] = HAIR_MID + (255,)
    # 3) stamp it back, shifted
    eyes = [k for k, v in patch.items() if is_eye(v[:3])]
    keep = set()
    if eyes and drop_far_eye:
        lead = min(e[0] for e in eyes)
        keep = {e for e in eyes if e[0] == lead}
    for (x, y), p in patch.items():
        nx = x + dx
        if not (0 <= nx < 32):
            continue
        if is_eye(p[:3]) and drop_far_eye and (x, y) not in keep:
            continue                      # the far eye is hidden in a profile
        if 0 <= nx < 32:
            px[nx, y] = p
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    frame = Image.open(REAL).convert("RGBA")
    variants = [
        ("sideA_dx-3", dict(dx=-3, drop_far_eye=False)),
        ("sideB_dx-4", dict(dx=-4, drop_far_eye=False)),
        ("sideC_dx-4_oneeye", dict(dx=-4, drop_far_eye=True)),
        ("sideD_dx-5_oneeye", dict(dx=-5, drop_far_eye=True)),
        ("sideE_dx-6_oneeye", dict(dx=-6, drop_far_eye=True)),
    ]
    for name, kw in variants:
        im = derive_side(frame, **kw)
        im.save(os.path.join(OUT, name + ".png"))
        print("wrote", name)


if __name__ == "__main__":
    main()
