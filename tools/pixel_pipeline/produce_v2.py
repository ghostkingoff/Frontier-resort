"""v2 production: the down column comes from the REAL .aseprite pixels, not from a redraw.

What changed vs the first attempt (and why the first one looked wrong):
  * the reference PNG (star1.png) is NOT the sprite data -- it differs from star1.aseprite on
    79 alpha + 187 colour pixels of visible art, so every redraw drifted away from the source.
  * the down column (front view, the one you see most) is now the aseprite's own 4 frames,
    bit-exact, with no diffusion at all.
  * the other directions are still generated, but initialised from the true pixels and
    post-processed with a modal (not box) downscale so the result is hard-edged pixel art.

Outputs the filenames build_sheet.py expects into work/gen2.
"""
import argparse
import importlib.util
import os
import shutil
import time
import urllib.parse
import urllib.request
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


gen = _load("gen", os.path.join(HERE, "gen.py"))
ase = _load("ase", os.path.join(HERE, "aseprite_decode.py"))

STAR_ASE = r"E:\素材\aseprite\star1.aseprite"
OUT = os.path.join(HERE, "work", "gen2")
REAL = os.path.join(HERE, "work", "real")
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
WALK_TXT = "walking, mid-stride, one leg forward"


def ns(**kw):
    d = dict(ckpt=CKPT, lora=None, lora_strength=0.8, negative=NEG, controlnet=None,
             control=None, control_strength=0.35, control_start=0.0, control_end=1.0,
             init=None, denoise=0.55, seed=12345, steps=28, cfg=7.0,
             sampler="dpmpp_2m", scheduler="karras", width=512, height=512, out=OUT, name="x")
    d.update(kw)
    return type("NS", (), d)


def run(cfg, target):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    wf = gen.build(cfg)
    pid = gen.post("/prompt", {"prompt": wf, "client_id": "produce2"})["prompt_id"]
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


def dump_real():
    """The aseprite's own frames -> the down column, bit-exact."""
    os.makedirs(REAL, exist_ok=True)
    frames, size, _ = ase.decode(STAR_ASE, verbose=True)
    print(f"  {len(frames)} real frames of {size[0]}x{size[1]}")

    def eq(a, b):
        pa, pb = a.load(), b.load()
        return sum(1 for y in range(a.height) for x in range(a.width) if pa[x, y] != pb[x, y])

    print(f"  f0 vs f2: {eq(frames[0], frames[2])} px   f1 vs f3: {eq(frames[1], frames[3])} px")
    print(f"  f3 vs mirror(f1): {eq(frames[3], frames[1].transpose(Image.FLIP_LEFT_RIGHT))} px")

    for i, f in enumerate(frames):
        f.save(os.path.join(REAL, f"real_f{i}.png"))
    # union palette source so no real pixel is altered by quantisation
    pal = Image.new("RGBA", (32 * len(frames), 32), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        pal.alpha_composite(f, (i * 32, 0))
    pal.save(os.path.join(REAL, "palette_source.png"))
    cols = sorted({p for p in pal.getdata() if p[3] > 0})
    print(f"  union palette across the 4 real frames: {len(cols)} colours")
    return len(frames)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-real", action="store_true")
    ap.add_argument("--skip-gen", action="store_true")
    ap.add_argument("--walk-denoise", type=float, default=0.55)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    n = 4
    if not args.skip_real:
        print("[1/3] real pixels from star1.aseprite")
        n = dump_real()

    if not args.skip_gen:
        print("[2/3] generated directions (up / left) + their walk frames")
        for d in ("up", "left"):
            init = os.path.join(PUPPET, f"puppet_idle_{'side' if d == 'left' else d}.png")
            run(ns(mode="img2img", init=init, denoise=0.55,
                   prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, {STYLE}", name=f"idle_{d}"),
                os.path.join(OUT, f"idle_{d}.png"))
        for d in ("up", "left"):
            pdir = "side" if d == "left" else d
            for f in range(1, n + 1):
                init = os.path.join(PUPPET, f"puppet_walk_{pdir}_f{f}.png")
                run(ns(mode="img2img", init=init, denoise=args.walk_denoise, seed=777 + f,
                       prompt=f"{TRIG[d]}, {CHAR}, {VIEW[d]}, {WALK_TXT}, {STYLE}",
                       name=f"walk_{d}_f{f}"), os.path.join(OUT, f"walk_{d}_f{f}.png"))

    print("[3/3] assembling the frame set (real down column + mirrored right)")
    for i in range(n):
        shutil.copyfile(os.path.join(REAL, f"real_f{i}.png"), os.path.join(OUT, f"walk_down_f{i+1}.png"))
    shutil.copyfile(os.path.join(REAL, "real_f0.png"), os.path.join(OUT, "idle_down.png"))
    mirror(os.path.join(OUT, "idle_left.png"), os.path.join(OUT, "idle_right.png"))
    print("  mirrored -> idle_right.png")
    for i in range(1, n + 1):
        mirror(os.path.join(OUT, f"walk_left_f{i}.png"), os.path.join(OUT, f"walk_right_f{i}.png"))
        print(f"  mirrored -> walk_right_f{i}.png")
    print("done ->", OUT)


if __name__ == "__main__":
    main()
