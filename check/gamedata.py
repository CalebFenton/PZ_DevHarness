"""What the installed game defines, for the checks to compare the mod against.

Two sources. GameProbe's API file holds what only the running JVM can answer: the classes,
methods and globals Lua reaches, and a few string tables (see GameProbe.writeApi). Everything
else is read from the game's own files: the Lua it ships (what it assigns, defines and requires),
its scripts (items, tags, recipes, models), its languages and English translations, its texture
packs and its tile definitions.

Reading the game's files takes a few seconds, so the result is cached as JSON next to the API
file, keyed by the game jar and by this checker's own source, and rebuilt when either changes.
"""
import hashlib
import json
import os

import luasource
import packs
import scripts
import tiledefs

# Tables the engine puts into the Lua environment itself rather than through an exposed class:
# LuaEventManager.register (Events), LuaHookManager.register (Hook), CoopMaster.register
# (CoopServer), VoiceManager.LuaRegister (VoiceManager) and LuaManager.exposeLuaCalendar
# (Calendar).
ENGINE_TABLES = {"Events", "Hook", "CoopServer", "VoiceManager", "Calendar"}

LUA_FOLDERS = ("client", "server", "shared")


class Game:
    def __init__(self, java_dir, api_file, cache_dir):
        self.java_dir = java_dir
        self.media = os.path.join(java_dir, "media")
        self._read_api(api_file)
        self._load_files(cache_dir)

    # -- GameProbe's facts --------------------------------------------------------------------

    def _read_api(self, path):
        self.methods = set()
        self.classes = {}           # simple name -> Java class name
        self.statics = {}           # simple name -> static members
        self.globals = set(ENGINE_TABLES)
        self.std_members = {}       # standard library table -> its keys
        self.events = set()
        self.translation_files = set()
        self.sandbox_names = set()
        self.item_fields = set()
        with open(path, encoding="utf-8") as f:
            for line in f:
                kind, _, rest = line.rstrip("\n").partition(" ")
                if kind == "method":
                    self.methods.add(rest)
                elif kind == "class":
                    simple, java_name = rest.split(" ", 1)
                    self.classes.setdefault(simple, java_name)
                elif kind == "static":
                    simple, member = rest.split(" ", 1)
                    self.statics.setdefault(simple, set()).add(member)
                elif kind == "global":
                    self.globals.add(rest)
                elif kind == "member":
                    table, key = rest.split(" ", 1)
                    self.std_members.setdefault(table, set()).add(key)
                elif kind == "event":
                    self.events.add(rest)
                elif kind == "translation-file":
                    self.translation_files.add(rest)
                elif kind == "sandbox":
                    self.sandbox_names.add(rest)
                    self.sandbox_names.add(rest.split(".")[0])
                elif kind == "item-field":
                    # Lowercased: Item.DoParam compares keys ignoring case.
                    self.item_fields.add(rest.lower())
        # Translator.readModTranslation reads Mod.json, the mod list's name and description, by
        # itself; it is no table of getText's.
        self.translation_files.add("Mod")

    # -- The game's own files, cached ---------------------------------------------------------

    def _load_files(self, cache_dir):
        jar = os.path.join(self.java_dir, "projectzomboid.jar")
        key = hashlib.sha1()
        stat = os.stat(jar)
        key.update(("%s %d %d" % (jar, stat.st_size, stat.st_mtime)).encode())
        for module in (__file__, luasource.__file__, scripts.__file__, packs.__file__, tiledefs.__file__):
            with open(module, "rb") as f:
                key.update(f.read())
        cache = os.path.join(cache_dir, "game-files.json")
        data = None
        if os.path.exists(cache):
            with open(cache, encoding="utf-8") as f:
                data = json.load(f)
            if data.get("key") != key.hexdigest():
                data = None
        if data is None:
            data = self._scan()
            data["key"] = key.hexdigest()
            with open(cache + ".tmp", "w", encoding="utf-8") as f:
                json.dump(data, f)
            os.replace(cache + ".tmp", cache)

        self.lua_globals = set(data["lua_globals"])
        self.lua_members = {table: set(keys) for table, keys in data["lua_members"].items()}
        self.lua_functions = set(data["lua_functions"])
        self.lua_events = set(data["lua_events"])
        self.lua_modules = set(data["lua_modules"])
        self.items = set(data["items"])
        self.tags = set(data["tags"])
        self.recipes = set(data["recipes"])
        self.item_types = set(data["item_types"])
        self.models = set(data["models"])
        self.translations = {name: set(keys) for name, keys in data["translations"].items()}
        self.languages = set(data["languages"])
        self.sprites = set(data["sprites"])
        self.tilesets = data["tilesets"]

    def _scan(self):
        data = {}
        lua_globals, lua_functions, lua_events, lua_modules = set(), set(), set(), set()
        lua_members = {}
        for folder in LUA_FOLDERS:
            top = os.path.join(self.media, "lua", folder)
            for path in _files(top, ".lua"):
                lua_modules.add(os.path.relpath(path, top)[:-4].replace(os.sep, "/"))
                lua = luasource.read(path)
                lua_globals |= lua.globals
                lua_functions |= lua.functions
                for table, key in lua.members:
                    lua_members.setdefault(table, set()).add(key)
                for chain in lua.chains:
                    # LuaEventManager.AddEvent("Name") registers an event from Lua.
                    if chain.names == ["LuaEventManager", "AddEvent"] and chain.called:
                        i = lua.index[chain.at] + 4
                        if i < len(lua.tokens) and lua.tokens[i].kind == luasource.STRING:
                            lua_events.add(lua.tokens[i].text)
        data.update(lua_globals=sorted(lua_globals), lua_functions=sorted(lua_functions),
                    lua_events=sorted(lua_events), lua_modules=sorted(lua_modules),
                    lua_members={table: sorted(keys) for table, keys in lua_members.items()})

        items, tags, recipes, item_types, models = set(), set(), set(), set(), set()
        for path in _files(os.path.join(self.media, "scripts"), ".txt"):
            with open(path, encoding="utf-8", errors="replace") as f:
                root = scripts.parse(f.read())
            for module, block in scripts.modules(root):
                for child in block.children:
                    if child.type == "item":
                        items.add("%s.%s" % (module, child.id))
                        for value in child.all("Tags"):
                            tags.update(t.strip().lower() for t in value.value.split(";") if t.strip())
                        for value in child.all("ItemType"):
                            item_types.add(value.value)
                    elif child.type == "craftRecipe":
                        recipes.add(child.id)
                    elif child.type == "model":
                        models.add("%s.%s" % (module, child.id))
        data.update(items=sorted(items), tags=sorted(tags), recipes=sorted(recipes),
                    item_types=sorted(item_types), models=sorted(models))

        translations = {}
        translate = os.path.join(self.media, "lua", "shared", "Translate")
        english = os.path.join(translate, "EN")
        for name in os.listdir(english):
            if name.endswith(".json"):
                with open(os.path.join(english, name), encoding="utf-8", errors="replace") as f:
                    try:
                        translations[name[:-5]] = sorted(json.load(f))
                    except ValueError:
                        pass
        data["translations"] = translations
        # Languages.init offers each folder of Translate that has a language.json.
        data["languages"] = sorted(name for name in os.listdir(translate)
                                   if os.path.exists(os.path.join(translate, name, "language.json")))

        sprites = set()
        for path in _files(os.path.join(self.media, "texturepacks"), ".pack"):
            for page in packs.read_index(path):
                sprites.update(sprite.name for sprite in page.sprites)
        data["sprites"] = sorted(sprites)

        # Tileset name -> tile count, for sprite names such as location_shop_generic_01_12.
        tilesets = {}
        for name in os.listdir(self.media):
            if name.endswith(".tiles"):
                # IsoWorld.init loads newtiledefinitions.tiles as file number 1.
                number = 1 if name == "newtiledefinitions.tiles" else None
                for tileset in tiledefs.load(os.path.join(self.media, name), number):
                    tilesets[tileset.name] = max(len(tileset.tiles), tilesets.get(tileset.name, 0))
        data["tilesets"] = tilesets
        return data

    # -- Lookups ------------------------------------------------------------------------------

    def file(self, relative):
        """The game file at a path relative to its Java folder (media/...), if it exists."""
        path = os.path.join(self.java_dir, *relative.split("/"))
        return path if os.path.exists(path) else None


def _files(top, suffix):
    for base, _dirs, names in os.walk(top):
        for name in sorted(names):
            if name.endswith(suffix):
                yield os.path.join(base, name)
