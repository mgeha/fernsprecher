#!/bin/sh
# Run the app against a built-in fake PBX with invented data (debug build),
# to try it or to take screenshots without an OXO.
#   scripts/demo.sh         -> call log, phone book, forwarding, dialling
#   scripts/demo.sh call    -> also rings an incoming call after a few seconds
# Texts and date formats are English, whatever the system language.
set -eu
cd "$(dirname "$0")/.."
CALL=""
[ "${1:-}" = "call" ] && CALL="--demo-call"
# shellcheck disable=SC2086
exec swift run Fernsprecher --demo $CALL -AppleLanguages "(en)" -AppleLocale en_GB
