"""Geometry helpers for a mod's builders, and the stage and pixel helpers its renders, bakes and
previews share. shading.py draws the materials.

Units are metres and the scene is Blender's: +Z up. An item is built standing on z = 0, centred on
the origin, with its front facing -Y. In a tile, -Y is south and +X east (Blender's +Y is the
game's north, because the game's y axis points south).
"""
import math
import os
import random

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector

# Directions ---------------------------------------------------------------------------------------

# Turning an object whose front faces south (-Y) to face each direction.
FACING_TURN = {"S": 0, "E": 90, "N": 180, "W": -90}

# The camera's frame: the game's tiles are seen from the south-east.
LEFT = Vector((-math.sqrt(0.5), -math.sqrt(0.5), 0))  # the viewer's left, south-west
RIGHT = -LEFT
TOWARD = Vector((math.sqrt(0.5), -math.sqrt(0.5), 0))  # toward the viewer, south-east
UP = Vector((0, 0, 1))
FACING = (90, 0, 45)  # turns an upright cylinder's axis, or a box's -Y face, toward the viewer
SQUARE = (0, 0, 45)  # turns a box's X along the viewer's right and its Y away from the viewer


def heading(degrees):
    """The level unit vector `degrees` from east, anticlockwise seen from above."""
    return Vector((math.cos(math.radians(degrees)), math.sin(math.radians(degrees)), 0))


def around(centre, angle, distance):
    """The point `distance` from `centre`, (x, y), `angle` degrees round from +X."""
    a = math.radians(angle)
    return centre[0] + math.cos(a) * distance, centre[1] + math.sin(a) * distance


def circle(radius, z, step=10):
    """Points round a level circle of `radius` at height `z`, every `step` degrees, closed: its first
    point repeated at its end, for a tube round it."""
    return [(radius * math.cos(math.radians(a)), radius * math.sin(math.radians(a)), z) for a in range(0, 361, step)]


def spline(points, steps=6):
    """Points along a smooth curve through `points` (Catmull-Rom), for a hose's or a wire's run."""
    points = [Vector(p) for p in points]
    padded = [points[0]] + points + [points[-1]]
    out = []
    for i in range(1, len(padded) - 2):
        p0, p1, p2, p3 = padded[i - 1:i + 3]
        for k in range(steps):
            t = k / steps
            out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (3 * p1 - p0 - 3 * p2 + p3) * t ** 3))
    out.append(points[-1])
    return out


def on_ground(points, radius):
    """`points` with none lower than `radius`, so a hose or wire the curve dips rests on the ground
    rather than through it, where a sprite has nothing to draw over."""
    return [Vector((p.x, p.y, max(p.z, radius))) for p in points]


# Meshes -------------------------------------------------------------------------------------------


# Each mesh carries its own wood grain coordinates (attribute "grain"): its vertices' positions
# turned so its longest side runs along X, where a grain material stretches its figure, and moved by
# an offset of its own, so boards side by side don't match. They stay in the part's frame, through a
# bake's merge into one mesh too, so the grain follows each board however it is placed.
_grain_offsets = random.Random(0)


def _object(name, bm, mat, collection):
    mesh = bpy.data.meshes.new(name)
    bm.normal_update()
    extent = [max(v.co[i] for v in bm.verts) - min(v.co[i] for v in bm.verts) for i in range(3)]
    axes = sorted(range(3), key=lambda i: -extent[i])
    offset = Vector([_grain_offsets.uniform(-20, 20) for _ in range(3)])
    layer = bm.verts.layers.float_vector.new("grain")
    for v in bm.verts:
        v[layer] = Vector([v.co[i] for i in axes]) + offset
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(mat)
    obj = bpy.data.objects.new(name, mesh)
    collection.objects.link(obj)
    return obj


