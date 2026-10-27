"""The static check's script checks: script syntax, items, model textures and craft recipes
(docs/static-check.md).
"""
import os
import re

import scripts
from moddata import (_read, any_texture, check, has_entry, item_exists, lua_defined, lua_globals, packed,
                     recipe_exists, text_problem)


# ---------------------------------------------------------------------------------------------
# Scripts

@check
def script_syntax(mod, game, report):
    # What ScriptParser silently does with a slip: drops the text after a block's last comma,
    # runs a value missing its comma into the next one or into the next block's header, and
    # keeps // as text.
    for path, root in mod.scripts + ([mod.sandbox] if mod.sandbox else []):
        report.saw("script files")
        for block in root.walk():
            if block.type != "imports":     # ScriptModule splits imports on commas itself
                for text, line in block.dropped:
                    report.fail("script-syntax", path, line, "%r has no comma after it, so the game drops it"
                                % _short(text))
            for value in block.values:
                if value.key is not None and re.search(r"\n\s*\w+\s*=", value.value):
                    report.fail("script-syntax", path, value.line, "%s has no comma after it, so the next line "
                                "became part of its value" % value.key)
            if any("=" in word for word in block.header):
                report.fail("script-syntax", path, block.line, "this block's header reads %r: a value before "
                            "it is missing its comma" % _short(" ".join(block.header)))
            elif len(block.header) > 2 and block.type in ("item", "craftRecipe", "model", "option"):
                report.fail("script-syntax", path, block.line, "%s %s: the game takes only the first word "
                            "after the type as the name" % (block.type, " ".join(block.header[1:])))
        if mod.sandbox is None or path != mod.sandbox[0]:
            for child in root.children:
                if child.type != "module":
                    report.fail("script-syntax", path, child.line, "%s block outside a module, which "
                                "ScriptManager ignores" % child.type)
        stripped = scripts.strip_comments(_read(path))
        for match in re.finditer(r"//", stripped):
            report.fail("script-syntax", path, stripped.count("\n", 0, match.start()) + 1,
                        "// starts no comment in a script, only /* */ does, so this is part of a value")


def _short(text):
    text = " ".join(text.split())
    return text if len(text) <= 50 else text[:47] + "..."


# ---------------------------------------------------------------------------------------------
# Items

LEGACY_ITEM_FIELDS = {
    "Type": "build 42 reads ItemType instead and leaves getItemType() null",
    "DisplayName": "build 42 names items from ItemName.json",
    "TeachedRecipes": "build 42 reads LearnedRecipes",
}


