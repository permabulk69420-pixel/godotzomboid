"""Generates the trees and bushes in Blender (headless, `pip install bpy`) and exports them for Godot.

Each tree is grown from a seed: a trunk that splits into limbs, which split into branches, down to twigs. The wood is a tapered tube
with bark texture (UVs in metres, like everything else). The foliage is cards (flat squares) each showing a whole clump of leaves
(assets/foliage/leaf_cluster.png), placed along the outer branches. A few hundred cards make a full canopy for very few triangles;
the cost on the Quest is overdraw, so card counts are kept modest.

Shading is done here, not baked: the cards' normals point out from the middle of the crown (so the canopy lights like one soft
mass instead of flat cards), and the vertex colours darken the inside and underside of the crown and the bark under it.

Output: assets/trees/trees.glb with objects <variant>_bark and <variant>_leaves for every variant, and assets/trees/trees.json
(name, kind, height, crown radius, trunk radius). Origin of every variant: the base of its trunk.

Run:  python3 tools/make_trees.py [--preview]       (--preview renders /tmp/trees.png)
"""
import argparse
import json
import math
import os
import random
import sys

import bpy  # noqa: E402  (bpy first: it makes bmesh importable)
import bmesh
from mathutils import Matrix, Vector

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "assets", "trees")

VARIANTS = [
    # name, kind, seed, trunk height, trunk radius, limbs, depth, limb length, card size, cards per tip
    dict(name="street_a", kind="street", seed=11, trunk_h=2.4, trunk_r=0.14, limbs=4, depth=3, limb_len=2.6, card=1.7, per_tip=2, fill=45),
    dict(name="street_b", kind="street", seed=23, trunk_h=2.1, trunk_r=0.13, limbs=5, depth=3, limb_len=2.2, card=1.5, per_tip=2, fill=40),
    dict(name="shade_a", kind="shade", seed=37, trunk_h=3.0, trunk_r=0.30, limbs=5, depth=3, limb_len=4.2, card=2.3, per_tip=2, fill=90),
    dict(name="shade_b", kind="shade", seed=41, trunk_h=2.6, trunk_r=0.26, limbs=6, depth=3, limb_len=3.6, card=2.1, per_tip=2, fill=80),
    dict(name="dead_a", kind="dead", seed=53, trunk_h=2.6, trunk_r=0.20, limbs=5, depth=4, limb_len=3.2, card=0.0, per_tip=0, fill=0),
    dict(name="bush_a", kind="bush", seed=61, radius=0.75, centre=0.65, cards=26, card=1.0),
    dict(name="bush_b", kind="bush", seed=67, radius=1.05, centre=0.85, cards=38, card=1.25),
]


class Mesh:
    def __init__(self):
        self.verts, self.normals, self.colours, self.faces, self.uvs = [], [], [], [], []

    def add_vert(self, p, n, c):
        self.verts.append(Vector(p))
        self.normals.append(Vector(n).normalized())
        self.colours.append(c)
        return len(self.verts) - 1


# ---- wood ----------------------------------------------------------------------------------------------------------------------------

def grow(rng, start, direction, length, radius, depth, max_depth, branches, tips):
    """One branch as a polyline with radii; recurses into children."""
    segments = max(3, int(length / 0.45))
    pts, radii = [Vector(start)], [radius]
    d = Vector(direction).normalized()
    p = Vector(start)
    end_radius = radius * (0.35 if depth == max_depth else 0.55)
    for i in range(1, segments + 1):
        wobble = Vector((rng.gauss(0, 0.12), rng.gauss(0, 0.12), rng.gauss(0, 0.06)))
        up = Vector((0, 0, 0.10 if depth > 0 else 0.0))
        d = (d + wobble + up).normalized()
        p = p + d * (length / segments)
        pts.append(p.copy())
        radii.append(radius + (end_radius - radius) * i / segments)
    branches.append((pts, radii))
    if depth >= max_depth:
        tips.append((pts[-1], d))
        tips.append((pts[len(pts) // 2], d))
        return
    children = rng.randint(2, 3) if depth > 0 else 0
    for k in range(children):
        t = rng.uniform(0.55, 1.0)
        idx = min(len(pts) - 1, max(1, int(t * (len(pts) - 1))))
        axis = d.cross(Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1, 1)))).normalized()
        angle = math.radians(rng.uniform(25, 55))
        child_dir = (Matrix.Rotation(angle, 3, axis) @ d + Vector((0, 0, 0.25))).normalized()
        grow(rng, pts[idx], child_dir, length * rng.uniform(0.55, 0.7), radii[idx] * 0.6, depth + 1, max_depth, branches, tips)


