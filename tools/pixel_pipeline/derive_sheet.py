"""Build the whole 4-direction sheet by DERIVING every frame from the real sprite pixels.

No diffusion, no redraw:
  down  = star1.aseprite frames 0..3, bit-exact
  up    = same frames with the face patch painted over with hair  (back of the head)
  left  = same frames with the face patch moved to the leading edge and the far eye hidden
  right = horizontal mirror of left

Because each direction is derived from the SAME source frame index, the leg motion of the
walk cycle matches across all four columns, and every pixel comes from the source palette.
"""
import importlib.util
import os
import shutil
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ase = _load("ase", os.path.join(HERE, "aseprite_decode.py"))

STAR_ASE = r"E:\素材\aseprite\star1.aseprite"
OUT = os.path.join(HERE, "work", "gen3")

SKIN = {(0xFC, 0xD4, 0xC3), (0xF6, 0xE8, 0xE2)}
BLUSH = {(0xF6, 0x89, 0x89)}
RED = (0xFF, 0x00, 0x00)
HAIR_MID = (0x24, 0x75, 0xB5)

FACE_X0, FACE_X1 = 12, 20
FACE_Y0, FACE_Y1 = 12, 19
FLOWER_X_MIN, FLOWER_Y_MAX = 17, 11    # the red flower lives above this; never treat it as an eye


def is_face(c):
    return c in SKIN or c in BLUSH or c == RED


def is_eye(x, y, c):
    return c == RED and y > FLOWER_Y_MAX and FACE_X0 <= x <= FACE_X1


def derive_back(frame):
    out = frame.copy()
    px = out.load()
    for y in range(FACE_Y0, FACE_Y1 + 1):
        for x in range(FACE_X0, FACE_X1 + 1):
            p = px[x, y]
            if p[3] and is_face(p[:3]):
                px[x, y] = HAIR_MID + (255,)
    return out


def derive_side(frame, dx=-4, trim=1):
    """Move the face patch to the leading edge; hide the far eye; optionally drop the
    trailing 1px column of the patch so the visible face is narrower (more profile-like)."""
    out = frame.copy()
    px = out.load()
    patch = {}
    for y in range(FACE_Y0, FACE_Y1 + 1):
        for x in range(FACE_X0, FACE_X1 + 1):
            p = px[x, y]
            if p[3] and is_face(p[:3]):
                patch[(x, y)] = p
    x_max = (max(x for x, _ in patch) - trim) if patch else 0
    for (x, y) in patch:
        px[x, y] = HAIR_MID + (255,)
    eyes = [k for k, v in patch.items() if is_eye(k[0], k[1], v[:3])]
    lead = min(e[0] for e in eyes) if eyes else None
    for (x, y), p in patch.items():
        if is_eye(x, y, p[:3]) and lead is not None and x != lead:
            continue                      # in a profile only the leading eye is visible
        if x > x_max:
            continue                      # trailing columns stay hair
        nx = x + dx
        if 0 <= nx < 32:
            px[nx, y] = p
    return out


def mirror(im):
    return im.transpose(Image.FLIP_LEFT_RIGHT)


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT, exist_ok=True)
    frames, size, _ = ase.decode(STAR_ASE, verbose=True)
    n = len(frames)
    print(f"  deriving {n} frames x 4 directions from {size[0]}x{size[1]} source pixels")

    for i, fr in enumerate(frames):
        fr.save(os.path.join(OUT, f"walk_down_f{i+1}.png"))
        derive_back(fr).save(os.path.join(OUT, f"walk_up_f{i+1}.png"))
        derive_side(fr).save(os.path.join(OUT, f"walk_left_f{i+1}.png"))
        mirror(derive_side(fr)).save(os.path.join(OUT, f"walk_right_f{i+1}.png"))

    fr0 = frames[0]
    fr0.save(os.path.join(OUT, "idle_down.png"))
    derive_back(fr0).save(os.path.join(OUT, "idle_up.png"))
    derive_side(fr0).save(os.path.join(OUT, "idle_left.png"))
    mirror(derive_side(fr0)).save(os.path.join(OUT, "idle_right.png"))

    # union palette of everything produced, so quantisation never alters a pixel
    pal = Image.new("RGBA", (32 * 4, 32), (0, 0, 0, 0))
    for c, name in enumerate(("idle_down", "idle_up", "idle_left", "idle_right")):
        pal.alpha_composite(Image.open(os.path.join(OUT, name + ".png")).convert("RGBA"), (c * 32, 0))
    pal.save(os.path.join(OUT, "palette_source.png"))
    cols = sorted({p for p in pal.getdata() if p[3] > 0})
    print(f"  palette across the derived sheet: {len(cols)} colours")
    print("done ->", OUT)


if __name__ == "__main__":
    main()
