"""Script files (media/scripts/*.txt, sandbox-options.txt) parsed the way the game parses them.

ScriptParser.stripComments removes /* */ comments, nested ones included, and nothing else: a //
is ordinary text. ScriptParser.readBlock then splits a block at commas and braces. The text before
a { is the child block's header, its type and id the first two words. Everything between two
commas is one value, a key and a value either side of the first = when there is one. Text after a
block's last comma is dropped without a word, so a value missing its comma just before a } is
lost. ScriptManager hands each top-level `module` block on and ignores anything else at the top.

Lines are kept for messages: comments are blanked rather than cut, so offsets never move.
"""
import bisect
import re
from dataclasses import dataclass, field


@dataclass
class Value:
    key: str        # None when the value has no =, as in a recipe's `item 1 [Base.Plank]`
    value: str
    line: int


@dataclass
class Block:
    type: str
    id: str
    line: int
    # The header's words, of which the game reads the first two. An = among them means a value
    # before the block lost its comma and ran into the header.
    header: list = field(default_factory=list)
    values: list = field(default_factory=list)
    children: list = field(default_factory=list)
    # Text after the last comma, which the game drops: (text, line).
    dropped: list = field(default_factory=list)

    def get(self, key):
        """The last value with this key, which is the one the game keeps."""
        found = None
        for value in self.values:
            if value.key is not None and value.key.lower() == key.lower():
                found = value
        return found

    def all(self, key):
        return [v for v in self.values if v.key is not None and v.key.lower() == key.lower()]

    def blocks(self, block_type):
        return [b for b in self.children if b.type.lower() == block_type.lower()]

    def walk(self):
        yield self
        for child in self.children:
            yield from child.walk()


def strip_comments(text):
    """The text with every /* */ comment, nested or not, replaced by spaces and newlines."""
    out = []
    depth = 0
    at = 0
    for match in re.finditer(r"/\*|\*/", text):
        if match.group() == "/*":
            if depth == 0:
                out.append(text[at:match.start()])
                at = match.start()
            depth += 1
        elif depth:
            depth -= 1
            if depth == 0:
                out.append(re.sub(r"[^\n]", " ", text[at:match.end()]))
                at = match.end()
    # An unclosed comment runs to the end, which is also where the game stops looking.
    tail = text[at:]
    out.append(re.sub(r"[^\n]", " ", tail) if depth else tail)
    return "".join(out)


def parse(text):
    """The file as a root Block whose children are its top-level blocks."""
    text = strip_comments(text)
    lines = _LineIndex(text)
    root = Block("", None, 1)
    stack = [root]
    start = 0
    for match in re.finditer(r"[{},]", text):
        piece = text[start:match.start()]
        block = stack[-1]
        if match.group() == "{":
            words = piece.split()
            child = Block(words[0] if words else "", words[1] if len(words) > 1 else None,
                          lines.line(start + len(piece) - len(piece.lstrip())), words)
            block.children.append(child)
            stack.append(child)
        elif match.group() == ",":
            block.values.append(_value(piece, lines.line(start + len(piece) - len(piece.lstrip()))))
        else:
            if piece.strip():
                block.dropped.append((piece.strip(), lines.line(start + len(piece) - len(piece.lstrip()))))
            if len(stack) > 1:
                stack.pop()
        start = match.end()
    return root


def _value(piece, line):
    key, equals, value = piece.partition("=")
    if not equals:
        return Value(None, piece.strip(), line)
    return Value(key.strip(), value.strip(), line)


class _LineIndex:
    def __init__(self, text):
        self.starts = [0] + [m.end() for m in re.finditer("\n", text)]

    def line(self, offset):
        return bisect.bisect_right(self.starts, offset)


def modules(root):
    """(module name, block) for each top-level module block."""
    return [(block.id, block) for block in root.children if block.type == "module"]
