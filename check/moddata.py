"""What the static check reads from a mod, and what a mod's own checks (plugins) build on.

Each check is a function registered with @check, under the name docs/static-check.md lists it by.
A plugin is a Python file a mod's dev/harness.conf names in CHECK_PLUGINS. It imports this module,
registers its own checks with @check, and may use the lookups below.
"""
import json
import os
from collections import Counter, namedtuple

import luasource
import packs
import scripts
import tiledefs


# ---------------------------------------------------------------------------------------------
# The report

class Report:
    def __init__(self, base):
        self.base = base
        self.problems = []
        self.notes = []
        self.seen = Counter()

    def where(self, path, line=None):
        relative = os.path.relpath(path, self.base) if os.path.isabs(path) else path
        return "%s:%d" % (relative, line) if line else relative

    def fail(self, check, path, line, message):
        self.problems.append((check, self.where(path, line), message))

    def note(self, message):
        self.notes.append(message)

    def saw(self, what, n=1):
        self.seen[what] += n

    def finish(self):
        print("checked " + ", ".join("%d %s" % (n, what) for what, n in sorted(self.seen.items())))
        for message in self.notes:
            print("note   " + message)
        for check, where, message in sorted(self.problems):
            print("FAIL   %-22s %s: %s" % (check, where, message))
        if self.problems:
            print("%d problem%s" % (len(self.problems), "" if len(self.problems) == 1 else "s"))
            return 1
        print("all cross-checks passed")
        return 0


CHECKS = []


def check(function):
    """A check, function(mod, game, report). Checks run in the order they register, the mod's
    plugins' after these."""
    CHECKS.append(function)
    return function


# ---------------------------------------------------------------------------------------------
# The mod

Item = namedtuple("Item", "block module imports path")
Recipe = namedtuple("Recipe", "block module path")
# A library mod the published mod requires: its folder, the id and the mod.info by key (_mod_info)
# of its 42 folder, and its version folders.
Library = namedtuple("Library", "folder id info info_path roots")


