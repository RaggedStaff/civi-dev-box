#!/usr/bin/env python3
"""
Find references to variables that will abort a script under `set -u`.

Every script here runs `set -euo pipefail`, which makes an unguarded reference
to an unset variable fatal:

    [ -n "$CIVICRM_WEB_USER" ]   ->  line 115: CIVICRM_WEB_USER: unbound variable

This has bitten three times now (CIVICRM_DB_HOST, CIVICRM_APP_DIR,
CIVICRM_WEB_USER), each only during a Jelastic import and never in local testing,
because the JPS supplies exactly the variables the happy path needs and no
others. A local test that sets the manifest's full environment cannot see it.

So the check is static. A name is safe if, anywhere in the same file or in
lib.sh (which every script sources), it is:

  * assigned            APP_ROOT="$(...)"   local a b c    verdict=""
  * defaulted           : "${NAME:=x}"      ${NAME:-x}
  * loop- or read-bound for x in ...          read x
  * supplied by the JPS manifest's node env

Two source regions are stripped before scanning, because they are not shell and
are dense with `$` variables:

  * heredoc bodies whose tag is not a shell tag (PHP lives here)
  * the single-quoted argument of `php -r '...'`

and `#` comments are removed. Both are line-oriented, so a match that was not on
its own logical line is reported verbatim, which keeps a finding reviewable.

Run via: make lint-unset   (or: python3 tests/unset-env-test.py)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = sorted(ROOT.glob("scripts/*.sh")) + sorted(ROOT.glob("tests/*.sh"))
LIB = ROOT / "scripts/lib.sh"

# A bare expansion: $NAME or ${NAME} with no operator inside the braces.
BARE = re.compile(r"\$\{(?P<braced>[A-Za-z_][A-Za-z0-9_]*)\}|\$(?P<plain>[A-Za-z_][A-Za-z0-9_]*)")

# `${NAME` followed by an operator -> the expansion supplies its own fallback.
GUARDED = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*[:?+-]")

# `\$` is a literal dollar, not an expansion.
ESCAPED_DOLLAR = re.compile(r"\\\$")

# Names guaranteed to exist, or that the shell itself defines.
BUILTIN = {
    "BASH_SOURCE", "PATH", "HOME", "USER", "PWD", "OLDPWD", "SHELL", "TMPDIR",
    "IFS", "RANDOM", "SECONDS", "LINENO", "HOSTNAME", "HOSTTYPE", "OSTYPE",
    "PS1", "PS2", "PS4", "UID", "EUID", "PPID", "PIPESTATUS", "REPLY", "OPTIND",
    "_CIVI_SELF", "BASH", "BASHPID", "GROUPS", "DIRSTACK",
}

# Tags whose body is shell we still want to read. Anything NOT listed here -
# notably PHP and INI - is treated as data and blanked out.
SHELL_HEREDOC_TAGS = {
    "EOF", "EOT", "SH", "BASH", "SCRIPT", "STUB", "CONF", "SHELL", "EOF_EOF",
    "CRON", "SUDOERS", "HEALTHCHECK", "DOCKERFILE", "HTA",
}

HEREDOC = re.compile(r"<<-?\s*(?P<q>['\"]?)(?P<tag>[A-Za-z_][A-Za-z0-9_]*)(?P=q)")
PHP_R = re.compile(r"""php\s+-r\s+'[^']*'""", re.DOTALL)
# `read -r a b c`, `for a b in ...`, `local a b`, `declare a b` bind bare names.
BARE_BINDING = re.compile(
    r"(?:\bfor\b|\bread\b(?:\s+-[a-zA-Z]+)*|\blocal\b|\bdeclare\b|\btypeset\b|\bexport\b(?:\s+-[a-zA-Z]+)*)"
    r"\s+(?P<names>-[a-zA-Z]+\s+)*"
    r"(?P<ids>[A-Za-z_][A-Za-z0-9_]*(?:\s+[A-Za-z_][A-Za-z0-9_]*)*)"
)


