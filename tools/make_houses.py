"""Generates the suburban house variants in Blender (headless, `pip install bpy`) and exports them for Godot.

Each house is assembled from the same kit of parts (walls with window and door openings, window frames, partitions, floors,
ceilings, gable roofs, porch, garage, furniture blocks) at real-world scale, so every variant matches. Every house is enterable:
living room, hall, kitchen/dining, two bedrooms and a bathroom.

Lighting: ambient occlusion is baked with Cycles (CPU, no GPU needed) into the vertex colours, in two passes:
  near - contact shadow within about a metre (corners, under furniture, where walls meet floors)
  sky  - how much open sky each point can see, so interiors darken away from the windows and the eaves shade the walls
The game multiplies the textures by these colours. Surfaces are split into a fine grid so the shading has somewhere to live.

UVs are in metres (1 UV unit = 1 m along the surface), so the game tiles every material at its true real-world size.

Output, per variant: assets/houses/house_<n>.glb with objects
  exterior   - outside walls, roof, frames, porch, garage (always drawn)
  interior   - inside walls, floors, ceilings, furniture (the game hides it from a distance)
  glass      - window panes
  collision_solid, collision_walk - simple boxes for bumping into and for standing on (not drawn)
plus assets/houses/houses.json describing each variant (size, door, garage) for the street generator.

Coordinates here: x along the street, y away from the street (the front wall is at y = 0), z up. In Godot (y up) the front
faces +z and the house extends towards -z.

Run:  python3 tools/make_houses.py [--only N] [--preview]      (--preview also renders a picture of each house to /tmp)
"""
import argparse
import json
import math
import os
import random
import sys

import bpy  # noqa: E402  (bpy first: it makes bmesh importable)
import bmesh
from mathutils import Vector

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "houses")

T = 0.15            # exterior wall thickness
PT = 0.10           # partition thickness
FLOOR = 0.15        # floor level above the ground
CEIL = 2.7          # floor to ceiling
TOP = FLOOR + CEIL  # top of the walls
PITCH = 0.45        # roof rise per metre of run (about 24 degrees)
OVERHANG = 0.45
ROOF_T = 0.12
DOOR_H = 2.1
CELL = 0.35         # largest grid cell on big surfaces (the baked shading needs vertices to live on)
VARIANTS = 8

X = Vector((1, 0, 0))
Y = Vector((0, 1, 0))
Z = Vector((0, 0, 1))

MATERIALS = ["ext_wall", "trim", "roof", "glass", "int_wall", "ceiling", "floor_wood", "floor_tiles", "porch",
             "garage_door", "fabric", "furn_wood", "appliance", "counter", "door"]


# ---- a mesh being built ------------------------------------------------------------------------------------------------------------

class Part:
    def __init__(self, name):
        self.name = name
        self.verts = []
        self.faces = []      # (vertex indices, material name, uvs per corner)

    def quad(self, p0, du, dv, mat, cell=CELL, uaxis=None, vaxis=None):
        """A rectangle from corner p0 along du and dv, facing du x dv, split into a grid no coarser than `cell`.
        UVs are positions in metres measured along uaxis and vaxis (defaults: du and dv directions)."""
        p0, du, dv = Vector(p0), Vector(du), Vector(dv)
        if du.length < 1e-4 or dv.length < 1e-4:
            return
        ua = (uaxis or du.normalized())
        va = (vaxis or dv.normalized())
        nu = max(1, math.ceil(du.length / cell - 1e-6))
        nv = max(1, math.ceil(dv.length / cell - 1e-6))
        base = len(self.verts)
        for j in range(nv + 1):
            for i in range(nu + 1):
                self.verts.append(p0 + du * (i / nu) + dv * (j / nv))
        for j in range(nv):
            for i in range(nu):
                a = base + j * (nu + 1) + i
                idx = [a, a + 1, a + nu + 2, a + nu + 1]
                self.faces.append((idx, mat, [(self.verts[k].dot(ua), self.verts[k].dot(va)) for k in idx]))

    def tri(self, a, b, c, mat, uaxis, vaxis):
        base = len(self.verts)
        pts = [Vector(a), Vector(b), Vector(c)]
        self.verts.extend(pts)
        self.faces.append(([base, base + 1, base + 2], mat, [(p.dot(uaxis), p.dot(vaxis)) for p in pts]))

    # axis-aligned rectangles, named by the way they face
    def wall_rect(self, facing, c, a0, a1, z0, z1, mat, cell=CELL):
        if a1 - a0 < 1e-4 or z1 - z0 < 1e-4:
            return
        h = Vector((0, 0, z1 - z0))
        if facing == "-y":
            self.quad((a0, c, z0), (a1 - a0, 0, 0), h, mat, cell, X, Z)
        elif facing == "+y":
            self.quad((a1, c, z0), (a0 - a1, 0, 0), h, mat, cell, X, Z)
        elif facing == "+x":
            self.quad((c, a0, z0), (0, a1 - a0, 0), h, mat, cell, Y, Z)
        elif facing == "-x":
            self.quad((c, a1, z0), (0, a0 - a1, 0), h, mat, cell, Y, Z)

    def flat_rect(self, facing, z, x0, x1, y0, y1, mat, cell=CELL):
        if x1 - x0 < 1e-4 or y1 - y0 < 1e-4:
            return
        if facing == "+z":
            self.quad((x0, y0, z), (x1 - x0, 0, 0), (0, y1 - y0, 0), mat, cell, X, Y)
        else:
            self.quad((x0, y0, z), (0, y1 - y0, 0), (x1 - x0, 0, 0), mat, cell, X, Y)

    def box(self, lo, hi, mat, cell=1.0, bottom=False):
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        self.flat_rect("+z", z1, x0, x1, y0, y1, mat, cell)
        if bottom:
            self.flat_rect("-z", z0, x0, x1, y0, y1, mat, cell)
        self.wall_rect("-y", y0, x0, x1, z0, z1, mat, cell)
        self.wall_rect("+y", y1, x0, x1, z0, z1, mat, cell)
        self.wall_rect("-x", x0, y0, y1, z0, z1, mat, cell)
        self.wall_rect("+x", x1, y0, y1, z0, z1, mat, cell)

    def mirror_x(self):
        for v in self.verts:
            v.x = -v.x
        self.faces = [(list(reversed(idx)), mat, [(-u, v) for (u, v) in reversed(uvs)]) for idx, mat, uvs in self.faces]