class Mod:
    """Every file of the mod the checks read, parsed once. Unreadable files are reported here.

    roots are the published mod's version folders, the first holding its mod.info, then the dev
    mod's and the harness mod's. The published mod's are those in the first one's mod folder.
    libraries are the folders of the library mods the published mod requires, in load order; they
    ship too, so their files are read and checked as the published mod's are."""

    def __init__(self, roots, name, report, all_languages=False, libraries=(), other_globals=()):
        published = [r for r in roots if os.path.dirname(r) == os.path.dirname(roots[0])]
        self.libraries = []
        for folder in libraries:
            info_path = os.path.join(folder, "42", "mod.info")
            info = _mod_info(info_path)
            self.libraries.append(Library(folder, (info.get("id") or [None])[0], info, info_path,
                                          [os.path.join(folder, part) for part in ("42", "common")
                                           if os.path.isdir(os.path.join(folder, part))]))
        library_roots = [r for library in self.libraries for r in library.roots]
        # The mod's files are looked up before a library's: the mod loads after its libraries, and
        # the game takes a file from the mod that loads last.
        self.roots = published + library_roots + [r for r in roots if r not in published]
        # Translation keys carry it, so translation-key can tell a string shaped like one.
        self.name = name
        self.report = report
        # Whether every language the game offers must have every translation English has.
        self.all_languages = all_languages
        # Globals of mods the mod works alongside without requiring them, which no file here defines.
        self.other_globals = set(other_globals)

        # The published mod's mod.info, in the first root; the dev mod's and the harness mod's
        # describe other mods.
        path = os.path.join(roots[0], "mod.info")
        self.info_path = path if os.path.exists(path) else None
        self.info = _mod_info(path)
        self.id = (self.info.get("id") or [None])[0]

        # The id of the published mod or library each root ships in.
        owners = dict.fromkeys(published, self.id)
        for library in self.libraries:
            owners.update(dict.fromkeys(library.roots, library.id))
        self.lua = []
        for root in self.roots:
            for path in self._files("media/lua", ".lua", [root]):
                lua = luasource.read(path)
                lua.module = _require_path(path)
                lua.requires = [(name[:-4] if name.endswith(".lua") else name, at)
                                for name, at in lua.calls_with_literal("require")]
                # The Workshop gets these, with the mod or as its libraries; the dev mod and the
                # harness mod stay home.
                lua.published = root in owners
                # Whose mod.info's require= the file's requires go by; None for the dev mod's and
                # the harness mod's.
                lua.owner = owners.get(root)
                self.lua.append(lua)

        self.scripts = []
        self.items, self.recipes, self.models = {}, {}, set()
        # Build-menu entities with a CraftRecipe component: their recipe goes by the entity's name,
        # and a magazine teaches it like any other (CraftRecipe in GameEntityScript).
        self.entity_recipes = set()
        for path in self._files("media/scripts", ".txt"):
            root = scripts.parse(_read(path))
            self.scripts.append((path, root))
            for module, block in scripts.modules(root):
                # ScriptModule splits an imports block on commas, a last name without one included.
                imports = [name.strip() for b in block.blocks("imports")
                           for text in [v.value for v in b.values] + [t for t, _ in b.dropped]
                           for name in text.split(",") if name.strip()]
                for child in block.children:
                    if child.type == "item":
                        self.items["%s.%s" % (module, child.id)] = Item(child, module, imports, path)
                    elif child.type == "craftRecipe":
                        self.recipes[child.id] = Recipe(child, module, path)
                    elif child.type == "model":
                        self.models.add("%s.%s" % (module, child.id))
                    elif child.type == "entity" and any(c.id == "CraftRecipe" for c in child.blocks("component")):
                        self.entity_recipes.add(child.id)

        # Language -> translation file name -> {key: text}, merged over the mods in load order, the
        # libraries first, as Translator.tryFillMapFromMods merges them: a later mod's text wins
        # unless it is empty. And each file as (language, name, path, its own {key: text}), for the
        # checks that go file by file.
        self.translations, self.translation_files = {}, []
        load_order = library_roots + [r for r in self.roots if r not in library_roots]
        for path in self._files("media/lua/shared/Translate", ".json", load_order):
            language = os.path.basename(os.path.dirname(path))
            name = os.path.basename(path)[:-len(".json")]
            table = self._json(path, strings=name != "language")
            if name == "language":     # Languages metadata, not a Translator string table.
                continue
            self.translation_files.append((language, name, path, table))
            merged = self.translations.setdefault(language, {}).setdefault(name, {})
            merged.update((key, text) for key, text in table.items() if text or key not in merged)

        self.sandbox = None
        for root in roots:
            path = os.path.join(root, "media", "sandbox-options.txt")
            if os.path.exists(path):
                self.sandbox = (path, scripts.parse(_read(path)))

        self.sprites = {}           # packed sprite name -> pack file
        for path in self._files("media/texturepacks", ".pack"):
            try:
                pages = packs.read_index(path)
            except (ValueError, EOFError) as e:
                report.fail("pack-format", path, None, "the game could not read it: %s" % e)
                continue
            for page in pages:
                for sprite in page.sprites:
                    self.sprites.setdefault(sprite.name, path)

        # (file, Tileset) for each tileset the published mod's tiledef= lines name.
        self.tilesets = []
        self._read_tilesets(report)

    def _read_tilesets(self, report):
        for value in self.info.get("tiledef", []):
            words = value.split()
            path = self.media_file("media/%s.tiles" % words[0]) if words else None
            if len(words) != 2 or not words[1].isdigit() or not 100 <= int(words[1]) <= 8189:
                # ChooseGameInfo.readModInfo drops the line without these.
                report.fail("tile-format", self.info_path, None, "tiledef=%s needs a file name and a "
                            "file number from 100 to 8189" % value)
            if path is None:
                report.fail("tile-format", self.info_path, None, "tiledef=%s names no media/%s.tiles"
                            % (value, words[0] if words else ""))
                continue
            with open(path, "rb") as f:
                data = f.read()
            try:
                tilesets = tiledefs.loads(data)
            except ValueError as e:
                report.fail("tile-format", path, None, "the game could not read it: %s" % e)
                continue
            if tiledefs.dumps(tilesets) != data:
                report.fail("tile-format", path, None, "reads, but does not write back the same, so "
                            "check/tiledefs.py misreads something in it")
            self.tilesets.extend((path, tileset) for tileset in tilesets)
        for value in self.info.get("pack", []):
            if not self.media_file("media/texturepacks/%s.pack" % value):
                report.fail("tile-format", self.info_path, None, "pack=%s names no media/texturepacks/%s.pack"
                            % (value, value))

    def tile(self, sprite):
        """(file, properties as a dict) of a tile of the mod's tilesets by sprite name, or None."""
        tileset_name, _, index = sprite.rpartition("_")
        if not index.isdigit():
            return None
        for path, tileset in self.tilesets:
            if tileset.name == tileset_name and int(index) < len(tileset.tiles):
                return path, dict(tileset.tiles[int(index)])
        return None

    def _files(self, under, suffix, roots=None):
        for root in self.roots if roots is None else roots:
            top = os.path.join(root, *under.split("/"))
            for base, _dirs, names in os.walk(top):
                for name in sorted(names):
                    if name.endswith(suffix):
                        yield os.path.join(base, name)

    def _json(self, path, strings=True):
        """A JSON object's fields, rejecting non-string values only for translation tables."""
        duplicates = []

        def pairs(items):
            seen = {}
            for key, value in items:
                if key in seen:
                    duplicates.append(key)
                seen[key] = value
            return seen

        try:
            data = json.loads(_read(path), object_pairs_hook=pairs)
        except ValueError as e:
            self.report.fail("translation-json", path, None, "not valid JSON: %s" % e)
            return {}
        if not isinstance(data, dict):
            self.report.fail("translation-json", path, None, "is not a JSON object")
            return {}
        for key in duplicates:
            self.report.fail("translation-json", path, None, "%s is given twice, and only the last one counts" % key)
        for key, value in data.items():
            if strings and not isinstance(value, str):
                self.report.fail("translation-json", path, None, "%s is not a string" % key)
        return {key: value for key, value in data.items() if isinstance(value, str)} if strings else data

    def english(self, file_name):
        return self.translations.get("EN", {}).get(file_name, {})

    def media_file(self, relative):
        """The mod file at a path relative to a mod root (media/...), if any root has it."""
        for root in self.roots:
            path = os.path.join(root, *relative.split("/"))
            if os.path.exists(path):
                return path
        return None


