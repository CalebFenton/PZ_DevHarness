# The static check

Checks a mod against the installed game without launching it, in seconds: every Lua file
compiled with the game's own compiler, then translations, scripts, textures, sandbox options and
Lua names cross-checked against what the game defines. Each check looks for a mistake the game
would not report: a missing translation shows its key, a wrong texture draws nothing, a script
value without its comma is dropped, and a Lua name that does not exist fails only when its line
runs.

```sh
dev/static-check.sh
```

A mod's `dev/static-check.sh` is a thin script like its other entry points:

```sh
#!/usr/bin/env bash
# dev/static-check.sh
. "$(dirname "$0")/harness/bin/static-check.sh"
```

It needs a JDK's `javac` (any version from 8 on, or `JAVAC`) and `python3`. `CACHE` moves the cache
(default `$TMPDIR/<CACHE_NAME>-check`). The first run after a game update or a change to the
checker reads the game's files and takes a few seconds more; after that a run takes under a
second.

## The conf

| Key | Meaning |
| --- | --- |
| `PRECHECK` | `PRECHECK=(dev/static-check.sh)` runs it before every game of the harness, so a typo costs seconds rather than a game start ([running.md](running.md#checks-before-a-run)). |
| `CHECK_PLUGINS` | Optional: a bash array of Python files, relative to the repository, with the mod's own checks ([Plugins](#plugins)). |
| `CHECK_ALL_LANGUAGES` | Optional: when set, every language the game offers (but `STREW`, its placeholder) must have every translation file and key English has (`translation-missing`); otherwise a language the mod has that lacks keys is only a note. |
| `WORKSHOP_REPO` | Optional: when set, the check also fails while `workshop.txt` isn't what `dev/workshop-txt.sh` makes of the README, or the description is over Steam's limit ([workshop-page.md](workshop-page.md)). |

It checks `MOD_DIR`'s `42` and `common`, the dev mod's `42` and the harness mod. Translations are
read from their `media/lua/shared/Translate`.

## How it works

- `check/GameProbe.java` runs on the game's own JVM with `projectzomboid.jar` on the class path. It
  compiles every Lua file with the game's Kahlua compiler (`lua-syntax`), and, once per game
  update, writes what Lua can reach: the classes `LuaManager$Exposer` hands to `setExposed`, with
  their methods, static members and constructors; the `@LuaMethod(global = true)` functions; the
  Kahlua standard library; and the string tables of `LuaEventManager`, `Translator`,
  `SandboxOptions` and `Item`.
- `check/gamedata.py` reads the rest from the game's files: what its Lua assigns, defines and
  requires, its items, tags, recipes and models, its languages and English translations, packs and
  tile definitions. The result is cached next to the API file, keyed by the jar and the checker's
  source.
- `check/luasource.py` tokenises Lua (comments and strings never look like code), `check/scripts.py`
  parses scripts the way `ScriptParser` does, `check/packs.py` and `check/tiledefs.py` read and
  write `.pack` and `.tiles` files, and `check/rules.py` holds the checks, one function each.
  `check/check.py` runs them.

Without a type checker, Lua names are checked by name: a call site does not say what it calls on,
and a name declared local anywhere in a file counts as local in all of it. Both can hide a
mistake, never report a correct name. Run over the game's own 1,400 Lua files, `global-name` and
`global-member` flag about 140 reads, nearly all real slips in vanilla (`UIFont.Normal`,
`ItemType.Drainable`, unset globals).

## The checks

| Check | What it catches |
| --- | --- |
| `lua-syntax` | A file the game's compiler refuses. |
| `translation-file` | A `Translate/<LANG>/<Name>.json` whose name `Translator` never loads, or a `<LANG>` folder that is no language of the game's and has no `language.json` of its own. |
| `translation-json` | Invalid JSON, a non-string value, or a key given twice (only the last counts). |
| `translation-key` | A literal `getText`/`getTextOrNull` key, or a string literal shaped like one of the mod's keys (one with the mod's folder name in it), that no translation answers. `getTextInternal` picks the file by the key's prefix, so an `IGUI_` key in `Tooltip.json` is reported as being in the wrong file. |
| `translation-extra` | A language with keys English lacks. |
| `translation-missing` | With `CHECK_ALL_LANGUAGES`, a language of the game's without a translation file or key English has. Without it, missing keys are a note. |
| `translation-placeholder` | A `%` other than `%1`..`%9` or `%%`, or a translation that uses a placeholder English does not pass or drops one English shows. |
| `script-syntax` | Text after a block's last comma (dropped), a value whose comma is missing (it swallows the next line, or the next block's header), `//` (no comment in scripts), a block outside a module. |
| `item-field` | A key `Item.DoParam` does not know; it silently becomes item mod data. |
| `item-legacy-field` | `Type`, `DisplayName`, `TeachedRecipes`, build 41 fields. |
| `item-type` | A missing `ItemType`, or one no game item uses. |
| `item-tag` | A tag without a namespace, which no `tags[]` query matches. |
| `item-no-icon` | An item without `Icon`, moveables included: the crafting window throws listing it. |
| `item-icon` | `Icon = X` with no `Item_X` in a pack or `media/textures`. |
| `item-name` | An item without an `ItemName.json` entry. |
| `item-tooltip` | A `Tooltip` key no translation answers. |
| `item-model` | A `WorldStaticModel`/`StaticModel` naming no model script. |
| `item-sprite` | A `WorldObjectSprite` past the tileset's tiles, without a packed sprite, or in no tileset (the mod's tilesets come from a plugin that fills `Mod.tilesets`). |
| `learned-recipe` | `LearnedRecipes` or `ResearchableRecipes` naming no craftRecipe. |
| `model-texture` | A model texture that is packed (a model samples its whole texture, so it would draw a slice of the page) or missing. |
| `recipe-module` | A craftRecipe with `NeedToBeLearn = true` outside module Base: research and magazines look recipes up by bare name, which resolves only in Base. |
| `recipe-name` | A craftRecipe without a `Recipes.json` entry. |
| `recipe-item` | A recipe input or output that is no item. |
| `recipe-tag` | A `tags[...]` query no item carries. |
| `recipe-hook` | `OnCreate`/`OnTest` naming nothing defined; `OnAddToMenu` dotted (the window does one `rawget` on the globals) or undefined. |
| `sandbox-type` | An option type the parser rejects. |
| `sandbox-option` | No `VERSION = 1`, missing or non-numeric min/max/default/numValues (the option is dropped), a default out of range. |
| `sandbox-label` | A missing `Sandbox_` label for an option (its `translation`, else its short name), its page, or an enum value. |
| `sandbox-var` | `SandboxVars.<Mod>.x` (or `x` on a local alias) that is no declared option, or `SandboxVars.X` that is no vanilla option. |
| `method-name` | `obj:name()` that no exposed class, no Lua and no string function has. Build 42 dropped `PropertyContainer.Is`/`.Val`, and nothing failed until the line ran. |
| `global-name` | A free name that is no local of its file and no global of the engine, the game's Lua or the mod's. `InventoryItemFactory` is a Java class build 42 does not expose. |
| `global-member` | `Class.x` on an exposed class that is none of its static members or nested classes, or `string.x`/`table.x`/`math.x` that the library lacks. |
| `event-name` | `Events.X` that no engine or Lua code registers. |
| `texture-path` | A literal `getTexture`/`tryGetTexture` path that resolves to no packed sprite or file, following `Texture.getSharedTexture`'s order. |
| `require-path` | A `require` naming no Lua file of the mod or game, or differing in case (Linux servers match exactly). |
| `timedaction-complete` | A client-only timed action with `complete()`, which never runs on a multiplayer client. |
| `pack-format` | A mod `.pack` the game could not read. |
| `pack-clash` | A mod sprite named like a vanilla one, which it replaces everywhere. |
| `no-input` | No Lua files found, so a wrong path cannot pass as a clean mod. |