class Boxes:
    """Plain boxes for collision."""
    def __init__(self):
        self.boxes = []

    def add(self, lo, hi):
        lo = Vector(lo); hi = Vector(hi)
        self.boxes.append((Vector((min(lo.x, hi.x), min(lo.y, hi.y), min(lo.z, hi.z))),
                           Vector((max(lo.x, hi.x), max(lo.y, hi.y), max(lo.z, hi.z)))))

    def to_part(self, name):
        part = Part(name)
        for lo, hi in self.boxes:
            part.box(lo, hi, "trim", cell=100.0, bottom=True)
        return part


# ---- walls -------------------------------------------------------------------------------------------------------------------------

def openings_panels(a0, a1, z0, z1, openings):
    """Rectangles (a0, a1, z0, z1) that cover a wall face except for its openings [(oa0, oa1, sill, head)]."""
    rects = []
    cursor = a0
    for oa0, oa1, sill, head in sorted(openings):
        rects.append((cursor, oa0, z0, z1))
        rects.append((oa0, oa1, z0, sill))
        rects.append((oa0, oa1, head, z1))
        cursor = oa1
    rects.append((cursor, a1, z0, z1))
    return [r for r in rects if r[1] - r[0] > 1e-4 and r[3] - r[2] > 1e-4]


def wall(out_part, in_part, along, c_out, inward, a0, a1, openings, out_mat, in_mat, reveal_part, reveal_mat,
         out_z=(0.0, TOP), in_z=(FLOOR, TOP), thickness=T, solid=None, out_range=None):
    """A straight wall. `along` is "x" or "y"; its outer face lies at coordinate c_out and the room is on the `inward` side (+1/-1).
    openings: [(a0, a1, sill, head)] cut through both faces, with reveals (the faces inside the opening) between them."""
    c_in = c_out + inward * thickness
    if along == "x":
        out_facing, in_facing = ("-y", "+y") if inward > 0 else ("+y", "-y")
    else:
        out_facing, in_facing = ("-x", "+x") if inward > 0 else ("+x", "-x")
    oa, ob = out_range or (a0, a1)
    for r in openings_panels(oa, ob, out_z[0], out_z[1], openings):
        out_part.wall_rect(out_facing, c_out, r[0], r[1], r[2], r[3], out_mat)
    for r in openings_panels(a0, a1, in_z[0], in_z[1], openings):
        in_part.wall_rect(in_facing, c_in, r[0], r[1], r[2], r[3], in_mat)
    lo_c, hi_c = min(c_out, c_in), max(c_out, c_in)
    for oa0, oa1, sill, head in openings:
        # jambs facing into the opening, the head facing down, the sill facing up
        if along == "x":
            reveal_part.quad((oa0, lo_c, sill), (0, hi_c - lo_c, 0), (0, 0, head - sill), reveal_mat, CELL, Y, Z)     # faces +x
            reveal_part.quad((oa1, hi_c, sill), (0, lo_c - hi_c, 0), (0, 0, head - sill), reveal_mat, CELL, Y, Z)     # faces -x
            reveal_part.flat_rect("-z", head, oa0, oa1, lo_c, hi_c, reveal_mat)
            if sill > FLOOR + 0.01:
                reveal_part.flat_rect("+z", sill, oa0, oa1, lo_c, hi_c, reveal_mat)
        else:
            reveal_part.quad((hi_c, oa0, sill), (lo_c - hi_c, 0, 0), (0, 0, head - sill), reveal_mat, CELL, X, Z)     # faces +y
            reveal_part.quad((lo_c, oa1, sill), (hi_c - lo_c, 0, 0), (0, 0, head - sill), reveal_mat, CELL, X, Z)     # faces -y
            reveal_part.flat_rect("-z", head, lo_c, hi_c, oa0, oa1, reveal_mat)
            if sill > FLOOR + 0.01:
                reveal_part.flat_rect("+z", sill, lo_c, hi_c, oa0, oa1, reveal_mat)
    if solid is not None:
        # collision: the wall between its door openings (windows count as solid)
        doors = sorted((o[0], o[1]) for o in openings if o[2] <= FLOOR + 0.01)
        cursor = a0
        for d0, d1 in doors + [(a1, a1)]:
            if d0 - cursor > 0.01:
                if along == "x":
                    solid.add((cursor, lo_c, 0), (d0, hi_c, TOP))
                else:
                    solid.add((lo_c, cursor, 0), (hi_c, d0, TOP))
            cursor = d1


