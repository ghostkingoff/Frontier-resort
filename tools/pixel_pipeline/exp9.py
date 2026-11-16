"""Experiment 9: refine the derived-back / derived-side inits with light img2img.

The colourised bald puppet (used in the earlier rounds) is why the up/left columns looked
like a different character: the init itself had no hair, no face, no dress detail. These
inits are derived from the real sprite pixels, so the identity is already in the init and
only a small amount of denoise is needed to make the view read correctly.
"""
import importlib.util
import os
import time
import urllib.parse
import urllib.request
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = _load("gen", os.path.join(HERE, "gen.py"))
bs = _load("build_sheet", os.path.join(HERE, "build_sheet.py"))

OUT = os.path.join(HERE, "work", "exp9")
DER = os.path.join(HERE, "work", "derived")
REAL = os.path.join(HERE, "work", "real")
CKPT = "PixelartSpritesheet_V.1.ckpt"
PAL = os.path.join(REAL, "palette_source.png")
NEG = ("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
       "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
       "cluttered, busy background, extra limbs, deformed, multiple characters, two people, "
       "magenta hair, purple hair, pink hair, two heads")
CHAR = ("a chibi girl with long blue hair, white dress with teal collar, dark teal shoes, "
        "2-head-tall chibi proportion")
STYLE = ("pixel art, crisp hard edges, no anti-aliasing, flat shading, clean solid shapes, "
         "bold 1px dark outline, flat solid magenta background")
TRIG = {"up": "PixelartBSS", "left": "PixelartLSS"}
VIEW = {"up": "back view, seen from behind, facing away, back of her head visible, no face",
        "left": "left side profile view, facing left, one eye visible from the side"}


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=None,
             control=None, control_strength=0.4, control_start=0.0, control_end=1.0,
             init=None, denoise=0.5, seed=4242, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "exp9"})["prompt_id"]
    t0 = time.time()
    while True:
        time.sleep(1.5)
        h = gen.get(f"/history/{pid}")
        if pid in h:
            imgs = [i for o in h[pid].get("outputs", {}).values() for i in o.get("images", [])]
            if not imgs:
                raise SystemExit(f"no image ({cfg.name}): {h[pid].get('status')}")
            i = imgs[0]
            url = f"/view?filename={urllib.parse.quote(i['filename'])}&subfolder={i.get('subfolder','')}&type={i['type']}"
            with urllib.request.urlopen(gen.SERVER + url, timeout=120) as r, open(target, "wb") as f:
                f.write(r.read())
            print(f"  {os.path.basename(target):<26} {time.time()-t0:5.1f}s", flush=True)
            return


def main():
    os.makedirs(OUT, exist_ok=True)
    palette = bs.load_palette(PAL)
    back = os.path.join(DER, "back_f0_512.png")
    front = os.path.join(REAL, "real_f0.png")

    cands = []
    for d in ("up", "left"):
        init = back if d == "up" else back
        for dn in (0.35, 0.5, 0.65):
            cands.append((f"{d} d{dn}", ns(mode="img2img", init=init, denoise=dn,
                                          prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, {STYLE}",
                                          name=f"{d}_d{dn}"), os.path.join(OUT, f"{d}_d{dn}.png")))
    for label, cfg, path in cands:
        run(cfg, path)

    # render every candidate at the real 32x32 output size, next to the real front frame
    z = 5
    tiles = []
    ref = Image.open(front).convert("RGBA")
    big = Image.new("RGBA", (32 * z, 32 * z), (40, 40, 48, 255))
    big.alpha_composite(ref.resize((32 * z, 32 * z), Image.NEAREST))
    ImageDraw.Draw(big).text((3, 3), "REAL front", fill=(255, 255, 0, 255))
    tiles.append((big, "REAL"))
    der = Image.open(os.path.join(DER, "back_f0.png")).convert("RGBA")
    big = Image.new("RGBA", (32 * z, 32 * z), (40, 40, 48, 255))
    big.alpha_composite(der.resize((32 * z, 32 * z), Image.NEAREST))
    ImageDraw.Draw(big).text((3, 3), "derived back", fill=(120, 255, 120, 255))
    tiles.append((big, "DERIVED"))
    for label, cfg, path in cands:
        cell = bs.process(path, palette, "auto", 60, 130, False, method="mode")
        big = Image.new("RGBA", (32 * z, 32 * z), (40, 40, 48, 255))
        big.alpha_composite(cell.resize((32 * z, 32 * z), Image.NEAREST))
        ImageDraw.Draw(big).text((3, 3), label, fill=(255, 255, 0, 255))
        tiles.append((big, label))

    cols = 4
    rows = (len(tiles) + cols - 1) // cols
    m = Image.new("RGBA", (cols * (32 * z + 6), rows * (32 * z + 6)), (25, 25, 30, 255))
    for i, (t, _) in enumerate(tiles):
        m.alpha_composite(t, ((i % cols) * (32 * z + 6), (i // cols) * (32 * z + 6)))
    mp = os.path.join(OUT, "montage32.png")
    m.convert("RGB").save(mp)
    print("montage ->", mp)


if __name__ == "__main__":
    main()
