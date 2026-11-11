#!/bin/sh
# Copies libghostty-vt's static library from a Ghostty checkout into
# ngam/lib and removes Zig's compiler runtime (compiler_rt.o). Odin's runtime
# defines some of the same helpers (__udivti3 and others), so linking both
# fails with duplicate symbols. libSystem (or libc) and Odin's runtime
# provide everything else compiler_rt.o has, and ghostty/ghostty.odin
# defines the two f128 conversions that only Zig's debug printing uses.
#
# ngam is tested against one Ghostty commit, the one in ngam/ghostty.commit,
# so this accepts only a checkout of that commit, with its tracked files
# unchanged and its library built after the commit was checked out. Set
# NGAM_GHOSTTY_UNPINNED=1 to copy any checkout. It records the copy's source in
# ngam/lib/libghostty-vt.source, which ngam/build.sh checks.
#
# Usage: ngam/ghostty-lib.sh [ghostty checkout]   (default: ../ghostty)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ghostty=${1:-${NGAM_GHOSTTY:-$here/../../ghostty}}
src=$ghostty/zig-out/lib/libghostty-vt.a
pin=$(cat "$here/ghostty.commit")
build_cmd="cd $ghostty && zig build -Demit-lib-vt -Doptimize=ReleaseFast"

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

head=$(git -C "$ghostty" rev-parse HEAD 2>/dev/null) || {
	echo "$ghostty is not a Ghostty git checkout" >&2
	exit 1
}
if [ "${NGAM_GHOSTTY_UNPINNED:-}" != 1 ]; then
	if [ "$head" != "$pin" ]; then
		echo "$ghostty is at $head, but ngam is pinned to $pin. Check that out and rebuild:" >&2
		echo "  git -C $ghostty checkout $pin && $build_cmd" >&2
		echo "(or set NGAM_GHOSTTY_UNPINNED=1 to use it anyway)" >&2
		exit 1
	fi
	if [ -n "$(git -C "$ghostty" status --porcelain --untracked-files=no)" ]; then
		echo "$ghostty has local changes, so its library is not the pinned one" >&2
		echo "(set NGAM_GHOSTTY_UNPINNED=1 to use it anyway)" >&2
		exit 1
	fi
fi
if [ ! -f "$src" ]; then
	echo "no $src; build it first:" >&2
	echo "  $build_cmd" >&2
	exit 1
fi
# The reflog says when HEAD last moved. A library older than that was
# built from the code checked out before.
moved=$(git -C "$ghostty" log -g -1 --format=%ct HEAD 2>/dev/null || echo 0)
if [ "${NGAM_GHOSTTY_UNPINNED:-}" != 1 ] && [ "$(mtime "$src")" -lt "$moved" ]; then
	echo "$src was built before $head was checked out; rebuild it:" >&2
	echo "  $build_cmd" >&2
	exit 1
fi

mkdir -p "$here/lib"
cp "$src" "$here/lib/libghostty-vt.a"
chmod u+w "$here/lib/libghostty-vt.a"
ar d "$here/lib/libghostty-vt.a" compiler_rt.o
ranlib "$here/lib/libghostty-vt.a"
printf 'commit %s\nsha256 %s\n' "$head" "$(sha256 "$src")" >"$here/lib/libghostty-vt.source"
echo "wrote $here/lib/libghostty-vt.a (Ghostty $head)"
