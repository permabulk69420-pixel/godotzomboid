"""Downloads the game's tiling materials from Poly Haven (all CC0) into assets/materials/<name>/.

Each material gets albedo.jpg, normal.jpg (OpenGL convention, as Godot wants) and orm.jpg (Poly Haven's packed
AO / roughness / metalness map, which Godot's ORMMaterial3D reads directly), plus an entry in assets/materials/materials.json
with its real-world size in metres, so the game can tile it at true scale.

Run:  python3 tools/fetch_materials.py            (skips materials already downloaded)
"""
import io
import json
import os
import sys
import urllib.request

from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "materials")

# game name: (Poly Haven asset, resolution, rotate 90 degrees?)  - rotation turns vertical planks into horizontal siding
MATERIALS = {
    "siding": ("white_planks_clean", "2k", True),
    "brick": ("red_brick_03", "2k", False),
    "stucco": ("white_stucco_02", "2k", False),
    "shingles": ("grey_roof_01", "2k", False),
    "asphalt": ("asphalt_02", "2k", False),
    "footpath": ("concrete_pavement", "2k", False),
    "driveway": ("concrete_floor_01", "2k", False),
    "lawn": ("leafy_grass", "2k", False),
    "plaster": ("painted_plaster_wall", "2k", False),
    "wood_floor": ("laminate_floor_02", "2k", False),
    "tiles": ("floor_tiles_06", "2k", False),
    "bark": ("bark_brown_02", "1k", False),
}

MAPS = {"albedo": "Diffuse", "normal": "nor_gl", "orm": "arm"}


def get(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "godotzomboid-asset-fetch/1.0"})   # Poly Haven refuses Python's default
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def rotate(image: Image.Image, kind: str) -> Image.Image:
    turned = image.rotate(90, expand=True)              # counter-clockwise
    if kind != "normal":
        return turned
    # the normals turn with the picture: (x, y) -> (-y, x)
    r, g, b = turned.split()
    return Image.merge("RGB", (g.point(lambda v: 255 - v), r, b))


def main() -> None:
    os.makedirs(ROOT, exist_ok=True)
    index_path = os.path.join(ROOT, "materials.json")
    index = json.load(open(index_path)) if os.path.exists(index_path) else {}
    for name, (asset, resolution, turn) in MATERIALS.items():
        folder = os.path.join(ROOT, name)
        if name in index and all(os.path.exists(os.path.join(folder, f"{m}.jpg")) for m in MAPS):
            continue
        print(f"{name} <- {asset} ({resolution})", flush=True)
        os.makedirs(folder, exist_ok=True)
        files = json.loads(get(f"https://api.polyhaven.com/files/{asset}"))
        info = json.loads(get(f"https://api.polyhaven.com/info/{asset}"))
        for game_map, ph_map in MAPS.items():
            image = Image.open(io.BytesIO(get(files[ph_map][resolution]["jpg"]["url"]))).convert("RGB")
            if turn:
                image = rotate(image, game_map)
            image.save(os.path.join(folder, f"{game_map}.jpg"), quality=90)
        width_mm, height_mm = info["dimensions"][:2]
        size = [height_mm / 1000.0, width_mm / 1000.0] if turn else [width_mm / 1000.0, height_mm / 1000.0]
        index[name] = {"source": f"https://polyhaven.com/a/{asset}", "size_m": [round(size[0], 3), round(size[1], 3)]}
        json.dump(index, open(index_path, "w"), indent=1, sort_keys=True)
    print("materials ready:", ", ".join(sorted(index)))


if __name__ == "__main__":
    sys.exit(main())
