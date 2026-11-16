"""Export the pose frames we need from the Eris Esra template sheets.

Template sheet layout (verified from the .aseprite tag names):
  128x160 = 5 rows x 4 cols, each cell 32x32, generated row-major over animation tags.
  Walk sheet rows: Walk_Down / Walk_Down_Side / Walk_Side / Walk_Side_Up / Walk_Up
  Idle sheet rows: Idle_Down / Idle_Down_Side / Idle_Side / Idle_Up_Side / Idle_Up

Project needs 4 directions: down / up / left / right  (left and right both come from Walk_Side,
right being the horizontal mirror -- approved by the user).

Outputs into --out:
  pose/walk_down_f{1..4}.png     256x256 (8x nearest of the 32x32 template frame)
  pose/walk_up_f{1..4}.png
  pose/walk_side_f{1..4}.png
  pose/walk_side_mirror_f{1..4}.png
  pose/idle_down.png, idle_up.png, idle_side.png, idle_side_mirror.png
  lineart/*.png   same frames but reduced to black outlines on white (for ControlNet lineart)
"""
import argparse
import os
from PIL import Image

SCALE = 8
CELL = 32

WALK_ROW = {"down": 0, "side": 2, "up": 4}
IDLE_ROW = {"down": 0, "side": 2, "up": 4}


def cell(sheet, row, col):
    box = (col * CELL, row * CELL, col * CELL + CELL, row * CELL + CELL)
    return sheet.crop(box)


def upscale(im, scale=SCALE):
    return im.resize((im.width * scale, im.height * scale), Image.NEAREST)


def to_lineart(im):
    """Anything opaque -> dark line on white; keeps the silhouette+interior marks."""
    out = Image.new("RGBA", im.size, (255, 255, 255, 255))
    src = im.load()
    dst = out.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = src[x, y]
            if a > 0:
                # keep the template's own dark outline dark, everything else mid-grey
                lum = (r + g + b) / 3.0
                v = 0 if lum < 120 else 170
                dst[x, y] = (v, v, v, 255)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--walk-sheet", required=True)
    ap.add_argument("--idle-sheet", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    walk = Image.open(args.walk_sheet).convert("RGBA")
    idle = Image.open(args.idle_sheet).convert("RGBA")
    assert walk.size == (128, 160), f"unexpected walk sheet size {walk.size}"
    assert idle.size == (128, 160), f"unexpected idle sheet size {idle.size}"

    pose_dir = os.path.join(args.out, "pose")
    la_dir = os.path.join(args.out, "lineart")
    os.makedirs(pose_dir, exist_ok=True)
    os.makedirs(la_dir, exist_ok=True)

    def emit(name, frame32):
        big = upscale(frame32)
        big.save(os.path.join(pose_dir, name + ".png"))
        to_lineart(big).save(os.path.join(la_dir, name + ".png"))

    # walk: 4 frames per direction row
    for d, row in WALK_ROW.items():
        for f in range(4):
            fr = cell(walk, row, f)
            emit(f"walk_{d}_f{f+1}", fr)
            if d == "side":
                emit(f"walk_side_mirror_f{f+1}", fr.transpose(Image.FLIP_LEFT_RIGHT))

    # idle: single frame per direction row
    for d, row in IDLE_ROW.items():
        fr = cell(idle, row, 0)
        emit(f"idle_{d}", fr)
        if d == "side":
            emit("idle_side_mirror", fr.transpose(Image.FLIP_LEFT_RIGHT))

    print("pose frames written to", pose_dir)
    print("lineart frames written to", la_dir)


if __name__ == "__main__":
    main()
