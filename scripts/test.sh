#!/bin/sh
# Run the tests with only the Command Line Tools installed.
# The CLT ship Swift Testing's macro plugin in plugins/testing/, which the
# default SwiftPM build system does not search; pass the path explicitly.
set -eu
cd "$(dirname "$0")/.."
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
exec swift test --scratch-path ".build/test" -j "$(sysctl -n hw.ncpu)" -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
