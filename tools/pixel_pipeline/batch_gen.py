"""Drive ComfyUI to produce all frames of the character sheet.

Model facts (from the SD_PixelArt_SpriteSheet_Generator model card):
  * it is an SD1.5 checkpoint driven by per-view trigger tokens:
        PixelartFSS = front   PixelartBSS = back   PixelartLSS = left   PixelartRSS = right
  * the author's own workflow: pick the best side result and MIRROR it for the other
    side, then remove the background and scale down -- which is what this pipeline does.

Stages:
  probe : one 512x512 txt2img per direction trigger, to inspect the raw output shape
  base  : the DOWN standing frame (the identity anchor)
  dirs  : UP and LEFT standing frames (img2img from the anchor, so the character carries over)
  walk  : 4 walk frames per direction, lineart ControlNet from the Eris Esra template poses
  mirror: derive RIGHT from LEFT (mirroring, as approved)
"""
import argparse
import importlib.util
import json
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

TRIG = {"down": "PixelartFSS", "up": "PixelartBSS", "left": "PixelartLSS", "right": "PixelartRSS"}
VIEW = {
    "down": "front view, facing the camera",
    "up": "back view, facing away from the camera",
    "left": "side view facing left",
    "right": "side view facing right",
}
CHAR = ("a single chibi girl, long blue hair with two twin tails, a small red flower hairpin, "
        "red eyes, pale lilac-white dress with a teal collar, dark teal shoes, "
        "2-head-tall chibi proportion, feet near the bottom of the canvas")
STYLE = ("pixel art, crisp hard edges, no anti-aliasing, no dithering, limited palette, "
         "bold 1px dark outline, flat shading, no baked shadow, clean solid shapes, "
         "no text, no letters, no watermark, isolated on a flat solid magenta background")
WALK = "walking, mid-stride, one leg forward, arm swing"

DEFAULTS = dict(
    ckpt="PixelartSpritesheet_V.1.ckpt", lora=None, lora_strength=0.8,
    negative=("blurry, soft edges, anti-aliased, gradient shading, photorealistic, 3d render, "
              "jpeg artifacts, noise, text, letters, numbers, logo, watermark, signature, "
              "multiple objects, cluttered, busy background, drop shadow, sprite sheet, grid, "
              "realistic proportions, extra limbs, deformed"),
    controlnet="control_v11p_sd15_lineart_fp16.safetensors",
    control=None, control_strength=0.85, control_start=0.0, control_end=1.0,
    init=None, denoise=0.62, seed=12345, steps=28, cfg=7.0,
    sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out="", name="gen",
)


def ns(**kw):
    d = dict(DEFAULTS)
    d.update(kw)
    return argparse.Namespace(**d)


def prompt(direction, walking=False, style=True):
    parts = [TRIG[direction], CHAR, VIEW[direction]]
    if walking:
        parts.append(WALK)
    if style:
        parts.append(STYLE)
    return ", ".join(parts)


def generate(cfg, target):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "pixel_pipeline"})["prompt_id"]
    t0 = time.time()
    while True:
        time.sleep(2)
        hist = gen.get(f"/history/{pid}")
        if pid not in hist:
            if time.time() - t0 > 900:
                raise SystemExit(f"timeout on {os.path.basename(target)}")
            continue
        h = hist[pid]
        imgs = [i for out in h.get("outputs", {}).values() for i in out.get("images", [])]
        if not imgs:
            raise SystemExit(f"no image for {os.path.basename(target)}: {json.dumps(h.get('status', {}))[:800]}")
        img = imgs[0]
        url = (f"/view?filename={urllib.parse.quote(img['filename'])}"
               f"&subfolder={img.get('subfolder', '')}&type={img['type']}")
        with urllib.request.urlopen(gen.SERVER + url, timeout=120) as r, open(target, "wb") as f:
            f.write(r.read())
        print(f"  saved {os.path.basename(target):<24} {time.time()-t0:5.1f}s  mode={cfg.mode}", flush=True)
        return


def mirror(src, dst):
    im = Image.open(src).convert("RGBA").transpose(Image.FLIP_LEFT_RIGHT)
    im.save(dst)
    print(f"  mirrored {os.path.basename(src)} -> {os.path.basename(dst)}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", choices=["probe", "base", "dirs", "walk", "mirror", "all"], default="probe")
    ap.add_argument("--out", default=os.path.join(HERE, "work", "gen"))
    ap.add_argument("--pose", default=os.path.join(HERE, "work", "lineart"))
    ap.add_argument("--seed", type=int, default=12345)
    ap.add_argument("--ckpt", default=DEFAULTS["ckpt"])
    ap.add_argument("--lora", default=None)
    ap.add_argument("--steps", type=int, default=28)
    args = ap.parse_args()
    o = args.out

    if args.stage in ("probe", "all"):
        print("[probe] one image per direction trigger")
        for d in ("down", "up", "left", "right"):
            generate(ns(mode="txt2img", ckpt=args.ckpt, lora=args.lora, seed=args.seed, steps=args.steps,
                        prompt=prompt(d), name=f"probe_{d}"), os.path.join(o, f"probe_{d}.png"))

    if args.stage in ("base", "all"):
        print("[base] anchor frame (down, standing)")
        generate(ns(mode="txt2img", ckpt=args.ckpt, lora=args.lora, seed=args.seed, steps=args.steps,
                    prompt=prompt("down"), name="base_down"), os.path.join(o, "base_down.png"))
        shutil.copyfile(os.path.join(o, "base_down.png"), os.path.join(o, "idle_down.png"))

    if args.stage in ("dirs", "all"):
        print("[dirs] up + left from the anchor via img2img")
        base = os.path.join(o, "base_down.png")
        if not os.path.exists(base):
            raise SystemExit("run --stage base first")
        for d in ("up", "left"):
            generate(ns(mode="img2img", ckpt=args.ckpt, lora=args.lora, seed=args.seed, steps=args.steps,
                        init=base, denoise=0.62, prompt=prompt(d), name=f"idle_{d}"),
                     os.path.join(o, f"idle_{d}.png"))

    if args.stage in ("walk", "all"):
        print("[walk] 4 walk frames per direction via lineart ControlNet")
        for d in ("down", "up", "left"):
            init = os.path.join(o, f"idle_{d}.png")
            if not os.path.exists(init):
                raise SystemExit(f"missing {init}")
            ctrl_dir = "side" if d == "left" else d
            for f in range(1, 5):
                ctrl = os.path.join(args.pose, f"walk_{ctrl_dir}_f{f}.png")
                if not os.path.exists(ctrl):
                    raise SystemExit(f"missing control pose {ctrl}")
                generate(ns(mode="lineart", ckpt=args.ckpt, lora=args.lora, seed=args.seed,
                            steps=args.steps, init=init, control=ctrl, denoise=0.72,
                            control_strength=0.85, prompt=prompt(d, walking=True),
                            name=f"walk_{d}_f{f}"), os.path.join(o, f"walk_{d}_f{f}.png"))

    if args.stage in ("mirror", "all"):
        print("[mirror] right <- left")
        if not os.path.exists(os.path.join(o, "idle_left.png")):
            raise SystemExit("run --stage dirs first")
        mirror(os.path.join(o, "idle_left.png"), os.path.join(o, "idle_right.png"))
        for f in range(1, 5):
            src = os.path.join(o, f"walk_left_f{f}.png")
            if not os.path.exists(src):
                raise SystemExit(f"missing {src}")
            mirror(src, os.path.join(o, f"walk_right_f{f}.png"))

    print("done ->", o)


if __name__ == "__main__":
    main()
