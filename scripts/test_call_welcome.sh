#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/self-tests" "$ROOT/.build/caches/clang"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/caches/clang"
swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Sources/CellDock/AppLanguage.swift" \
  "$ROOT/Sources/CellDock/AppIdentityMigration.swift" \
  "$ROOT"/Sources/CellDock/CallWelcome*.swift \
  "$ROOT/Sources/CellDock/CallTTSClient.swift" \
  "$ROOT/Tests/CallWelcomeSelfTests/main.swift" \
  -o "$ROOT/.build/self-tests/CallWelcomeSelfTests"
fixture_port=$(mktemp /tmp/CellDock-TTS-port.XXXXXX)
python3 "$ROOT/Tests/CallWelcomeSelfTests/tts_fixture.py" "$fixture_port" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true; rm -f "$fixture_port"' EXIT
for attempt in {1..100}; do
  [[ -s "$fixture_port" ]] && break
  sleep 0.05
done
[[ -s "$fixture_port" ]]
WELCOME_TTS_TEST_URL="http://127.0.0.1:$(cat "$fixture_port")" "$ROOT/.build/self-tests/CallWelcomeSelfTests"
