"""Experiment 4: turn the good front frame into back / side views.

exp3 proved init=star1 cannot rotate. Here the init is the *generated* front frame (already
in this model's pixel style and in star1's palette), which should let the per-view trigger
tokens actually rotate the character while the palette survives.

Tests, per direction:
  * img2img from the front frame, trigger BSS/LSS, denoise 0.7 / 0.8 / 0.9
  * plus a variant that also gets the template's back/side pose as a weak ControlNet hint
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

OUT = os.path.join(HERE, "work", "exp4")
POSE = os.path.join(HERE, "work", "pose")
FRONT = os.path.join(HERE, "work", "exp3", "down_cn0.35.png")
CKPT = "PixelartSpritesheet_V.1.ckpt"
CN = "control_v11p_sd15_lineart_fp16.safetensors"
NEG = ("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
       "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
       "cluttered, busy background, extra limbs, deformed, multiple characters, two people, "
       "front view, facing camera")
STYLE = ("pixel art, crisp hard edges, no anti-aliasing, flat shading, clean solid shapes, "
         "bold 1px dark outline, 2-head-tall chibi proportion")
CHAR = ("a chibi girl with long blue hair and blue twin tails, red eyes, "
        "white dress with teal collar, dark teal shoes")
TRIG = {"up": "PixelartBSS", "left": "PixelartLSS", "right": "PixelartRSS"}
VIEW = {"up": "back view, seen from behind, facing away from the camera, back of her head visible",
        "left": "left side profile view, facing left",
        "right": "right side profile view, facing right"}


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=CN,
             control=None, control_strength=0.3, control_start=0.0, control_end=1.0,
             init=FRONT, denoise=0.8, seed=12345, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "exp4"})["prompt_id"]
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
            print(f"  {os.path.basename(target):<28} {time.time()-t0:5.1f}s")
            return


def main():
    os.makedirs(OUT, exist_ok=True)
    exp = []
    for d in ("up", "left"):
        pose_dir = "up" if d == "up" else "side"
        ctrl = os.path.join(POSE, f"{'walk' if False else 'idle'}_{pose_dir}.png")
        for dn in (0.7, 0.8, 0.9):
            exp.append((f"{d} d{dn}", ns(mode="img2img", denoise=dn,
                                         prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, {STYLE}",
                                         name=f"{d}_d{dn}")))
        exp.append((f"{d} d0.8 +cn0.3", ns(mode="lineart", denoise=0.8, control=ctrl,
                                           control_strength=0.3,
                                           prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, {STYLE}",
                                           name=f"{d}_d0.8cn")))
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
    m = m.resize((m.width // 2, m.height // 2), Image.LANCZOS)
    mp = os.path.join(OUT, "montage.png")
    m.save(mp)
    print("montage ->", mp)


if __name__ == "__main__":
    main()
