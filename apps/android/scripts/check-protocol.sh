#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/scripts/dependencies.py"
mkdir -p "$ROOT/.build/protocol-tests"
javac -encoding UTF-8 -cp "$ROOT/.build/deps/zxing-core-3.5.3.jar" -d "$ROOT/.build/protocol-tests" \
  "$ROOT/src/io/github/weqdevs/remote/Invitation.java" "$ROOT/tests/InvitationTest.java" \
  "$ROOT/src/io/github/weqdevs/remote/WebAccess.java" "$ROOT/tests/WebAccessTest.java" \
  "$ROOT/src/io/github/weqdevs/remote/WebStartup.java" "$ROOT/tests/WebStartupTest.java" \
  "$ROOT/src/io/github/weqdevs/remote/WebDownloadProgress.java" "$ROOT/tests/WebDownloadProgressTest.java" \
  "$ROOT/src/io/github/weqdevs/remote/ConnectionHealth.java" "$ROOT/tests/ConnectionHealthTest.java" \
  "$ROOT/src/io/github/weqdevs/remote/ReleaseVersion.java" "$ROOT/tests/ReleaseVersionTest.java" \
  "$ROOT/src/io/github/weqdevs/remote/ReleaseManifest.java" \
  "$ROOT/src/io/github/weqdevs/remote/UpdateMirrors.java" "$ROOT/tests/UpdateMirrorsTest.java" \
  "$ROOT/src/io/github/weqdevs/remote/ReleaseCatalog.java"
java -cp "$ROOT/.build/protocol-tests:$ROOT/.build/deps/zxing-core-3.5.3.jar" io.github.weqdevs.remote.InvitationTest
java -cp "$ROOT/.build/protocol-tests" io.github.weqdevs.remote.WebAccessTest
java -cp "$ROOT/.build/protocol-tests" io.github.weqdevs.remote.WebStartupTest
java -cp "$ROOT/.build/protocol-tests" io.github.weqdevs.remote.WebDownloadProgressTest
java -cp "$ROOT/.build/protocol-tests" io.github.weqdevs.remote.ConnectionHealthTest
java -cp "$ROOT/.build/protocol-tests" io.github.weqdevs.remote.ReleaseVersionTest
java -cp "$ROOT/.build/protocol-tests" io.github.weqdevs.remote.UpdateMirrorsTest
