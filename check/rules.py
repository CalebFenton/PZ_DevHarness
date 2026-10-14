"""The checks, and what a mod's own checks (plugins) build on.

check.py runs them after GameProbe has compiled every Lua file. Each check is a function below,
under the name docs/static-check.md lists it by, and looks for a mistake the game would not
report: a missing translation shows its key, a wrong texture draws nothing, a script value without
its comma is dropped, and a Lua name that does not exist fails only when its line runs.

A plugin is a Python file a mod's dev/harness.conf names in CHECK_PLUGINS. It imports this module,
registers its own readers and checks with @read and @check, and may use the lookups below.
"""
import json
import os
import re
from collections import Counter, namedtuple

import luasource
import packs
import scripts


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
READERS = []


def check(function):
    """A check, function(mod, game, report). Checks run in the order they register, the mod's
    plugins' after these."""
    CHECKS.append(function)
    return function


def read(function):
    """A reader, function(mod, report), which a plugin uses to read more of the mod once Mod has
    read its files and before any check runs, as a tile plugin fills Mod.tilesets."""
    READERS.append(function)
    return function


# ---------------------------------------------------------------------------------------------
# The mod

Item = namedtuple("Item", "block module imports path")
Recipe = namedtuple("Recipe", "block module path")


class Mod:
    """Every file of the mod the checks read, parsed once. Unreadable files are reported here."""

    def __init__(self, roots, name, report, all_languages=False):
        self.roots = roots
        # Translation keys carry it, so translation-key can tell a string shaped like one.
        self.name = name
        self.report = report
        # Whether every language the game offers must have every translation English has.
        self.all_languages = all_languages

        self.lua = []
        for path in self._files("media/lua", ".lua"):
            lua = luasource.read(path)
            lua.module = _require_path(path)
            self.lua.append(lua)

        self.scripts = []
        self.items, self.recipes, self.models = {}, {}, set()
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

        # Language -> translation file name -> {key: text}, and where each file is.
        self.translations, self.translation_paths = {}, {}
        for path in self._files("media/lua/shared/Translate", ".json"):
            language = os.path.basename(os.path.dirname(path))
            name = os.path.basename(path)[:-len(".json")]
            self.translation_paths[language, name] = path
            self.translations.setdefault(language, {})[name] = self._json(path)

        self.sandbox = None
        for root in roots:
            path = os.path.join(root, "media", "sandbox-options.txt")
            if os.path.exists(path):
                self.sandbox = (path, scripts.parse(_read(path)))

        # The published mod's mod.info, in the first root; the dev mod's and the harness mod's
        # describe other mods.
        self.info_path, self.info = None, {}
        path = os.path.join(roots[0], "mod.info")
        if os.path.exists(path):
            self.info_path = path
            for line in _read(path).splitlines():
                key, equals, value = line.partition("=")
                if equals:
                    self.info.setdefault(key.strip(), []).append(value.strip())

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

        # (file, Tileset) for each tileset the mod defines, which item-sprite looks sprites up in.
        # Reading the mod's .tiles files is a plugin's: a reader fills this.
        self.tilesets = []

    def _files(self, under, suffix):
        for root in self.roots:
            top = os.path.join(root, *under.split("/"))
            for base, _dirs, names in os.walk(top):
                for name in sorted(names):
                    if name.endswith(suffix):
                        yield os.path.join(base, name)

    def _json(self, path):
        """A translation file's {key: text}, reporting what the game's JSON reader would trip on
        or quietly lose."""
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
            if not isinstance(value, str):
                self.report.fail("translation-json", path, None, "%s is not a string" % key)
        return {key: value for key, value in data.items() if isinstance(value, str)}

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
    return name in mod.recipes or name in game.recipes


def lua_defined(mod, game):
    """Names given a function anywhere in the game's or the mod's Lua."""
    if not hasattr(mod, "_functions"):
        mod._functions = set(game.lua_functions).union(*(lua.functions for lua in mod.lua))
    return mod._functions


def lua_globals(mod, game):
    """Every global some Lua or the engine defines."""
    if not hasattr(mod, "_globals"):
        known = set(game.globals) | set(game.classes) | game.lua_globals
        for lua in mod.lua:
            known |= lua.globals
        # _G.name = ... defines a global too.
        known |= game.lua_members.get("_G", set())
        for lua in mod.lua:
            known |= {key for table, key in lua.members if table == "_G"}
        mod._globals = known
    return mod._globals


