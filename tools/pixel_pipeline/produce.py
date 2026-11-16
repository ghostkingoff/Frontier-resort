"""Production run: build the full 4-direction frame set with the recipe found in exp5.

Recipe (empirically the only combination that keeps star1's identity AND correct views):
  down  idle : img2img from star1 upscaled 16x, PixelartFSS, denoise 0.50
  up    idle : img2img from the colourised template back view, PixelartBSS, denoise 0.55
  left  idle : img2img from the colourised template side view, PixelartLSS, denoise 0.55
  right idle : horizontal mirror of left
  walk frames: img2img from that direction's idle frame + ControlNet lineart of the matching
               single template walk pose (strength 0.35), denoise 0.55
  right walk : horizontal mirror of left walk

Outputs the exact filenames build_sheet.py expects, into work/gen.
"""
import importlib.util
import os
import shutil
import time
import urllib.parse
import urllib.request
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gen", os.path.join(HERE, "gen.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

OUT = os.path.join(HERE, "work", "gen")
PUPPET = os.path.join(HERE, "work", "puppet")
POSE = os.path.join(HERE, "work", "pose")
STAR = os.path.join(HERE, "work", "star1_512.png")
CKPT = "PixelartSpritesheet_V.1.ckpt"
CN = "control_v11p_sd15_lineart_fp16.safetensors"

NEG = ("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
       "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
       "cluttered, busy background, extra limbs, deformed, multiple characters, two people, "
       "magenta hair, purple hair, pink hair, red hair, two heads")
CHAR = ("a chibi girl with long blue hair, red eyes, white dress with teal collar, "
        "dark teal shoes, 2-head-tall chibi proportion")
STYLE = ("pixel art, crisp hard edges, no anti-aliasing, flat shading, clean solid shapes, "
         "bold 1px dark outline, flat solid magenta background")
TRIG = {"down": "PixelartFSS", "up": "PixelartBSS", "left": "PixelartLSS"}
VIEW = {"down": "front view, facing the camera",
        "up": "back view, seen from behind, facing away, back of her head visible",
        "left": "left side profile view, facing left"}
WALK_TXT = "walking, mid-stride, one leg forward"


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=CN,
             control=None, control_strength=0.35, control_start=0.0, control_end=1.0,
             init=None, denoise=0.55, seed=12345, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "produce"})["prompt_id"]
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
            print(f"  {os.path.basename(target):<24} {time.time()-t0:5.1f}s", flush=True)
            return


def mirror(src, dst):
    Image.open(src).convert("RGBA").transpose(Image.FLIP_LEFT_RIGHT).save(dst)
    print(f"  mirrored -> {os.path.basename(dst)}", flush=True)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--walk-denoise", type=float, default=0.55)
    ap.add_argument("--walk-cn", type=float, default=0.35)
    ap.add_argument("--skip-idle", action="store_true")
    ap.add_argument("--seed", type=int, default=12345)
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)

    print("[1/3] standing frames")
    if not args.skip_idle:
        run(ns(mode="img2img", init=STAR, denoise=0.50, seed=args.seed,
               prompt=f"{TRIG['down']}, {CHAR}, {VIEW['down']}, {STYLE}", name="idle_down"),
            os.path.join(OUT, "idle_down.png"))
        run(ns(mode="img2img", init=os.path.join(PUPPET, "puppet_idle_up.png"), denoise=0.55, seed=args.seed,
               prompt=f"{TRIG['up']}, {CHAR}, {VIEW['up']}, {STYLE}", name="idle_up"),
            os.path.join(OUT, "idle_up.png"))
        run(ns(mode="img2img", init=os.path.join(PUPPET, "puppet_idle_side.png"), denoise=0.55, seed=args.seed,
               prompt=f"{TRIG['left']}, {CHAR}, {VIEW['left']}, {STYLE}", name="idle_left"),
            os.path.join(OUT, "idle_left.png"))
        mirror(os.path.join(OUT, "idle_left.png"), os.path.join(OUT, "idle_right.png"))

    print("[2/3] walk frames (init = colourised template walk pose)")
    for d in ("down", "up", "left"):
        pose_dir = "side" if d == "left" else d
        for f in range(1, 5):
            init = os.path.join(PUPPET, f"puppet_walk_{pose_dir}_f{f}.png")
            run(ns(mode="img2img", init=init, denoise=args.walk_denoise, seed=args.seed + f,
                   prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, {WALK_TXT}, {STYLE}",
                   name=f"walk_{d}_f{f}"), os.path.join(OUT, f"walk_{d}_f{f}.png"))
    print("[3/3] right column <- mirror(left)")
    for f in range(1, 5):
        mirror(os.path.join(OUT, f"walk_left_f{f}.png"), os.path.join(OUT, f"walk_right_f{f}.png"))

    print("done ->", OUT)


if __name__ == "__main__":
    main()
