"""Build a 512x512 ControlNet strip holding the 4 template walk poses of one direction.

The sprite-sheet checkpoint draws a row of 4 sprites; conditioning it with a strip of the
Eris Esra walk poses (2-head-tall chibi, correct contact/passing alternation) pins both the
pose sequence and the proportions. Each 32x32 template frame is scaled 4x into a 128px cell
and the row is placed so the feet land where the model normally puts them (~y=380).

Output: work/strips/walk_<down|up|left|side>.png
"""
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
WALK = r"E:\素材\2d\Eris Esra's Character Template 4.1\16x32\16x32 Walk-Sheet.png"
ROW = {"down": 0, "up": 4, "side": 2}
OUT = os.path.join(HERE, "work", "strips")
CELL = 128
FEET_Y = 380


def main():
    os.makedirs(OUT, exist_ok=True)
    sheet = Image.open(WALK).convert("RGBA")
    for d, row in ROW.items():
        canvas = Image.new("RGBA", (512, 512), (255, 255, 255, 255))
        for f in range(4):
            fr = sheet.crop((f * 32, row * 32, f * 32 + 32, row * 32 + 32))
            big = fr.resize((CELL, CELL), Image.NEAREST)
            # template character occupies rows 7..30 inside its 32px cell
            top = FEET_Y - int(30 * CELL / 32)
            canvas.alpha_composite(big, (f * CELL, top))
        p = os.path.join(OUT, f"walk_{d}.png")
        canvas.convert("RGB").save(p)
        print("wrote", p)


if __name__ == "__main__":
    main()
