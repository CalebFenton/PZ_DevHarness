"""The Cycles shader node graphs a mod's palette draws its materials with: `material` for painted,
plastic, metal and wooden surfaces, `holdout` for an overlay tile's base, and `stain` for a patch
on a tile's floor that has to meet its neighbours' (kit.py's units and axes)."""
import math

import bpy


def hex_rgb(value):
    """'#rrggbb' to linear RGB, so a palette's colours read like the sRGB values of a paint chip."""
    def channel(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return tuple(channel(int(value[i:i + 2], 16)) for i in (1, 3, 5))


def _principled(material):
    if not material.node_tree:
        material.use_nodes = True
    nodes = material.node_tree.nodes
    return nodes, nodes.get("Principled BSDF") or nodes.new("ShaderNodeBsdfPrincipled")


# Every material by name, made once: a palette's entries are made on first use and shared.
_MATERIALS = {}

# Wood grain, by kind: the size across the grain of the figure the grain lines follow (metres),
# how many times longer it runs along the grain, how many lines cross one figure, and how dark a
# line is. Boards are sawn, so their grain runs in long straight streaks; plywood's face is a veneer
# peeled off the log, its figure broad and wavy. Weathered planks, as the game draws its own crates
# and composters, are dark with grain cut deep by the rain. Small wood, a tray's sides or a carved
# blade, takes a finer figure, or a board's would cross it once or not at all and leave it flat.
GRAIN = {"board": (0.08, 12.0, 3.0, 0.5), "veneer": (0.09, 4.0, 3.0, 0.3), "weathered": (0.05, 14.0, 4.0, 0.3),
         "fine": (0.025, 10.0, 3.0, 0.45)}
GRAIN_EARLY = 1.1  # the pale wood between grain lines
# Grime blotches across any one part, on top of those its size in metres gives it: a part a few
# centimetres long, an icon's whole item, would otherwise sit inside one blotch and look flat.
GRIME_PER_PART = 3.5


def _math(nodes, links, operation, a, b=None, c=None, clamp=False):
    """A math node on sockets or numbers, returning its output socket."""
    node = nodes.new("ShaderNodeMath")
    node.operation = operation
    node.use_clamp = clamp
    for i, value in enumerate((a, b, c)):
        if value is None:
            continue
        if isinstance(value, (int, float)):
            node.inputs[i].default_value = value
        else:
            links.new(value, node.inputs[i])
    return node.outputs[0]


def _noise(nodes, links, vector, scale, detail):
    """A noise texture over `vector`, returning its Fac."""
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = detail
    links.new(vector, noise.inputs["Vector"])
    return noise.outputs["Fac"]


def _mix(nodes, links, factor, a, b, blend="MIX"):
    """A colour mix from `a` to `b` by `factor`, each a socket, a number, an RGBA tuple or a
    '#rrggbb' colour, returning its result."""
    node = nodes.new("ShaderNodeMix")
    node.data_type = "RGBA"
    node.blend_type = blend
    for socket, value in ((node.inputs["Factor"], factor), (node.inputs[6], a), (node.inputs[7], b)):
        if isinstance(value, bpy.types.NodeSocket):
            links.new(value, socket)
        else:
            socket.default_value = (*hex_rgb(value), 1.0) if isinstance(value, str) else value
    return node.outputs[2]


def material(name, colour, roughness=0.6, metallic=0.0, grime=0.12, scale=40.0, emission=None, speckle=None, grain=None,
             streaks=None, scorch=None, turf=None, fade=None, shine=0.5):
    """A painted, plastic or metal surface named `name`, made once. `grime` darkens it in blotches,
    so flat colours don't look like a render. `speckle` = (colour, amount) mottles it with a second
    colour in a web of flakes, the base colour left at each flake's centre and less of it the higher
    `amount`: the way multicrystalline cells sparkle, sand is flecked with darker grains, or rust
    spots scrap steel. `streaks` = (colour, amount) runs that colour down its sides in thin streaks,
    as rust and soot run down a drum left out in the rain. `scorch` = (soot, heat, height) blackens
    it from its foot up to a ragged line `height` metres up, with a band of heat tint above, as a
    fire inside leaves a stove. `emission` makes it glow, for lit LEDs. `grain`, a kind in GRAIN,
    draws dark grain lines along each part's longest side, as kit's `_object` laid them out. `turf`
    = (colour, start, end) turns it to that colour from `start` to `end` metres out from the part's
    own centre, and `fade` = (start, end) thins it to nothing over those, both along a ragged line:
    a bank of earth grassed over towards its foot and lost in whatever ground the game draws round
    it. Only a tile sprite keeps a faded part's transparency; a baked texture doesn't. `shine` is
    the strength of its reflection of the sky, as Principled BSDF's Specular IOR Level, whose
    default the default keeps: soil hardly has any, and with it greys like the game's grass never
    does."""
    if name in _MATERIALS:
        return _MATERIALS[name]
    mat = bpy.data.materials.new(name)
    nodes, bsdf = _principled(mat)
    links = mat.node_tree.links
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Specular IOR Level"].default_value = shine
    paint = (*hex_rgb(colour), 1.0)
    coords = nodes.new("ShaderNodeTexCoord")
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.35
    ramp.color_ramp.elements[0].color = (1 - grime, 1 - grime, 1 - grime, 1)
    ramp.color_ramp.elements[1].position = 0.7
    ramp.color_ramp.elements[1].color = (1, 1, 1, 1)
    # The blotches follow the part's metres and its own extent (Generated runs 0 to 1 across it),
    # so a small part gets some too; a part a metre or more long gets somewhat finer ones than before.
    per_part = nodes.new("ShaderNodeVectorMath")
    per_part.operation = "MULTIPLY_ADD"
    links.new(coords.outputs["Generated"], per_part.inputs[0])
    per_part.inputs[1].default_value = (GRIME_PER_PART / (scale / 8),) * 3
    links.new(coords.outputs["Object"], per_part.inputs[2])
    links.new(_noise(nodes, links, per_part.outputs["Vector"], scale / 8, 6.0), ramp.inputs["Fac"])
    reach = None
    if turf or fade:
        # How far out from the part's centre, give or take a ragged few centimetres.
        axes = nodes.new("ShaderNodeSeparateXYZ")
        links.new(coords.outputs["Object"], axes.inputs[0])
        flat = nodes.new("ShaderNodeCombineXYZ")
        links.new(axes.outputs["X"], flat.inputs["X"])
        links.new(axes.outputs["Y"], flat.inputs["Y"])
        length = nodes.new("ShaderNodeVectorMath")
        length.operation = "LENGTH"
        links.new(flat.outputs[0], length.inputs[0])
        ragged = _noise(nodes, links, coords.outputs["Object"], 7.0, 4.0)
        reach = _math(nodes, links, "ADD", length.outputs["Value"], _math(nodes, links, "MULTIPLY_ADD", ragged, 0.1, -0.05))
    if turf:
        grass, start, end = turf
        paint = _mix(nodes, links, _math(nodes, links, "MULTIPLY_ADD", reach, 1 / (end - start), -start / (end - start), clamp=True),
                     paint, grass)
    colour_out = _mix(nodes, links, 1.0, paint, ramp.outputs["Color"], "MULTIPLY")
    if speckle:
        flakes = nodes.new("ShaderNodeTexVoronoi")
        flakes.inputs["Scale"].default_value = scale * 6
        links.new(coords.outputs["Object"], flakes.inputs["Vector"])
        colour_out = _mix(nodes, links, _math(nodes, links, "MULTIPLY", flakes.outputs["Distance"], speckle[1]), colour_out, speckle[0])
    if streaks:
        # Noise squeezed tall: its features run down the part's local Z, and only its peaks show.
        squeeze = nodes.new("ShaderNodeVectorMath")
        squeeze.operation = "MULTIPLY"
        squeeze.inputs[1].default_value = (1.0, 1.0, 0.06)
        links.new(coords.outputs["Object"], squeeze.inputs[0])
        runs = _noise(nodes, links, squeeze.outputs[0], scale * 1.5, 4.0)
        peaks = nodes.new("ShaderNodeValToRGB")
        peaks.color_ramp.elements[0].position = 0.5
        peaks.color_ramp.elements[0].color = (0, 0, 0, 1)
        peaks.color_ramp.elements[1].position = 0.75
        peaks.color_ramp.elements[1].color = (streaks[1], streaks[1], streaks[1], 1)
        links.new(runs, peaks.inputs["Fac"])
        # Only down the sides: rain runs down a wall, not across a lid.
        normal = nodes.new("ShaderNodeNewGeometry")
        axes = nodes.new("ShaderNodeSeparateXYZ")
        links.new(normal.outputs["Normal"], axes.inputs[0])
        flat = _math(nodes, links, "ABSOLUTE", axes.outputs["Z"])
        side = _math(nodes, links, "SUBTRACT", 1.0, flat)
        amount = _math(nodes, links, "MULTIPLY", peaks.outputs["Color"], side)
        colour_out = _mix(nodes, links, amount, colour_out, streaks[0])
    if scorch:
        # Soot up to a ragged line `scorch[2]` above the part's foot, and a band of heat tint above it.
        soot, heat, height = scorch
        axes = nodes.new("ShaderNodeSeparateXYZ")
        links.new(coords.outputs["Object"], axes.inputs[0])
        wobble = _math(nodes, links, "MULTIPLY_ADD", _noise(nodes, links, coords.outputs["Object"], 9.0, 3.0), 0.16, -0.08)
        level = _math(nodes, links, "ADD", axes.outputs["Z"], wobble)
        below = _math(nodes, links, "SUBTRACT", height, level)
        sooted = _math(nodes, links, "MULTIPLY", below, 20.0, clamp=True)
        above = _math(nodes, links, "SUBTRACT", level, height + 0.05)
        band = _math(nodes, links, "ABSOLUTE", above)
        tinted = _math(nodes, links, "MULTIPLY_ADD", band, -12.0, 0.7, clamp=True)
        for factor, over in ((tinted, heat), (sooted, soot)):
            colour_out = _mix(nodes, links, factor, colour_out, over)
    if grain:
        across, stretch, lines, line = GRAIN[grain]
        attribute = nodes.new("ShaderNodeAttribute")
        attribute.attribute_name = "grain"
        along = nodes.new("ShaderNodeVectorMath")
        along.operation = "MULTIPLY"
        along.inputs[1].default_value = (1 / stretch, 1, 1)
        links.new(attribute.outputs["Vector"], along.inputs[0])
        figure = _noise(nodes, links, along.outputs[0], 1 / across, 2.0)
        # The figure's contour lines: up and down `lines` times over its range, a dark line at each
        # low.
        wave = _math(nodes, links, "PINGPONG", _math(nodes, links, "MULTIPLY", figure, lines * 2), 1.0)
        shade = nodes.new("ShaderNodeValToRGB")
        shade.color_ramp.elements[0].position = 0.0
        shade.color_ramp.elements[0].color = (line, line, line, 1)
        shade.color_ramp.elements[1].position = 0.3
        shade.color_ramp.elements[1].color = (1, 1, 1, 1)
        early = shade.color_ramp.elements.new(1.0)
        early.color = (GRAIN_EARLY, GRAIN_EARLY, GRAIN_EARLY, 1)
        links.new(wave, shade.inputs["Fac"])
        colour_out = _mix(nodes, links, 1.0, colour_out, shade.outputs["Color"], "MULTIPLY")
    links.new(colour_out, bsdf.inputs["Base Color"])
    if fade:
        # Thinned to a holdout, not a transparent shader, so the parts it buries stay hidden where it
        # thins: only the game's ground shows through.
        start, end = fade
        thinned = nodes.new("ShaderNodeMixShader")
        links.new(_math(nodes, links, "MULTIPLY_ADD", reach, -1 / (end - start), end / (end - start), clamp=True),
                  thinned.inputs["Fac"])
        links.new(nodes.new("ShaderNodeHoldout").outputs[0], thinned.inputs[1])
        links.new(bsdf.outputs[0], thinned.inputs[2])
        links.new(thinned.outputs[0], nodes.get("Material Output").inputs["Surface"])
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*hex_rgb(emission), 1.0)
        bsdf.inputs["Emission Strength"].default_value = 6.0
    _MATERIALS[name] = mat
    return mat


