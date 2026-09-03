#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO=$(CDPATH= cd -- "$ROOT/../.." && pwd)
APP="$REPO/build/host-iphoneos/Build/Products/Release-iphoneos/Applesauce.app"

# Packaging modes:
#
#   (default)                   Fully unsigned. AltStore/Sideloadly/Xcode apply
#                               their own signature and entitlements.
#   --trollstore                Fakesign with the TrollStore entitlements.
#                               TrollStore keeps them when it resigns on
#                               install, and get-task-allow is what makes its
#                               "Enable JIT" option appear. Safe on every
#                               TrollStore-capable device.
#   --trollstore-permanent-jit  As above, plus dynamic-codesigning so JIT
#                               survives relaunches. A11 and older ONLY; on
#                               A12+ the app crashes on launch.
MODE=unsigned
OUTPUT=

usage() {
    echo "Usage: $0 [--trollstore | --trollstore-permanent-jit] [output.ipa]"
    echo
    echo "  --trollstore                Fakesign so TrollStore can enable JIT"
    echo "                              per launch."
    echo "  --trollstore-permanent-jit  Also embed dynamic-codesigning"
    echo "                              (A11 and older only)."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --trollstore)
            MODE=trollstore
            ;;
        --trollstore-permanent-jit)
            MODE=permanent
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$OUTPUT" ]; then
                echo "Unexpected extra argument: $1" >&2
                exit 2
            fi
            OUTPUT=$1
            ;;
    esac
    shift
done

case "$MODE" in
    unsigned)
        ENTITLEMENTS=
        DEFAULT_OUTPUT="$REPO/dist/Applesauce-iOS-unsigned.ipa"
        ;;
    trollstore)
        ENTITLEMENTS="$ROOT/Config/TouchHLEHost-TrollStore.entitlements"
        DEFAULT_OUTPUT="$REPO/dist/Applesauce-iOS-trollstore.ipa"
        ;;
    permanent)
        ENTITLEMENTS="$ROOT/Config/TouchHLEHost-TrollStore-PermanentJIT.entitlements"
        DEFAULT_OUTPUT="$REPO/dist/Applesauce-iOS-trollstore-permanent-jit.ipa"
        ;;
esac

[ -n "$OUTPUT" ] || OUTPUT="$DEFAULT_OUTPUT"

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="$PWD/$OUTPUT" ;;
esac

if [ -n "$ENTITLEMENTS" ]; then
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "Missing entitlements file: $ENTITLEMENTS" >&2
        exit 1
    fi
    if ! command -v ldid >/dev/null 2>&1; then
        echo "Fakesigning needs ldid (brew install ldid)." >&2
        exit 1
    fi
fi

if [ "$MODE" = permanent ]; then
    echo "WARNING: dynamic-codesigning is banned on iOS 15+ with A12 and newer" >&2
    echo "         chips (iPhone XS/XR onwards). The app will crash on launch" >&2
    echo "         there. Use --trollstore on those devices." >&2
fi

if [ ! -d "$APP" ]; then
    echo "Unsigned app not found at $APP" >&2
    echo "Run platform/ios/scripts/build-host.sh iphoneos Release first." >&2
    exit 1
fi

if codesign -dv "$APP" >/dev/null 2>&1; then
    echo "Refusing to package a signed app: $APP" >&2
    echo "Rebuild with platform/ios/scripts/build-host.sh iphoneos Release." >&2
    exit 1
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/applesauce-ipa.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

mkdir -p "$STAGE/Payload" "$(dirname -- "$OUTPUT")"
ditto "$APP" "$STAGE/Payload/Applesauce.app"
STRIP_TOOL=$(xcrun --find strip)
"$STRIP_TOOL" -S -x "$STAGE/Payload/Applesauce.app/Applesauce"

if [ -n "$ENTITLEMENTS" ]; then
    ldid "-S$ENTITLEMENTS" "$STAGE/Payload/Applesauce.app/Applesauce"
    echo "Fakesigned with entitlements from $ENTITLEMENTS"

    # build-host.sh builds with CODE_SIGNING_ALLOWED=NO, so Embed-Cores leaves
    # SDL and the core dylibs unsigned. That is correct for the plain IPA --
    # the signer the user runs handles Frameworks itself -- but a fakesigned
    # IPA is meant to install as it stands, and dyld will not load an unsigned
    # dylib into a signed process. Entitlements belong to the executable
    # alone; the libraries only need a signature.
    for library in "$STAGE/Payload/Applesauce.app/Frameworks"/*.dylib; do
        [ -f "$library" ] || continue
        ldid -S "$library"
        echo "Fakesigned $(basename "$library")"
    done
fi

(
    cd "$STAGE"
    /usr/bin/zip -qry "$STAGE/Applesauce.ipa" Payload
)
mv -f "$STAGE/Applesauce.ipa" "$OUTPUT"

if [ -n "$ENTITLEMENTS" ]; then
    echo "Created fakesigned IPA: $OUTPUT"
else
    echo "Created unsigned IPA: $OUTPUT"
fi
CHECKSUM="$OUTPUT.sha256"
(
    cd "$(dirname -- "$OUTPUT")"
    shasum -a 256 "$(basename -- "$OUTPUT")" >"$(basename -- "$CHECKSUM")"
)
cat "$CHECKSUM"
echo "Created checksum: $CHECKSUM"
