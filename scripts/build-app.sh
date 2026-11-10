#!/bin/sh
# Build Fernsprecher.app (universal, ad-hoc signed) with only the Command Line Tools.
#   scripts/build-app.sh            -> build/Fernsprecher.app
set -eu
cd "$(dirname "$0")/.."

ARCHS="arm64 x86_64"
APP="build/Fernsprecher.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Build all architectures in parallel. Release builds use whole-module
# optimization, which runs one frontend per module; -num-threads lets its
# LLVM codegen use every core.
JOBS=$(sysctl -n hw.ncpu)
PIDS=""
for ARCH in $ARCHS; do
    swift build -c release --product Fernsprecher --triple "$ARCH-apple-macosx14.0" \
        --scratch-path ".build/$ARCH" -j "$JOBS" -Xswiftc -num-threads -Xswiftc "$JOBS" &
    PIDS="$PIDS $!"
done
for PID in $PIDS; do
    wait "$PID"
done

# The binaries as arguments, so that a path with spaces stays in one piece.
set --
for ARCH in $ARCHS; do
    set -- "$@" "$(swift build -c release --product Fernsprecher \
        --triple "$ARCH-apple-macosx14.0" --scratch-path ".build/$ARCH" --show-bin-path)/Fernsprecher"
done
lipo -create "$@" -output "$APP/Contents/MacOS/Fernsprecher"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Fernsprecher.icns "$APP/Contents/Resources/"
# Translations; English is the development language (keys in the source).
cp -R Resources/*.lproj "$APP/Contents/Resources/"
for LOCALIZATION in en de; do
    if [ ! -f "$APP/Contents/Resources/$LOCALIZATION.lproj/Localizable.strings" ]; then
        echo "error: $LOCALIZATION.lproj missing in $APP" >&2
        exit 1
    fi
done
plutil -lint -s "$APP"/Contents/Resources/*.lproj/*.strings
# Build number = build date, so builds of the same version can be told apart.
BUILD=$(date +%Y%m%d)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

# Ad-hoc signature: Apple Silicon does not run unsigned code. Without a
# Developer ID there is no identity that other Macs would trust.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"
echo "Built $APP ($VERSION ($BUILD), $(lipo -archs "$APP/Contents/MacOS/Fernsprecher"))"
