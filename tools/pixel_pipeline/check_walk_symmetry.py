"""Check the symmetry structure of the template's 4 walk frames per row.

If frame3 == frame1 and frame4 == mirror(frame2), the template's cycle is a proper
4-frame walk (contact, passing-R, contact, passing-L) and can be used as-is.
Otherwise frame3 should be replaced by mirror(frame1) to make the legs alternate.
"""
from PIL import Image

SHEET = r"E:\素材\2d\Eris Esra's Character Template 4.1\16x32\16x32 Walk-Sheet.png"
ROWS = {0: "Walk_Down", 2: "Walk_Side", 4: "Walk_Up"}


def cell(im, row, col):
    return im.crop((col * 32, row * 32, col * 32 + 32, row * 32 + 32))


def diff(a, b):
    pa, pb = a.load(), b.load()
    n = 0
    for y in range(32):
        for x in range(32):
            if pa[x, y] != pb[x, y]:
                n += 1
    return n


im = Image.open(SHEET).convert("RGBA")
print("frames are indexed f1..f4 (= col 0..3)")
for row, name in ROWS.items():
    f = [cell(im, row, c) for c in range(4)]
    m = [x.transpose(Image.FLIP_LEFT_RIGHT) for x in f]
    print(f"\n{name}")
    print(f"  f1 vs f3            : {diff(f[0], f[2]):4d} px differ")
    print(f"  f2 vs f4            : {diff(f[1], f[3]):4d} px differ")
    print(f"  f4 vs mirror(f2)    : {diff(f[3], m[1]):4d} px differ")
    print(f"  f3 vs mirror(f1)    : {diff(f[2], m[0]):4d} px differ")
    print(f"  f2 vs mirror(f1)    : {diff(f[1], m[0]):4d} px differ")
