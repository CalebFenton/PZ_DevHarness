"""Writes a mod's workshop.txt description from its README.md (docs/workshop-page.md).

    python3 workshop.py --repo <owner/name> [--branch <branch>] [--skip <heading>]...
                        [--map <map folder>]... [--check] <README.md> <workshop.txt> <mod id>...

bin/workshop-txt.sh runs it with what the mod's dev/harness.conf says, and bin/static-check.sh with
--check, which writes nothing and fails when workshop.txt isn't what the README makes or the page
won't fit. The README's ## sections named by --skip stay off the Workshop page. The title, id, tags
and visibility already in workshop.txt are kept; the file is written as the game's uploader
writes it (SteamWorkshopItem.writeWorkshopTxt), so an upload doesn't change it.

Takes GitHub Markdown without HTML: headings, paragraphs, **bold**, *italics*, `code`, links,
images (a linked image too), - and 1. lists, tables, fenced code and --- rules. Nested lists come
out flat, and headings below ### as [h3], since Steam has none. Relative image paths become
raw.githubusercontent.com URLs and relative links the repository's pages, which show only once
the repository is public.
"""
import argparse
import re
import sys

# Steam's limit on a description, in bytes (ISteamRemoteStorage
# k_cchPublishedDocumentDescriptionMax), which counts the footer the game adds
# (SteamWorkshopItem.getSubmitDescription).
DESCRIPTION_BYTES = 8000
# A Workshop ID's length, for the footer of an item not yet published.
WORKSHOP_ID_DIGITS = 10

# A link or image target: no spaces, balanced parentheses allowed, then an optional title.
TARGET = r"([^\s()]*(?:\([^\s()]*\)[^\s()]*)*)(?:\s+\"[^\"]*\")?"
IMAGE = re.compile(r"!\[[^\]]*\]\(" + TARGET + r"\)")
LINK = re.compile(r"\[([^\[\]]+)\]\(" + TARGET + r"\)")
ESCAPE = re.compile(r"\\([\\`*_{}\[\]()#+\-.!|])")
CODE = re.compile(r"(`+)(.+?)\1")
BOLD = re.compile(r"(\*\*|__)(?=\S)(.+?)(?<=\S)\1(?![*_])")
ITALIC = re.compile(r"(?<![\w*])([*_])(?=\S)(.+?)(?<=\S)\1(?![\w*])")
KEPT = re.compile("\0(\\d+)\0")

HEADING = re.compile(r"\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*")
BULLET = re.compile(r"\s*[-*+]\s+(.*)")
NUMBERED = re.compile(r"\s*\d+[.)]\s+(.*)")
FENCE = re.compile(r"\s*(```|~~~)")
RULE = re.compile(r"\s{0,3}([-*_])(\s*\1){2,}\s*")
TABLE_RULE = re.compile(r"\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?")
# Steam has headings down to [h3].
DEEPEST_HEADING = 3


class Page:
    def __init__(self, repo, branch):
        self.raw = f"https://raw.githubusercontent.com/{repo}/{branch}/"
        self.blob = f"https://github.com/{repo}/blob/{branch}/"

    def inline(self, text):
        # What emphasis must not reach (escaped characters, code, URLs) waits in `kept` as \0n\0.
        kept = []

        def keep(value):
            kept.append(value)
            return f"\0{len(kept) - 1}\0"

        text = ESCAPE.sub(lambda m: keep(m.group(1)), text)
        text = CODE.sub(lambda m: keep(m.group(2).strip()), text)
        text = IMAGE.sub(lambda m: keep(f"[img]{self.url(m.group(1), self.raw)}[/img]"), text)

        def link(match):
            label, target = match.groups()
            if target.startswith("#"):
                return label
            # A link to an image, such as a sheet linked to itself at full size, opens the file.
            base = self.raw if re.search(r"\.(png|jpe?g|gif)$", target, re.I) else self.blob
            return keep(f"[url={self.url(target, base)}]") + label + keep("[/url]")

        text = LINK.sub(link, text)
        text = BOLD.sub(r"[b]\2[/b]", text)
        text = ITALIC.sub(r"[i]\2[/i]", text)
        return KEPT.sub(lambda m: kept[int(m.group(1))], text)

    @staticmethod
    def url(target, base):
        if re.match(r"[A-Za-z][A-Za-z0-9+.-]*:", target):
            return target
        return base + re.sub(r"^(\./)+|^/", "", target)


def cells(line):
    """A table row's cells; `\\|` is a pipe inside a cell."""
    row = line.strip()
    row = row[1:] if row.startswith("|") else row
    row = row[:-1] if row.endswith("|") and not row.endswith("\\|") else row
    return [cell.strip().replace("\\|", "|") for cell in re.split(r"(?<!\\)\|", row)]


def is_table(lines, i):
    return "|" in lines[i] and i + 1 < len(lines) and bool(TABLE_RULE.fullmatch(lines[i + 1].strip()))


def starts_block(lines, i):
    line = lines[i]
    return bool(HEADING.fullmatch(line) or FENCE.match(line) or RULE.fullmatch(line)
                or BULLET.fullmatch(line) or NUMBERED.fullmatch(line) or is_table(lines, i))


