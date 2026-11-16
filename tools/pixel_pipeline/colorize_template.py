"""Recolour the Eris Esra template poses into star1's palette to build "puppet" inits.

Why: low-denoise img2img preserves the init's colours and design, but the model cannot
rotate a frontal init. So each view needs an init that is ALREADY that view AND already
wearing star1's colours. The template supplies the 2-head-tall chibi poses; this script
supplies the colours.

Positional rule (32x32 template frame): everything above the neck line becomes HAIR, below
it becomes DRESS; the template's own face accents (s/c) become skin and blush.
"""
import os
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
TPL = r"E:\素材\2d\Eris Esra's Character Template 4.1\16x32"
OUT = os.path.join(HERE, "work", "puppet")
SCALE = 16
NECK_Y = 18          # rows < NECK_Y are head/hair, rows >= NECK_Y are body
FOOT_Y = 28          # rows >= FOOT_Y are shoes

# star1 palette
BLUE = (0x24, 0x75, 0xB5)      # hair
BLUE_D = (0x0B, 0x4B, 0x7D)    # hair shade / outline
DRESS = (0xC8, 0xC6, 0xD7)     # dress light
DRESS_D = (0x8E, 0x8A, 0xAC)   # dress shade
SKIN = (0xFC, 0xD4, 0xC3)
BLUSH = (0xF6, 0x89, 0x89)
TEAL = (0x00, 0x61, 0x66)

# template source colours
T_LIGHT = (250, 243, 232)
T_MID = (185, 179, 161)
T_DARK = (47, 37, 34)
T_SKIN = (231, 213, 198)
T_BLUSH = (209, 157, 167)

WALK_ROWS = {"down": 0, "side": 2, "up": 4}
IDLE_ROWS = {"down": 0, "side": 2, "up": 4}


def colourise(frame):
    """frame: 32x32 RGBA template cell -> recoloured copy."""
    out = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    src, dst = frame.load(), out.load()
    for y in range(32):
        head = y < NECK_Y
        foot = y >= FOOT_Y
        for x in range(32):
            r, g, b, a = src[x, y]
            if a == 0:
                continue
            c = (r, g, b)
            if c == T_DARK:
                col = BLUE_D
            elif c == T_LIGHT:
                # flatten the body: the template's alternating light/mid shading turned into
                # vertical stripes once the model redrew it, so the body gets one flat dress colour
                col = BLUE if head else (TEAL if foot else DRESS)
            elif c == T_MID:
                col = BLUE_D if head else (TEAL if foot else DRESS_D)
            elif c == T_SKIN:
                col = SKIN
            elif c == T_BLUSH:
                col = BLUSH
            else:
                col = c
            dst[x, y] = (col[0], col[1], col[2], 255)
    return out


def on_magenta(frame32):
    """upscale nearest and flatten onto the magenta background star1's init uses."""
    big = frame32.resize((32 * SCALE, 32 * SCALE), Image.NEAREST)
    bg = Image.new("RGBA", big.size, (255, 0, 255, 255))
    bg.alpha_composite(big)
    return bg.convert("RGB")


def main():
    os.makedirs(OUT, exist_ok=True)
    walk = Image.open(os.path.join(TPL, "16x32 Walk-Sheet.png")).convert("RGBA")
    idle = Image.open(os.path.join(TPL, "16x32 Idle-Sheet.png")).convert("RGBA")

    for d, row in IDLE_ROWS.items():
        fr = idle.crop((0, row * 32, 32, row * 32 + 32))
        p = os.path.join(OUT, f"puppet_idle_{d}.png")
        on_magenta(colourise(fr)).save(p)
        print("wrote", p)
        if d == "side":
            p2 = os.path.join(OUT, "puppet_idle_side_mirror.png")
            on_magenta(colourise(fr.transpose(Image.FLIP_LEFT_RIGHT))).save(p2)
            print("wrote", p2)

    for d, row in WALK_ROWS.items():
        for f in range(4):
            fr = walk.crop((f * 32, row * 32, f * 32 + 32, row * 32 + 32))
            p = os.path.join(OUT, f"puppet_walk_{d}_f{f+1}.png")
            on_magenta(colourise(fr)).save(p)
        print(f"wrote puppet_walk_{d}_f1..4")


if __name__ == "__main__":
    main()
