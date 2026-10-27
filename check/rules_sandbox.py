"""The static check's sandbox option checks (docs/static-check.md)."""
import luasource
from moddata import check, has_entry


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
    declared = {block.id for block in mod.sandbox[1].children if block.id} if mod.sandbox else set()
    groups = {name.split(".")[0] for name in declared if "." in name}
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