def window_dressing(ext, glass, along, c_out, inward, oa0, oa1, sill, head):
    """Frame and sill on the outside, the pane in the middle of the wall."""
    out_dir = -inward
    f = 0.07      # frame width
    p = 0.04      # how far it stands proud of the wall
    mid = c_out + inward * T * 0.5
    if along == "x":
        y0, y1 = sorted((c_out, c_out + out_dir * p))
        ext.box((oa0 - f, y0, sill - f), (oa0, y1, head + f), "trim", 0.5)
        ext.box((oa1, y0, sill - f), (oa1 + f, y1, head + f), "trim", 0.5)
        ext.box((oa0, y0, head), (oa1, y1, head + f), "trim", 0.5)
        s0, s1 = sorted((c_out, c_out + out_dir * (p + 0.05)))
        ext.box((oa0 - f - 0.03, s0, sill - f - 0.04), (oa1 + f + 0.03, s1, sill - f + 0.02), "trim", 0.5, bottom=True)
        glass.wall_rect("-y" if inward > 0 else "+y", mid, oa0, oa1, sill, head, "glass", 10.0)
        # a glazing bar across the middle
        b0, b1 = sorted((mid - 0.02, mid + 0.02))
        ext.box(((oa0 + oa1) * 0.5 - 0.025, b0, sill), ((oa0 + oa1) * 0.5 + 0.025, b1, head), "trim", 0.5)
    else:
        x0, x1 = sorted((c_out, c_out + out_dir * p))
        ext.box((x0, oa0 - f, sill - f), (x1, oa0, head + f), "trim", 0.5)
        ext.box((x0, oa1, sill - f), (x1, oa1 + f, head + f), "trim", 0.5)
        ext.box((x0, oa0, head), (x1, oa1, head + f), "trim", 0.5)
        s0, s1 = sorted((c_out, c_out + out_dir * (p + 0.05)))
        ext.box((s0, oa0 - f - 0.03, sill - f - 0.04), (s1, oa1 + f + 0.03, sill - f + 0.02), "trim", 0.5, bottom=True)
        glass.wall_rect("-x" if inward > 0 else "+x", mid, oa0, oa1, sill, head, "glass", 10.0)
        b0, b1 = sorted((mid - 0.02, mid + 0.02))
        ext.box((b0, (oa0 + oa1) * 0.5 - 0.025, sill), (b1, (oa0 + oa1) * 0.5 + 0.025, head), "trim", 0.5)


# ---- roofs -------------------------------------------------------------------------------------------------------------------------

