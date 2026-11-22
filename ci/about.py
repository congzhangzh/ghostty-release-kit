#!/usr/bin/env python3
"""What ghostty.exe's About and What's new show, taken from the kit's own files at build time.

    python3 -I ci/about.py whatsnew <sources.lock> <version>   this release's paragraph
    python3 -I ci/about.py family <about.py>                    py-screen's family line

whatsnew: sources.lock describes every release in its header, one paragraph each, starting
"#   r<YYYYMMDD>.<N>: ...". For a version <upstream>+r<YYYYMMDD>.<N> this prints that paragraph as
plain text (the "# " comment marks and the release name taken off, lines joined). No paragraph
(a test build, a version without +r) prints nothing and exits 0.

family: py-screen's src/py_screen/about.py says SLOGAN = f"{MOTTO} · <family line>". This reads
the file as Python syntax, never runs it, and prints the family line. It fails loudly if
SLOGAN no longer has that shape, so a change in py-screen is noticed, not shipped wrong.
"""
import ast
import re
import sys


def whatsnew(lock_path: str, version: str) -> str:
    m = re.search(r"\+r(\d{8}\.\d+)$", version)
    if not m:
        return ""
    tag = m.group(1)
    with open(lock_path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    out: list[str] = []
    inside = False
    for line in lines:
        if not line.startswith("#"):
            if inside:
                break
            continue
        body = line[1:]
        # A paragraph starts "#   r<tag>:"; another release, or a "# <name>:" entry, ends it.
        start = re.match(r"\s{3}r(\d{8}\.\d+):\s?(.*)$", body)
        if start:
            if inside:
                break
            if start.group(1) == tag:
                inside = True
                out.append(start.group(2))
            continue
        if inside:
            cont = re.match(r"\s{3}(\S.*)$", body)
            if not cont:
                break
            out.append(cont.group(1))
    return " ".join(s.strip() for s in out if s.strip())


def family(about_path: str) -> str:
    with open(about_path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), filename=about_path)
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "SLOGAN" for t in node.targets):
            v = node.value
            if (
                isinstance(v, ast.JoinedStr)
                and len(v.values) == 2
                and isinstance(v.values[0], ast.FormattedValue)
                and isinstance(v.values[0].value, ast.Name)
                and v.values[0].value.id == "MOTTO"
                and isinstance(v.values[1], ast.Constant)
                and isinstance(v.values[1].value, str)
                and v.values[1].value.startswith(" · ")
            ):
                return v.values[1].value[len(" · "):]
            raise SystemExit(f"about.py: SLOGAN is not f\"{{MOTTO}} · <family line>\" any more ({about_path})")
    raise SystemExit(f"about.py: no SLOGAN in {about_path}")


def main() -> None:
    if len(sys.argv) == 4 and sys.argv[1] == "whatsnew":
        text = whatsnew(sys.argv[2], sys.argv[3])
        if text:  # nothing at all for no paragraph: an empty file means "nothing new"
            print(text)
    elif len(sys.argv) == 3 and sys.argv[1] == "family":
        print(family(sys.argv[2]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
