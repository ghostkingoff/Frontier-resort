#!/usr/bin/env python3
"""Import completed lighting-aware Aseprite assets into Godot runtime paths."""

from __future__ import annotations

import json
import shutil
import struct
import sys
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "art" / "source" / "buildings"
RUNTIME_ROOT = ROOT / "art" / "characters" / "buildings"
SOURCE_TREE_ROOT = ROOT / "art" / "source" / "trees"
RUNTIME_TREE_ROOT = ROOT / "art" / "characters" / "trees"
SOURCE_GROUND_ROOT = ROOT / "art" / "source" / "ground"
RUNTIME_GROUND_ROOT = ROOT / "art" / "characters" / "ground"
EXTERNAL_ROOT = Path(r"E:\素材\aseprite\build")
EXTERNAL_LAYER_ROOT = Path(r"E:\素材\aseprite\layer")

ASSETS = {
    "lodge_ordinary": {
        "source_dir": EXTERNAL_ROOT / "基础度假屋",
        "aseprite": "PuTongDuJiaWu.aseprite",
        "lighting_dir": "PuTongDuJiaWu_layers_lighting",
        "proxy": "PuTongDuJiaWu_3DShadowProxy_v3.blend",
        "proxy_footprint_px": (146.0, 98.09375),
        "proxy_scale": 32.0,
        "expected_layers": {
            "layer",
            "ground",
            "wall",
            "roof",
            "interior",
            "canwalk",
            "portal",
            "light",
        },
    },
    "shop_general": {
        "source_dir": EXTERNAL_ROOT / "小商店",
        "aseprite": "build1.aseprite",
        "lighting_dir": "build1_lighting",
        "proxy": "Build1_3DShadowProxy.blend",
        "proxy_footprint_px": (176.0, 118.25),
        "proxy_scale": 32.0,
        "expected_layers": {
            "layer",
            "interior",
            "portal",
            "CanWalk",
            "wall",
            "roof",
            "light",
        },
    },
    "shop_small": {
        "source_dir": EXTERNAL_ROOT / "小型超市",
        "aseprite": "ChaoShi1.aseprite",
        "lighting_dir": "ChaoShi1_lighting",
        "proxy": "ChaoShi1_3DShadowProxy_v2.blend",
        "proxy_footprint_px": (192.0, 128.0),
        "proxy_scale": 32.0,
        "expected_layers": {
            "layer",
            "interior",
            "portal",
            "canwalk",
            "wall",
            "roof",
            "light",
        },
    },
    "street_lamp": {
        "source_dir": EXTERNAL_ROOT / "灯1",
        "aseprite": "light.aseprite",
        "lighting_dir": "light_lighting",
        "proxy": "Light1_3DShadowProxy.blend",
        "expected_layers": {
            "layer",
            "wall",
            "roof",
            "light",
        },
    },
}

REQUIRED_LIGHTING_MAPS = {
    "lodge_ordinary": {
        "ground.png",
        "ground_n.png",
        "ground_s.png",
        "ground_o.png",
        "wall.png",
        "wall_n.png",
        "wall_s.png",
        "wall_o.png",
        "roof.png",
        "roof_n.png",
        "roof_s.png",
        "roof_o.png",
    },
    "shop_general": {
        "wall.png",
        "wall_n.png",
        "wall_s.png",
        "wall_o.png",
        "roof.png",
        "roof_n.png",
        "roof_s.png",
        "roof_o.png",
    },
    "shop_small": {
        "wall.png",
        "wall_n.png",
        "wall_s.png",
        "wall_o.png",
        "roof.png",
        "roof_n.png",
        "roof_s.png",
        "roof_o.png",
    },
    "street_lamp": {
        "wall.png",
        "wall_n.png",
        "wall_s.png",
        "wall_o.png",
        "roof.png",
        "roof_n.png",
        "roof_s.png",
        "roof_o.png",
    },
}

TREE_ASSETS = {
    "pine": {
        "source_dir": EXTERNAL_ROOT / "松树",
        "aseprite": "tree1.aseprite",
        "color_png": "tree1.png",
        "lighting_dir": "tree1_lighting",
        "proxy": "Tree1_3DShadowProxy.blend",
    },
}

