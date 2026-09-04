#!/bin/sh
set -eu

# Replaces oaknut's code_block.hpp in every dynarmic checkout given, with the
# copy in platform/ios/patches -- but only where that is the right thing to do.
#
# It is a file copy rather than a commit because dynarmic is a submodule of
# johnny901901901/dynarmic, which this repository cannot push to, and because
# the second emulator core is a separate checkout with its own dynarmic. Neither
# survives the next `git submodule update`.
#
# The two cores do not use the same oaknut, and only one of them has the
# problem this patch fixes:
#
#   HyperHLE (this repository) builds johnny901901901/dynarmic, whose oaknut
#   reaches JIT memory by executing `brk #0xf00d` and waiting for a debugger to
#   answer. StikDebug answers; TrollStore's "Enable JIT" does not, and the
#   unhandled trap kills the process the moment a game starts.
#
#   touchHLE (johnny901901901/touchHLE, branch ios-core-dylib) builds
#   touchHLE/dynarmic, whose oaknut is upstream: it mmaps PROT_READ|PROT_EXEC
#   and flips between writable and executable with mprotect. That works under
#   CS_DEBUGGED, so TrollStore was never broken there -- and replacing it would
#   break it, because that dynarmic needs protect()/unprotect() to really call
#   mprotect, while the JIT-server version leaves them as no-ops.
#
# So a checkout that is oaknut but not the JIT-server one is skipped, not
# patched and not treated as an error. Passing it in anyway is deliberate: if
# its submodule pin ever moves to a JIT-server oaknut, this starts patching it
# without anyone having to notice.
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

patched_any=0

for dynarmic in "$@"; do
    target="$dynarmic/$RELATIVE_PATH"

    if [ ! -f "$target" ]; then
        echo "error: no oaknut code block at $target" >&2
        echo "       Check the path, and that submodules were checked out." >&2
        exit 1
    fi

    if ! grep -q 'namespace oaknut' "$target"; then
        echo "error: $target does not look like oaknut at all." >&2
        exit 1
    fi

    if ! grep -q '0xf00d' "$target"; then
        echo "Skipped $target (upstream oaknut; mprotect route already works)"
        continue
    fi

    cp -f "$REPLACEMENT" "$target"
    echo "Patched $target"
    patched_any=1
done

# The whole point is HyperHLE's core. If nothing matched, its submodule pin has
# moved and the replacement no longer applies to anything -- which would ship a
# build that dies on TrollStore exactly as before, with nothing in the log to
# say why.
if [ "$patched_any" = 0 ]; then
    echo "error: none of the checkouts given use the JIT-server oaknut." >&2
    echo "       Re-check platform/ios/patches/oaknut-code_block.hpp against them." >&2
    exit 1
fi