def gable_roof(ext, x0, x1, y0, y1, top, ridge_along, oh_len=(OVERHANG, OVERHANG), oh_span=(OVERHANG, OVERHANG), gable_mat="ext_wall"):
    """A gable roof over the rectangle, ridge running along x or y, with overhangs (per end and per side), fascia, a ridge cap
    and the gable end walls. Returns the height of the ridge."""
    if ridge_along == "x":
        span0, span1, len0, len1 = y0, y1, x0, x1
        def P(l, s, z):
            return Vector((l, s, z))
        flip = False
    else:
        span0, span1, len0, len1 = x0, x1, y0, y1
        def P(l, s, z):
            return Vector((s, l, z))
        flip = True       # swapping the axes mirrors the winding
    origin = P(0, 0, 0)
    half = (span1 - span0) * 0.5
    mid = span0 + half
    ridge_z = top + half * PITCH
    L0, L1 = len0 - oh_len[0], len1 + oh_len[1]
    along_vec = P(1, 0, 0) - origin

    def q(p0, du, dv, mat, cell, ua=None, va=None):
        if flip:
            ext.quad(p0 + du, -du, dv, mat, cell, ua, va)
        else:
            ext.quad(p0, du, dv, mat, cell, ua, va)

    cap_half = 0.0
    cap_z = ridge_z
    for side, oh in ((-1, oh_span[0]), (1, oh_span[1])):
        eave_s = mid + side * (half + oh)
        eave_z = top - oh * PITCH
        start = P(L0 if side < 0 else L1, eave_s, eave_z)
        du = P(L1 - L0 if side < 0 else L0 - L1, 0, 0) - origin
        dv = P(0, mid, ridge_z) - P(0, eave_s, eave_z)
        slope_dir = dv.normalized()
        normal = (dv.cross(du) if flip else du.cross(dv)).normalized()
        up = normal * ROOF_T
        q(start + up, du, dv, "roof", CELL * 2, along_vec, slope_dir)       # shingled top
        q(start + du, -du, dv, "trim", CELL * 3, along_vec, slope_dir)      # underside (soffit)
        q(start, du, up, "trim", 2.0, along_vec, Z)                         # fascia board along the eave
        for l in (L0, L1):                                                  # the cut ends of the slab, both ways round
            a = P(l, eave_s, eave_z)
            b = P(l, mid, ridge_z)
            ext.quad(a, b - a, up, "trim", 2.0)
            ext.quad(a + up, b - a, -up, "trim", 2.0)
        cap_half = abs((P(0, 0, 0) + up - origin).dot(P(0, 1, 0) - origin))
        cap_z = ridge_z + up.z
    # a cap over the ridge, closing the gap between the two slabs
    a = P(L0, mid - cap_half, cap_z)
    q(a, P(L1 - L0, 0, 0) - origin, P(0, 2 * cap_half, 0) - origin, "roof", 2.0, along_vec, P(0, 1, 0) - origin)
    # gable end walls: triangles above the wall tops, flush with the outer wall faces
    for l, outward in ((len0, -1), (len1, 1)):
        a = P(l, span0, top)
        b = P(l, span1, top)
        c = P(l, mid, ridge_z)
        ua = P(0, 1, 0) - origin
        facing_out = P(outward, 0, 0) - origin
        if (b - a).cross(c - a).dot(facing_out) > 0:
            ext.tri(a, b, c, gable_mat, ua, Z)
        else:
            ext.tri(b, a, c, gable_mat, ua, Z)
    return ridge_z


def shed_roof(ext, x0, x1, y_wall, depth, z_wall, z_front):
    """A small lean-to roof off the front wall (for the porch), sloping down towards the street."""
    up = Vector((0, 0, ROOF_T))
    start = Vector((x0, y_wall - depth, z_front))
    du = Vector((x1 - x0, 0, 0))
    dv = Vector((0, depth, z_wall - z_front))
    ext.quad(start + up, du, dv, "roof", CELL * 2, X, dv.normalized())
    ext.quad(start + du, -du, dv, "trim", 2.0, X, dv.normalized())
    ext.quad(start, du, up, "trim", 2.0, X, Z)
    for corner in (start, start + du):         # the two side edges, both ways round
        ext.quad(corner, dv, up, "trim", 2.0)
        ext.quad(corner + up, dv, -up, "trim", 2.0)


# ---- one house ---------------------------------------------------------------------------------------------------------------------