GROUND_ASSETS = {
    "grass_wild": {
        "source_dir": EXTERNAL_LAYER_ROOT / "草地",
        "aseprite": "glass1.aseprite",
        "color_png": "glass1.png",
        "lighting_dir": "grass1_lighting",
        "color_map": "grass1.png",
        "normal_map": "grass1_n.png",
        "specular_map": "grass1_s.png",
        "occlusion_map": "grass1_o.png",
    },
    "grass_trimmed": {
        "source_dir": EXTERNAL_LAYER_ROOT / "修剪草坪",
        "aseprite": "glass_trim.aseprite",
        "color_png": "glass_trim.png",
        "lighting_dir": "grass_trim_lighting",
        "color_map": "grass_trim.png",
        "normal_map": "grass_trim_n.png",
        "specular_map": "grass_trim_s.png",
        "occlusion_map": "grass_trim_o.png",
    },
}


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = zlib.crc32(kind)
    checksum = zlib.crc32(payload, checksum)
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", checksum & 0xFFFFFFFF)
    )


def write_rgba_png(path: Path, width: int, height: int, pixels: bytearray) -> None:
    rows = bytearray()
    row_bytes = width * 4
    for y in range(height):
        rows.append(0)
        rows.extend(pixels[y * row_bytes : (y + 1) * row_bytes])
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png.extend(png_chunk(b"IHDR", header))
    png.extend(png_chunk(b"IDAT", zlib.compress(bytes(rows), 9)))
    png.extend(png_chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def alpha_bounds(pixels: bytearray, width: int, height: int) -> list[int] | None:
    min_x = width
    min_y = height
    max_x = -1
    max_y = -1
    for y in range(height):
        row = y * width * 4
        for x in range(width):
            if pixels[row + x * 4 + 3] == 0:
                continue
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    if max_x < min_x or max_y < min_y:
        return None
    return [min_x, min_y, max_x - min_x + 1, max_y - min_y + 1]


def alpha_components(pixels: bytearray, width: int, height: int) -> list[dict]:
    remaining: set[tuple[int, int]] = set()
    for y in range(height):
        row = y * width * 4
        for x in range(width):
            if pixels[row + x * 4 + 3] > 0:
                remaining.add((x, y))
    components: list[dict] = []
    offsets = (
        (-1, -1), (0, -1), (1, -1),
        (-1, 0), (1, 0),
        (-1, 1), (0, 1), (1, 1),
    )
    while remaining:
        first = next(iter(remaining))
        remaining.remove(first)
        queue = [first]
        points = [first]
        while queue:
            x, y = queue.pop()
            for dx, dy in offsets:
                neighbor = (x + dx, y + dy)
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    queue.append(neighbor)
                    points.append(neighbor)
        min_x = min(point[0] for point in points)
        min_y = min(point[1] for point in points)
        max_x = max(point[0] for point in points)
        max_y = max(point[1] for point in points)
        sample = points[len(points) // 2]
        sample_index = (sample[1] * width + sample[0]) * 4
        components.append(
            {
                "bounds": [
                    min_x,
                    min_y,
                    max_x - min_x + 1,
                    max_y - min_y + 1,
                ],
                "center": [
                    round((min_x + max_x) * 0.5, 3),
                    round((min_y + max_y) * 0.5, 3),
                ],
                "color": "#%02X%02X%02X" % tuple(pixels[sample_index : sample_index + 3]),
                "pixel_count": len(points),
            }
        )
    components.sort(key=lambda item: (item["bounds"][1], item["bounds"][0]))
    return components


def extract_aseprite(source: Path, output_dir: Path) -> dict:
    data = source.read_bytes()
    if len(data) < 128 or struct.unpack_from("<H", data, 4)[0] != 0xA5E0:
        raise ValueError(f"not an Aseprite file: {source}")
    frame_count = struct.unpack_from("<H", data, 6)[0]
    width = struct.unpack_from("<H", data, 8)[0]
    height = struct.unpack_from("<H", data, 10)[0]
    depth = struct.unpack_from("<H", data, 12)[0]
    if frame_count != 1 or depth != 32:
        raise ValueError("expected a single-frame RGBA Aseprite file")

    layers: list[dict] = []
    canvases: dict[int, bytearray] = {}
    cels: list[dict] = []
    frame_offset = 128
    frame_size = struct.unpack_from("<I", data, frame_offset)[0]
    frame_end = frame_offset + frame_size
    offset = frame_offset + 16
    while offset < frame_end:
        chunk_size, chunk_type = struct.unpack_from("<IH", data, offset)
        payload = offset + 6
        chunk_end = offset + chunk_size
        if chunk_type == 0x2004:
            flags, layer_type, child_level = struct.unpack_from("<HHH", data, payload)
            opacity = data[payload + 12]
            name_length = struct.unpack_from("<H", data, payload + 16)[0]
            name = data[payload + 18 : payload + 18 + name_length].decode("utf-8")
            layers.append(
                {
                    "index": len(layers),
                    "name": name,
                    "flags": flags,
                    "type": layer_type,
                    "child_level": child_level,
                    "opacity": opacity,
                }
            )
        elif chunk_type == 0x2005:
            layer_index = struct.unpack_from("<H", data, payload)[0]
            x = struct.unpack_from("<h", data, payload + 2)[0]
            y = struct.unpack_from("<h", data, payload + 4)[0]
            opacity = data[payload + 6]
            cel_type = struct.unpack_from("<H", data, payload + 7)[0]
            if cel_type != 2:
                raise ValueError(f"unsupported cel type {cel_type}")
            cel_width, cel_height = struct.unpack_from("<HH", data, payload + 16)
            raw = zlib.decompress(data[payload + 20 : chunk_end])
            if len(raw) != cel_width * cel_height * 4:
                raise ValueError("unexpected Aseprite cel payload size")
            canvas = canvases.setdefault(layer_index, bytearray(width * height * 4))
            for row in range(cel_height):
                destination_y = y + row
                if destination_y < 0 or destination_y >= height:
                    continue
                for column in range(cel_width):
                    destination_x = x + column
                    if destination_x < 0 or destination_x >= width:
                        continue
                    source_index = (row * cel_width + column) * 4
                    destination_index = (destination_y * width + destination_x) * 4
                    alpha = raw[source_index + 3]
                    canvas[destination_index : destination_index + 4] = bytes(
                        (
                            raw[source_index],
                            raw[source_index + 1],
                            raw[source_index + 2],
                            (alpha * opacity + 127) // 255,
                        )
                    )
            cels.append(
                {
                    "layer": layers[layer_index]["name"],
                    "x": x,
                    "y": y,
                    "width": cel_width,
                    "height": cel_height,
                }
            )
        offset = chunk_end

    output_dir.mkdir(parents=True, exist_ok=True)
    layer_metadata: list[dict] = []
    for layer in layers:
        pixels = canvases.get(layer["index"], bytearray(width * height * 4))
        safe_name = "".join(
            character if character.isalnum() or character in "-_" else "_"
            for character in layer["name"]
        )
        output_path = output_dir / f"{safe_name}.png"
        write_rgba_png(output_path, width, height, pixels)
        layer_metadata.append(
            {
                **layer,
                "runtime_file": str(output_path.relative_to(ROOT)).replace("\\", "/"),
                "alpha_bounds": alpha_bounds(pixels, width, height),
                "components": (
                    alpha_components(pixels, width, height)
                    if layer["name"] in {"portal", "light"}
                    else []
                ),
            }
        )

    metadata = {
        "source": str(source),
        "canvas": [width, height],
        "layers": layer_metadata,
        "cels": cels,
    }
    (output_dir / "layers.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return metadata


def file_hash(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_proxy_metadata(
    asset_id: str,
    metadata: dict,
    spec: dict,
) -> None:
    expected_footprint = spec.get("proxy_footprint_px")
    expected_scale = spec.get("proxy_scale")
    if expected_footprint is None and expected_scale is None:
        return
    if not metadata:
        raise ValueError(f"{asset_id}: missing shadow_proxy.json")
    if expected_scale is not None and abs(
        float(metadata.get("uniform_scale", 0.0)) - float(expected_scale)
    ) > 0.001:
        raise ValueError(
            f"{asset_id}: proxy scale is {metadata.get('uniform_scale')}, "
            f"expected {expected_scale}"
        )
    if expected_footprint is not None:
        actual = metadata.get("footprint_px", [])
        if len(actual) != 2 or any(
            abs(float(actual[index]) - float(expected_footprint[index])) > 0.01
            for index in range(2)
        ):
            raise ValueError(
                f"{asset_id}: proxy footprint is {actual}, "
                f"expected {list(expected_footprint)}"
            )


def import_asset(asset_id: str, spec: dict) -> dict:
    source_dir: Path = spec["source_dir"]
    expected: set[str] = spec["expected_layers"]
    source_target = SOURCE_ROOT / asset_id
    runtime_target = RUNTIME_ROOT / asset_id
    if source_target.exists():
        shutil.rmtree(source_target)
    shutil.copytree(source_dir, source_target)

    layer_dir = runtime_target / "layers"
    if layer_dir.exists():
        shutil.rmtree(layer_dir)
    layer_metadata = extract_aseprite(
        source_target / spec["aseprite"],
        layer_dir,
    )
    found = {layer["name"] for layer in layer_metadata["layers"]}
    missing = expected - found
    if missing:
        raise ValueError(f"{asset_id}: missing required layers {sorted(missing)}")

    lighting_source = source_target / spec["lighting_dir"]
    lighting_target = runtime_target / "lighting"
    if lighting_target.exists():
        shutil.rmtree(lighting_target)
    shutil.copytree(lighting_source, lighting_target)

    required_maps = REQUIRED_LIGHTING_MAPS[asset_id]
    missing_maps = {
        name for name in required_maps if not (lighting_target / name).is_file()
    }
    if missing_maps:
        raise ValueError(f"{asset_id}: missing lighting maps {sorted(missing_maps)}")

    source_files = [path for path in source_target.rglob("*") if path.is_file()]
    manifest = {
        "asset_id": asset_id,
        "source_dir": str(source_target.relative_to(ROOT)).replace("\\", "/"),
        "runtime_dir": str(runtime_target.relative_to(ROOT)).replace("\\", "/"),
        "canvas": layer_metadata["canvas"],
        "layers": layer_metadata["layers"],
        "proxy_source": str(
            (source_target / spec["proxy"]).relative_to(ROOT)
        ).replace("\\", "/"),
        "proxy_runtime": str(
            (runtime_target / "shadow_proxy.glb").relative_to(ROOT)
        ).replace("\\", "/"),
        "lighting_maps": {
            str(path.relative_to(lighting_target)).replace("\\", "/"): file_hash(path)
            for path in sorted(lighting_target.glob("*.png"))
        },
        "source_hashes": {
            str(path.relative_to(source_target)).replace("\\", "/"): file_hash(path)
            for path in sorted(source_files)
        },
    }
    proxy_metadata_path = runtime_target / "shadow_proxy.json"
    proxy_metadata = None
    if proxy_metadata_path.is_file():
        proxy_metadata = json.loads(
            proxy_metadata_path.read_text(encoding="utf-8")
        )
        validate_proxy_metadata(asset_id, proxy_metadata, spec)
        manifest["proxy_metadata"] = proxy_metadata
    (runtime_target / "asset.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return manifest


def import_tree_asset(asset_id: str, spec: dict) -> dict:
    source_target = SOURCE_TREE_ROOT / asset_id
    runtime_target = RUNTIME_TREE_ROOT / asset_id
    if source_target.exists():
        shutil.rmtree(source_target)
    shutil.copytree(spec["source_dir"], source_target)

    layer_metadata = extract_aseprite(
        source_target / spec["aseprite"],
        runtime_target / "layers",
    )
    lighting_source = source_target / spec["lighting_dir"]
    runtime_target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_target / spec["color_png"], runtime_target / "color.png")
    shutil.copy2(lighting_source / "wall_n.png", runtime_target / "normal.png")
    shutil.copy2(lighting_source / "wall_s.png", runtime_target / "specular.png")
    shutil.copy2(lighting_source / "wall_o.png", runtime_target / "occlusion.png")

    source_files = [path for path in source_target.rglob("*") if path.is_file()]
    manifest = {
        "asset_id": asset_id,
        "source_dir": str(source_target.relative_to(ROOT)).replace("\\", "/"),
        "runtime_dir": str(runtime_target.relative_to(ROOT)).replace("\\", "/"),
        "canvas": layer_metadata["canvas"],
        "layers": layer_metadata["layers"],
        "proxy_source": str(
            (source_target / spec["proxy"]).relative_to(ROOT)
        ).replace("\\", "/"),
        "proxy_runtime": str(
            (runtime_target / "shadow_proxy.glb").relative_to(ROOT)
        ).replace("\\", "/"),
        "surface_maps": {
            name: file_hash(runtime_target / name)
            for name in [
                "color.png",
                "normal.png",
                "specular.png",
                "occlusion.png",
            ]
        },
        "source_hashes": {
            str(path.relative_to(source_target)).replace("\\", "/"): file_hash(path)
            for path in sorted(source_files)
        },
    }
    proxy_metadata_path = runtime_target / "shadow_proxy.json"
    if proxy_metadata_path.is_file():
        manifest["proxy_metadata"] = json.loads(
            proxy_metadata_path.read_text(encoding="utf-8")
        )
    (runtime_target / "asset.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return manifest


def import_ground_asset(asset_id: str, spec: dict) -> dict:
    source_target = SOURCE_GROUND_ROOT / asset_id
    runtime_target = RUNTIME_GROUND_ROOT / asset_id
    if source_target.exists():
        shutil.rmtree(source_target)
    shutil.copytree(spec["source_dir"], source_target)
    runtime_target.mkdir(parents=True, exist_ok=True)

    lighting_source = source_target / spec["lighting_dir"]
    copies = {
        spec["color_png"]: "color.png",
        spec["lighting_dir"] + "/" + spec["color_map"]: "color.png",
        spec["lighting_dir"] + "/" + spec["normal_map"]: "normal.png",
        spec["lighting_dir"] + "/" + spec["specular_map"]: "specular.png",
        spec["lighting_dir"] + "/" + spec["occlusion_map"]: "occlusion.png",
    }
    for relative_source, runtime_name in copies.items():
        shutil.copy2(source_target / relative_source, runtime_target / runtime_name)

    source_files = [path for path in source_target.rglob("*") if path.is_file()]
    manifest = {
        "asset_id": asset_id,
        "source_dir": str(source_target.relative_to(ROOT)).replace("\\", "/"),
        "runtime_dir": str(runtime_target.relative_to(ROOT)).replace("\\", "/"),
        "canvas_px": [32, 32],
        "runtime_maps": {
            name: file_hash(runtime_target / name)
            for name in [
                "color.png",
                "normal.png",
                "specular.png",
                "occlusion.png",
            ]
        },
        "source_hashes": {
            str(path.relative_to(source_target)).replace("\\", "/"): file_hash(path)
            for path in sorted(source_files)
        },
    }
    (runtime_target / "asset.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return manifest


def main() -> None:
    (ROOT / "art" / "source").mkdir(parents=True, exist_ok=True)
    (ROOT / "art" / "source" / ".gdignore").write_text("", encoding="utf-8")
    requested = sys.argv[1:]
    known = set(ASSETS) | set(TREE_ASSETS) | set(GROUND_ASSETS)
    unknown = set(requested) - known
    if unknown:
        raise SystemExit(f"unknown asset ids: {sorted(unknown)}")
    selected = requested or list(ASSETS) + list(TREE_ASSETS) + list(GROUND_ASSETS)
    for asset_id in selected:
        if asset_id in ASSETS:
            manifest = import_asset(asset_id, ASSETS[asset_id])
        elif asset_id in TREE_ASSETS:
            manifest = import_tree_asset(asset_id, TREE_ASSETS[asset_id])
        else:
            manifest = import_ground_asset(asset_id, GROUND_ASSETS[asset_id])
        canvas = manifest.get("canvas", manifest.get("canvas_px"))
        print(f"[lighting-assets] {asset_id}: {canvas}")


if __name__ == "__main__":
    main()