def holdout():
    """Hides what is behind it and leaves its own pixels transparent: an overlay tile renders its
    base object with this, so the overlay keeps only what the base doesn't cover."""
    if "Holdout" in _MATERIALS:
        return _MATERIALS["Holdout"]
    mat = bpy.data.materials.new("Holdout")
    nodes, bsdf = _principled(mat)
    out = nodes.get("Material Output")
    hold = nodes.new("ShaderNodeHoldout")
    mat.node_tree.links.new(hold.outputs[0], out.inputs["Surface"])
    _MATERIALS["Holdout"] = mat
    return mat


def _periodic_noise(nodes, links, axes, scale, detail, variant):
    """Noise over a tile's floor that repeats every metre along X and Y, so it matches itself
    across the edge between two tiles, as long as `variant` is 0. Each axis is wrapped round a
    circle a metre round, which keeps the noise's size per metre; `variant` moves the whole
    pattern somewhere else."""
    tau = 2 * math.pi
    parts = []
    for axis in ("X", "Y"):
        angle = _math(nodes, links, "MULTIPLY", axes.outputs[axis], tau)
        for operation in ("COSINE", "SINE"):
            parts.append(_math(nodes, links, "MULTIPLY_ADD", _math(nodes, links, operation, angle), 1 / tau,
                               variant * 7.31))
    point = nodes.new("ShaderNodeCombineXYZ")
    for i in range(3):
        links.new(parts[i], point.inputs[i])
    noise = nodes.new("ShaderNodeTexNoise")
    noise.noise_dimensions = "4D"
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = detail
    links.new(point.outputs[0], noise.inputs["Vector"])
    links.new(parts[3], noise.inputs["W"])
    return noise.outputs["Fac"]


