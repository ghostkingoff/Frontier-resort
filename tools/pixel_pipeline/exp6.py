"""Experiment 6: how hard must the pose ControlNet push before the legs actually move?

Generates the DOWN direction with several (denoise, control strength) pairs for the two
distinct template poses (f1 = legs apart contact, f2 = legs together passing) and lays them
out next to the idle frame, so the amount of real leg motion is visible at a glance.
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

OUT = os.path.join(HERE, "work", "exp6")
POSE = os.path.join(HERE, "work", "pose")
IDLE = os.path.join(HERE, "work", "gen", "idle_down.png")
CKPT = "PixelartSpritesheet_V.1.ckpt"
CN = "control_v11p_sd15_lineart_fp16.safetensors"
NEG = ("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
       "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
       "cluttered, busy background, extra limbs, deformed, multiple characters, two people, "
       "magenta hair, purple hair, pink hair, two heads")
PROMPT = ("PixelartFSS, a chibi girl with long blue hair, red eyes, white dress with teal collar, "
          "2-head-tall chibi proportion, walking, mid-stride, one leg forward, "
          "pixel art, crisp hard edges, no anti-aliasing, flat shading, bold 1px dark outline, "
          "flat solid magenta background")

SETTINGS = [(0.55, 0.7), (0.70, 0.7), (0.70, 0.9), (0.85, 0.6), (0.85, 0.9)]


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=CN,
             control=None, control_strength=0.7, control_start=0.0, control_end=1.0,
             init=IDLE, denoise=0.7, seed=999, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "exp6"})["prompt_id"]
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
    rows = [("idle (reference)", IDLE)]
    for dn, cn in SETTINGS:
        for f in (1, 2):
            ctrl = os.path.join(POSE, f"walk_down_f{f}.png")
            p = os.path.join(OUT, f"d{dn}_cn{cn}_f{f}.png")
            run(ns(mode="lineart", denoise=dn, control=ctrl, control_strength=cn,
                   prompt=PROMPT, name=f"d{dn}_cn{cn}_f{f}"), p)
            rows.append((f"d{dn} cn{cn} f{f}", p))

    # crop the middle band of each and lay them out in a grid at 2x
    tiles = []
    for label, p in rows:
        t = Image.open(p).convert("RGB").crop((120, 110, 400, 400)).resize((280, 290), Image.NEAREST)
        dr = ImageDraw.Draw(t)
        dr.rectangle([0, 0, 150, 14], fill=(0, 0, 0))
        dr.text((3, 3), label, fill=(255, 255, 0))
        tiles.append(t)
    cols = 4
    rows_n = (len(tiles) + cols - 1) // cols
    m = Image.new("RGB", (280 * cols, 290 * rows_n), (15, 15, 15))
    for i, t in enumerate(tiles):
        m.paste(t, ((i % cols) * 280, (i // cols) * 290))
    mp = os.path.join(OUT, "montage.png")
    m.save(mp)
    print("montage ->", mp)


if __name__ == "__main__":
    main()
