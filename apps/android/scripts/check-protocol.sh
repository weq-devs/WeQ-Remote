#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/protocol-tests"
javac -encoding UTF-8 -cp "$ROOT/.build/deps/zxing-core-3.5.3.jar" -d "$ROOT/.build/protocol-tests" \
  "$ROOT/src/io/github/weqdevs/remote/Invitation.java" "$ROOT/tests/InvitationTest.java"
java -cp "$ROOT/.build/protocol-tests:$ROOT/.build/deps/zxing-core-3.5.3.jar" io.github.weqdevs.remote.InvitationTest