def lua_members(mod, game, table):
    members = set(game.lua_members.get(table, ()))
    for lua in mod.lua:
        members |= {key for t, key in lua.members if t == table}
    return members


# ---------------------------------------------------------------------------------------------
# Translations

# Strewberrie, the game's placeholder language, replaces every word with its own name; nobody
# translates into it.
PLACEHOLDER_LANGUAGES = {"STREW"}


@check
def translation_file(mod, game, report):
    # Translator.loadFiles fills each table from one file name; a file by any other name is
    # never opened. Languages.init offers only folders with a language.json, the game's or a mod's
    # own, so a folder named for no such language is never read either.
    for (language, name), path in sorted(mod.translation_paths.items()):
        report.saw("translation files")
        if name not in game.translation_files:
            report.fail("translation-file", path, None, "the game loads no translation file called %s.json "
                        "(it reads %s)" % (name, ", ".join(sorted(game.translation_files))))
    for language in sorted(mod.translations):
        if language not in game.languages and \
                not mod.media_file("media/lua/shared/Translate/%s/language.json" % language):
            path = os.path.dirname(next(p for (lang, _), p in mod.translation_paths.items() if lang == language))
            report.fail("translation-file", path, None, "the game offers no language %s, so it never reads "
                        "this folder (its languages are %s)" % (language, ", ".join(sorted(game.languages))))


@check
def translation_key(mod, game, report):
    # A literal getText key, and any string literal shaped like one of the mod's own keys, so
    # keys kept in tables and looked up later are checked too. Strings joined with .. are built
    # at runtime and skipped.
    shapes = set()
    getText_files = {file_name for _, file_name in TEXT_TABLES}
    for name in mod.translations.get("EN", {}):
        if name not in getText_files:
            continue
        for key in mod.english(name):
            at = key.find(mod.name)
            if at > 0:
                shapes.add(key[:at + len(mod.name)])
    for lua in mod.lua:
        checked = set()
        for function in ("getText", "getTextOrNull"):
            for key, at in lua.calls_with_literal(function):
                report.saw("getText keys")
                checked.add(at)
                problem = text_problem(mod, game, key)
                if problem:
                    report.fail("translation-key", lua.path, lua.line(at), problem)
        for text, at, joined in lua.strings:
            if at in checked or joined or not re.fullmatch(r"\w+", text) or text.endswith("_"):
                continue
            if any(text.startswith(shape) for shape in shapes):
                report.saw("key-shaped strings")
                problem = text_problem(mod, game, text)
                if problem:
                    report.fail("translation-key", lua.path, lua.line(at), problem)


@check
def translation_languages(mod, game, report):
    # Translator loads English and the chosen language over it, so a key the language lacks shows
    # in English, and a key English lacks is read by nothing.
    english = mod.translations.get("EN", {})
    languages = set(mod.translations)
    if mod.all_languages:
        languages |= game.languages - PLACEHOLDER_LANGUAGES
    for language in sorted(languages - {"EN"}):
        files = mod.translations.get(language, {})
        missing = 0
        for name, table in sorted(files.items()):
            extra = sorted(set(table) - set(english.get(name, {})))
            if extra:
                report.fail("translation-extra", mod.translation_paths[language, name], None,
                            "%d key(s) English does not have, which nothing reads: %s"
                            % (len(extra), ", ".join(extra[:5])))
        for name, source in sorted(english.items()):
            lacking = sorted(set(source) - set(files.get(name, {})))
            missing += len(lacking)
            if not mod.all_languages or not lacking:
                continue
            if name in files:
                report.fail("translation-missing", mod.translation_paths[language, name], None,
                            "lacks %d key(s) English has, which show in English: %s"
                            % (len(lacking), ", ".join(lacking[:5])))
            else:
                english_path = mod.translation_paths["EN", name]
                path = os.path.join(os.path.dirname(os.path.dirname(english_path)), language,
                                    os.path.basename(english_path))
                report.fail("translation-missing", path, None, "missing, so all of %s.json shows in English"
                            % name)
        if missing and not mod.all_languages:
            report.note("%s lacks %d key(s) English has, which show in English" % (language, missing))


