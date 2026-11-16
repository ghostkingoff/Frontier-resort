"""Experiment 7: walk frames from colourised template WALK poses as init (no ControlNet).

exp5 established that a colourised template view used as an img2img init at denoise ~0.55
yields a good sprite with star1's palette AND the template's view. The template's walk rows
give legs-apart / legs-together poses, so the same trick should produce real walk frames
without the face damage that high denoise + strong ControlNet caused.
"""
import importlib.util
import os
import time
import urllib.parse
import urllib.request
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen", os.path.join(HERE, "gen.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

OUT = os.path.join(HERE, "work", "exp7")
PUPPET = os.path.join(HERE, "work", "puppet")
CKPT = "PixelartSpritesheet_V.1.ckpt"
NEG = ("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
       "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
       "cluttered, busy background, extra limbs, deformed, multiple characters, two people, "
       "magenta hair, purple hair, pink hair, two heads")
CHAR = ("a chibi girl with long blue hair, red eyes, white dress with teal collar, "
        "dark teal shoes, 2-head-tall chibi proportion")
STYLE = ("pixel art, crisp hard edges, no anti-aliasing, flat shading, clean solid shapes, "
         "bold 1px dark outline, flat solid magenta background")
TRIG = {"down": "PixelartFSS", "up": "PixelartBSS", "left": "PixelartLSS"}
VIEW = {"down": "front view, facing the camera",
        "up": "back view, seen from behind, facing away, back of her head visible",
        "left": "left side profile view, facing left"}


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=None,
             control=None, control_strength=0.35, control_start=0.0, control_end=1.0,
             init=None, denoise=0.55, seed=777, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "exp7"})["prompt_id"]
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
            print(f"  {os.path.basename(target):<28} {time.time()-t0:5.1f}s", flush=True)
            return


def main():
    os.makedirs(OUT, exist_ok=True)
    tiles = []
    for d, pdir in (("down", "down"), ("up", "up"), ("left", "side")):
        for f in range(1, 5):
            init = os.path.join(PUPPET, f"puppet_walk_{pdir}_f{f}.png")
            p = os.path.join(OUT, f"{d}_f{f}.png")
            run(ns(mode="img2img", init=init, denoise=0.55,
                   prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, walking, mid-stride, {STYLE}",
                   name=f"{d}_f{f}"), p)
            tiles.append((f"{d} f{f}", p))

    # final-resolution check: run each through the real 32x32 pipeline
    import build_sheet as bs
    palette = bs.load_palette(r"E:\素材\aseprite\star1.png")
    cells = []
    for label, p in tiles:
        cell = bs.process(p, palette, "auto", 60, 130, False, method="box", quant_before=True)
        cell = cell.resize((96, 96), Image.NEAREST)
        dr = ImageDraw.Draw(cell)
        dr.rectangle([0, 0, 70, 12], fill=(0, 0, 0))
        dr.text((2, 2), label, fill=(255, 255, 0))
        cells.append(cell)
    cols = 4
    rows = (len(cells) + cols - 1) // cols
    m = Image.new("RGB", (96 * cols, 96 * rows), (30, 30, 30))
    for i, c in enumerate(cells):
        m.paste(c, ((i % cols) * 96, (i // cols) * 96))
    mp = os.path.join(OUT, "montage_32.png")
    m.save(mp)
    print("montage (final 32x32) ->", mp)


if __name__ == "__main__":
    main()