def box(collection, name, mat, size, at=(0, 0, 0), bevel=0.0, rotate=None):
    """A box of `size` whose bottom centre is at `at`, optionally rotated (euler degrees) about that
    point. A small bevel catches light along the edges, which keeps low-poly boxes readable."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    bmesh.ops.translate(bm, vec=Vector((0, 0, size[2] / 2)), verts=bm.verts)
    if bevel > 0:
        bmesh.ops.bevel(bm, geom=list(bm.edges), offset=min(bevel, min(size) / 2.5), segments=1,
                        affect="EDGES", profile=0.5)
    obj = _object(name, bm, mat, collection)
    place(obj, at, rotate)
    return obj


def beam(collection, name, mat, start, end, section, bevel=0.0):
    """A straight post, board or bar from `start` to `end`, `section` = (width, thickness) across
    it: a box turned the shortest way from upright, so a beam in the YZ plane keeps its width on
    X and one along X stands its width up on Z."""
    start, end = Vector(start), Vector(end)
    run = end - start
    obj = box(collection, name, mat, (section[0], section[1], run.length), bevel=bevel)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(run)
    obj.location = start
    return obj


def board(collection, name, mat, start, end, section, face, bevel=0.003):
    """A board from `start` to `end`, `section` = (width, thickness) across it, its broad side
    looking toward `face` (a direction)."""
    obj = beam(collection, name, mat, start, end, section, bevel=bevel)
    run = (Vector(end) - Vector(start)).normalized()
    normal = Vector(face) - run * run.dot(Vector(face))
    normal.normalize()
    obj.rotation_quaternion = Matrix((normal.cross(run), normal, run)).transposed().to_quaternion()
    return obj


def _round_sides(bm, ends):
    """Smooth-shades every face but `ends`, and keeps the edges round them sharp: a drum or a pipe
    drawn in flat facets shows vertical bands that the game's own round things don't."""
    for face in bm.faces:
        face.smooth = face not in ends
    for face in ends:
        for edge in face.edges:
            edge.smooth = False


def cylinder(collection, name, mat, radius, height, at=(0, 0, 0), rotate=None, segments=12, radius_top=None):
    """An upright cylinder (or cone, with `radius_top`) whose bottom centre is at `at`."""
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segments, radius1=radius,
                          radius2=radius if radius_top is None else radius_top, depth=height)
    bmesh.ops.translate(bm, vec=Vector((0, 0, height / 2)), verts=bm.verts)
    bm.normal_update()
    _round_sides(bm, {face for face in bm.faces if abs(face.normal.z) > 0.999})
    obj = _object(name, bm, mat, collection)
    place(obj, at, rotate)
    return obj


def tube(collection, name, mat, points, radius, sides=6, up=None):
    """A cable or pipe along `points`, its rings carried along the path without twist: each ring
    turns from the last only as far as the path bends, so a hose keeps its sides round every bend.
    `up` turns the first ring to hold a side toward it; a pipe bent in a plane square to `up` keeps
    that side toward it all along, so pipes meeting end to end on neighbouring tiles have the same
    rings where they meet. Without `up` the first ring takes a fixed side of its own. A path that
    ends where it starts closes into a seamless loop with no ends."""
    points = [Vector(p) for p in points]
    closed = len(points) > 2 and (points[-1] - points[0]).length < 1e-6
    if closed:
        points.pop()
    n = len(points)
    if closed:
        tangents = [(points[(i + 1) % n] - points[i - 1]).normalized() for i in range(n)]
    else:
        tangents = [(points[min(i + 1, n - 1)] - points[max(i - 1, 0)]).normalized() for i in range(n)]
    first = tangents[0]
    across = (Vector(up) - first * first.dot(Vector(up))).normalized() if up else first.orthogonal().normalized()
    frames = [across]
    for last, tangent in zip(tangents, tangents[1:]):
        across = last.rotation_difference(tangent) @ across
        frames.append(across)
    if closed:
        # Carried round a loop that isn't flat, the ring comes back turned about the path; spread
        # that turn along the loop by length so the last ring meets the first square.
        back = tangents[-1].rotation_difference(first) @ across
        turn = math.atan2(first.dot(back.cross(frames[0])), back.dot(frames[0]))
        steps = [(b - a).length for a, b in zip(points, points[1:] + points[:1])]
        total, done = sum(steps), 0.0
        for i in range(1, n):
            done += steps[i - 1]
            frames[i] = Quaternion(tangents[i], turn * done / total) @ frames[i]
    bm = bmesh.new()
    rings = [[bm.verts.new(point + (across * math.cos(a) + tangent.cross(across) * math.sin(a)) * radius)
              for a in (2 * math.pi * k / sides for k in range(sides))]
             for point, tangent, across in zip(points, tangents, frames)]
    for a, b in zip(rings, rings[1:] + rings[:1] if closed else rings[1:]):
        for k in range(sides):
            bm.faces.new((a[k], a[(k + 1) % sides], b[(k + 1) % sides], b[k]))
    ends = set() if closed else {bm.faces.new(list(reversed(rings[0]))), bm.faces.new(rings[-1])}
    _round_sides(bm, ends)
    return _object(name, bm, mat, collection)


def ring(collection, name, mat, centre, radius, z, thickness):
    """A ring of tube lying flat round `centre` at height `z`, as a drum's rolled rim, a seam or a
    coil: a solid cap there would lie in the plane of what it rings and shade it black."""
    tube(collection, name, mat, [(*around(centre, 360 * k / 28, radius), z) for k in range(29)], thickness, 6)


def prism(collection, name, mat, outline, depth, at=(0, 0, 0), rotate=None):
    """A flat shape extruded along +Y: `outline` is a list of (x, z) points, counter-clockwise when
    seen from the front. Used for brackets, triangles and cut sheet."""
    bm = bmesh.new()
    front = [bm.verts.new((x, -depth / 2, z)) for x, z in outline]
    back = [bm.verts.new((x, depth / 2, z)) for x, z in outline]
    bm.faces.new(front)
    bm.faces.new(list(reversed(back)))
    n = len(outline)
    for i in range(n):
        bm.faces.new((front[(i + 1) % n], front[i], back[i], back[(i + 1) % n]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    obj = _object(name, bm, mat, collection)
    place(obj, at, rotate)
    return obj


def loft(collection, name, mat, sections):
    """A solid skinned through cross-sections, each (z, [(x, y), ...]): one closed outline,
    counter-clockwise seen from above, the same number of points in every section, capped at both
    ends. One mesh with no faces buried in another, where boxes laid end to end would leave seams
    that bake dark and split the texture into slivers."""
    bm = bmesh.new()
    rings = [[bm.verts.new((x, y, z)) for x, y in outline] for z, outline in sections]
    n = len(rings[0])
    for a, b in zip(rings, rings[1:]):
        for k in range(n):
            bm.faces.new((a[k], a[(k + 1) % n], b[(k + 1) % n], b[k]))
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _object(name, bm, mat, collection)


def lathe(collection, name, mat, profile, segments=24, arc=(0.0, 360.0), at=(0, 0, 0), shape=None, smooth=True):
    """A surface turned about Z through `profile`, a list of (radius, z) points from the bottom up,
    over `arc` degrees (a slice of it, for one barrel stave). `shape(angle, row)` returns a
    (radial, vertical) nudge in metres for each vertex, to crumple a sheet into folds. Open at its
    ends: close it with a profile point at radius 0."""
    whole = arc[1] - arc[0] >= 360
    columns = segments if whole else segments + 1
    bm = bmesh.new()
    rows = []
    for row, (radius, z) in enumerate(profile):
        ring = []
        for k in range(columns):
            angle = arc[0] + (arc[1] - arc[0]) * k / segments
            out, up = shape(angle, row) if shape else (0.0, 0.0)
            a = math.radians(angle)
            ring.append(bm.verts.new(((radius + out) * math.cos(a), (radius + out) * math.sin(a), z + up)))
        rows.append(ring)
    for a, b in zip(rows, rows[1:]):
        for k in range(segments):
            nxt = (k + 1) % columns
            quad = (a[k], a[nxt], b[nxt], b[k])
            # A ring of radius 0 closes the surface: its points are one, so its quads are triangles.
            unique = [v for i, v in enumerate(quad) if all((v.co - w.co).length > 1e-7 for w in quad[:i])]
            if len(unique) >= 3:
                bm.faces.new(unique)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
    for face in bm.faces:
        face.smooth = smooth
    bm.normal_update()
    obj = _object(name, bm, mat, collection)
    place(obj, at)
    return obj


def profile_radius(profile, z):
    """The radius of a lathe `profile` at height `z`, held at its end radii beyond its ends."""
    if z < profile[0][1]:
        return profile[0][0]
    for (r0, z0), (r1, z1) in zip(profile, profile[1:]):
        if z0 <= z <= z1 and z0 < z1:
            return r0 + (r1 - r0) * (z - z0) / (z1 - z0)
    return profile[-1][0]


def bank(collection, name, mat, profile, at=(0, 0, 0), lumps=0.0, seed=0, segments=32):
    """A surface turned round the Z axis through `profile`, [(radius, z), ...] from its inner edge
    out, open at both edges and facing up: earth banked round something that hides its inner edge.
    `lumps` raises or lowers each vertex by up to that fraction of its height at random (from
    `seed`), so an edge on the ground stays on it. It is smooth shaded."""
    rng = random.Random(seed)
    bm = bmesh.new()
    rings = []
    for radius, z in profile:
        row = []
        for k in range(segments):
            azimuth = 2 * math.pi * k / segments
            row.append(bm.verts.new((radius * math.cos(azimuth), radius * math.sin(azimuth),
                                     z * (1 + lumps * rng.uniform(-1, 1)))))
        rings.append(row)
    # Out along the radius, then on round the axis: counter-clockwise seen from above, facing up.
    for a, b in zip(rings, rings[1:]):
        for k in range(segments):
            face = bm.faces.new((a[k], b[k], b[(k + 1) % segments], a[(k + 1) % segments]))
            face.smooth = True
    obj = _object(name, bm, mat, collection)
    place(obj, at)
    return obj


def mound(collection, name, mat, radii, at=(0, 0, 0), rotate=None, squareness=1.0, lumps=0.0, seed=0, segments=16,
          rings=6):
    """A heap, a filled sack or a dome: the top half of an ellipsoid with semi-axes `radii`, its flat
    base on z = 0, so nothing of it shows below the floor of a tile. `squareness` above 1 squares
    its outline and shoulders, as a stuffed pillow's; `lumps` pushes each vertex out or in by up to
    that fraction at random (from `seed`), so a heap or a slack bag isn't turned as on a lathe. It
    is smooth shaded, having no edges to catch the light."""
    rng = random.Random(seed)

    def shaped(c):
        return math.copysign(abs(c) ** (1 / squareness), c)

    bm = bmesh.new()
    rows = []
    for i in range(rings):
        polar = math.pi / 2 * i / rings
        row = []
        for k in range(segments):
            azimuth = 2 * math.pi * k / segments
            bump = 1 + lumps * rng.uniform(-1, 1)
            out = shaped(math.cos(polar)) * bump
            up = radii[2] * shaped(math.sin(polar)) * bump
            row.append(bm.verts.new((radii[0] * out * shaped(math.cos(azimuth)), radii[1] * out * shaped(math.sin(azimuth)), up)))
        rows.append(row)
    top = bm.verts.new((0, 0, radii[2] * (1 + lumps * rng.uniform(-1, 1))))
    for a, b in zip(rows, rows[1:]):
        for k in range(segments):
            bm.faces.new((a[k], a[(k + 1) % segments], b[(k + 1) % segments], b[k]))
    for k in range(segments):
        bm.faces.new((rows[-1][k], rows[-1][(k + 1) % segments], top))
    for face in bm.faces:
        face.smooth = True
    bm.faces.new(list(reversed(rows[0])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    obj = _object(name, bm, mat, collection)
    place(obj, at, rotate)
    return obj


def text(collection, name, mat, body, size, at=(0, 0, 0), rotate=(90, 0, 0), align="CENTER"):
    """Flat lettering as a mesh, by default standing upright and reading from the front (-Y), its
    baseline centre at `at`. Lift it a millimetre off the surface it is printed on."""
    curve = bpy.data.curves.new(name, "FONT")
    curve.body = body
    curve.size = size
    curve.align_x = align
    curve.align_y = "BOTTOM_BASELINE"
    curve.resolution_u = 3
    temp = bpy.data.objects.new(name + "_curve", curve)
    collection.objects.link(temp)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(temp.evaluated_get(depsgraph))
    bpy.data.objects.remove(temp)
    bpy.data.curves.remove(curve)
    mesh.materials.clear()
    mesh.materials.append(mat)
    obj = bpy.data.objects.new(name, mesh)
    collection.objects.link(obj)
    place(obj, at, rotate)
    return obj


def place(obj, at, rotate=None):
    obj.location = Vector(at)
    if rotate:
        obj.rotation_euler = [math.radians(a) for a in rotate]
    return obj


def group(collection, name, objects, at=(0, 0, 0), rotate=None):
    """Moves and turns several parts as one, through a parent empty."""
    empty = bpy.data.objects.new(name, None)
    collection.objects.link(empty)
    for obj in objects:
        obj.parent = empty
    place(empty, at, rotate)
    return empty


def added(collection, build, *args, **options):
    """Runs `build(collection, *args, **options)` and returns the objects it added, in the
    collection's order."""
    before = set(collection.objects)
    build(collection, *args, **options)
    return [obj for obj in collection.objects if obj not in before]