@check
def translation_placeholder(mod, game, report):
    # Translator.formatFixer turns %1..%9 into String.format arguments and keeps %%. Any other %
    # is malformed (the game's own dev build refuses to start over one). A placeholder a
    # translation adds is filled by nothing, and one it drops hides the value English shows.
    for language, files in sorted(mod.translations.items()):
        for name, table in files.items():
            path = mod.translation_paths[language, name]
            for key, text in table.items():
                used = set(re.findall(r"%.?", text, re.S))
                bad = sorted(p for p in used if not re.fullmatch(r"%[1-9%]", p))
                if bad:
                    report.fail("translation-placeholder", path, None, "%s has %s, where only %%1 to %%9 and %%%% "
                                "are understood" % (key, " ".join(repr(p) for p in bad)))
                source = mod.english(name).get(key)
                if language == "EN" or source is None:
                    continue
                english = {p for p in re.findall(r"%.?", source, re.S) if re.fullmatch(r"%[1-9]", p)}
                ours = {p for p in used if re.fullmatch(r"%[1-9]", p)}
                if ours - english:
                    report.fail("translation-placeholder", path, None, "%s uses %s, which English does not "
                                "pass" % (key, " ".join(sorted(ours - english))))
                if english - ours:
                    report.fail("translation-placeholder", path, None, "%s drops %s, so the value English "
                                "shows there is missing" % (key, " ".join(sorted(english - ours))))


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
            for value in part.values:
                if value.key is not None or not re.match(r"-?item\b", value.value):
                    continue
                for prefix, listed in re.findall(r"(\w*)\[([^\]]*)\]", value.value):
                    entries = [e.strip() for e in listed.split(";") if e.strip()]
                    if prefix == "tags":
                        for tag in entries:
                            report.saw("recipe tags")
                            if tag.lower() not in game.tags and not _mod_tag(mod, tag):
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


def _mod_tag(mod, tag):
    tag = tag.lower()
    return any(tag in (t.strip().lower() for v in item.block.all("Tags") for t in v.value.split(";"))
               for item in mod.items.values())


def _lua_path_defined(mod, game, target):
    """Whether a.b.c names something: its root a global, and c a function name some Lua defines
    (or, for a root that is a Java class, one of its static methods)."""
    names = target.split(".")
    if names[0] in game.statics and len(names) == 2 and names[1] in game.statics[names[0]]:
        return True
    return names[0] in lua_globals(mod, game) and (len(names) == 1 or names[-1] in lua_defined(mod, game))


# ---------------------------------------------------------------------------------------------
# Sandbox options

SANDBOX_TYPES = ("boolean", "double", "enum", "integer", "string")


@check
def sandbox_options(mod, game, report):
    if mod.sandbox is None:
        return
    path, root = mod.sandbox
    version = root.get("VERSION")
    if version is None or version.value != "1":
        # CustomSandboxOptions.parse throws without VERSION = 1, losing every option.
        report.fail("sandbox-option", path, None, "the file needs VERSION = 1, or the game reads none of it")
    for block in root.children:
        report.saw("sandbox options")
        if block.type.lower() != "option":
            report.fail("sandbox-option", path, block.line, "%s block: the file holds only option blocks"
                        % block.type)
            continue
        option_type = block.get("type")
        if option_type is None or option_type.value not in SANDBOX_TYPES:
            report.fail("sandbox-type", path, block.line, "option %s has type %s, not one of %s, so the game "
                        "drops it" % (block.id, option_type.value if option_type else "(none)", ", ".join(SANDBOX_TYPES)))
            continue
        number = int if option_type.value in ("integer", "enum") else float

        def value(key):
            v = block.get(key)
            try:
                return number(v.value) if v else None
            except ValueError:
                return None

        if option_type.value in ("integer", "double"):
            low, high, default = value("min"), value("max"), value("default")
            if None in (low, high, default):
                report.fail("sandbox-option", path, block.line, "option %s needs numeric min, max and default, "
                            "or the game drops it" % block.id)
            elif not low <= default <= high:
                report.fail("sandbox-option", path, block.line, "option %s defaults to %s, outside %s..%s"
                            % (block.id, default, low, high))
        elif option_type.value == "enum":
            count, default = value("numValues"), value("default")
            if count is None or default is None or count < 1 or default < 1:
                report.fail("sandbox-option", path, block.line, "option %s needs numValues and default of 1 or "
                            "more, or the game drops it" % block.id)
            elif default > count:
                report.fail("sandbox-option", path, block.line, "option %s defaults to value %d of %d"
                            % (block.id, default, count))

        # SandboxOptions labels an option Sandbox_<translation, else its name after the dot>, a page
        # Sandbox_<page>, and enum value n Sandbox_<valueTranslation, else that name>_option<n>.
        short = block.id.split(".", 1)[-1]
        label = (block.get("translation").value if block.get("translation") else short)
        keys = ["Sandbox_" + label]
        if block.get("page"):
            keys.append("Sandbox_" + block.get("page").value)
        if option_type.value == "enum" and value("numValues"):
            values = block.get("valueTranslation").value if block.get("valueTranslation") else label
            keys += ["Sandbox_%s_option%d" % (values, n) for n in range(1, value("numValues") + 1)]
        for key in keys:
            if not has_entry(mod, game, "Sandbox", key):
                report.fail("sandbox-label", path, block.line, "option %s has no %s in Sandbox.json" % (block.id, key))


