#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/self-tests" "$ROOT/.build/caches/clang"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/caches/clang"
swiftc -swift-version 5 -parse-as-library \
  "$ROOT/Sources/CellDock/AppLanguage.swift" \
  "$ROOT/Sources/CellDock/AppIdentityMigration.swift" \
  "$ROOT/Sources/CellDock/CellularModuleID.swift" \
  "$ROOT/Sources/CellDock/CallModels.swift" \
  "$ROOT/Sources/CellDock/CallRecordingStore.swift" \
  "$ROOT/Sources/CellDock/WeComWebhook.swift" \
  "$ROOT/Sources/CellDock/CallASRClient.swift" \
  "$ROOT"/Sources/CellDock/CallTranscription*.swift \
  "$ROOT/Tests/CallTranscriptionSelfTests/main.swift" \
  -o "$ROOT/.build/self-tests/CallTranscriptionSelfTests"
"$ROOT/.build/self-tests/CallTranscriptionSelfTests"