@check
def items(mod, game, report):
    for full_type, (block, module, imports, path) in sorted(mod.items.items()):
        report.saw("items")
        category = block.get("DisplayCategory")
        hidden = category is not None and category.value == "Hidden"
        for value in block.values:
            if value.key is None:
                continue
            if value.key in LEGACY_ITEM_FIELDS:
                report.fail("item-legacy-field", path, value.line, "%s is a build 41 field: %s"
                            % (value.key, LEGACY_ITEM_FIELDS[value.key]))
            elif value.key.lower() not in game.item_fields:
                # Item.DoParam stores a key it does not know as item mod data, without complaint.
                report.fail("item-field", path, value.line, "%s is no item field the game knows, so it only "
                            "ends up in the item's mod data" % value.key)

        item_type = block.get("ItemType")
        if item_type is None:
            report.fail("item-type", path, block.line, "%s has no ItemType" % full_type)
        elif item_type.value not in game.item_types:
            report.fail("item-type", path, item_type.line, "ItemType = %s is none the game's items use (%s...)"
                        % (item_type.value, ", ".join(sorted(game.item_types)[:4])))

        for value in block.all("Tags"):
            for tag in filter(None, (t.strip() for t in value.value.split(";"))):
                if ":" not in tag:
                    # Build 42 tags are resource locations; a bare one matches no tags[] query.
                    report.fail("item-tag", path, value.line, "tag %s has no namespace, so nothing finds it (base:%s?)"
                                % (tag, tag.lower()))

        icon = block.get("Icon")
        if icon is None and not hidden:
            # The crafting window draws the script's icon, moveables included, and throws listing
            # an item without one.
            report.fail("item-no-icon", path, block.line, "%s has no Icon" % full_type)
        elif icon is not None:
            report.saw("item icons")
            if not any_texture(mod, game, "Item_" + icon.value):
                # Item.getNormalTexture asks for Item_<Icon> and draws a question mark without it.
                report.fail("item-icon", path, icon.line, "Icon = %s, but no pack or media/textures has Item_%s"
                            % (icon.value, icon.value))

        if not hidden and not has_entry(mod, game, "ItemName", full_type):
            report.fail("item-name", path, block.line, "%s has no ItemName.json entry, so it shows its script name"
                        % full_type)
        tooltip = block.get("Tooltip")
        if tooltip is not None:
            problem = text_problem(mod, game, tooltip.value)
            if problem:
                report.fail("item-tooltip", path, tooltip.line, problem)

        for key in ("WorldStaticModel", "StaticModel"):
            model = block.get(key)
            if model is not None and not _model_exists(mod, game, model.value, module, imports):
                report.fail("item-model", path, model.line, "%s = %s is no model script" % (key, model.value))

        sprite = block.get("WorldObjectSprite")
        if sprite is not None:
            problem = _sprite_problem(mod, game, sprite.value)
            if problem:
                report.fail("item-sprite", path, sprite.line, problem)

        for key in ("LearnedRecipes", "ResearchableRecipes"):
            for value in block.all(key):
                for name in filter(None, (n.strip() for n in value.value.split(";"))):
                    if not recipe_exists(mod, game, name):
                        report.fail("learned-recipe", path, value.line, "%s names %s, which no craftRecipe defines"
                                    % (key, name))


def _model_exists(mod, game, name, module, imports):
    if "." in name:
        return name in mod.models or name in game.models
    return any(("%s.%s" % (m, name)) in mod.models or ("%s.%s" % (m, name)) in game.models
               for m in [module, *imports, "Base"])


def _sprite_problem(mod, game, sprite):
    """Why a tile sprite name would not draw, or None. Names are <tileset>_<index>."""
    tileset_name, _, index = sprite.rpartition("_")
    if not index.isdigit():
        return "%s is not a tileset name and tile index" % sprite
    for path, tileset in mod.tilesets:
        if tileset.name == tileset_name:
            if int(index) >= len(tileset.tiles):
                return "%s is past the %d tiles of %s" % (sprite, len(tileset.tiles), tileset_name)
            if not packed(mod, game, sprite):
                return "no pack has a sprite %s" % sprite
            return None
    if int(index) < game.tilesets.get(tileset_name, 0):
        return None
    return "no tileset of the mod or the game has %s" % sprite


@check
def model_texture(mod, game, report):
    # A model binds its whole texture and samples it with UVs running 0 to 1 across it, so a
    # packed sprite would show a slice of every other sprite on its page, with no error.
    for path, root in mod.scripts:
        for _module, block in scripts.modules(root):
            for model in block.blocks("model"):
                texture = model.get("texture")
                if texture is None:
                    continue
                report.saw("model textures")
                bare = texture.value.replace("\\", "/").rsplit("/", 1)[-1]
                if bare in mod.sprites:
                    report.fail("model-texture", path, texture.line, "texture = %s is packed in %s, so the model "
                                "would sample the whole page" % (texture.value, os.path.basename(mod.sprites[bare])))
                elif not (mod.media_file("media/textures/%s.png" % texture.value)
                          or game.file("media/textures/%s.png" % texture.value)):
                    report.fail("model-texture", path, texture.line, "texture = %s has no media/textures/%s.png"
                                % (texture.value, texture.value))


# ---------------------------------------------------------------------------------------------
# Craft recipes