def _read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def _mod_info(path):
    """A mod.info's values by key, each key's in file order; {} if there is no such file."""
    info = {}
    if os.path.exists(path):
        for line in _read(path).splitlines():
            key, equals, value = line.partition("=")
            if equals:
                info.setdefault(key.strip(), []).append(value.strip())
    return info


def required_ids(info):
    """The mod ids a mod.info (_mod_info) requires. ChooseGameInfo.readModInfo keeps the last
    require= line, drops its backslashes and splits it on commas, and isAvailableRequired trims
    each id."""
    lines = info.get("require")
    return [i.strip() for i in lines[-1].replace("\\", "").split(",") if i.strip()] if lines else []


def _require_path(path):
    """The module name require() finds a Lua file by: its path under lua/client, server or shared."""
    parts = path.replace(os.sep, "/").split("/media/lua/", 1)[-1].split("/", 1)
    return parts[1][:-len(".lua")] if len(parts) == 2 else None


# ---------------------------------------------------------------------------------------------
# Shared lookups

# Translator.getTextInternal picks the table a key is looked up in by its prefix, and each table
# is filled only from the translation file of its name, so an IGUI_ key in Tooltip.json is never
# found. Keys with none of these prefixes come back as themselves.
TEXT_TABLES = [
    ("UI_", "UI"), ("Moodles_", "Moodles"), ("SurvivalGuide_", "SurvivalGuide"), ("Farming_", "Farming"),
    ("IGUI_", "IG_UI"), ("ContextMenu_", "ContextMenu"), ("GameSound_", "GameSound"), ("Sandbox_", "Sandbox"),
    ("Tooltip_", "Tooltip"), ("Challenge_", "Challenge"), ("MakeUp", "MakeUp"), ("Stash_", "Stash"),
    ("RM_", "Recorded_Media"), ("SurvivorName_", "SurvivorNames"), ("SurvivorSurname_", "SurvivorNames"),
    ("Attributes_", "Attributes"), ("Fluid_", "Fluids"), ("Print_Media_", "Print_Media"),
    ("Print_Text_", "Print_Text"), ("EC_", "Entity"), ("RD_", "RadioData"), ("BODYPART_", "BodyParts"),
    ("MapLabel_", "MapLabel"), ("credits_", "Credits"), ("AEBS_", "DynamicRadio"),
]