def list_items(lines, i, pattern):
    """The items of the list at line i and the line after it; a blank line between items, or an
    indented paragraph under one, doesn't end the list."""
    items, after_blank = [], False
    while i < len(lines):
        line = lines[i]
        item = pattern.fullmatch(line)
        if not line.strip():
            j = i
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j == len(lines) or not (pattern.fullmatch(lines[j]) or lines[j][:1].isspace()):
                break
            i, after_blank = j, True
        elif item:
            items.append(item.group(1).strip())
            i, after_blank = i + 1, False
        elif line[:1].isspace() or not (after_blank or starts_block(lines, i)):
            items[-1] += " " + line.strip()
            i += 1
        else:
            break
    return items, i


def blocks(lines, skip):
    """The README's blocks, as (kind, payload): heading, paragraph, list, olist, table, code and
    rule. A ## or # heading named in `skip` drops everything up to the next one."""
    i, skipping = 0, False
    while i < len(lines):
        line = lines[i]
        fence = FENCE.match(line)
        if fence:
            end = i + 1
            while end < len(lines) and not lines[end].strip().startswith(fence.group(1)):
                end += 1
            if not skipping:
                yield "code", lines[i + 1:end]
            i = end + 1
            continue
        heading = HEADING.fullmatch(line)
        if heading:
            level = len(heading.group(1))
            if level <= 2:
                skipping = heading.group(2) in skip
            if not skipping:
                yield "heading", (min(level, DEEPEST_HEADING), heading.group(2))
            i += 1
            continue
        if skipping or not line.strip():
            i += 1
            continue
        if RULE.fullmatch(line):
            yield "rule", None
            i += 1
        elif is_table(lines, i):
            rows = [cells(line)]
            i += 2
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                rows.append(cells(lines[i]))
                i += 1
            yield "table", rows
        elif BULLET.fullmatch(line):
            items, i = list_items(lines, i, BULLET)
            yield "list", items
        elif NUMBERED.fullmatch(line):
            items, i = list_items(lines, i, NUMBERED)
            yield "olist", items
        else:
            text = [line.strip()]
            i += 1
            while i < len(lines) and lines[i].strip() and not starts_block(lines, i):
                text.append(lines[i].strip())
                i += 1
            yield "paragraph", " ".join(text)


def description(readme, page, skip):
    out = []
    after_heading = False
    for kind, payload in blocks(readme.splitlines(), skip):
        if out and not after_heading:
            out.append("")
        after_heading = False
        if kind == "heading":
            level, text = payload
            if IMAGE.fullmatch(text):
                out.append(page.inline(text))
            else:
                out.append(f"[h{level}]{page.inline(text)}[/h{level}]")
                after_heading = True
        elif kind == "paragraph":
            out.append(page.inline(payload))
        elif kind in ("list", "olist"):
            out.append(f"[{kind}]")
            out.extend(f"[*]{page.inline(item)}" for item in payload)
            out.append(f"[/{kind}]")
        elif kind == "code":
            out.extend(["[code]", *payload, "[/code]"])
        elif kind == "rule":
            out.append("[hr][/hr]")
        else:
            # One line: Steam turns each line break into a <br>, which a table would push above itself.
            rows = []
            for n, row in enumerate(payload):
                tag = "th" if n == 0 else "td"
                rows.append("[tr]" + "".join(f"[{tag}]{page.inline(c)}[/{tag}]" for c in row) + "[/tr]")
            out.append("[table]" + "".join(rows) + "[/table]")
    return out


def read_fields(path):
    fields = {"id": "", "title": "", "tags": "", "visibility": "public"}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                key, _, value = line.strip().partition("=")
                if key in fields:
                    fields[key] = value
    except FileNotFoundError:
        pass
    return fields


def main(argv):
    parser = argparse.ArgumentParser(usage=__doc__.split("\n\n")[1])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--branch", default="master")
    parser.add_argument("--skip", action="append", default=[])
    parser.add_argument("--map", action="append", default=[])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("readme")
    parser.add_argument("workshop")
    parser.add_argument("mod_ids", nargs="+")
    args = parser.parse_args(argv)

    with open(args.readme, encoding="utf-8") as f:
        lines = description(f.read(), Page(args.repo, args.branch), set(args.skip))
    fields = read_fields(args.workshop)
    text = "\n".join(
        ["version=1", f"id={fields['id']}", f"title={fields['title']}"]
        + [f"description={line}" for line in lines]
        + [f"tags={fields['tags']}", f"visibility={fields['visibility']}"]) + "\n"

    footer = "\n\nWorkshop ID: " + (fields["id"] or "0" * WORKSHOP_ID_DIGITS)
    footer += "".join(f"\nMod ID: {mod_id}" for mod_id in args.mod_ids)
    footer += "".join(f"\nMap Folder: {folder}" for folder in args.map)
    size = len(("\n".join(lines) + footer).encode("utf-8"))
    status = 0
    if size > DESCRIPTION_BYTES:
        print(f"workshop.txt: the description is {size} bytes with the game's footer, over Steam's "
              f"{DESCRIPTION_BYTES}; cut {args.readme}", file=sys.stderr)
        status = 1
    # SteamWorkshopItem.readWorkshopTxt deletes the key from anywhere in the line.
    if any("description=" in line for line in lines):
        print(f"workshop.txt: {args.readme} says 'description=', which the game's reader deletes",
              file=sys.stderr)
        status = 1
    if args.check:
        try:
            with open(args.workshop, encoding="utf-8") as f:
                current = f.read()
        except FileNotFoundError:
            current = ""
        if current != text:
            print(f"workshop.txt: not what {args.readme} makes; run dev/workshop-txt.sh", file=sys.stderr)
            status = 1
    elif status == 0:
        with open(args.workshop, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"wrote {args.workshop}: {size} of {DESCRIPTION_BYTES} bytes")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
