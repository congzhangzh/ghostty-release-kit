#!/usr/bin/env bash
# Cross-compile Ghostty for Windows with Zig on Linux and package it, one zip per architecture:
#
#   ci/build.sh <ghostty source> <version> <out dir> <arch>...      arch: x86_64, aarch64
#
# For each architecture: libghostty (ReleaseFast) for <arch>-windows-gnu, then the host
# (windows/build.sh in the source) linked against its static library, then
#   <out>/ghostty-<version>-windows-<arch>.zip   ghostty-<version>-windows-<arch>/ghostty.exe,
#                                                 BUILDINFO.txt, LICENSE, README.txt
# and <out>/SHA256SUMS over the zips. Needs zig (the version build.zig.zon asks for) and zip.
set -euo pipefail
src=$(cd "$1" && pwd) version=$2 out=$3
shift 3
[ $# -gt 0 ] || set -- x86_64 aarch64
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$out/work
kit=$(cd "$(dirname "$0")/.." && pwd)

[ -x "$src/windows/build.sh" ] || { echo "::error::$src has no windows/build.sh: not a Windows-capable Ghostty" >&2; exit 1; }

for arch in "$@"; do
	echo "::group::libghostty $arch"
	(cd "$src" && zig build -Dtarget="$arch-windows-gnu" -Doptimize=ReleaseFast --prefix "$work/lib-$arch")
	echo "::endgroup::"
	name=ghostty-$version-windows-$arch
	pkg=$work/pkg-$arch/$name
	rm -rf "$work/pkg-$arch"
	mkdir -p "$pkg"
	# What `ghostty.exe /buildinfo` and BUILDINFO.txt say about this release, before what
	# windows/build.sh adds (source commit, build, core components). The env comes from
	# ci/resolve.sh and GitHub Actions; a local build has less of it.
	info=$work/release-info-$arch.txt
	{
		case $version in *+r[0-9]*) echo "release: Ghostty for Windows ${version##*+r}" ;; esac
		echo "version: $version"
		if [ -n "${REF:-}" ]; then echo "ghostty: ${SRC:-?} $REF @ ${SHA:-?}"; fi
		if [ -n "${BASE:-}" ]; then echo "upstream base: ghostty-org/ghostty $(git -C "$src" rev-parse "$BASE" 2> /dev/null || echo "$BASE")"; fi
		if [ -n "${GITHUB_SHA:-}" ]; then echo "kit: ${GITHUB_REPOSITORY:-ghostty-release-kit} @ $GITHUB_SHA"; fi
	} > "$info"
	BUILDINFO_FILE=$info "$src/windows/build.sh" "$work/lib-$arch" "$arch" "$work/host-$arch" release
	cp "$work/host-$arch/ghostty.exe" "$pkg/"
	if [ -f "$work/host-$arch/BUILDINFO.txt" ]; then cp "$work/host-$arch/BUILDINFO.txt" "$pkg/"; fi
	cp "$src/LICENSE" "$pkg/LICENSE"
	sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/$arch/g" "$kit/ci/README.txt" > "$pkg/README.txt"
	(cd "$work/pkg-$arch" && rm -f "$out/$name.zip" && zip -q -r -X "$out/$name.zip" "$name")
	echo "packaged $out/$name.zip ($(du -h "$out/$name.zip" | cut -f1))"
done
(cd "$out" && sha256sum ghostty-*.zip > SHA256SUMS && cat SHA256SUMS)