def text_table(key):
    for prefix, file_name in TEXT_TABLES:
        if key.startswith(prefix):
            return file_name
    return None


def has_entry(mod, game, file_name, key):
    return key in mod.english(file_name) or key in game.translations.get(file_name, ())


def has_text(mod, game, key):
    """Whether getText(key) finds a translation rather than echoing the key."""
    file_name = text_table(key)
    return file_name is not None and has_entry(mod, game, file_name, key)


def text_problem(mod, game, key):
    """Why getText(key) would echo the key, or None if it finds a translation."""
    file_name = text_table(key)
    if file_name is None:
        return "no translation table takes keys starting like %s" % key
    if has_entry(mod, game, file_name, key):
        return None
    for other in mod.translations.get("EN", {}):
        if key in mod.english(other):
            return "%s is in %s.json, but getText looks it up only in %s.json" % (key, other, file_name)
    return "%s is in no %s.json" % (key, file_name)


def packed(mod, game, name):
    return name in mod.sprites or name in game.sprites


def shared_texture(mod, game, name):
    """Whether Texture.getSharedTexture(name) finds something. It asks the packs for the name with
    its directories and .png dropped (unless it ends in .txt or runs through /mods/), then for the
    name as given, and last loads the file when the name has an extension."""
    path = name.replace("\\", "/")
    if not path.endswith(".txt") and "/mods/" not in path:
        bare = path[:-len(".png")] if path.endswith(".png") else path
        if packed(mod, game, bare[bare.rfind("/") + 1:]):
            return True
    if packed(mod, game, path):
        return True
    return "." in path and bool(mod.media_file(path) or game.file(path))


def any_texture(mod, game, name):
    """Texture.trygetTexture: getSharedTexture, then media/textures/<name>.png."""
    loose = "media/textures/" + name + ("" if name.endswith(".png") else ".png")
    return shared_texture(mod, game, name) or bool(mod.media_file(loose) or game.file(loose))


def item_exists(mod, game, name, module=None, imports=()):
    if "." in name:
        return name in mod.items or name in game.items
    return any(("%s.%s" % (m, name)) in mod.items or ("%s.%s" % (m, name)) in game.items
               for m in [module, *imports, "Base"] if m)


def recipe_exists(mod, game, name):
    return name in mod.recipes or name in mod.entity_recipes or name in game.recipes


def lua_defined(mod, game):
    """Names given a function anywhere in the game's or the mod's Lua."""
    if not hasattr(mod, "_functions"):
        mod._functions = set(game.lua_functions).union(*(lua.functions for lua in mod.lua))
    return mod._functions


def lua_globals(mod, game, published=False):
    """Every global some Lua or the engine defines; optionally only the Lua that ships."""
    cache = "_published_globals" if published else "_globals"
    if not hasattr(mod, cache):
        known = (set(game.globals) | set(game.classes) | game.lua_globals | game.lua_members.get("_G", set())
                 | mod.other_globals)
        for lua in mod.lua:
            if not published or lua.published:
                # _G.name = ... defines a global too.
                known |= lua.globals | {key for table, key in lua.members if table == "_G"}
        setattr(mod, cache, known)
    return getattr(mod, cache)


def lua_members(mod, game, table):
    members = set(game.lua_members.get(table, ()))
    for lua in mod.lua:
        members |= {key for t, key in lua.members if t == table}
    return members