@check
def recipes(mod, game, report):
    tags = game.tags | {tag.strip().lower() for item in mod.items.values()
                        for value in item.block.all("Tags") for tag in value.value.split(";")}
    for name, (block, module, path) in sorted(mod.recipes.items()):
        report.saw("craft recipes")
        learned = block.get("NeedToBeLearn")
        if module != "Base" and learned is not None and learned.value.lower() == "true":
            # The game looks a recipe up by bare name for research and a magazine's recipe list,
            # and a bare name resolves only in Base (ScriptBucketCollection.getScript). A recipe
            # every player knows is never looked up that way.
            report.fail("recipe-module", path, block.line, "craftRecipe %s needs to be learned, but is in module "
                        "%s, where research and magazines cannot find it; it belongs in module Base"
                        % (name, module))
        if not has_entry(mod, game, "Recipes", name):
            report.fail("recipe-name", path, block.line, "craftRecipe %s has no Recipes.json entry" % name)

        for part in block.blocks("inputs") + block.blocks("outputs"):
            previous = None
            for value in part.values:
                # A `-` or `+` line takes from or fills the item of the line before it, which must
                # ask exactly one item (InputScript.OnPostWorldDictionaryInit), or the world refuses
                # to load.
                if value.key is None and value.value[:1] in ("-", "+") and previous is not None \
                        and not re.match(r"item\s+1\s", previous.value):
                    report.fail("recipe-fluid-owner", path, value.line, "%s works on the line before it, which "
                                "must ask exactly one item: %s" % (value.value.split()[0], previous.value))
                if value.key is None:
                    previous = value
                if value.key is not None or not re.match(r"-?item\b", value.value):
                    continue
                for prefix, listed in re.findall(r"(\w*)\[([^\]]*)\]", value.value):
                    entries = [e.strip() for e in listed.split(";") if e.strip()]
                    if prefix == "tags":
                        for tag in entries:
                            report.saw("recipe tags")
                            if tag.lower() not in tags:
                                report.fail("recipe-tag", path, value.line, "no item carries tag %s, so this "
                                            "input can never be met" % tag)
                    elif prefix == "":
                        for entry in entries:
                            # `2:Base.Glue` asks two of that item where the line asks one
                            # (InputScript.Load).
                            entry = entry.split(":")[-1]
                            if entry != "*" and not item_exists(mod, game, entry, module):
                                report.fail("recipe-item", path, value.line, "%s is no item" % entry)
                # An output names its item bare, as in `item 1 MyMod.Thing`.
                for word in value.value.split()[2:3]:
                    if re.fullmatch(r"[A-Za-z_]\w*\.\w+", word) and not item_exists(mod, game, word):
                        report.fail("recipe-item", path, value.line, "%s is no item" % word)

        for hook in ("OnCreate", "OnTest"):
            target = block.get(hook)
            if target is not None and not _lua_path_defined(mod, game, target.value):
                report.fail("recipe-hook", path, target.line, "%s = %s is no function the game or mod defines"
                            % (hook, target.value))
        menu = block.get("OnAddToMenu")
        if menu is not None:
            # The crafting window fetches it with one rawget on the global table, so a dotted path
            # finds nothing and the recipe silently leaves the list.
            if "." in menu.value:
                report.fail("recipe-hook", path, menu.line, "OnAddToMenu = %s is a dotted path, but the game "
                            "looks up a plain global name" % menu.value)
            elif menu.value not in lua_globals(mod, game):
                report.fail("recipe-hook", path, menu.line, "OnAddToMenu = %s is no global function" % menu.value)


def _lua_path_defined(mod, game, target):
    """Whether a.b.c names something: its root a global, and c a function name some Lua defines
    (or, for a root that is a Java class, one of its static methods)."""
    names = target.split(".")
    if names[0] in game.statics and len(names) == 2 and names[1] in game.statics[names[0]]:
        return True
    return names[0] in lua_globals(mod, game) and (len(names) == 1 or names[-1] in lua_defined(mod, game))
