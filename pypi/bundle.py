"""Make the Windows wheels of ghostty-for-windows from the plain wheel and the release zips.

    cd pypi && uv build --wheel                       # dist/ghostty_for_windows-<v>-py3-none-any.whl
    python3 -I bundle.py dist/ghostty_for_windows-<v>-py3-none-any.whl <out dir> \\
        ghostty-<version>-windows-x86_64.zip ghostty-<version>-windows-aarch64.zip

For each zip (x86_64 -> win_amd64, aarch64 -> win_arm64) the plain wheel is repacked, tagged
for that platform, with the zip's whole package in ghostty_for_windows/ghostty/ (ghostty.exe,
conpty.dll, OpenConsole.exe, opengl/, share/, the notices): package data, not a script, so
`uv tool install` puts no second exe on PATH. Its metadata names every licence it carries, and
LICENSE and THIRD-PARTY-NOTICES.txt from the zip also go into .dist-info/licenses/. The plain
wheel is never published (it has no ghostty.exe). Standard library only, as freerdp-tk's
scripts/bundle_client.py; the same inputs give the same wheel (fixed times, sorted entries).
"""

import base64
import hashlib
import re
import sys
import zipfile
from pathlib import Path

PLATFORMS = {"x86_64": "win_amd64", "aarch64": "win_arm64"}
ZIP_TIME = (2020, 1, 1, 0, 0, 0)
# What the platform wheels carry: the launcher (Apache-2.0), Ghostty (MIT), Microsoft's ConPTY
# (MIT), Mesa (MIT, BSL-1.0, Apache-2.0) and LLVM (Apache-2.0 WITH LLVM-exception).
LICENSE_EXPRESSION = "Apache-2.0 AND MIT AND BSL-1.0 AND Apache-2.0 WITH LLVM-exception"
# PyPI refuses a file over 100 MB unless the project's limit was raised.
MAX_WHEEL = 100 * 1000 * 1000


def record_line(path: str, data: bytes) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    return f"{path},sha256={digest},{len(data)}"


def zip_package(path: Path) -> dict[str, bytes]:
    """Every file of a release zip, relative to its one top folder."""
    files = {}
    with zipfile.ZipFile(path) as z:
        tops = {i.filename.split("/", 1)[0] for i in z.infolist()}
        if len(tops) != 1:
            sys.exit(f"{path.name}: expected one top folder, found {sorted(tops)}")
        for info in z.infolist():
            if info.is_dir():
                continue
            rel = info.filename.split("/", 1)[1]
            files[rel] = z.read(info)
    if "ghostty.exe" not in files:
        sys.exit(f"{path.name}: no ghostty.exe")
    return files


def arch_of(path: Path) -> str:
    m = re.search(r"-windows-(x86_64|aarch64)\.zip$", path.name)
    if not m:
        sys.exit(f"{path.name}: not a ghostty-<version>-windows-<arch>.zip")
    return m[1]


def bundle(wheel: Path, release_zip: Path, out: Path) -> Path:
    name, version = wheel.name.split("-")[:2]
    info = f"{name}-{version}.dist-info"
    tag = PLATFORMS[arch_of(release_zip)]
    package = zip_package(release_zip)
    with zipfile.ZipFile(wheel) as z:
        entries = {i.filename: z.read(i) for i in z.infolist() if i.filename != f"{info}/RECORD"}

    text = entries[f"{info}/WHEEL"].decode()
    text = re.sub(r"^Tag: .*$", f"Tag: py3-none-{tag}", text, flags=re.MULTILINE)
    entries[f"{info}/WHEEL"] = text.replace("Root-Is-Purelib: true", "Root-Is-Purelib: false").encode()

    meta = entries[f"{info}/METADATA"].decode()
    meta = re.sub(r"^License-Expression: .*$", f"License-Expression: {LICENSE_EXPRESSION}", meta,
                  count=1, flags=re.MULTILINE)
    licences = {}
    for f, dest in (("LICENSE", "ghostty/LICENSE"), ("THIRD-PARTY-NOTICES.txt", "ghostty/THIRD-PARTY-NOTICES.txt")):
        if f in package:
            licences[f"{info}/licenses/{dest}"] = package[f]
            # after the last License-File line, or after License-Expression
            line = f"License-File: {dest}\n"
            last = list(re.finditer(r"^License-(File|Expression): .*\n", meta, flags=re.MULTILINE))[-1]
            meta = meta[: last.end()] + line + meta[last.end():]
    entries[f"{info}/METADATA"] = meta.encode()

    data = {f"ghostty_for_windows/ghostty/{rel}": blob for rel, blob in package.items()}
    merged = {**entries, **licences, **data}
    ordered = [*sorted(p for p in merged if not p.startswith(info)), *sorted(p for p in merged if p.startswith(info))]
    record = [record_line(p, merged[p]) for p in ordered] + [f"{info}/RECORD,,"]
    merged[f"{info}/RECORD"] = ("\n".join(record) + "\n").encode()

    target = out / f"{name}-{version}-py3-none-{tag}.whl"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in [*ordered, f"{info}/RECORD"]:
            entry = zipfile.ZipInfo(path, ZIP_TIME)
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            z.writestr(entry, merged[path])
    size = target.stat().st_size
    print(f"{target.name}: {len(package)} files of {release_zip.name}, {size} bytes")
    if size > MAX_WHEEL:
        sys.exit(f"{target.name} is {size} bytes, over PyPI's {MAX_WHEEL} limit for one file")
    return target


def main() -> None:
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    wheel, out = Path(sys.argv[1]), Path(sys.argv[2])
    if not wheel.name.endswith("-py3-none-any.whl"):
        sys.exit(f"{wheel.name}: give the plain wheel from uv build")
    out.mkdir(parents=True, exist_ok=True)
    seen = set()
    for z in map(Path, sys.argv[3:]):
        arch = arch_of(z)
        if arch in seen:
            sys.exit(f"two zips for {arch}")
        seen.add(arch)
        bundle(wheel, z, out)


if __name__ == "__main__":
    main()
