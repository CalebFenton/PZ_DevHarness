"""Lua source read as tokens, and the facts the checks need from one file.

No parser: Kahlua already proves each file compiles (GameProbe), so this only has to tell names,
strings and punctuation apart, which regexes on raw text get wrong inside comments and strings.
Scopes are not tracked. A name declared local anywhere in a file counts as local everywhere in
it, which can hide a misspelt global but never reports a correct name.
"""
import bisect
import re
from dataclasses import dataclass, field

_TOKEN = re.compile(r"""
    (?P<comment> --\[(?P<ceq>=*)\[ .*? \](?P=ceq)\] | --[^\n]* )
  | (?P<long>    \[(?P<leq>=*)\[ .*? \](?P=leq)\] )
  | (?P<string>  "(?:\\[\s\S]|[^"\\\n])*" | '(?:\\[\s\S]|[^'\\\n])*' )
  | (?P<number>  0[xX][0-9a-fA-F]+ | (?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)? )
  | (?P<name>    [A-Za-z_]\w* )
  | (?P<op>      \.\.\.|\.\.|==|~=|<=|>=|[-+*/%^\#<>=(){}\[\];:,.] )
""", re.S | re.X)

KEYWORDS = frozenset("""and break do else elseif end false for function if in local nil not or
    repeat return then true until while""".split())

# Kinds of Token.
NAME, KEYWORD, STRING, NUMBER, OP = "name", "keyword", "string", "number", "op"


@dataclass
class Token:
    kind: str
    text: str       # a string's contents without quotes or brackets, escapes left as written
    at: int         # offset in the file


def tokenize(source):
    tokens = []
    for match in _TOKEN.finditer(source):
        if match.group("comment") is not None:
            continue
        kind, text = match.lastgroup, match.group()
        if kind == "long":
            brackets = len(match.group("leq")) + 2
            kind, text = STRING, text[brackets:-brackets]
        elif kind == "string":
            kind, text = STRING, text[1:-1]
        elif kind == NAME and text in KEYWORDS:
            kind = KEYWORD
        tokens.append(Token(kind, text, match.start()))
    return tokens


@dataclass
class Chain:
    """A free name and the .member names right after it, as in SandboxVars.MyMod.x."""
    names: list
    at: int
    called: bool        # the last name is called, with (, a string or a table
    assigned: bool      # the chain is the target of an =


@dataclass
class LuaFile:
    path: str
    source: str
    tokens: list = field(default_factory=list)
    locals: set = field(default_factory=set)
    globals: set = field(default_factory=set)          # names this file assigns as globals
    members: set = field(default_factory=set)          # (table, key) this file assigns
    functions: set = field(default_factory=set)        # every name a function is defined under
    chains: list = field(default_factory=list)         # free names as read, with their members
    methods: list = field(default_factory=list)        # (name, offset) of each obj:name() call
    tables: list = field(default_factory=list)         # (offset, {key: literal}) per table constructor
    strings: list = field(default_factory=list)        # (text, offset, joined) per string literal
    index: dict = field(default_factory=dict)          # token offset -> token position

    def line(self, offset):
        if not hasattr(self, "_starts"):
            self._starts = [0] + [m.end() for m in re.finditer("\n", self.source)]
        return bisect.bisect_right(self._starts, offset)

    def calls_with_literal(self, function):
        """(literal, offset) for each call of a global function whose first argument is a string
        literal on its own: getText("x") and require "x" count, getText("x" .. y) does not."""
        found = []
        tokens = self.tokens
        for chain in self.chains:
            if chain.names != [function] or not chain.called:
                continue
            i = self.index[chain.at] + 1
            if tokens[i].kind == STRING:
                found.append((tokens[i].text, tokens[i].at))
            elif tokens[i].text == "(" and i + 2 < len(tokens) and tokens[i + 1].kind == STRING \
                    and tokens[i + 2].text in (")", ","):
                found.append((tokens[i + 1].text, tokens[i + 1].at))
        return found


def read(path, source=None):
    if source is None:
        with open(path, encoding="utf-8", errors="replace") as f:
            source = f.read()
    lua = LuaFile(path, source, tokenize(source))
    _analyse(lua)
    return lua