def tube(mesh, pts, radii, sides, colour_at):
    """A tapered tube along the polyline, UVs in metres (around, along)."""
    base = len(mesh.verts)
    frames = []
    tangent = (pts[1] - pts[0]).normalized()
    normal = tangent.orthogonal().normalized()
    along = 0.0
    for i, p in enumerate(pts):
        if i > 0:
            new_t = (pts[min(i + 1, len(pts) - 1)] - pts[i - 1]).normalized()
            axis = tangent.cross(new_t)
            if axis.length > 1e-6:
                normal = Matrix.Rotation(tangent.angle(new_t), 3, axis.normalized()) @ normal
            tangent = new_t
            along += (pts[i] - pts[i - 1]).length
        binormal = tangent.cross(normal)
        frames.append((p, normal.copy(), binormal.copy(), radii[i], along))
    circumference = math.tau * radii[0]
    for p, n, b, r, along in frames:
        for s in range(sides + 1):
            a = math.tau * s / sides
            off = n * math.cos(a) + b * math.sin(a)
            mesh.add_vert(p + off * r, off, colour_at(p))
            mesh.uvs.append(None)
            mesh.uvs[-1] = (circumference * s / sides, along)
    ring = sides + 1
    for i in range(len(frames) - 1):
        for s in range(sides):
            a = base + i * ring + s
            mesh.faces.append([a, a + 1, a + ring + 1, a + ring])


# ---- foliage -----------------------------------------------------------------------------------------------------------------------

def card(mesh, rng, centre, size, outward, crown_centre, crown_radius, crown_bottom, crown_top):
    """A square card showing a clump of leaves, roughly facing out of the crown, with crown-shaped normals and shading."""
    n = (outward.normalized() + Vector((rng.gauss(0, 0.6), rng.gauss(0, 0.6), rng.gauss(0, 0.6)))).normalized()
    u = n.orthogonal().normalized()
    u = Matrix.Rotation(rng.uniform(0, math.tau), 3, n) @ u
    v = n.cross(u)
    half = size * 0.5
    corners = [centre - u * half - v * half, centre + u * half - v * half, centre + u * half + v * half, centre - u * half + v * half]
    uv = [(0, 0), (1, 0), (1, 1), (0, 1)]
    idx = []
    for c, t in zip(corners, uv):
        radial = c - crown_centre
        normal = (radial.normalized() * 0.75 + n * 0.25) if radial.length > 1e-4 else n
        outer = min(1.0, radial.length / max(crown_radius, 0.1))
        height = (c.z - crown_bottom) / max(crown_top - crown_bottom, 0.1)
        light = max(0.0, min(1.0, 0.25 + 0.45 * outer + 0.35 * height))
        idx.append(mesh.add_vert(c, normal, (light, light, light, 1.0)))
        mesh.uvs.append(t)
    mesh.faces.append(idx)


