"""Extract the palette of a pixel-art PNG (colors + counts), sorted by usage."""
import sys
from collections import Counter
from PIL import Image

path = sys.argv[1]
im = Image.open(path).convert("RGBA")
px = list(im.getdata())
c = Counter(px)
print(f"file={path}  size={im.width}x{im.height}  distinct={len(c)}")
total = len(px)
for color, n in c.most_common():
    r, g, b, a = color
    print(f"  #{r:02X}{g:02X}{b:02X}  a={a:3d}  n={n:5d}  {n*100.0/total:5.1f}%")
