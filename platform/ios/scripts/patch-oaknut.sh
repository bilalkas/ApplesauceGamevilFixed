#!/bin/sh
set -eu

# Replaces oaknut's code_block.hpp in every dynarmic checkout given, with the
# copy in platform/ios/patches.
#
# It is a file copy rather than a commit because dynarmic is a submodule of
# johnny901901901/dynarmic, which this repository cannot push to, and because
# the second emulator core is a separate checkout that brings its own copy of
# the same submodule. Both have to be patched, and neither survives the next
# `git submodule update`.
#
# Usage: patch-oaknut.sh <dynarmic-dir> [<dynarmic-dir> ...]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPLACEMENT="$ROOT/patches/oaknut-code_block.hpp"
RELATIVE_PATH=externals/oaknut/include/oaknut/code_block.hpp

if [ $# -eq 0 ]; then
    echo "Usage: $0 <dynarmic-dir> [<dynarmic-dir> ...]" >&2
    exit 2
fi

if [ ! -f "$REPLACEMENT" ]; then
    echo "error: no replacement header at $REPLACEMENT" >&2
    exit 1
fi

for dynarmic in "$@"; do
    target="$dynarmic/$RELATIVE_PATH"

    if [ ! -f "$target" ]; then
        echo "error: no oaknut code block at $target" >&2
        echo "       Check the path, and that submodules were checked out." >&2
        exit 1
    fi

    # Only the JIT-server fork of oaknut contains this breakpoint; upstream's
    # iOS path is a plain mmap. If it is gone, the fork has moved on and
    # overwriting the file would undo whatever replaced it -- so stop, loudly,
    # rather than ship a silently reverted core.
    if ! grep -q '0xf00d' "$target"; then
        echo "error: $target is not the JIT-server oaknut this patch is for." >&2
        echo "       Re-check the replacement against it before building." >&2
        exit 1
    fi

    cp -f "$REPLACEMENT" "$target"
    echo "Patched $target"
done
