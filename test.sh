#!/bin/bash
# Логика без GUI: swiftc собирает тестовый бинарник и запускает его.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$DIR/.build"
swiftc -O -o "$DIR/.build/tests" \
  "$DIR/src/SpendLogic.swift" "$DIR/src/Config.swift" "$DIR/src/KeyStore.swift" "$DIR/tests/main.swift"
"$DIR/.build/tests"
