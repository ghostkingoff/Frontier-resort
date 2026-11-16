"""Cheap A/B experiments on the sprite-sheet checkpoint.

Runs a handful of configs and builds one labelled montage so the result can be judged
in a single look. Each 512x512 generation takes ~4s on the 4050, so a matrix is cheap.
"""
import importlib.util
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen", os.path.join(HERE, "gen.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

OUT = os.path.join(HERE, "work", "exp")
CKPT = "PixelartSpritesheet_V.1.ckpt"
NEG = ("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
       "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
       "cluttered, busy background, realistic proportions, extra limbs, deformed")
STYLE = ("pixel art, crisp hard edges, no anti-aliasing, flat shading, clean solid shapes, "
         "no text, isolated on a flat solid magenta background")
BLUE = ("a single chibi girl with long blue hair and blue twin tails, a small red flower hairpin, "
        "red eyes, white dress with teal collar, dark teal shoes, 2-head-tall chibi proportions")
WEIGHTED = ("a single chibi girl, (long blue hair:1.5), (blue twin tails:1.4), "
            "(red flower hairpin:1.2), red eyes, white dress, teal collar, "
            "2-head-tall chibi proportion, huge head, small body")


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=None,
             control=None, control_strength=0.85, control_start=0.0, control_end=1.0,
             init=None, denoise=0.6, seed=12345, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "exp"})["prompt_id"]
    import time
    import urllib.parse
    import urllib.request
    t0 = time.time()
    while True:
        time.sleep(1.5)
        h = gen.get(f"/history/{pid}")
        if pid in h:
            imgs = [i for o in h[pid].get("outputs", {}).values() for i in o.get("images", [])]
            if not imgs:
                raise SystemExit(f"no image: {h[pid].get('status')}")
            i = imgs[0]
            url = f"/view?filename={urllib.parse.quote(i['filename'])}&subfolder={i.get('subfolder','')}&type={i['type']}"
            with urllib.request.urlopen(gen.SERVER + url, timeout=120) as r, open(target, "wb") as f:
                f.write(r.read())
            print(f"  {os.path.basename(target):<22} {time.time()-t0:5.1f}s")
            return


def main():
    os.makedirs(OUT, exist_ok=True)
    star = os.path.join(HERE, "work", "star1_512.png")
    exp = [
        ("A txt2img blue prompt", ns(mode="txt2img", prompt=f"PixelartFSS, {BLUE}, {STYLE}")),
        ("B img2img star1 d=0.55", ns(mode="img2img", init=star, denoise=0.55,
                                      prompt=f"PixelartFSS, {BLUE}, {STYLE}")),
        ("C img2img star1 d=0.70", ns(mode="img2img", init=star, denoise=0.70,
                                      prompt=f"PixelartFSS, {BLUE}, {STYLE}")),
        ("D img2img star1 d=0.85", ns(mode="img2img", init=star, denoise=0.85,
                                      prompt=f"PixelartFSS, {BLUE}, {STYLE}")),
        ("E txt2img weighted cfg9", ns(mode="txt2img", cfg=9.0, prompt=f"PixelartFSS, {WEIGHTED}, {STYLE}")),
        ("F img2img star1 d=0.70 cfg9", ns(mode="img2img", init=star, denoise=0.70, cfg=9.0,
                                           prompt=f"PixelartFSS, {WEIGHTED}, {STYLE}")),
    ]
    files = []
    for label, cfg in exp:
        name = label.split()[0].lower()
        p = os.path.join(OUT, f"{name}.png")
        run(cfg, p)
        files.append((label, p))

    tiles = []
    for label, p in files:
        t = Image.open(p).convert("RGB").resize((512, 512), Image.NEAREST)
        d = ImageDraw.Draw(t)
        d.rectangle([0, 0, 320, 15], fill=(0, 0, 0))
        d.text((3, 3), label, fill=(255, 255, 0))
        tiles.append(t)
    cols = 3
    rows = (len(tiles) + cols - 1) // cols
    m = Image.new("RGB", (512 * cols, 512 * rows), (20, 20, 20))
    for i, t in enumerate(tiles):
        m.paste(t, ((i % cols) * 512, (i // cols) * 512))
    mp = os.path.join(OUT, "montage.png")
    m.save(mp)
    print("montage ->", mp)


if __name__ == "__main__":
    main()
