#!/bin/sh
# Build Fernsprecher.app and pack it for a GitHub release.
#   scripts/build-release.sh        -> build/Fernsprecher-<version>.zip
#                                      build/Fernsprecher-<version>.zip.sha256
set -eu
cd "$(dirname "$0")/.."

# Always rebuild, so the archive matches the source it is released from.
sh scripts/build-app.sh

APP="build/Fernsprecher.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="Fernsprecher-$VERSION.zip"
rm -f "build/$NAME" "build/$NAME.sha256"

# ditto keeps the bundle intact (symlinks, extended attributes), so the code
# signature is still valid after unpacking.
ditto -c -k --keepParent "$APP" "build/$NAME"
# The checksum file names the archive without a path: `shasum -c` then works
# next to the download.
(cd build && shasum -a 256 "$NAME" > "$NAME.sha256")
echo "Built build/$NAME"
cat "build/$NAME.sha256"
