#!/bin/bash
# Run the pure-logic tests. Compiles the app's real Organise.swift (Foundation-only)
# together with the test file, so the tests exercise the shipping code.
#
# Usage: Tests/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)/ml-logic-tests"
swiftc "$here/../MusicLibrarian/Organise.swift" "$here/../MusicLibrarian/Normalize.swift" "$here/OrganiseLogicTests.swift" -o "$out"
"$out"
