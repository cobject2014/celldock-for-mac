#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
swift run --disable-sandbox CellDockBackupSelfTests
swift run --disable-sandbox CellDockBackupSelfTests --large-archive 128
swift build --disable-sandbox -Xswiftc -disable-sandbox --product CellDock
"$(swift build --disable-sandbox --show-bin-path)/CellDock" --backup-model-self-test