def make_house(index):
    rng = random.Random(1000 + index)
    W = round(rng.uniform(11.0, 14.0), 2)
    D = round(rng.uniform(10.0, 12.0), 2)
    ridge = "x" if index % 3 != 2 else "y"            # most houses side-gabled, every third one front-gabled
    garage = index % 4 != 3                           # most have an attached garage
    porch = rng.random() < 0.65
    mirror = index % 2 == 1

    ext, inn, glass = Part("exterior"), Part("interior"), Part("glass")
    solid, walk = Boxes(), Boxes()

    xL, xR, yF, yB = -W / 2 + T, W / 2 - T, T, D - T
    left_w = rng.uniform(4.2, 5.0)
    hx0 = xL + left_w
    hx1 = hx0 + 1.3
    yb1 = yF + 3.6
    yb2 = yb1 + 2.4
    yk = yb2
    door_x = (hx0 + hx1) * 0.5

    def win(center, width, sill=FLOOR + 0.8, head=FLOOR + DOOR_H):
        return (center - width / 2, center + width / 2, sill, head)

    # exterior walls: the front and back run the full width, the sides fit between them
    front_open = [win((xL + hx0) / 2, 1.8), win((hx1 + xR) / 2, 1.4), (door_x - 0.48, door_x + 0.48, FLOOR, FLOOR + DOOR_H)]
    back_open = [win((xL + hx0) / 2 + 0.3, 1.4, FLOOR + 1.05), win((hx1 + xR) / 2, 1.4)]
    left_open = [win((yF + yk) / 2, 1.2), win((yk + yB) / 2, 1.2)]
    right_open = [] if garage else [win((yF + yb1) / 2, 1.2), win((yb1 + yb2) / 2, 0.7, FLOOR + 1.4), win((yb2 + yB) / 2, 1.2)]
    wall(ext, inn, "x", 0.0, 1, -W / 2, W / 2, front_open, "ext_wall", "int_wall", ext, "trim", solid=solid)
    wall(ext, inn, "x", D, -1, -W / 2, W / 2, back_open, "ext_wall", "int_wall", ext, "trim", solid=solid)
    wall(ext, inn, "y", -W / 2, 1, T, D - T, left_open, "ext_wall", "int_wall", ext, "trim", solid=solid, out_range=(0.0, D))
    wall(ext, inn, "y", W / 2, -1, T, D - T, right_open, "ext_wall", "int_wall", ext, "trim", solid=solid, out_range=(0.0, D))
    for along, c, inward, openings in (("x", 0.0, 1, front_open), ("x", D, -1, back_open), ("y", -W / 2, 1, left_open), ("y", W / 2, -1, right_open)):
        for o in openings:
            if o[2] > FLOOR + 0.01:
                window_dressing(ext, glass, along, c, inward, *o)

    # partitions (doorways are open, no doors)
    def doorway(center, width=0.9):
        return (center - width / 2, center + width / 2, FLOOR, FLOOR + DOOR_H)

    def partition(along, c, a0, a1, openings):
        wall(inn, inn, along, c - PT / 2, 1, a0, a1, openings, "int_wall", "int_wall", inn, "int_wall",
             out_z=(FLOOR, TOP), in_z=(FLOOR, TOP), thickness=PT, solid=solid)

    partition("y", hx0, yF, yk, [doorway(yF + (yk - yF) * 0.35, 1.6)])               # living | hall
    partition("x", yk, xL, hx0, [doorway((xL + hx0) / 2, 2.2)])                      # living | kitchen
    partition("y", hx1, yF, yB, [doorway(yF + 0.8), doorway((yb1 + yb2) / 2), doorway(yb2 + 0.8)])  # hall+kitchen | bedrooms, bath
    partition("x", yb1, hx1, xR, [])                                                 # bedroom | bath
    partition("x", yb2, hx1, xR, [])                                                 # bath | bedroom

    # floors, by room
    rooms = [("living", xL, hx0, yF, yk, "floor_wood"), ("hall", hx0, hx1, yF, yk, "floor_wood"),
             ("kitchen", xL, hx1, yk, yB, "floor_tiles"), ("bed1", hx1, xR, yF, yb1, "floor_wood"),
             ("bath", hx1, xR, yb1, yb2, "floor_tiles"), ("bed2", hx1, xR, yb2, yB, "floor_wood")]
    for name, x0, x1, y0, y1, mat in rooms:
        inn.flat_rect("+z", FLOOR, x0, x1, y0, y1, mat)
    inn.flat_rect("+z", FLOOR, door_x - 0.48, door_x + 0.48, 0.0, T, "floor_wood")   # the threshold
    inn.flat_rect("-z", TOP, xL, xR, yF, yB, "ceiling")
    walk.add((-W / 2, 0, -0.5), (W / 2, D, FLOOR))

    # the front door, standing open into the hall
    hinge = Vector((door_x - 0.46, T, FLOOR))
    angle = math.radians(75)
    door_dir = Vector((math.cos(angle), math.sin(angle), 0))
    door_n = Vector((-math.sin(angle), math.cos(angle), 0))
    ext_door = Part("door_tmp")
    p0 = hinge
    ext_door.quad(p0, door_dir * 0.92, Z * 2.05, "door", 0.5)
    ext_door.quad(p0 + door_n * 0.045 + door_dir * 0.92, -door_dir * 0.92, Z * 2.05, "door", 0.5)
    ext_door.quad(p0 + door_dir * 0.92, door_n * 0.045, Z * 2.05, "door", 0.5)
    ext_door.quad(p0 + Z * 2.05, door_dir * 0.92, door_n * 0.045, "door", 0.5)
    merge(inn, ext_door)

    # porch (or a step) at the front door
    if porch:
        pw, pd = 3.4, 1.9
        ext.box((door_x - pw / 2, -pd, 0), (door_x + pw / 2, 0, FLOOR), "porch", 0.5)
        walk.add((door_x - pw / 2, -pd, -0.5), (door_x + pw / 2, 0, FLOOR))
        for px in (door_x - pw / 2 + 0.12, door_x + pw / 2 - 0.12):
            ext.box((px - 0.07, -pd + 0.05, FLOOR), (px + 0.07, -pd + 0.19, TOP - 0.6), "trim", 0.5)
            solid.add((px - 0.1, -pd + 0.02, 0), (px + 0.1, -pd + 0.22, TOP))
        shed_roof(ext, door_x - pw / 2 - 0.2, door_x + pw / 2 + 0.2, 0.0, pd + 0.25, TOP - 0.45, TOP - 0.62)
    else:
        ext.box((door_x - 0.8, -0.6, 0), (door_x + 0.8, 0, FLOOR * 0.6), "porch", 0.5)
        walk.add((door_x - 0.8, -0.6, -0.5), (door_x + 0.8, 0, FLOOR * 0.6))

    # roof over the house
    ridge_z = gable_roof(ext, -W / 2, W / 2, 0.0, D, TOP, ridge)

    # garage, attached on the right (+x) side, set back a little
    garage_info = None
    if garage:
        gw, gd = 6.2, 6.6
        gx0, gx1 = W / 2, W / 2 + gw
        gy0 = rng.choice([0.0, 0.6, 1.2])
        gy1 = gy0 + gd
        gtop = 2.5
        door_w, door_h = 4.9, 2.2
        dx0, dx1 = (gx0 + gx1) / 2 - door_w / 2, (gx0 + gx1) / 2 + door_w / 2
        dummy = Part("garage_inside")
        wall(ext, dummy, "x", gy0, 1, gx0, gx1 + 0.0, [(dx0, dx1, 0.05, door_h)], "ext_wall", "int_wall", ext, "trim",
             out_z=(0.0, gtop), in_z=(0.05, gtop))
        ext.wall_rect("+y", gy1, gx0, gx1, 0.0, gtop, "ext_wall")
        ext.wall_rect("+x", gx1, gy0, gy1, 0.0, gtop, "ext_wall")
        if gy1 > D:
            ext.wall_rect("-x", gx0, D, gy1, 0.0, gtop, "ext_wall")
        # the door: four horizontal panels, recessed a little
        for k in range(4):
            z0 = 0.05 + k * (door_h - 0.05) / 4
            z1 = z0 + (door_h - 0.05) / 4 - 0.015
            ext.box((dx0, gy0 + 0.08, z0), (dx1, gy0 + 0.12, z1), "garage_door", 0.6)
        ext.flat_rect("+z", 0.03, dx0, dx1, gy0, gy0 + 0.1, "porch")
        gable_roof(ext, gx0, gx1, gy0, gy1, gtop, "y", oh_span=(0.03, OVERHANG))
        solid.add((gx0, gy0, 0), (gx1, gy1, gtop))
        garage_info = {"door_x": (gx0 + gx1) / 2, "door_width": door_w, "front_y": gy0}

    # furniture
    furnish(inn, solid, rng, xL, hx0, hx1, xR, yF, yk, yb1, yb2, yB)

    parts = [ext, inn, glass]
    min_x = -W / 2 - OVERHANG
    max_x = (W / 2 + 6.2 + OVERHANG) if garage else W / 2 + OVERHANG
    info = {
        "id": index,
        "file": f"house_{index}.glb",
        "width": W, "depth": D,
        "min_x": round(min_x, 3), "max_x": round(max_x, 3),
        "front_y": round(-1.9 if porch else -0.6, 3), "back_y": round(max(D, (garage_info or {}).get("front_y", 0) + 6.6) + OVERHANG, 3),
        "door_x": round(door_x, 3),
        "garage": garage_info,
        "porch": porch,
        "ridge": ridge,
        "height": round(ridge_z + ROOF_T, 3),
    }
    solid_part = solid.to_part("collision_solid")
    walk_part = walk.to_part("collision_walk")
    if mirror:
        for p in parts + [solid_part, walk_part]:
            p.mirror_x()
        info["min_x"], info["max_x"] = -info["max_x"], -info["min_x"]
        info["door_x"] = -info["door_x"]
        if garage_info:
            garage_info["door_x"] = -garage_info["door_x"]
    info["mirrored"] = mirror
    for k in ("min_x", "max_x", "door_x"):
        info[k] = round(info[k], 3)
    if garage_info:
        garage_info["door_x"] = round(garage_info["door_x"], 3)
        garage_info["front_y"] = round(garage_info["front_y"], 3)
    return parts, solid_part, walk_part, info


