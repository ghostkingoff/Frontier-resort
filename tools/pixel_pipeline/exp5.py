"""Experiment 5: puppet inits -- colourised template views used as img2img inits.

Compares, for the back and side views:
  * puppet init alone (denoise 0.5 / 0.6 / 0.7)
  * puppet init + the matching single template pose as a weak ControlNet hint
Judged on: is it the right view, is the palette star1's, is it a clean chibi sprite.
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

OUT = os.path.join(HERE, "work", "exp5")
PUPPET = os.path.join(HERE, "work", "puppet")
POSE = os.path.join(HERE, "work", "pose")
CKPT = "PixelartSpritesheet_V.1.ckpt"
CN = "control_v11p_sd15_lineart_fp16.safetensors"
NEG = ("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
       "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
       "cluttered, busy background, extra limbs, deformed, multiple characters, two people, "
       "magenta hair, purple hair, pink hair")
CHAR = ("a chibi girl with long blue hair, red eyes, white dress with teal collar, "
        "dark teal shoes, 2-head-tall chibi proportion")
TRIG = {"down": "PixelartFSS", "up": "PixelartBSS", "left": "PixelartLSS"}
STYLE = ("pixel art, crisp hard edges, no anti-aliasing, flat shading, clean solid shapes, "
         "bold 1px dark outline, flat solid magenta background")
VIEW = {"down": "front view, facing the camera",
        "up": "back view, seen from behind, facing away, back of her head visible",
        "left": "left side profile view, facing left"}


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=CN,
             control=None, control_strength=0.3, control_start=0.0, control_end=1.0,
             init=None, denoise=0.55, seed=12345, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "exp5"})["prompt_id"]
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
            print(f"  {os.path.basename(target):<30} {time.time()-t0:5.1f}s")
            return


def main():
    os.makedirs(OUT, exist_ok=True)
    exp = []
    for d in ("up", "left"):
        init = os.path.join(PUPPET, f"puppet_idle_{'side' if d == 'left' else d}.png")
        for dn in (0.5, 0.6, 0.7):
            exp.append((f"{d} d{dn}", ns(mode="img2img", init=init, denoise=dn,
                                         prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, {STYLE}",
                                         name=f"{d}_d{dn}")))
        ctrl = os.path.join(POSE, f"idle_{d if d == 'up' else 'side'}.png")
        exp.append((f"{d} d0.6 +cn0.3", ns(mode="lineart", init=init, denoise=0.6,
                                           control=ctrl, control_strength=0.3,
                                           prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, {STYLE}",
                                           name=f"{d}_d0.6cn")))
    # down: same recipe on the real star1 init, as the control case
    star = os.path.join(HERE, "work", "star1_512.png")
    for dn in (0.5, 0.6):
        exp.append((f"down d{dn}", ns(mode="img2img", init=star, denoise=dn,
                                      prompt=f"{TRIG['down']}, {CHAR}, {VIEW['down']}, {STYLE}",
                                      name=f"down_d{dn}")))

    files = []
    for label, cfg in exp:
        p = os.path.join(OUT, cfg.name + ".png")
        run(cfg, p)
        files.append((label, p))

    tiles = []
    for label, p in files:
        t = Image.open(p).convert("RGB").resize((512, 512), Image.NEAREST)
        dr = ImageDraw.Draw(t)
        dr.rectangle([0, 0, 200, 15], fill=(0, 0, 0))
        dr.text((3, 3), label, fill=(255, 255, 0))
        tiles.append(t)
    cols = 4
    rows = (len(tiles) + cols - 1) // cols
    m = Image.new("RGB", (512 * cols, 512 * rows), (20, 20, 20))
    for i, t in enumerate(tiles):
        m.paste(t, ((i % cols) * 512, (i // cols) * 512))
    mp = os.path.join(OUT, "montage.png")
    m.save(mp)
    print("montage ->", mp)


if __name__ == "__main__":
    main()
