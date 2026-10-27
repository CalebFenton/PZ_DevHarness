"""The static check's translation checks (docs/static-check.md)."""
import os
import re

from moddata import TEXT_TABLES, check, text_problem


# Strewberrie, the game's placeholder language, replaces every word with its own name; nobody
# translates into it.
PLACEHOLDER_LANGUAGES = {"STREW"}


@check
def translation_file(mod, game, report):
    # Translator.loadFiles fills each table from one file name; a file by any other name is
    # never opened. Languages.init offers only folders with a language.json, the game's or a mod's
    # own, so a folder named for no such language is never read either.
    for language, name, path, _ in sorted(mod.translation_files):
        report.saw("translation files")
        if name not in game.translation_files:
            report.fail("translation-file", path, None, "the game loads no translation file called %s.json "
                        "(it reads %s)" % (name, ", ".join(sorted(game.translation_files))))
    for language in sorted(mod.translations):
        if language not in game.languages and \
                not mod.media_file("media/lua/shared/Translate/%s/language.json" % language):
            path = os.path.dirname(next(p for lang, _, p, _ in mod.translation_files if lang == language))
            report.fail("translation-file", path, None, "the game offers no language %s, so it never reads "
                        "this folder (its languages are %s)" % (language, ", ".join(sorted(game.languages))))


@check
def translation_key(mod, game, report):
    # A literal getText key, and any string literal shaped like one of the mod's own keys or a
    # library's, so keys kept in tables and looked up later are checked too. Strings joined with ..
    # are built at runtime and skipped.
    shapes = set()
    getText_files = {file_name for _, file_name in TEXT_TABLES}
    names = [mod.name] + [os.path.basename(library.folder) for library in mod.libraries]
    for name in mod.translations.get("EN", {}):
        if name not in getText_files:
            continue
        for key in mod.english(name):
            for owner in names:
                at = key.find(owner)
                if at > 0:
                    shapes.add(key[:at + len(owner)])
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
    # in English, and a key English lacks is read by nothing. Every mod's files fill the same
    # tables, so a file is held to them all.
    english = mod.translations.get("EN", {})
    languages = set(mod.translations)
    if mod.all_languages:
        languages |= game.languages - PLACEHOLDER_LANGUAGES
    for language in sorted(languages - {"EN"}):
        files = mod.translations.get(language, {})
        missing = 0
        for _, name, path, table in sorted(f for f in mod.translation_files if f[0] == language):
            extra = sorted(set(table) - set(english.get(name, {})))
            if extra:
                report.fail("translation-extra", path, None,
                            "%d key(s) English does not have, which nothing reads: %s"
                            % (len(extra), ", ".join(extra[:5])))
        for _, name, english_path, source in sorted(f for f in mod.translation_files if f[0] == "EN"):
            lacking = sorted(set(source) - set(files.get(name, {})))
            missing += len(lacking)
            if not mod.all_languages or not lacking:
                continue
            # The file beside this English one, in the same mod.
            path = os.path.join(os.path.dirname(os.path.dirname(english_path)), language,
                                os.path.basename(english_path))
            if os.path.exists(path):
                report.fail("translation-missing", path, None,
                            "lacks %d key(s) English has, which show in English: %s"
                            % (len(lacking), ", ".join(lacking[:5])))
            else:
                report.fail("translation-missing", path, None, "missing, so all of %s.json shows in English"
                            % name)
        if missing and not mod.all_languages:
            report.note("%s lacks %d key(s) English has, which show in English" % (language, missing))


@check
def translation_placeholder(mod, game, report):
    # Translator.formatFixer turns %1..%9 into String.format arguments and keeps %%. Any other %
    # is malformed (the game's own dev build refuses to start over one). A placeholder a
    # translation adds is filled by nothing, and one it drops hides the value English shows.
    for language, name, path, table in sorted(mod.translation_files):
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