def make_variant(v):
    rng = random.Random(v["seed"])
    wood, leaves = Mesh(), Mesh()
    info = {"name": v["name"], "kind": v["kind"]}
    if v["kind"] == "bush":
        centre = Vector((0, 0, v["centre"]))
        r = v["radius"]
        for k in range(v["cards"]):
            d = Vector((rng.gauss(0, 1), rng.gauss(0, 1), abs(rng.gauss(0, 0.8)))).normalized()
            pos = centre + d * r * rng.uniform(0.35, 0.85)
            pos.z = max(pos.z, v["card"] * 0.3)
            card(leaves, rng, pos, v["card"] * rng.uniform(0.8, 1.15), d, centre, r, 0.0, centre.z + r)
        # a few stems
        for k in range(5):
            d = Vector((rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5), 1)).normalized()
            tube(wood, [Vector((0, 0, 0)), d * r * 0.6, d * r], [0.025, 0.018, 0.01], 4, lambda p: (0.35, 0.35, 0.35, 1.0))
        info.update(height=round(centre.z + r, 2), crown_radius=round(r, 2), trunk_radius=0.0)
        return wood, leaves, info

    branches, tips = [], []
    # the trunk: straight-ish up to where it splits
    trunk_pts = [Vector((0, 0, 0))]
    p = Vector((0, 0, 0))
    lean = Vector((rng.gauss(0, 0.05), rng.gauss(0, 0.05), 1)).normalized()
    for i in range(1, 6):
        p = p + lean * (v["trunk_h"] / 5) + Vector((rng.gauss(0, 0.02), rng.gauss(0, 0.02), 0))
        trunk_pts.append(p.copy())
    trunk_radii = [v["trunk_r"] * (1.25 - 0.35 * i / 5) for i in range(6)]
    trunk_radii[0] *= 1.3                                   # the flare at the root
    branches.append((trunk_pts, trunk_radii))
    for k in range(v["limbs"]):
        ang = math.tau * k / v["limbs"] + rng.uniform(-0.3, 0.3)
        d = Vector((math.cos(ang), math.sin(ang), rng.uniform(0.55, 1.0))).normalized()
        grow(rng, trunk_pts[-1], d, v["limb_len"] * rng.uniform(0.85, 1.1), trunk_radii[-1] * 0.75, 1, v["depth"], branches, tips)

    tip_pts = [t[0] for t in tips] or [trunk_pts[-1]]
    crown_centre = sum(tip_pts, Vector()) / len(tip_pts)
    crown_radius = max((t - crown_centre).length for t in tip_pts) + v["card"] * 0.5
    crown_bottom = min(t.z for t in tip_pts) - v["card"] * 0.5
    crown_top = max(t.z for t in tip_pts) + v["card"] * 0.5

    def bark_colour(p):
        if v["kind"] == "dead":
            return (0.8, 0.8, 0.8, 1.0)
        inside = 1.0 - min(1.0, (p - crown_centre).length / max(crown_radius, 0.1))
        shade = 0.85 - 0.45 * inside if p.z > crown_bottom - 0.5 else 0.75
        return (shade, shade, shade, 1.0)

    for pts, radii in branches:
        sides = 8 if radii[0] > 0.12 else (5 if radii[0] > 0.04 else 3)
        tube(wood, pts, radii, sides, bark_colour)
    if v["per_tip"] > 0:
        for pos, d in tips:
            for k in range(v["per_tip"]):
                offset = Vector((rng.gauss(0, 0.35), rng.gauss(0, 0.35), rng.gauss(0, 0.25)))
                outward = (pos - crown_centre) + d * 0.5
                card(leaves, rng, pos + offset, v["card"] * rng.uniform(0.8, 1.2), outward, crown_centre, crown_radius, crown_bottom, crown_top)
        # fill the inside of the crown so it reads as one mass rather than separate tufts
        for k in range(v["fill"]):
            pos, d = tips[rng.randrange(len(tips))]
            pull = rng.uniform(0.0, 0.55)
            at = pos + (crown_centre - pos) * pull + Vector((rng.gauss(0, 0.5), rng.gauss(0, 0.5), rng.gauss(0, 0.35)))
            card(leaves, rng, at, v["card"] * rng.uniform(0.9, 1.3), at - crown_centre, crown_centre, crown_radius, crown_bottom, crown_top)
    info.update(height=round(crown_top if v["per_tip"] else max(p.z for pts, _ in branches for p in pts), 2),
                crown_radius=round(crown_radius, 2), trunk_radius=round(v["trunk_r"] * 1.3, 3))
    return wood, leaves, info