def _analyse(lua):
    tokens = lua.tokens
    count = len(tokens)
    lua.index = {token.at: i for i, token in enumerate(tokens)}

    def text(i):
        return tokens[i].text if 0 <= i < count else ""

    def kind(i):
        return tokens[i].kind if 0 <= i < count else ""

    # Open brackets, each with the table constructor's literal fields when it is a {.
    brackets = []
    i = 0
    while i < count:
        token = tokens[i]
        t = token.text

        if token.kind == KEYWORD and t in ("local", "for") and kind(i + 1) == NAME:
            # local a, b / for k, v: declarations, neither reads nor global assignments.
            j = i + 1
            while kind(j) == NAME:
                lua.locals.add(text(j))
                j += 2 if text(j + 1) == "," else 1
            i = j
            continue

        if token.kind == KEYWORD and t == "function":
            j = i + 1
            if kind(j) == NAME:
                # function a.b:c(): reads a, and defines c on it, or a itself with no dots.
                names = [text(j)]
                while text(j + 1) in (".", ":") and kind(j + 2) == NAME:
                    names.append(text(j + 2))
                    j += 2
                is_local = text(i - 1) == "local"
                if is_local:
                    lua.locals.add(names[0])
                elif len(names) == 1:
                    lua.globals.add(names[0])
                else:
                    lua.members.add((names[0], names[1]))
                lua.functions.add(names[-1])
                lua.chains.append(Chain(names, tokens[i + 1].at, False, not is_local))
                j += 1
            # The parameters, and the parentheses around them, which open no bracket here.
            if text(j) == "(":
                j += 1
                while kind(j) == NAME or text(j) in (",", "..."):
                    if kind(j) == NAME:
                        lua.locals.add(text(j))
                    j += 1
                if text(j) == ")":
                    j += 1
            i = j
            continue

        if token.kind == OP:
            if t in ("(", "[", "{"):
                brackets.append({} if t == "{" else None)
            elif t in (")", "]", "}"):
                fields = brackets.pop() if brackets else None
                if fields:
                    lua.tables.append((token.at, fields))
            elif t == ":" and kind(i + 1) == NAME:
                after = text(i + 2)
                if after in ("(", "{") or kind(i + 2) == STRING:
                    lua.methods.append((text(i + 1), tokens[i + 1].at))

        elif token.kind == STRING:
            joined = text(i - 1) == ".." or text(i + 1) == ".."
            lua.strings.append((t, token.at, joined))

        elif token.kind == NAME and text(i - 1) not in (".", ":"):
            in_table = brackets and brackets[-1] is not None
            if in_table and text(i - 1) in ("{", ",", ";") and text(i + 1) == "=":
                # A constructor field: name = value. Keep literal values for the checks.
                value = tokens[i + 2] if i + 2 < count else None
                if value is not None and value.kind in (STRING, NUMBER) and text(i + 3) in (",", ";", "}"):
                    brackets[-1][t] = value.text if value.kind == STRING else _number(value.text)
                elif text(i + 2) == "function":
                    lua.functions.add(t)
                i += 1
                continue
            # A free name, with whatever .member names follow it.
            names = [t]
            j = i
            while text(j + 1) == "." and kind(j + 2) == NAME:
                names.append(text(j + 2))
                j += 2
            nxt = text(j + 1)
            called = nxt in ("(", "{") or kind(j + 1) == STRING
            assigned = nxt == "="
            lua.chains.append(Chain(names, token.at, called, assigned))
            if assigned:
                if len(names) == 1:
                    lua.globals.add(t)
                else:
                    lua.members.add((names[0], names[1]))
                if text(j + 2) == "function":
                    lua.functions.add(names[-1])
            i = j + 1
            continue

        i += 1

    # ["name"] = function in a constructor or an index assignment.
    for i in range(count - 4):
        if tokens[i].text == "[" and tokens[i + 1].kind == STRING and tokens[i + 2].text == "]" \
                and tokens[i + 3].text == "=" and tokens[i + 4].text == "function":
            lua.functions.add(tokens[i + 1].text)

    # Without scopes, `x = ...` cannot tell a global from a local declared earlier in the file.
    # A file that declares x local almost always means that one, as with a local called string.
    lua.globals -= lua.locals


def _number(text):
    try:
        return int(text, 0)
    except ValueError:
        return float(text)
