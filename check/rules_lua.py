"""The static check's checks on the Lua names a mod uses (docs/static-check.md)."""
import os

from moddata import _read, any_texture, check, lua_defined, lua_globals, lua_members, required_ids, shared_texture


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
        for name, at in lua.requires:
            report.saw("requires")
            if name in modules:
                continue
            if name.lower() in lowered:
                report.fail("require-path", lua.path, lua.line(at), "require \"%s\" differs in case from %s, "
                            "which a Linux server does not find" % (name, lowered[name.lower()]))
            else:
                report.fail("require-path", lua.path, lua.line(at), "require \"%s\" names no Lua file of the "
                            "mod, its libraries or the game" % name)


@check
def unpublished_lua(mod, game, report):
    # The Workshop gets the published mod and its libraries alone, so a require or a global it
    # finds only in the dev mod's or the harness mod's Lua passes every harness run and fails for
    # players.
    published = [lua for lua in mod.lua if lua.published]
    modules = game.lua_modules | {lua.module for lua in published if lua.module}
    dev_modules = {lua.module for lua in mod.lua if lua.module and not lua.published} - modules
    dev_globals = lua_globals(mod, game) - lua_globals(mod, game, published=True)
    for lua in published:
        for name, at in lua.requires:
            if name in dev_modules:
                report.fail("unpublished-lua", lua.path, lua.line(at), "require \"%s\" is a dev-mod or harness "
                            "module, which the published mod lacks; move the code that needs it into the dev mod"
                            % name)
        reported = set()
        for chain in lua.chains:
            name = chain.names[0]
            if name in dev_globals and name not in lua.locals and name not in reported:
                reported.add(name)
                report.fail("unpublished-lua", lua.path, lua.line(chain.at), "%s is a global only the dev mod's "
                            "or the harness mod's Lua defines, which the published mod lacks" % name)


@check
def library_require(mod, game, report):
    # A player's game loads the mods a mod.info requires, before the mod, and of the mods a harness
    # run loads has only those. So the published mod.info must require exactly the conf's
    # LIBRARY_MODS: a library it leaves out is there in every harness run and check but not for
    # players, and a mod it adds is in none of them. A library also loads for mods other than this
    # one, so a module its Lua requires must be its own, or a mod's its own mod.info requires.
    path = mod.info_path or os.path.join(mod.roots[0], "mod.info")
    line = None
    if mod.info_path:
        lines = [n for n, text in enumerate(_read(path).splitlines(), 1) if text.strip().startswith("require=")]
        line = lines[-1] if lines else None
    listed = required_ids(mod.info)
    loaded = [library.id for library in mod.libraries]
    for library in loaded:
        if library not in listed:
            report.fail("library-require", path, line, "require= lacks %s, which dev/harness.conf's LIBRARY_MODS "
                        "loads in every harness run and check, so a player's game would run the mod without it"
                        % library)
    for other in listed:
        if other not in loaded:
            report.fail("library-require", path, line, "require= names %s, which dev/harness.conf's LIBRARY_MODS "
                        "lacks, so no harness run or check loads it" % other)
    owners = {}
    for lua in mod.lua:
        if lua.owner and lua.module:
            owners.setdefault(lua.module, set()).add(lua.owner)
    requires = {library.id: set(required_ids(library.info)) for library in mod.libraries}
    for lua in mod.lua:
        # The mod's own require= is held to LIBRARY_MODS above.
        if lua.owner not in requires:
            continue
        for name, at in lua.requires:
            found = owners.get(name, set())
            if not found or lua.owner in found or found & requires[lua.owner] or name in game.lua_modules:
                continue
            owner = " and ".join(sorted(found))
            report.fail("library-require", lua.path, lua.line(at), "require \"%s\" is a module of %s, which %s's "
                        "mod.info doesn't require, so the library fails in a game without %s"
                        % (name, owner, lua.owner, owner))


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