def merge(into, other):
    base = len(into.verts)
    into.verts.extend(other.verts)
    for idx, mat, uvs in other.faces:
        into.faces.append(([i + base for i in idx], mat, uvs))


def furnish(inn, solid, rng, xL, hx0, hx1, xR, yF, yk, yb1, yb2, yB):
    F = FLOOR

    def put(lo, hi, mat, block=True):
        inn.box((lo[0], lo[1], F + lo[2]), (hi[0], hi[1], F + hi[2]), mat, 0.5)
        if block:
            solid.add((lo[0], lo[1], 0), (hi[0], hi[1], F + hi[2]))

    # living room: a sofa against the side wall, a coffee table, a TV unit against the hall wall
    ly = yF + (yk - yF) * 0.72
    put((xL, ly - 1.0, 0), (xL + 0.9, ly + 1.0, 0.45), "fabric")
    put((xL, ly - 1.0, 0.45), (xL + 0.25, ly + 1.0, 0.85), "fabric")
    put((xL + 1.4, ly - 0.55, 0), (xL + 2.0, ly + 0.55, 0.42), "furn_wood")
    put((hx0 - PT / 2 - 0.45, ly - 0.8, 0), (hx0 - PT / 2, ly + 0.8, 0.55), "furn_wood")
    put((hx0 - PT / 2 - 0.12, ly - 0.55, 0.55), (hx0 - PT / 2 - 0.06, ly + 0.55, 1.2), "appliance", False)   # the TV
    # kitchen: counters along the back wall, a fridge, a table with four chairs
    put((xL, yB - 0.62, 0), (xL + 3.0, yB, 0.88), "counter")
    put((xL, yB - 0.64, 0.88), (xL + 3.0, yB, 0.92), "furn_wood", False)
    put((xL + 1.0, yB - 0.6, 0.92), (xL + 1.6, yB - 0.05, 0.96), "appliance", False)                       # the cooktop
    put((xL + 3.1, yB - 0.72, 0), (xL + 3.9, yB, 1.8), "appliance")
    tx, ty = (xL + hx1) / 2, (yk + yB) / 2 - 0.3
    put((tx - 0.8, ty - 0.45, 0.72), (tx + 0.8, ty + 0.45, 0.76), "furn_wood")
    for lx in (tx - 0.7, tx + 0.64):
        for ly2 in (ty - 0.39, ty + 0.33):
            put((lx, ly2, 0), (lx + 0.06, ly2 + 0.06, 0.72), "furn_wood", False)
    solid.add((tx - 0.8, ty - 0.45, 0), (tx + 0.8, ty + 0.45, F + 0.76))
    for cx, cy, back in ((tx - 0.35, ty - 0.75, -1), (tx + 0.35, ty - 0.75, -1), (tx - 0.35, ty + 0.75, 1), (tx + 0.35, ty + 0.75, 1)):
        put((cx - 0.22, cy - 0.22, 0.42), (cx + 0.22, cy + 0.22, 0.46), "furn_wood")
        by = cy + back * 0.2
        put((cx - 0.22, by - 0.03, 0.46), (cx + 0.22, by + 0.03, 0.9), "furn_wood", False)
        for ox in (-0.2, 0.17):
            for oy in (-0.2, 0.17):
                put((cx + ox, cy + oy, 0), (cx + ox + 0.03, cy + oy + 0.03, 0.42), "furn_wood", False)
    # bedrooms: a bed with its head against the outside wall, bedside table, wardrobe
    for (y0, y1, width) in ((yF, yb1, 1.6), (yb2, yB, 1.0)):
        by = (y0 + y1) / 2 - 0.2
        put((xR - 2.05, by - width / 2, 0), (xR, by + width / 2, 0.5), "fabric")
        put((xR - 0.08, by - width / 2, 0.5), (xR, by + width / 2, 1.05), "furn_wood", False)
        put((xR - 0.5, by + width / 2 + 0.1, 0), (xR, by + width / 2 + 0.55, 0.55), "furn_wood")
        put((hx1 + PT / 2 + 1.1, y1 - 0.6, 0), (hx1 + PT / 2 + 2.3, y1, 2.0), "furn_wood")
    # bathroom: bath along the back wall, toilet, vanity
    put((xR - 1.7, yb2 - PT / 2 - 0.75, 0), (xR, yb2 - PT / 2, 0.55), "appliance")
    put((xR - 0.55, yb1 + PT / 2, 0), (xR - 0.15, yb1 + PT / 2 + 0.65, 0.42), "appliance")
    put((xR - 0.5, yb1 + PT / 2, 0.42), (xR - 0.2, yb1 + PT / 2 + 0.18, 0.8), "appliance", False)
    put((xR - 1.8, yb1 + PT / 2, 0), (xR - 0.9, yb1 + PT / 2 + 0.5, 0.85), "counter")


