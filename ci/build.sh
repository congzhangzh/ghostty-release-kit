#!/usr/bin/env bash
# Cross-compile Ghostty for Windows with Zig on Linux and package it, one zip per architecture:
#
#   ci/build.sh <ghostty source> <version> <out dir> <arch>...      arch: x86_64, aarch64
#
# For each architecture: libghostty (ReleaseFast, with the themes) for <arch>-windows-gnu, then
# the host (windows/build.sh in the source) linked against its static library, then
#   <out>/ghostty-<version>-windows-<arch>.zip   ghostty-<version>-windows-<arch>/ghostty.exe,
#                                                 BUILDINFO.txt, LICENSE, README.txt, and share/
#                                                 (themes, shell integration, terminfo) when the
#                                                 source has windows/resources.sh, and Microsoft's
#                                                 conpty.dll, OpenConsole.exe and their
#                                                 THIRD-PARTY-NOTICES.txt when it side-loads them
# and <out>/SHA256SUMS over the zips. Only x86_64 must build; another architecture that fails
# is left out and named in <out>/NOT-BUILT. Needs zig (the version build.zig.zon asks for), zip,
# curl and python3.
set -euo pipefail
src=$(cd "$1" && pwd) version=$2 out=$3
shift 3
[ $# -gt 0 ] || set -- x86_64 aarch64
mkdir -p "$out"
out=$(cd "$out" && pwd)
work=$out/work
kit=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$work"
# pin <name> <column>: a field of sources.lock's line for <name> (name version url commit).
pin() { awk -v n="$1" -v c="$2" '$1 == n { print $c; exit }' "$kit/sources.lock"; }

# Microsoft's ConPTY, pinned in sources.lock (name version url sha256:<hex>), for a source that
# side-loads it (src/os/conpty.zig): fetched once, checked, its files left unmodified.
conpty=
if [ -f "$src/src/os/conpty.zig" ]; then
	conpty=$work/conpty-$(pin conpty 2).nupkg
	[ -n "$(pin conpty 3)" ] || { echo "::error::sources.lock has no conpty line" >&2; exit 1; }
	[ -f "$conpty" ] || curl -fsSL --retry 3 -o "$conpty" "$(pin conpty 3)"
	echo "$(pin conpty 4 | sed 's/^sha256://')  $conpty" | sha256sum -c --quiet - ||
		{ echo "::error::$conpty differs from the SHA-256 in sources.lock" >&2; exit 1; }
fi

# What ghostty.exe's About and What's new show (ci/about.py), passed to windows/build.sh, which
# embeds them; a host that doesn't know them ignores both. What's new: this release's paragraph
# of sources.lock's header (empty for a build of no release). The family line: from the
# about.py of the py-screen commit sources.lock pins, read as Python syntax, never run.
whatsnew=$work/whatsnew.txt
python3 -I "$kit/ci/about.py" whatsnew "$kit/sources.lock" "$version" > "$whatsnew"
family='' family_from=''
if [ -n "$(pin py-screen 4)" ]; then
	repo=$(pin py-screen 3)
	repo=${repo#git+https://github.com/}
	repo=${repo%.git}
	curl -fsSL --retry 3 -o "$work/py-screen-about.py" \
		"https://raw.githubusercontent.com/$repo/$(pin py-screen 4)/src/py_screen/about.py"
	family=$(python3 -I "$kit/ci/about.py" family "$work/py-screen-about.py")
	family_from="py-screen $(pin py-screen 2) @ $(pin py-screen 4 | cut -c1-12)"
fi

[ -x "$src/windows/build.sh" ] || { echo "::error::$src has no windows/build.sh: not a Windows-capable Ghostty" >&2; exit 1; }

# One architecture: libghostty, the host, the package. Run in its own subshell with set -e, so
# a failure ends that architecture only (set -e does not apply inside an `if` or `||`).
one() {
	local arch=$1 name pkg info nu
	echo "::group::libghostty $arch"
	(cd "$src" && zig build -Dtarget="$arch-windows-gnu" -Doptimize=ReleaseFast -Demit-themes=true --prefix "$work/lib-$arch")
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
		if [ -s "$whatsnew" ]; then echo "whatsnew: r${version##*+r}"; fi
		if [ -n "$family_from" ]; then echo "family: $family_from"; fi
	} > "$info"
	WHATSNEW_FILE=$whatsnew FAMILY_LINE=$family BUILDINFO_FILE=$info "$src/windows/build.sh" "$work/lib-$arch" "$arch" "$work/host-$arch" release
	cp "$work/host-$arch/ghostty.exe" "$pkg/"
	# Ghostty's resources beside ghostty.exe (share/terminfo is what the core looks for).
	if [ -x "$src/windows/resources.sh" ]; then "$src/windows/resources.sh" "$work/lib-$arch" "$pkg"; fi
	if [ -n "$conpty" ]; then
		case $arch in x86_64) nu=x64 ;; aarch64) nu=arm64 ;; esac
		unzip -q -o -j "$conpty" "runtimes/win-$nu/native/conpty.dll" "build/native/runtimes/$nu/OpenConsole.exe" -d "$pkg"
		cp "$kit/ci/THIRD-PARTY-NOTICES.txt" "$pkg/"
	fi
	if [ -f "$work/host-$arch/BUILDINFO.txt" ]; then cp "$work/host-$arch/BUILDINFO.txt" "$pkg/"; fi
	cp "$src/LICENSE" "$pkg/LICENSE"
	sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/$arch/g" "$kit/ci/README.txt" > "$pkg/README.txt"
	(cd "$work/pkg-$arch" && rm -f "$out/$name.zip" && zip -q -r -X "$out/$name.zip" "$name")
	echo "packaged $out/$name.zip ($(stat -c %s "$out/$name.zip") bytes)"
}

# x86_64 must build: it is what releases are tested and used on. Any other architecture is
# best effort (the owner, 2026-11-22: "focus on x64 ... arm break can be fix by next release"):
# when it fails, its zip is left out, it is named in <out>/NOT-BUILT, and the release goes on.
rm -f "$out/NOT-BUILT"
for arch in "$@"; do
	set +e
	(set -e; one "$arch")
	rc=$?
	set -e
	[ $rc = 0 ] && continue
	echo "::endgroup::"
	rm -f "$out/ghostty-$version-windows-$arch.zip"
	if [ "$arch" = x86_64 ]; then echo "::error::x86_64 did not build (exit $rc)" >&2; exit $rc; fi
	echo "::warning::$arch did not build (exit $rc): left out of this release" >&2
	echo "$arch" >> "$out/NOT-BUILT"
done
(cd "$out" && sha256sum ghostty-*.zip > SHA256SUMS && cat SHA256SUMS)
