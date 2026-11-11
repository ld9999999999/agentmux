#!/bin/sh
# Builds ngam into ngam/bin/ngam. First it checks that ngam/lib holds the
# current build of the pinned Ghostty commit (ngam/ghostty.commit): the
# copy that ghostty-lib.sh made, which still matches the library in
# zig-out. If a check fails, it says what to run. Set
# NGAM_GHOSTTY_UNPINNED=1 to skip the checks, for example to link another
# copy with
# -define:GHOSTTY_LIB=<path relative to ngam/>.
#
# Usage: ngam/build.sh [odin build options...]   (Ghostty: $NGAM_GHOSTTY,
#                                                  default ../ghostty)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
ghostty=${NGAM_GHOSTTY:-$here/../../ghostty}
lib=$here/lib/libghostty-vt.a
src=$ghostty/zig-out/lib/libghostty-vt.a
pin=$(cat "$here/ghostty.commit")

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
refresh() {
	echo "$1; run:" >&2
	echo "  $here/ghostty-lib.sh${NGAM_GHOSTTY:+ $NGAM_GHOSTTY}" >&2
	exit 1
}

if [ "${NGAM_GHOSTTY_UNPINNED:-}" != 1 ]; then
	[ -f "$lib" ] && [ -f "$here/lib/libghostty-vt.source" ] ||
		refresh "ngam/lib has no libghostty-vt from ghostty-lib.sh"
	commit=$(sed -n 's/^commit //p' "$here/lib/libghostty-vt.source")
	sum=$(sed -n 's/^sha256 //p' "$here/lib/libghostty-vt.source")
	[ "$commit" = "$pin" ] || refresh "ngam/lib's libghostty-vt is from Ghostty $commit, not the pinned $pin"
	[ -f "$src" ] || {
		echo "no $src to check ngam/lib's copy against (set NGAM_GHOSTTY to the checkout)" >&2
		exit 1
	}
	[ "$(sha256 "$src")" = "$sum" ] || refresh "$src has changed since ngam/lib's copy was made"
fi
mkdir -p "$here/bin"
exec odin build "$here" -out:"$here/bin/ngam" -vet "$@"
