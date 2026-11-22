"""Makes the foliage textures (RGBA, transparent background) the trees, bushes, ivy and grass use.

The leaves are real: the separate leaves are cut out of Poly Haven's shrub_03 leaf texture (CC0), then stamped many times, turned,
scaled and tinted, into:
  assets/foliage/leaf_cluster.png  - a round clump of leaves on twigs, for tree canopies and bushes (one card shows a whole clump)
  assets/foliage/ivy.png           - a climbing stem with leaves, tiling vertically, for ivy on walls
  assets/foliage/grass.png         - a clump of long grass blades (drawn, not photographed), for overgrown lawns and weeds

Transparent pixels get the colour of the nearest leaf, so mipmapping doesn't add dark fringes.

Run:  python3 tools/make_foliage_textures.py
"""
import io
import json
import math
import os
import random
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "foliage")
LEAF_COMPONENTS_MIN_AREA = 30000      # the shrub's leaves are big blobs in its alpha map; its flower stalks are thin and skipped


def get(url):
    request = urllib.request.Request(url, headers={"User-Agent": "godotzomboid-asset-fetch/1.0"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def leaf_sprites():
    files = json.loads(get("https://api.polyhaven.com/files/shrub_03"))
    def image(kind):
        entry = files[kind]["2k"]
        url = (entry.get("png") or entry.get("jpg"))["url"]
        return Image.open(io.BytesIO(get(url)))
    colour = image("Diffuse").convert("RGB")
    alpha = image("Alpha").convert("L")
    mask = np.array(alpha) > 128
    labels, _ = ndimage.label(mask)
    sprites = []
    for i, box in enumerate(ndimage.find_objects(labels)):
        part = labels[box] == i + 1
        h, w = part.shape
        if part.sum() < LEAF_COMPONENTS_MIN_AREA or max(h, w) / min(h, w) > 2.2:
            continue
        rgb = colour.crop((box[1].start, box[0].start, box[1].stop, box[0].stop))
        a = Image.fromarray((part * 255).astype(np.uint8))
        sprite = rgb.convert("RGBA")
        sprite.putalpha(a)
        sprites.append(sprite)
    print(f"{len(sprites)} leaves cut out")
    return sprites


def tinted(sprite, tint, brightness):
    r, g, b, a = sprite.split()
    arr = np.asarray(Image.merge("RGB", (r, g, b))).astype(np.float32) / 255.0
    arr = arr * np.array(tint, dtype=np.float32) * brightness
    out = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8)).convert("RGBA")
    out.putalpha(a)
    return out


def stamp(canvas, sprite, centre, length, angle_deg):
    scale = length / max(sprite.size)
    s = sprite.resize((max(1, int(sprite.width * scale)), max(1, int(sprite.height * scale))), Image.LANCZOS)
    s = s.rotate(angle_deg, resample=Image.BICUBIC, expand=True)
    canvas.alpha_composite(s, (int(centre[0] - s.width / 2), int(centre[1] - s.height / 2)))


def bleed(img):
    """Fill transparent pixels with the colour of the nearest opaque one (keeps alpha as is)."""
    arr = np.array(img)
    opaque = arr[..., 3] > 127
    if not opaque.any():
        return img
    _, (iy, ix) = ndimage.distance_transform_edt(~opaque, return_indices=True)
    arr[..., :3] = arr[iy, ix, :3]
    arr[..., 3] = np.where(opaque, 255, 0)
    return Image.fromarray(arr)


LEAF_TINTS = [(0.62, 0.86, 0.48), (0.55, 0.78, 0.42), (0.70, 0.88, 0.50), (0.50, 0.70, 0.40), (0.80, 0.86, 0.50)]


def leaf_cluster(sprites, rng, size=1024):
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    c = size / 2
    # twigs radiating from the middle
    tips = []
    for k in range(9):
        ang = rng.uniform(0, math.tau)
        r = rng.uniform(0.30, 0.42) * size
        tip = (c + math.cos(ang) * r, c + math.sin(ang) * r)
        tips.append(tip)
        draw.line([(c, c), tip], fill=(70, 55, 40, 255), width=int(size * 0.008))
    # leaves: back ones first and darker, front ones last and brighter
    count = 230
    for k in range(count):
        depth = k / count
        ang = rng.uniform(0, math.tau)
        r = (rng.random() ** 0.6) * size * 0.40
        pos = (c + math.cos(ang) * r, c + math.sin(ang) * r)
        outward = math.degrees(-ang) - 90 + rng.uniform(-40, 40)        # stems point roughly back to the middle
        sprite = sprites[rng.randrange(len(sprites))]
        tint = LEAF_TINTS[rng.randrange(len(LEAF_TINTS))]
        stamp(canvas, tinted(sprite, tint, 0.55 + 0.5 * depth), pos, size * rng.uniform(0.07, 0.11), outward)
    return bleed(canvas)


def ivy(sprites, rng, w=512, h=1024):
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    # a wavy stem that starts and ends in the middle, so the texture tiles vertically
    pts = [(w / 2 + math.sin(y / h * math.tau * 2) * w * 0.12, y) for y in range(0, h + 1, 8)]
    draw.line(pts, fill=(60, 50, 35, 255), width=6)
    for k in range(70):
        y = rng.uniform(0, h)
        x = w / 2 + math.sin(y / h * math.tau * 2) * w * 0.12 + rng.uniform(-w * 0.32, w * 0.32)
        sprite = sprites[rng.randrange(len(sprites))]
        tint = (0.42, 0.62, 0.34) if rng.random() < 0.7 else (0.55, 0.70, 0.38)
        for dy in (-h, 0, h):                          # wrap so the tiling is seamless
            stamp(canvas, tinted(sprite, tint, rng.uniform(0.6, 1.0)), (x, y + dy), w * rng.uniform(0.16, 0.24), rng.uniform(0, 360))
    return bleed(canvas)


def grass(rng, size=512):
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    for k in range(120):
        base_x = size * 0.5 + rng.gauss(0, size * 0.13)
        height = size * rng.uniform(0.45, 0.97)
        lean = rng.gauss(0, size * 0.14)
        width = size * rng.uniform(0.004, 0.010)
        dry = rng.random()
        g = (0.30 + 0.25 * dry, 0.42 + 0.15 * dry, 0.16 + 0.10 * dry)
        shade = rng.uniform(0.55, 1.0)
        steps = 10
        left, right = [], []
        for i in range(steps + 1):
            t = i / steps
            x = base_x + lean * t * t
            y = size - height * t
            half = width * (1 - t) + 0.5
            left.append((x - half, y))
            right.append((x + half, y))
        colour = tuple(int(255 * min(1.0, ch * shade * (1.0 + 0.4 * dry))) for ch in g) + (255,)
        draw.polygon(left + right[::-1], fill=colour)
    canvas = canvas.filter(ImageFilter.SMOOTH)
    return bleed(canvas)


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = random.Random(7)
    sprites = leaf_sprites()
    leaf_cluster(sprites, rng).save(os.path.join(OUT, "leaf_cluster.png"))
    ivy(sprites, rng).save(os.path.join(OUT, "ivy.png"))
    grass(rng).save(os.path.join(OUT, "grass.png"))
    print("foliage textures written to", OUT)


if __name__ == "__main__":
    main()