def _tile_noise(nodes, links, axes, scale, detail, variant, inland):
    """Periodic noise near the tile's edges, where neighbouring tiles must match, blending by
    `inland` (0 at the edges, 1 in the middle) into the same noise moved by `variant`, so tiles
    don't all show the same blotches."""
    edge = _periodic_noise(nodes, links, axes, scale, detail, 0)
    middle = _periodic_noise(nodes, links, axes, scale, detail, variant)
    return _math(nodes, links, "MULTIPLY_ADD", _math(nodes, links, "SUBTRACT", middle, edge), inland, edge)


def stain(name, colour, arms, centre, near, far, softness, ragged, opacity, scale=6.0, variant=1):
    """A flat patch lying on a tile's floor that draws as `colour` whatever the light: wet soil,
    which the game's grass shows through at the edge. It covers a round patch `centre` metres
    across round the tile's middle and a band along each of `arms` (unit (x, y) directions) out to
    the tile's edge, `near` metres to either side at the middle narrowing to `far` at the edge.
    It is opaque inside and fades out over `softness` metres, its edge moved in and out by up to
    `ragged` metres of noise. A band leaves the tile as its neighbour's band of the opposite arm
    comes in, noise and all, so the patches of a run of such tiles join into one strip, while a
    tile alone narrows to a neck at each edge rather than ending square. It is unlit because the
    floor it darkens is lit by the game, and a lit surface this large takes grain from the
    render's samples."""
    if name in _MATERIALS:
        return _MATERIALS[name]
    mat = bpy.data.materials.new(name)
    if not mat.node_tree:
        mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    for node in list(nodes):
        if node.type != "OUTPUT_MATERIAL":
            nodes.remove(node)
    coords = nodes.new("ShaderNodeTexCoord")
    axes = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coords.outputs["Object"], axes.inputs[0])
    flat = nodes.new("ShaderNodeCombineXYZ")
    links.new(axes.outputs["X"], flat.inputs[0])
    links.new(axes.outputs["Y"], flat.inputs[1])
    length = nodes.new("ShaderNodeVectorMath")
    length.operation = "LENGTH"
    links.new(flat.outputs[0], length.inputs[0])
    # How far outside the patch each point is, in metres: the least of the round patch's and each
    # band's. A band's half width shrinks from `near` to `far` along it; behind the middle the
    # round patch covers.
    outside = _math(nodes, links, "SUBTRACT", length.outputs["Value"], centre / 2)
    for dx, dy in arms:
        along = _math(nodes, links, "MULTIPLY", axes.outputs["X" if dx else "Y"], dx or dy)
        across = _math(nodes, links, "ABSOLUTE", axes.outputs["Y" if dx else "X"])
        way = _math(nodes, links, "MULTIPLY", along, 2.0, clamp=True)
        half = _math(nodes, links, "MULTIPLY_ADD", way, far - near, near)
        band = _math(nodes, links, "MAXIMUM", _math(nodes, links, "SUBTRACT", across, half),
                     _math(nodes, links, "MULTIPLY", along, -1.0))
        outside = _math(nodes, links, "MINIMUM", outside, band)
    # 0 at the tile's edges, where neighbours must match, rising to 1 inland.
    reach = _math(nodes, links, "MAXIMUM", _math(nodes, links, "ABSOLUTE", axes.outputs["X"]),
                  _math(nodes, links, "ABSOLUTE", axes.outputs["Y"]))
    inland = _math(nodes, links, "MULTIPLY", _math(nodes, links, "SUBTRACT", 0.45, reach), 1 / 0.15, clamp=True)
    jag = _tile_noise(nodes, links, axes, scale, 1.5, variant, inland)
    edge = _math(nodes, links, "ADD", outside, _math(nodes, links, "MULTIPLY_ADD", jag, ragged, -ragged / 2))
    fade = _math(nodes, links, "DIVIDE", edge, -softness, clamp=True)
    alpha = _math(nodes, links, "MULTIPLY", fade, opacity)
    # Darker in blotches, as soil dries unevenly.
    blotch = _tile_noise(nodes, links, axes, scale * 2, 1.0, variant, inland)
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.3
    ramp.color_ramp.elements[0].color = (0.75, 0.75, 0.75, 1)
    ramp.color_ramp.elements[1].position = 0.7
    ramp.color_ramp.elements[1].color = (1.15, 1.15, 1.15, 1)
    links.new(blotch, ramp.inputs["Fac"])
    tint = _mix(nodes, links, 1.0, colour, ramp.outputs["Color"], "MULTIPLY")
    glow = nodes.new("ShaderNodeEmission")
    glow.inputs["Strength"].default_value = 1.0
    links.new(tint, glow.inputs["Color"])
    clear = nodes.new("ShaderNodeBsdfTransparent")
    mix = nodes.new("ShaderNodeMixShader")
    links.new(alpha, mix.inputs["Fac"])
    links.new(clear.outputs[0], mix.inputs[1])
    links.new(glow.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], nodes.get("Material Output").inputs["Surface"])
    _MATERIALS[name] = mat
    return mat