# ---- Blender ---------------------------------------------------------------------------------------------------------------------

def to_object(name, mesh, material):
    me = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bv = [bm.verts.new(p) for p in mesh.verts]
    bm.verts.index_update()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    for f in mesh.faces:
        face = bm.faces.new([bv[i] for i in f])
        for loop, i in zip(face.loops, f):
            loop[uv_layer].uv = mesh.uvs[i]
    bm.to_mesh(me)
    bm.free()
    me.materials.append(material)
    col = me.color_attributes.new("Col", "BYTE_COLOR", "POINT")
    for i, c in enumerate(mesh.colours):
        col.data[i].color = c
    me.color_attributes.active_color = col
    me.normals_split_custom_set_from_vertices(mesh.normals)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def material(name, texture=None, alpha=False):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    bsdf = nodes["Principled BSDF"]
    vc = nodes.new("ShaderNodeVertexColor")
    vc.layer_name = "Col"
    mix = nodes.new("ShaderNodeMixRGB")
    mix.blend_type = "MULTIPLY"
    mix.inputs[0].default_value = 1.0
    links.new(vc.outputs["Color"], mix.inputs[2])
    if texture:
        img = nodes.new("ShaderNodeTexImage")
        img.image = bpy.data.images.load(texture)
        links.new(img.outputs["Color"], mix.inputs[1])
        if alpha:
            links.new(img.outputs["Alpha"], bsdf.inputs["Alpha"])
    else:
        mix.inputs[1].default_value = (0.35, 0.28, 0.22, 1)
    links.new(mix.outputs[0], bsdf.inputs["Base Color"])
    return m


def preview(objects_by_variant):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 24
    scene.cycles.device = "CPU"
    scene.render.resolution_x, scene.render.resolution_y = 1100, 420
    world = bpy.data.worlds.new("w")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.65, 0.8, 1)
    scene.world = world
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3
    sun.rotation_euler = (math.radians(50), 0, math.radians(30))
    scene.collection.objects.link(sun)
    bpy.ops.mesh.primitive_plane_add(size=200)
    x = 0.0
    for objs in objects_by_variant:
        for o in objs:
            o.location.x = x
        x += 9.0
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = x + 2
    cam.location = ((x - 9.0) / 2, -40, 6)
    cam.rotation_euler = (math.radians(90), 0, 0)
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.filepath = "/tmp/trees.png"
    bpy.ops.render.render(write_still=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bark = material("bark", os.path.join(ROOT, "assets", "materials", "bark", "albedo.jpg"))
    leaf = material("leaves", os.path.join(ROOT, "assets", "foliage", "leaf_cluster.png"), alpha=True)
    infos, objs_by_variant, exported = [], [], []
    for v in VARIANTS:
        wood, leaves, info = make_variant(v)
        objs = [to_object(v["name"] + "_bark", wood, bark)]
        if leaves.verts:
            objs.append(to_object(v["name"] + "_leaves", leaves, leaf))
        info["triangles"] = sum(len(f) - 2 for f in wood.faces) + sum(len(f) - 2 for f in leaves.faces)
        infos.append(info)
        objs_by_variant.append(objs)
        exported += objs
        print(f"{info['name']}: {info['triangles']} triangles, height {info['height']} m, crown {info['crown_radius']} m", flush=True)
    os.makedirs(OUT, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    for o in exported:
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "trees.glb"), use_selection=True, export_format="GLB",
                              export_vertex_color="ACTIVE", export_all_vertex_colors=False, export_normals=True,
                              export_materials="EXPORT", export_image_format="NONE", export_yup=True)
    json.dump({"variants": infos}, open(os.path.join(OUT, "trees.json"), "w"), indent=1)
    if args.preview:
        preview(objs_by_variant)


if __name__ == "__main__":
    main()
