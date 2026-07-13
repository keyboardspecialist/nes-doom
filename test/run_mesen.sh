#!/bin/sh
# Headless test run: run_mesen.sh <rom> <lua script>
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
"$MESEN" --testrunner "$1" "$2"
code=$?
echo "mesen exit code: $code"
exit $code
