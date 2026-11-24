#!/usr/bin/env python3
"""privacy-check.py (lane B, 2026-11-23): read every demo frame and refuse what would show a person.

    python3 -I -X utf8 ci/demo/privacy-check.py <frames dir> <machine.txt>

The demos are recorded on a GitHub runner, never on the owner's desktop. Still, before they are
published, every frame is read (OCR, tesseract) and checked for: the runner's machine name and
user name (machine.txt, written by the recording job), any home folder (C:\\Users\\<name>,
/home/<name>), the runner's workspace (\\a\\ or /a/ paths), an e-mail address, and an IP other
than 127.0.0.1. One hit fails the check (exit 1), and the demos are not published. Every frame is
read. OCR can miss text, so the first published set is also looked at by a person.
"""
import pathlib
import re
import subprocess
import sys


def main() -> int:
    frames = pathlib.Path(sys.argv[1])
    machine = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace").split()
    words = [w for w in machine if len(w) >= 4]
    patterns = [re.compile(re.escape(w), re.I) for w in words] + [
        re.compile(r"[A-Za-z]:\\+Users\\+[^\\\s]+", re.I),
        re.compile(r"/home/[A-Za-z0-9._-]+"),
        re.compile(r"[\\/]a[\\/]ghostty-release-kit", re.I),
        re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+"),
        re.compile(r"\b(?!127\.0\.0\.1\b)(?:\d{1,3}\.){3}\d{1,3}\b"),
    ]
    files = sorted(p for p in frames.rglob("f*.*") if p.suffix in (".png", ".bmp"))
    hits = 0
    for f in files:
        text = subprocess.run(["tesseract", str(f), "-", "--psm", "11"], capture_output=True,
                              text=True, encoding="utf-8", errors="replace").stdout
        for p in patterns:
            for m in p.finditer(text):
                hits += 1
                print(f"HIT {f.relative_to(frames)}: {p.pattern!r} matched {m.group(0)!r}")
    print(f"privacy-check: {len(files)} frames read, {hits} hits ({', '.join(words) or 'no machine words'} and the general patterns)")
    return 1 if hits or not files else 0


if __name__ == "__main__":
    sys.exit(main())
