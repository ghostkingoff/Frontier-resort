"""Minimal ComfyUI API client for the pixel-sprite pipeline.

Modes:
  txt2img  : plain text to image
  img2img  : init image + denoise (structure kept, details re-drawn)
  lineart  : init image + ControlNet lineart (pose kept hard)

Input images (init/control) are copied into ComfyUI's input directory first.

Examples:
  python gen.py txt2img --prompt "..." --out out --name test
  python gen.py img2img --init work/pose/walk_down_f1.png --denoise 0.55 --prompt "..." ...
  python gen.py lineart --init <base frame> --control work/lineart/walk_down_f2.png --control-strength 0.7 ...
"""
import argparse
import json
import os
import shutil
import time
import urllib.request
import uuid

SERVER = "http://127.0.0.1:8188"
COMFY_INPUT = r"E:\ComfyUI\ComfyUI_windows_portable\ComfyUI\input"


def post(path, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(SERVER + path, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        raise SystemExit(f"ComfyUI rejected the workflow (HTTP {e.code}):\n{body[:2000]}")


def get(path, timeout=60):
    with urllib.request.urlopen(SERVER + path, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def stage_input(path):
    """Copy a local image into ComfyUI/input and return the filename to reference."""
    name = f"pipe_{uuid.uuid4().hex[:8]}_{os.path.basename(path)}"
    shutil.copyfile(path, os.path.join(COMFY_INPUT, name))
    return name


def build(args):
    g = {}
    g["1"] = {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": args.ckpt}}
    model_src = ["1", 0]
    clip_src = ["1", 1]
    vae_src = ["1", 2]

    if args.lora:
        g["2"] = {"class_type": "LoraLoader",
                  "inputs": {"lora_name": args.lora, "strength_model": args.lora_strength,
                             "strength_clip": args.lora_strength, "model": model_src, "clip": clip_src}}
        model_src, clip_src = ["2", 0], ["2", 1]

    g["3"] = {"class_type": "CLIPTextEncode", "inputs": {"text": args.prompt, "clip": clip_src}}
    g["4"] = {"class_type": "CLIPTextEncode", "inputs": {"text": args.negative, "clip": clip_src}}

    latent_src = None
    if args.mode in ("img2img", "lineart") and args.init:
        g["5"] = {"class_type": "LoadImage", "inputs": {"image": stage_input(args.init)}}
        g["6"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["5", 0], "vae": vae_src}}
        latent_src = ["6", 0]
    else:
        g["5"] = {"class_type": "EmptyLatentImage",
                  "inputs": {"width": args.width, "height": args.height, "batch_size": 1}}
        latent_src = ["5", 0]

    positive = ["3", 0]
    if args.mode == "lineart" and args.control:
        g["7"] = {"class_type": "LoadImage", "inputs": {"image": stage_input(args.control)}}
        g["8"] = {"class_type": "ControlNetLoader", "inputs": {"control_net_name": args.controlnet}}
        g["9"] = {"class_type": "ControlNetApplyAdvanced",
                  "inputs": {"strength": args.control_strength, "start_percent": args.control_start,
                             "end_percent": args.control_end, "positive": positive, "negative": ["4", 0],
                             "control_net": ["8", 0], "image": ["7", 0]}}
        positive, negative = ["9", 0], ["9", 1]
    else:
        negative = ["4", 0]

    g["10"] = {"class_type": "KSampler",
               "inputs": {"seed": args.seed, "steps": args.steps, "cfg": args.cfg,
                          "sampler_name": args.sampler, "scheduler": args.scheduler,
                          "denoise": args.denoise if args.mode in ("img2img", "lineart") else 1.0,
                          "model": model_src, "positive": positive, "negative": negative,
                          "latent_image": latent_src}}
    g["11"] = {"class_type": "VAEDecode", "inputs": {"samples": ["10", 0], "vae": vae_src}}
    g["12"] = {"class_type": "SaveImage", "inputs": {"filename_prefix": args.name, "images": ["11", 0]}}
    return g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["txt2img", "img2img", "lineart"])
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--negative", default="blurry, soft edges, anti-aliased, gradient shading, photorealistic, "
                                        "3d render, jpeg artifacts, noise, text, letters, numbers, logo, watermark, "
                                        "signature, multiple objects, cluttered, busy background, drop shadow, "
                                        "realistic proportions, extra limbs, deformed")
    ap.add_argument("--ckpt", default="PixelartSpritesheet_V.1.ckpt")
    ap.add_argument("--lora", default=None)
    ap.add_argument("--lora-strength", type=float, default=0.8)
    ap.add_argument("--controlnet", default="control_v11p_sd15_lineart_fp16.safetensors")
    ap.add_argument("--control", default=None)
    ap.add_argument("--control-strength", type=float, default=0.7)
    ap.add_argument("--control-start", type=float, default=0.0)
    ap.add_argument("--control-end", type=float, default=1.0)
    ap.add_argument("--init", default=None)
    ap.add_argument("--denoise", type=float, default=0.55)
    ap.add_argument("--seed", type=int, default=12345)
    ap.add_argument("--steps", type=int, default=28)
    ap.add_argument("--cfg", type=float, default=7.0)
    ap.add_argument("--sampler", default="dpmpp_2m")
    ap.add_argument("--scheduler", default="karras")
    ap.add_argument("--width", type=int, default=512)
    ap.add_argument("--height", type=int, default=512)
    ap.add_argument("--out", default="out")
    ap.add_argument("--name", default="gen")
    args = ap.parse_args()

    wf = build(args)
    os.makedirs(args.out, exist_ok=True)
    res = post("/prompt", {"prompt": wf, "client_id": "pixel_pipeline"})
    pid = res["prompt_id"]
    print(f"queued prompt_id={pid} mode={args.mode} seed={args.seed}")
    t0 = time.time()
    while True:
        time.sleep(2)
        hist = get(f"/history/{pid}")
        if pid in hist:
            h = hist[pid]
            status = h.get("status", {})
            if status.get("status_str") == "error" or status.get("completed") is False and status.get("messages"):
                pass
            for node_id, out in h.get("outputs", {}).items():
                for img in out.get("images", []):
                    src = f"/view?filename={urllib.parse.quote(img['filename'])}&subfolder={img.get('subfolder','')}&type={img['type']}"
                    dst = os.path.join(args.out, img["filename"])
                    with urllib.request.urlopen(SERVER + src, timeout=120) as r, open(dst, "wb") as f:
                        f.write(r.read())
                    print(f"saved {dst}  ({time.time()-t0:.1f}s)")
            if not h.get("outputs"):
                print("no images; status:", json.dumps(status)[:600])
            return
        if time.time() - t0 > 900:
            raise SystemExit("timeout waiting for prompt")


if __name__ == "__main__":
    import urllib.parse
    main()
