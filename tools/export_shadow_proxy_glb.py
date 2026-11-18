"""Blender-side export for one lighting shadow proxy.

Example:
    blender --background --python tools/export_shadow_proxy_glb.py -- \
        --blend path/to/proxy.blend \
        --output res://path/proxy.glb \
        --footprint 192 128 \
        --scale 32
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def _portable_path(path: Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(PROJECT_ROOT).as_posix()
    except ValueError:
        return resolved.as_posix()


def _args() -> dict:
    argv = sys.argv
    if "--" not in argv:
        raise ValueError("missing -- arguments")
    values = argv[argv.index("--") + 1 :]
    parsed = {}
    index = 0
    while index < len(values):
        key = values[index]
        if key == "--footprint":
            parsed["footprint"] = (float(values[index + 1]), float(values[index + 2]))
            index += 3
        elif key == "--scale":
            parsed["scale"] = float(values[index + 1])
            index += 2
        else:
            parsed[key.lstrip("-").replace("-", "_")] = values[index + 1]
            index += 2
    return parsed


def _mesh_objects() -> list[bpy.types.Object]:
    return [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]


def _bounds(objects: list[bpy.types.Object]) -> tuple[Vector, Vector]:
    points = [
        obj.matrix_world @ Vector(corner)
        for obj in objects
        for corner in obj.bound_box
    ]
    minimum = Vector(
        (
            min(point.x for point in points),
            min(point.y for point in points),
            min(point.z for point in points),
        )
    )
    maximum = Vector(
        (
            max(point.x for point in points),
            max(point.y for point in points),
            max(point.z for point in points),
        )
    )
    return minimum, maximum


def main() -> None:
    arguments = _args()
    blend_path = Path(arguments["blend"])
    output_path = Path(arguments["output"])
    footprint_x, footprint_y = arguments["footprint"]

    bpy.ops.wm.open_mainfile(filepath=str(blend_path))
    objects = _mesh_objects()
    if not objects:
        raise RuntimeError("shadow proxy has no mesh objects")

    minimum, maximum = _bounds(objects)
    span = maximum - minimum
    if min(span.x, span.y, span.z) <= 0.0001:
        raise RuntimeError(f"invalid proxy bounds: {span}")

    if "scale" in arguments:
        uniform_scale = arguments["scale"]
        expected_x = span.x * uniform_scale
        expected_y = span.y * uniform_scale
        if abs(expected_x - footprint_x) > 0.05 or abs(expected_y - footprint_y) > 0.05:
            raise RuntimeError(
                "footprint does not match the model envelope at the requested scale: "
                f"expected ({expected_x:.5f}, {expected_y:.5f}), "
                f"got ({footprint_x:.5f}, {footprint_y:.5f})"
            )
    else:
        scale_x = footprint_x / span.x
        scale_y = footprint_y / span.y
        uniform_scale = (scale_x + scale_y) * 0.5
    for obj in objects:
        obj.scale *= uniform_scale
    bpy.context.view_layer.update()

    minimum, maximum = _bounds(objects)
    center = (minimum + maximum) * 0.5
    translation = Vector((-center.x, -center.y, -minimum.z))
    for obj in objects:
        obj.location += translation
    bpy.context.view_layer.update()

    for scene_object in bpy.context.scene.objects:
        scene_object.select_set(False)
    for obj in objects:
        obj.hide_set(False)
        obj.hide_viewport = False
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]

    minimum, maximum = _bounds(objects)
    triangle_count = 0
    for obj in objects:
        obj.data.calc_loop_triangles()
        triangle_count += len(obj.data.loop_triangles)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(output_path),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_cameras=False,
        export_lights=False,
        export_yup=True,
    )
    metadata = {
        "source_blend": _portable_path(blend_path),
        "proxy_file": _portable_path(output_path),
        "uniform_scale": uniform_scale,
        "footprint_px": [footprint_x, footprint_y],
        "bounds_min_px": [round(value, 4) for value in minimum],
        "bounds_max_px": [round(value, 4) for value in maximum],
        "size_px": [round(value, 4) for value in maximum - minimum],
        "pivot_px": [0.0, 0.0, 0.0],
        "ground_y_px": 0.0,
        "triangle_count": triangle_count,
        "mesh_count": len(objects),
    }
    output_path.with_suffix(".json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"[shadow-proxy] {output_path}: {triangle_count} tris {metadata['size_px']}")


if __name__ == "__main__":
    main()