def parts(collection, build, *args, **options):
    """Runs `build(collection, ...)` and returns the top-level objects it added, for `group`."""
    return [obj for obj in added(collection, build, *args, **options) if obj.parent is None]


def part_name(obj):
    """An object's name as its builder gave it, without the number Blender adds to a repeat."""
    return obj.name.split(".")[0]


def edited_copy(obj, edit=None):
    """A copy of `obj` with a mesh of its own, in the scene, `edit(bm)` applied to that mesh."""
    piece = obj.copy()
    piece.data = obj.data.copy()
    bpy.context.scene.collection.objects.link(piece)
    if edit:
        bm = bmesh.new()
        bm.from_mesh(piece.data)
        edit(bm)
        bm.to_mesh(piece.data)
        bm.free()
    return piece


def select(obj, *others):
    """Makes `obj` the active object and it and `others` the only selected ones, as an operator
    (a bake, an unwrap, an export of the selection) acts on."""
    bpy.ops.object.select_all(action="DESELECT")
    for each in (obj, *others):
        each.select_set(True)
    bpy.context.view_layer.objects.active = obj


# Stage and pixels ---------------------------------------------------------------------------------


def new_stage(samples, background):
    """A factory-fresh Cycles scene on the CPU, `samples` a pixel, lit by a world of `background`
    colour, and its collection the builds go in."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    world = bpy.data.worlds.new("Ambient")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = background
    scene.world = world
    stage = bpy.data.collections.new("Stage")
    scene.collection.children.link(stage)
    return stage


def clear(stage):
    """Takes every object off the stage, and the meshes nothing uses any more, and starts the grain
    offsets over, so a build's parts get the same grain whatever was built before it."""
    _grain_offsets.seed(0)
    for obj in list(stage.objects):
        bpy.data.objects.remove(obj)
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)


def load_pixels(path):
    """An image file as a float array of rows from the top, RGBA."""
    image = bpy.data.images.load(path)
    width, height = image.size
    pixels = np.array(image.pixels[:], dtype=np.float32).reshape(height, width, 4)[::-1]
    bpy.data.images.remove(image)
    return pixels


def save_pixels(path, pixels, alpha=True):
    """Writes a load_pixels array as a PNG, its values as they are, without a colour transform;
    without `alpha`, opaque."""
    height, width, _ = pixels.shape
    image = bpy.data.images.new("out", width, height, alpha=alpha)
    image.colorspace_settings.name = "Non-Color"
    image.pixels[:] = np.clip(pixels[::-1], 0, 1).ravel()
    image.filepath_raw = path
    image.file_format = "PNG"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save()
    bpy.data.images.remove(image)
