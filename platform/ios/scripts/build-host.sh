#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO=$(CDPATH= cd -- "$ROOT/../.." && pwd)
SDK=${1:-iphonesimulator}
CONFIGURATION=${2:-Release}

case "$SDK" in
    iphonesimulator)
        DESTINATION='generic/platform=iOS Simulator'
        RUST_TARGET='aarch64-apple-ios-sim'
        ;;
    iphoneos)
        DESTINATION='generic/platform=iOS'
        RUST_TARGET='aarch64-apple-ios'
        ;;
    *)
        echo "Usage: $0 [iphonesimulator|iphoneos] [Debug|Release]" >&2
        exit 2
        ;;
esac

case "$CONFIGURATION" in
    Debug|Release)
        ;;
    *)
        echo "Usage: $0 [iphonesimulator|iphoneos] [Debug|Release]" >&2
        exit 2
        ;;
esac

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

# Empty, not inherited: this call always builds this repository's own core.
TOUCHHLE_CORE_REPO= sh "$ROOT/scripts/build-rust.sh" "$RUST_TARGET" "$CONFIGURATION"

# The app ships every core it is built with. TOUCHHLE_CORE_REPO points at a
# checkout of the other core (johnny901901901/touchHLE, branch ios-core-dylib);
# without it the app is built with HyperHLE alone and the core picker hides
# itself.
if [ -n "${TOUCHHLE_CORE_REPO:-}" ]; then
    TOUCHHLE_CORE_REPO="$TOUCHHLE_CORE_REPO" \
        sh "$ROOT/scripts/build-rust.sh" "$RUST_TARGET" "$CONFIGURATION"
fi

# -quiet: without it xcodebuild echoes every compiler invocation, and the few
# thousand lines of that bury the actual diagnostic so deeply that a CI log tail
# contains no "error:" line at all. With it, only warnings and errors are
# printed, so a failing build's output *is* the reason it failed.
xcodebuild \
    -quiet \
    -project "$ROOT/TouchHLEHost.xcodeproj" \
    -scheme TouchHLEHost \
    -configuration "$CONFIGURATION" \
    -sdk "$SDK" \
    -destination "$DESTINATION" \
    -derivedDataPath "$REPO/build/host-$SDK" \
    CODE_SIGNING_ALLOWED=NO \
    build