# ---- Blender scene: build, bake, export -------------------------------------------------------------------------------------------

def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 128
    scene.cycles.use_denoising = False
    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (1, 1, 1, 1)
    bg.inputs[1].default_value = 1.0
    scene.world = world
    for name in MATERIALS:
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        bsdf = m.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = (0.8, 0.8, 0.8, 1)
    return scene


def to_object(part):
    mesh = bpy.data.meshes.new(part.name)
    bm = bmesh.new()
    bverts = [bm.verts.new(v) for v in part.verts]
    bm.verts.index_update()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    mat_index = {}
    for idx, mat, uvs in part.faces:
        try:
            face = bm.faces.new([bverts[i] for i in idx])
        except ValueError:
            continue    # a duplicate face; skip it
        if mat not in mat_index:
            mat_index[mat] = len(mat_index)
            mesh.materials.append(bpy.data.materials[mat])
        face.material_index = mat_index[mat]
        for loop, uv in zip(face.loops, uvs):
            loop[uv_layer].uv = uv
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(part.name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def bake_shading(objs, ground):
    """Bakes near AO and sky visibility into colour attributes and combines them into one: Col = near^0.7 * (0.5 + 0.5 * sky)."""
    scene = bpy.context.scene
    for o in objs:
        for name in ("near", "sky", "Col"):
            o.data.color_attributes.new(name, "BYTE_COLOR", "POINT")

    def bake(attr, distance, use_ground):
        ground.hide_render = not use_ground
        scene.world.light_settings.distance = distance
        for o in objs:
            o.data.color_attributes.active_color = o.data.color_attributes[attr]
        bpy.ops.object.select_all(action="DESELECT")
        for o in objs:
            o.select_set(True)
        bpy.context.view_layer.objects.active = objs[0]
        bpy.ops.object.bake(type="AO", target="VERTEX_COLORS")

    bake("near", 1.0, True)
    bake("sky", 12.0, False)
    for o in objs:
        near = o.data.color_attributes["near"].data
        sky = o.data.color_attributes["sky"].data
        col = o.data.color_attributes["Col"].data
        for i in range(len(col)):
            n = near[i].color[0]
            s = sky[i].color[0]
            v = (n ** 0.7) * (0.5 + 0.5 * s)
            col[i].color = (v, v, v, 1.0)
        o.data.color_attributes.remove(o.data.color_attributes["near"])
        o.data.color_attributes.remove(o.data.color_attributes["sky"])
        o.data.color_attributes.active_color = o.data.color_attributes["Col"]
        o.data.color_attributes.render_color_index = 0


def render_preview(path, info):
    scene = bpy.context.scene
    cam_data = bpy.data.cameras.new("cam")
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    cx = (info["min_x"] + info["max_x"]) / 2
    cam.location = (cx - 14, -17, 7)
    direction = Vector((cx, 4, 2)) - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    cam_data.lens = 24
    scene.camera = cam
    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 3
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = (math.radians(55), 0, math.radians(-40))
    scene.collection.objects.link(sun)
    # show the baked colours in the picture
    for m in bpy.data.materials:
        nodes = m.node_tree.nodes
        attr = nodes.new("ShaderNodeVertexColor")
        attr.layer_name = "Col"
        m.node_tree.links.new(attr.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])
    scene.render.resolution_x = 640
    scene.render.resolution_y = 400
    scene.cycles.samples = 16
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def build_variant(index, preview):
    reset_scene()
    parts, solid_part, walk_part, info = make_house(index)
    ext, inn, glass = [to_object(p) for p in parts]
    solid = to_object(solid_part)
    walk = to_object(walk_part)
    bpy.ops.mesh.primitive_plane_add(size=80, location=(0, 0, 0))
    ground = bpy.context.active_object
    ground.name = "bake_ground"
    glass.hide_render = True
    solid.hide_render = True
    walk.hide_render = True
    bake_shading([ext, inn], ground)
    glass.data.color_attributes.new("Col", "BYTE_COLOR", "POINT")
    for c in glass.data.color_attributes["Col"].data:
        c.color = (1, 1, 1, 1)
    for o in (solid, walk):
        o.data.materials.clear()
    if preview:
        ground.hide_render = False
        render_preview(f"/tmp/house_{index}.png", info)
    bpy.data.objects.remove(ground)
    bpy.ops.object.select_all(action="DESELECT")
    for o in (ext, inn, glass, solid, walk):
        o.select_set(True)
    os.makedirs(OUT, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, info["file"]), use_selection=True, export_format="GLB",
                              export_vertex_color="ACTIVE", export_all_vertex_colors=False, export_normals=True,
                              export_texcoords=True, export_materials="EXPORT", export_image_format="NONE", export_yup=True)
    info["triangles"] = sum(len(p.faces) * 2 for p in parts)
    return info


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", type=int, default=None)
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    index_path = os.path.join(OUT, "houses.json")
    index = json.load(open(index_path)) if os.path.exists(index_path) else {"variants": []}
    by_id = {v["id"]: v for v in index["variants"]}
    for i in range(VARIANTS):
        if args.only is not None and i != args.only:
            continue
        info = build_variant(i, args.preview)
        by_id[i] = info
        print(f"house {i}: {info['width']} x {info['depth']} m, garage {bool(info['garage'])}, porch {info['porch']}, "
              f"~{info['triangles']} triangles", flush=True)
    index["variants"] = [by_id[k] for k in sorted(by_id)]
    json.dump(index, open(index_path, "w"), indent=1)


if __name__ == "__main__":
    main()
