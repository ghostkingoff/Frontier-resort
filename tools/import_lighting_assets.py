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
EXTERNAL_ROOT = Path(r"E:\素材\aseprite\build")

ASSETS = {
    "lodge_ordinary": {
        "source_dir": EXTERNAL_ROOT / "基础度假屋",
        "aseprite": "PuTongDuJiaWu.aseprite",
        "lighting_dir": "PuTongDuJiaWu_layers_lighting",
        "proxy": "PuTongDuJiaWu_3DShadowProxy_v2.blend",
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

    required_maps = {
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
    }
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
    if proxy_metadata_path.is_file():
        manifest["proxy_metadata"] = json.loads(
            proxy_metadata_path.read_text(encoding="utf-8")
        )
    (runtime_target / "asset.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return manifest


def main() -> None:
    (ROOT / "art" / "source").mkdir(parents=True, exist_ok=True)
    (ROOT / "art" / "source" / ".gdignore").write_text("", encoding="utf-8")
    requested = sys.argv[1:]
    unknown = set(requested) - set(ASSETS)
    if unknown:
        raise SystemExit(f"unknown asset ids: {sorted(unknown)}")
    selected = requested or list(ASSETS)
    for asset_id in selected:
        spec = ASSETS[asset_id]
        manifest = import_asset(asset_id, spec)
        print(f"[lighting-assets] {asset_id}: {manifest['canvas']}")


if __name__ == "__main__":
    main()
