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
#                                                 THIRD-PARTY-NOTICES.txt when it side-loads them,
#                                                 and Mesa's opengl\opengl32.dll (software
#                                                 OpenGL) and its notices when it falls back to it
# and <out>/SHA256SUMS over the zips. The architectures in MUST_BUILD (default x86_64) must
# build; another that fails is left out and named in <out>/NOT-BUILT. Needs zig (the version build.zig.zon asks for), zip,
# curl, python3, and 7z for a source with the Mesa fallback.
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

# Mesa's software OpenGL, for a source whose renderer falls back to it when the system's
# OpenGL is too old (pkg/opengl/wgl.zig: GHOSTTY_GL): mmozeiko/build-mesa's llvmpipe
# opengl32.dll, one archive per architecture, pinned in sources.lock as mesa-<arch> (name
# version url sha256:<hex>), fetched once, checked, the DLL left unmodified. mesa <arch>
# prints the archive's path, empty when the source has no fallback.
mesa_fallback=
if [ -f "$src/pkg/opengl/wgl.zig" ] && grep -q GHOSTTY_GL "$src/pkg/opengl/wgl.zig"; then
	mesa_fallback=1
	command -v 7z > /dev/null || { echo "::error::7z is needed to unpack Mesa's opengl32.dll" >&2; exit 1; }
fi
mesa() {
	[ -n "$mesa_fallback" ] || return 0
	local f=$work/mesa-$1-$(pin "mesa-$1" 2).7z
	[ -n "$(pin "mesa-$1" 3)" ] || { echo "::error::sources.lock has no mesa-$1 line" >&2; return 1; }
	[ -f "$f" ] || curl -fsSL --retry 3 -o "$f" "$(pin "mesa-$1" 3)"
	echo "$(pin "mesa-$1" 4 | sed 's/^sha256://')  $f" | sha256sum -c --quiet - ||
		{ echo "::error::$f differs from the SHA-256 in sources.lock" >&2; return 1; }
	echo "$f"
}

# What ghostty.exe's About and What's new show (ci/about.py), passed to windows/build.sh, which
# embeds them; a host that doesn't know them ignores both. What's new: this release's paragraph
# of sources.lock's header (empty for a build of no release). The family line: from the
# about.py of the py-screen commit sources.lock pins, read as Python syntax, never run.
whatsnew=$work/whatsnew.txt
# A test build may be given its own notes (WHATSNEW_TEXT, from the workflow's "whatsnew" input),
# so a build for someone to try shows its What's new; a release's notes are only its paragraph.
if [ -n "${WHATSNEW_TEXT:-}" ]; then
	case $version in *+r[0-9]*)
		echo "::error::WHATSNEW_TEXT is for test builds; a release's notes are its sources.lock paragraph" >&2
		exit 1
		;;
	esac
	printf '%s\n' "$WHATSNEW_TEXT" > "$whatsnew"
else
	python3 -I "$kit/ci/about.py" whatsnew "$kit/sources.lock" "$version" > "$whatsnew"
fi
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
	local arch=$1 name pkg info nu mesa7z
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
		if [ -n "${WHATSNEW_TEXT:-}" ]; then echo "whatsnew: given to this test build"
		elif [ -s "$whatsnew" ]; then echo "whatsnew: r${version##*+r}"; fi
		if [ -n "$family_from" ]; then echo "family: $family_from"; fi
		if [ -n "$mesa_fallback" ]; then echo "opengl fallback: Mesa $(pin "mesa-$arch" 2) llvmpipe (mmozeiko/build-mesa), opengl\\opengl32.dll"; fi
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
	# Mesa's opengl32.dll in opengl\, never beside ghostty.exe (there it would win every load of
	# opengl32.dll by name, the system's too); its notices go after ConPTY's.
	mesa7z=$(mesa "$arch")
	if [ -n "$mesa7z" ]; then
		mkdir -p "$pkg/opengl"
		7z e -y -bd -o"$pkg/opengl" "$mesa7z" opengl32.dll > /dev/null
		[ -s "$pkg/opengl/opengl32.dll" ] || { echo "::error::no opengl32.dll in $mesa7z" >&2; exit 1; }
		[ -f "$pkg/THIRD-PARTY-NOTICES.txt" ] || printf 'Third-party software in this package\n====================================\n' > "$pkg/THIRD-PARTY-NOTICES.txt"
		cat "$kit/ci/THIRD-PARTY-NOTICES-mesa.txt" >> "$pkg/THIRD-PARTY-NOTICES.txt"
	fi
	if [ -f "$work/host-$arch/BUILDINFO.txt" ]; then cp "$work/host-$arch/BUILDINFO.txt" "$pkg/"; fi
	cp "$src/LICENSE" "$pkg/LICENSE"
	sed -e "s/@VERSION@/$version/g" -e "s/@ARCH@/$arch/g" "$kit/ci/README.txt" > "$pkg/README.txt"
	(cd "$work/pkg-$arch" && rm -f "$out/$name.zip" && zip -q -r -X "$out/$name.zip" "$name")
	echo "packaged $out/$name.zip ($(stat -c %s "$out/$name.zip") bytes)"
}

# MUST_BUILD (space-separated, default x86_64) names the architectures a release cannot go out
# without: one of them failing fails the build. Any other architecture is best effort (the
# owner, 2026-11-22: "focus on x64 ... arm break can be fix by next release"): when it fails,
# its zip is left out, it is named in <out>/NOT-BUILT, and the release goes on. The workflow
# sets MUST_BUILD; while x86_64 alone is required it is the release's tested architecture.
must=" ${MUST_BUILD:-x86_64} "
rm -f "$out/NOT-BUILT"
for arch in "$@"; do
	set +e
	(set -e; one "$arch")
	rc=$?
	set -e
	[ $rc = 0 ] && continue
	echo "::endgroup::"
	rm -f "$out/ghostty-$version-windows-$arch.zip"
	if [[ $must == *" $arch "* ]]; then echo "::error::$arch did not build (exit $rc), and MUST_BUILD requires it" >&2; exit $rc; fi
	echo "::warning::$arch did not build (exit $rc): left out of this release" >&2
	echo "$arch" >> "$out/NOT-BUILT"
done
(cd "$out" && sha256sum ghostty-*.zip > SHA256SUMS && cat SHA256SUMS)