## Plugins

A mod's own rules, such as ones about its tiles or its map coordinates, live in the mod's
repository as Python files that `CHECK_PLUGINS` names. The checker loads each after its own
checks, in the order given, and runs their checks after its own. A plugin imports `rules`, which
`check/check.py` puts on the path along with `gamedata`, `luasource`, `scripts`, `packs` and
`tiledefs`:

```python
"""My mod's rules (dev/check/widgets.py)."""
from rules import check, has_text


@check
def widget_labels(mod, game, report):
    for lua in mod.lua:
        for key, at in lua.calls_with_literal("addWidget"):
            report.saw("widgets")
            if not has_text(mod, game, "IGUI_Widget_" + key):
                report.fail("widget-label", lua.path, lua.line(at), "widget %s has no label" % key)
```

- `@check` registers `function(mod, game, report)`. `@read` registers `function(mod, report)`,
  run once the mod's files are read and before any check, to read more of the mod: a plugin that
  reads the mod's `.tiles` files fills `mod.tilesets` there, which `item-sprite` looks sprites up
  in.
- `mod` (`rules.Mod`) holds what was read: `lua` (one `luasource` file each, with its tokens,
  names, strings and tables), `scripts`, `items`, `recipes`, `models`, `translations` and
  `translation_paths`, `sandbox`, `info` (the published mod's `mod.info` lines), `sprites`,
  `tilesets`, and `media_file(path)`. `game` (`gamedata.Game`) holds the game's side, and
  `file(path)` finds a game file.
- `report.fail(rule, path, line, message)` fails the run, `report.note(message)` only prints,
  and `report.saw(what)` counts for the summary line.
- `rules` has the lookups the built-in checks use, such as `has_entry`, `has_text`,
  `text_problem`, `item_exists`, `recipe_exists`, `packed`, `lua_globals` and `lua_defined`.

A plugin's rule names and what they catch go in its docstring, as this page lists the built-in
ones.
