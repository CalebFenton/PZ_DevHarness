"""The checks on the mod's texture packs (Mod.sprites) and on the tiles of the tilesets its
mod.info names with tiledef= (Mod.tilesets).

check.py imports this after the rules_*.py modules, so these run after the checks there and before
any plugin's.
"""
from moddata import check, has_entry, has_text, item_exists


@check
def pack_clash(mod, game, report):
    # Sprite names are global, and a mod's packs load after the game's, so a mod sprite named
    # like a vanilla one replaces it everywhere.
    report.saw("packed sprites", len(mod.sprites))
    for name, path in sorted(mod.sprites.items()):
        if name in game.sprites:
            report.fail("pack-clash", path, None, "sprite %s replaces the game's sprite of that name" % name)


def _full_type(name, module):
    return name if "." in name else "%s.%s" % (module, name)


@check
def tiles(mod, game, report):
    for path, tileset in mod.tilesets:
        for index, properties in enumerate(tileset.tiles):
            if not properties:
                continue
            report.saw("tiles")
            sprite = "%s_%d" % (tileset.name, index)
            values = dict(properties)
            if sprite not in mod.sprites:
                report.fail("tile-sprite", path, None, "%s has properties but no pack has its sprite" % sprite)
            item = values.get("CustomItem")
            if item is not None and not item_exists(mod, game, item):
                report.fail("tile-item", path, None, "%s: CustomItem = %s is no item, so picking it up gives "
                            "nothing" % (sprite, item))
            # Translator.getMoveableDisplayName: "<GroupName> <CustomName>", spaces and dashes to
            # underscores and apostrophes dropped, looked up in Moveables.json.
            if values.get("CustomName"):
                name = (values["GroupName"] + " " if values.get("GroupName") else "") + values["CustomName"]
                key = name.replace(" ", "_").replace("-", "_").replace("'", "")
                if not has_entry(mod, game, "Moveables", key):
                    report.fail("tile-name", path, None, "%s is named %r, but Moveables.json has no %s"
                                % (sprite, name, key))
            # ISInventoryPage titles a container getText("IGUI_ContainerTitle_" .. type).
            if values.get("container"):
                key = "IGUI_ContainerTitle_" + values["container"]
                if not has_text(mod, game, key):
                    report.fail("tile-container", path, None, "%s holds a %s container, but IG_UI.json has no %s"
                                % (sprite, values["container"], key))


@check
def tile_item_pair(mod, game, report):
    # Picking a tile up gives its CustomItem, and placing that item puts down the item's
    # WorldObjectSprite, so the two have to name each other or a pick-up and a put-down change
    # what the object is. A tile's other facings and states name the item too, which places only
    # one of them.
    for full_type, (block, module, _imports, path) in sorted(mod.items.items()):
        sprite = block.get("WorldObjectSprite")
        tile = sprite and mod.tile(sprite.value)
        if not tile:
            continue
        report.saw("tile items")
        custom = tile[1].get("CustomItem")
        if custom is None:
            report.fail("tile-item-pair", path, sprite.line, "%s places %s, which has no CustomItem, so it "
                        "picks up as a generic moveable" % (full_type, sprite.value))
        elif _full_type(custom, module) != full_type:
            report.fail("tile-item-pair", path, sprite.line, "%s places %s, which picks up as %s (its "
                        "CustomItem)" % (full_type, sprite.value, custom))
    for path, tileset in mod.tilesets:
        for index, properties in enumerate(tileset.tiles):
            custom = dict(properties).get("CustomItem")
            item = mod.items.get(custom or "")
            if item is None:
                continue
            sprite = item.block.get("WorldObjectSprite")
            if sprite is None:
                report.fail("tile-item-pair", path, None, "%s_%d picks up as %s, which has no WorldObjectSprite, "
                            "so it places nothing" % (tileset.name, index, custom))
            elif not mod.tile(sprite.value):
                report.fail("tile-item-pair", path, None, "%s_%d picks up as %s, which places %s, no tile of "
                            "the mod's" % (tileset.name, index, custom, sprite.value))