def strip_non_shell(text: str) -> str:
    """Blank out heredoc bodies (non-shell tags), php -r snippets and comments.

    Strictly positional: at each offset we try php -r, then a heredoc opener,
    then a comment. Doing it this way matters - an earlier version searched
    ahead for the next '#' with text.find(), which skipped over every php -r
    snippet that happened to sit between the cursor and that '#', and so
    reported $x, $argv, $pdo as if they were shell variables.
    """
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]

        # php -r '<code>'  - the PHP is full of $variables that are not ours.
        m = PHP_R.match(text, i)
        if m and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            out.append(" " * (m.end() - i))
            i = m.end()
            continue

        # A heredoc opener. Skip its body unless the tag is shell.
        m = HEREDOC.match(text, i)
        if m:
            out.append(text[i:m.end()])
            tag = m.group("tag")
            if tag not in SHELL_HEREDOC_TAGS:
                tm = re.compile(rf"^[ \t]*{re.escape(tag)}[ \t]*$", re.MULTILINE).search(text, m.end())
                stop = tm.end() if tm else n
                out.append("\n" + "\n" * text.count("\n", m.end(), stop))
                i = stop
                continue
            i = m.end()
            continue

        # A comment runs to the end of its own line.
        if ch == "#":
            end = text.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue

        out.append(ch)
        i += 1
    return "".join(out)


def defined_names(text: str) -> set[str]:
    """Every name this file makes defined somewhere."""
    names: set[str] = set()

    # `NAME=` at any position: `APP_ROOT="$(x)"`, `if FOO=$(..); then`, `verdict=""`.
    for m in re.finditer(r"(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)=", text):
        names.add(m.group(1))
    # `NAME+=` / `NAME[...]=` (arrays, appends)
    for m in re.finditer(r"(?:^|[\s;&|(])([A-Za-z_][A-Za-z0-9_]*)\s*(\[[^]]*\])?\+?=", text):
        names.add(m.group(1))

    # `printf -v NAME` assigns without an equals sign.
    for m in re.finditer(r"\bprintf\s+(?:-\w+\s+)*-v\s+([A-Za-z_][A-Za-z0-9_]*)", text):
        names.add(m.group(1))
    # Bare bindings: for x in, read x, local a b, declare a b, export a b
    for m in BARE_BINDING.finditer(text):
        # Skip `for` in the `php -r` sense and word lists that are really a
        # single name followed by `in`.
        chunk = m.group("ids")
        if re.search(r"\bin\b", chunk):
            chunk = chunk.split(" in ", 1)[0]
        for name in chunk.split():
            if name.startswith("-") or "=" in name:
                continue
            names.add(name)

    # Defaults and guarded expansions
    for m in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*)[:?+-]", text):
        names.add(m.group(1))
    return names


def scan(path: Path, known: set[str]) -> list[tuple[int, str, str]]:
    original = path.read_text()
    text = strip_non_shell(original)
    lines = original.splitlines()

    defined = known | BUILTIN | defined_names(text)

    findings: list[tuple[int, str, str]] = []
    for m in BARE.finditer(text):
        name = m.group("braced") or m.group("plain")
        if name in defined:
            continue
        start = m.start()
        # `\$` is a literal dollar, not an expansion.
        if start > 0 and text[start - 1] == "\\":
            continue
        if m.group("braced"):
            after = text[m.end():m.end() + 2]
            if after[:1] in (":", "?", "-", "+", "="):
                continue
        line_no = text.count("\n", 0, start) + 1
        src = lines[line_no - 1].strip() if line_no <= len(lines) else ""
        findings.append((line_no, src, name))
    return findings


def manifest_env() -> set[str]:
    import yaml  # noqa: PLC0415 - only needed when the manifest is present

    data = yaml.safe_load((ROOT / "jps/civi-standalone.jps").read_text())
    names: set[str] = set()
    for node in data.get("nodes") or []:
        names.update((node.get("env") or {}).keys())
    return names


def main() -> int:
    try:
        known = manifest_env() | defined_names(LIB.read_text())
    except Exception as exc:  # pragma: no cover - the manifest is always present here
        print(f"  could not read the manifest/lib.sh: {exc}", file=sys.stderr)
        known = set()

    total = 0
    for path in SCRIPTS:
        findings = scan(path, known)
        if not findings:
            continue
        print(f"  {path.relative_to(ROOT)}")
        for line_no, src, name in findings:
            total += 1
            print(f"    line {line_no}: {name} - unguarded reference")
            print(f"      {src}")
    if total:
        print(f"\n  {total} unguarded reference(s).")
        print("  Under `set -u` each aborts the script when the variable is unset,")
        print("  which is how the last three import failures happened. Guard it:")
        print('    [ -n "${NAME:-}" ]   or   : "${NAME:=default}"')
        return 1
    print("  no unguarded references")
    return 0


if __name__ == "__main__":
    sys.exit(main())