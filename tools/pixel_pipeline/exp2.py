"""Experiment 2: pin direction + proportions with a ControlNet pose strip.

Question: can a strip of the 4 template walk poses (2-head-tall chibi) force the checkpoint
to draw 4 correct-posed, correct-proportioned sprites, and does the blue hair survive when
we condition on star1's colours via img2img?
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

OUT = os.path.join(HERE, "work", "exp2")
STRIPS = os.path.join(HERE, "work", "strips")
CKPT = "PixelartSpritesheet_V.1.ckpt"
CN = "control_v11p_sd15_lineart_fp16.safetensors"
NEG = ("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
       "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
       "cluttered, busy background, realistic proportions, extra limbs, deformed, "
       "adult proportions, tall")
STYLE = ("pixel art, crisp hard edges, no anti-aliasing, flat shading, clean solid shapes, "
         "2-head-tall chibi proportion, huge head, tiny body, bold 1px dark outline")
CHAR = ("a single chibi girl with long blue hair and blue twin tails, a small red flower hairpin, "
        "red eyes, white dress with teal collar, dark teal shoes")
TRIG = {"down": "PixelartFSS", "up": "PixelartBSS", "left": "PixelartLSS", "right": "PixelartRSS"}


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=CN,
             control=None, control_strength=0.8, control_start=0.0, control_end=1.0,
             init=None, denoise=0.75, seed=12345, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "exp2"})["prompt_id"]
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
            print(f"  {os.path.basename(target):<26} {time.time()-t0:5.1f}s")
            return


def main():
    os.makedirs(OUT, exist_ok=True)
    star = os.path.join(HERE, "work", "star1_512.png")
    exp = []
    for d in ("down", "up", "left"):
        strip = os.path.join(STRIPS, f"walk_{'side' if d == 'left' else d}.png")
        for strength in (0.6, 0.85):
            exp.append((f"{d} cn{strength} txt2img",
                        ns(mode="lineart", control=strip, control_strength=strength,
                           prompt=f"{TRIG[d]}, {CHAR}, {STYLE}", name=f"{d}_txt_{strength}")))
        exp.append((f"{d} cn0.85 img2img star1",
                    ns(mode="lineart", control=strip, control_strength=0.85, init=star, denoise=0.75,
                       prompt=f"{TRIG[d]}, {CHAR}, {STYLE}", name=f"{d}_i2i")))

    files = []
    for label, cfg in exp:
        p = os.path.join(OUT, cfg.name + ".png")
        run(cfg, p)
        files.append((label, p))

    tiles = []
    for label, p in files:
        t = Image.open(p).convert("RGB").resize((512, 512), Image.NEAREST)
        d = ImageDraw.Draw(t)
        d.rectangle([0, 0, 330, 15], fill=(0, 0, 0))
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