@check
def sandbox_vars(mod, game, report):
    declared = set()
    groups = set()
    if mod.sandbox:
        for block in mod.sandbox[1].children:
            if block.id:
                declared.add(block.id)
                if "." in block.id:
                    groups.add(block.id.split(".")[0])
    for lua in mod.lua:
        aliases = _sandbox_aliases(lua, groups)
        for chain in lua.chains:
            names = chain.names
            if names[0] == "SandboxVars" and len(names) > 1:
                report.saw("SandboxVars reads")
                if names[1] in groups:
                    if len(names) > 2 and "%s.%s" % (names[1], names[2]) not in declared:
                        report.fail("sandbox-var", lua.path, lua.line(chain.at), "SandboxVars.%s.%s is no option of "
                                    "sandbox-options.txt" % (names[1], names[2]))
                elif names[1] not in game.sandbox_names:
                    report.fail("sandbox-var", lua.path, lua.line(chain.at), "SandboxVars.%s is neither a game "
                                "option nor a group of this mod's" % names[1])
            elif names[0] in aliases and len(names) > 1:
                group = aliases[names[0]]
                if "%s.%s" % (group, names[1]) not in declared:
                    report.fail("sandbox-var", lua.path, lua.line(chain.at), "%s.%s (SandboxVars.%s.%s) is no option "
                                "of sandbox-options.txt" % (names[0], names[1], group, names[1]))


def _sandbox_aliases(lua, groups):
    """local x = SandboxVars.Group, so x.Option is read like SandboxVars.Group.Option."""
    aliases = {}
    tokens = lua.tokens
    for i in range(len(tokens) - 6):
        if tokens[i].text == "local" and tokens[i + 1].kind == luasource.NAME and tokens[i + 2].text == "=" \
                and tokens[i + 3].text == "SandboxVars" and tokens[i + 4].text == "." \
                and tokens[i + 5].text in groups and tokens[i + 6].text not in (".", "[", ":"):
            aliases[tokens[i + 1].text] = tokens[i + 5].text
    return aliases


# ---------------------------------------------------------------------------------------------
# Lua names

# Names the Lua runtime gives every function without declaring them anywhere.
IMPLICIT_LOCALS = {"self", "arg"}


@check
def method_name(mod, game, report):
    # Lua calling a method that does not exist fails only when the line runs. Names only: a call
    # site does not say what it calls on, so this asks whether any exposed class, any Lua or the
    # string library has the name. That still catches a method the engine retired, as
    # PropertyContainer.Is and .Val were in build 42.
    known = game.methods | lua_defined(mod, game) | game.std_members.get("string", set())
    for lua in mod.lua:
        reported = set()
        for name, at in lua.methods:
            report.saw("method calls")
            if name not in known and name not in reported:
                reported.add(name)
                report.fail("method-name", lua.path, lua.line(at), ":%s() is no method of a class Lua can reach, "
                            "nor a function any Lua defines" % name)


@check
def global_name(mod, game, report):
    # Every free name the mod reads must be a local of its file, or a global that the engine, the
    # game's Lua or the mod's Lua defines. InventoryItemFactory is a Java class build 42 does not
    # expose, so InventoryItemFactory.CreateItem indexed nil: method-name could not see it,
    # CreateItem being a real method of a class Lua cannot reach.
    known = lua_globals(mod, game)
    for lua in mod.lua:
        reported = set()
        for chain in lua.chains:
            name = chain.names[0]
            report.saw("global reads")
            if chain.assigned and len(chain.names) == 1:
                continue
            if name in lua.locals or name in IMPLICIT_LOCALS or name in known or name in reported:
                continue
            reported.add(name)
            report.fail("global-name", lua.path, lua.line(chain.at), "%s is no local here and no global the "
                        "engine or any Lua defines" % name)


