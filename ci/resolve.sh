#!/usr/bin/env bash
# Read sources.lock, fetch the Ghostty fork and say what to build, as KEY=value lines for
# $GITHUB_ENV (or eval in a local run).
#
# Usage: ci/resolve.sh <kit dir> <clone dir> [<ref> <run id>]
#   no <ref>  the pinned build: the ghostty commit from sources.lock, which must still be the
#             tip of its release branch on the fork (a release never moves), with ghostty-base
#             (the upstream commit it sits on) an ancestor of it. Until the first pick there is
#             no ghostty line: then the build is ghostty-base itself, a baseline, never published.
#   <ref>     a test build of another fork branch or commit (e.g. integration-windows before a
#             pick), version <upstream>+ci<run id>.<sha7>; never published
#
# Prints SHA, VERSION, BASE (the upstream commit, "-" when unknown), SRC (the fork's URL),
# REF (what was built) and PINNED (true or false).
set -euo pipefail
kit=$1 clone=$2 ref=${3:-} run=${4:-0}

field() { awk -v n="$1" -v c="$2" '$1 == n { print $c; exit }' "$kit/sources.lock"; }
version=$(field ghostty 2) url=$(field ghostty 3) commit=$(field ghostty 4)
base_branch=$(field ghostty-base 2) base_url=$(field ghostty-base 3) base_commit=$(field ghostty-base 4)
[ -n "$base_commit" ] || { echo "::error::sources.lock has no ghostty-base line" >&2; exit 1; }

fork=https://github.com/congzhangzh/ghostty.git
upstream=${base_url#git+}
upstream=${upstream%%#*}
if [ -n "$commit" ]; then
	src=${url#git+} branch=${src#*#}
	src=${src%%#*}
else
	src=$fork branch=
fi

[ -d "$clone/.git" ] || git init -q "$clone"
g() { git -C "$clone" "$@"; }
g remote get-url origin > /dev/null 2>&1 || g remote add origin "$src"
g remote get-url upstream > /dev/null 2>&1 || g remote add upstream "$upstream"
g fetch -q --filter=blob:none upstream "$base_branch"
g fetch -q --filter=blob:none origin

# The upstream version, from build.zig.zon of a commit (e.g. 1.4.1-dev).
upver() { g show "$1:build.zig.zon" | sed -n 's/^ *\.version = "\(.*\)",/\1/p' | head -1; }

base=$(g rev-parse --verify "$base_commit^{commit}")
if [ -z "$ref" ] && [ -n "$commit" ]; then
	sha=$(g rev-parse --verify "$commit^{commit}")
	tip=$(g rev-parse --verify "origin/$branch^{commit}")
	if [ "$tip" != "$sha" ]; then
		echo "::error::$branch is at ${tip:0:12} on the fork, sources.lock pins ${sha:0:12}; a release must never move" >&2
		exit 1
	fi
	g merge-base --is-ancestor "$base" "$sha" ||
		{ echo "::error::ghostty-base ${base:0:12} is not an ancestor of ${sha:0:12}" >&2; exit 1; }
	pinned=true
elif [ -z "$ref" ]; then
	# no pick yet: build the base as a baseline
	sha=$base version=$(upver "$sha")+base.${sha:0:7} branch=$base_branch src=$upstream
	pinned=false
else
	sha=$(g rev-parse --verify -q "origin/$ref^{commit}" || g rev-parse --verify "$ref^{commit}")
	version=$(upver "$sha")+ci$run.${sha:0:7}
	base=$(g merge-base "$sha" "upstream/$base_branch" || echo -)
	branch=$ref
	pinned=false
fi

printf 'SHA=%s\nVERSION=%s\nBASE=%s\nSRC=%s\nREF=%s\nPINNED=%s\n' \
	"$sha" "$version" "$base" "$src" "$branch" "$pinned"
