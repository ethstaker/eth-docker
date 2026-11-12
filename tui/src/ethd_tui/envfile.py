"""Read .env files the way ethd's __get_value_from_env does, and quote values for writing back."""

import re
from pathlib import Path

_ASSIGN = re.compile(r"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def parse(text: str) -> dict[str, str]:
    """Raw values by name, quotes kept. The first assignment of a name wins, as in ethd."""
    values: dict[str, str] = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        match = _ASSIGN.match(lines[i])
        i += 1
        if not match:
            continue
        name, rest = match.groups()
        quote = rest[:1]
        if quote in ('"', "'") and re.fullmatch(rf"{quote}[^{quote}]*", rest):
            # Multi-line value, runs until a line that ends in the same quote
            chunk = [rest]
            while i < len(lines):
                chunk.append(lines[i])
                i += 1
                if lines[i - 1].rstrip().endswith(quote):
                    break
            value = "\n".join(chunk).rstrip()
        else:
            value = rest.strip()
        values.setdefault(name, value)
    return values


def parse_help(text: str) -> dict[str, str]:
    """The comment block above each variable in default.env, shared by consecutive variables."""
    helps: dict[str, str] = {}
    comment: list[str] = []
    after_var = False
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            comment, after_var = [], False
        elif stripped.startswith("#"):
            if after_var:
                comment, after_var = [], False
            comment.append(stripped.lstrip("#").strip())
        elif match := _ASSIGN.match(line):
            helps.setdefault(match.group(1), "\n".join(comment))
            after_var = True
    return helps


def unquote(raw: str) -> str:
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ('"', "'"):
        return raw[1:-1]
    return raw


def quote(value: str, like: str) -> str:
    """Quote value for .env, keeping the quote style of the raw value it replaces."""
    style = (
        like[:1]
        if like[:1] in ('"', "'") and like.endswith(like[:1]) and len(like) >= 2
        else ""
    )
    if not style and re.search(r"[\s#'\"]", value):
        style = '"'
    if style and style in value:
        style = "'" if style == '"' else '"'
        if style in value:
            raise ValueError("a value cannot contain both kinds of quotes")
    return f"{style}{value}{style}"


def load(path: Path) -> dict[str, str]:
    return parse(path.read_text()) if path.exists() else {}