@check
def global_member(mod, game, report):
    # A.b where A is an exposed Java class or a standard library table, and no Lua makes A a
    # table of its own: b must be one of its static members or library functions.
    lua_tables = set(game.lua_globals).union(*(lua.globals for lua in mod.lua))
    for lua in mod.lua:
        reported = set()
        for chain in lua.chains:
            if len(chain.names) < 2 or chain.names[0] in lua.locals or chain.names[0] in lua_tables:
                continue
            table, member = chain.names[0], chain.names[1]
            if table in game.classes:
                allowed = game.statics.get(table, set())
                what = "static member of %s" % game.classes[table]
            elif table in game.std_members:
                allowed = game.std_members[table]
                what = "function of the %s library" % table
            else:
                continue
            report.saw("library and class members")
            if member in allowed or member in lua_members(mod, game, table) or (table, member) in reported:
                continue
            reported.add((table, member))
            report.fail("global-member", lua.path, lua.line(chain.at), "%s.%s is no %s" % (table, member, what))


@check
def event_name(mod, game, report):
    # Events.X.Add on an event the engine never registers indexes nil and throws at load.
    events = game.events | game.lua_events
    for lua in mod.lua:
        for chain in lua.chains:
            if chain.names[0] == "Events" and len(chain.names) > 1 and "Events" not in lua.locals:
                report.saw("event hooks")
                if chain.names[1] not in events:
                    report.fail("event-name", lua.path, lua.line(chain.at), "Events.%s is no event the game "
                                "registers" % chain.names[1])


@check
def texture_path(mod, game, report):
    for lua in mod.lua:
        for function, finds in (("getTexture", shared_texture), ("tryGetTexture", any_texture)):
            for name, at in lua.calls_with_literal(function):
                report.saw("texture paths")
                if not finds(mod, game, name):
                    report.fail("texture-path", lua.path, lua.line(at), "%s(\"%s\") finds no packed sprite or file"
                                % (function, name))


@check
def require_path(mod, game, report):
    # require finds a module by its path under lua/client, server or shared. The match is exact on
    # Linux servers, so a case slip works on macOS and Windows only.
    modules = game.lua_modules | {lua.module for lua in mod.lua if lua.module}
    lowered = {m.lower(): m for m in modules}
    for lua in mod.lua:
        for name, at in lua.calls_with_literal("require"):
            report.saw("requires")
            name = name[:-len(".lua")] if name.endswith(".lua") else name
            if name in modules:
                continue
            if name.lower() in lowered:
                report.fail("require-path", lua.path, lua.line(at), "require \"%s\" differs in case from %s, "
                            "which a Linux server does not find" % (name, lowered[name.lower()]))
            else:
                report.fail("require-path", lua.path, lua.line(at), "require \"%s\" names no Lua file of the "
                            "mod or the game" % name)


@check
def timed_action_complete(mod, game, report):
    # The engine never calls a timed action's complete() on a multiplayer client: the server runs
    # its own copy, and complete() runs there. An action that exists only under client/ has no
    # server copy, so its complete() runs nowhere. perform() runs on whoever performs it.
    for lua in mod.lua:
        if "/media/lua/client/" not in lua.path.replace(os.sep, "/"):
            continue
        tokens = lua.tokens
        actions = {tokens[i].text for i in range(len(tokens) - 4)
                   if tokens[i + 1].text == "=" and tokens[i + 2].text == "ISBaseTimedAction"
                   and tokens[i + 3].text == ":" and tokens[i + 4].text == "derive"}
        report.saw("client timed actions", len(actions))
        for i in range(len(tokens) - 3):
            if tokens[i].text == "function" and tokens[i + 1].text in actions and tokens[i + 2].text == ":" \
                    and tokens[i + 3].text == "complete":
                report.fail("timedaction-complete", lua.path, lua.line(tokens[i].at), "%s:complete() never runs: "
                            "the action is client-only, and the engine skips complete() on a multiplayer "
                            "client; do the work in perform()" % tokens[i + 1].text)


# ---------------------------------------------------------------------------------------------
# Texture packs

@check
def pack_clash(mod, game, report):
    # Sprite names are global, and a mod's packs load after the game's, so a mod sprite named
    # like a vanilla one replaces it everywhere.
    report.saw("packed sprites", len(mod.sprites))
    for name, path in sorted(mod.sprites.items()):
        if name in game.sprites:
            report.fail("pack-clash", path, None, "sprite %s replaces the game's sprite of that name" % name)
