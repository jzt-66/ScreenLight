#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCREENLIGHT_BUILD_DIR:-$SOURCE_DIR/.build}"
APP="${1:-$SOURCE_DIR/../屏幕亮度.app}"
mkdir -p "$BUILD_DIR"
clang -Wall -Wextra -Werror -fsanitize=address,undefined -g -I "$SOURCE_DIR/Sources" \
  "$SOURCE_DIR/Tests/DDCPacketTests.c" -o "$BUILD_DIR/packet-tests"
"$BUILD_DIR/packet-tests"
swiftc -module-cache-path "$BUILD_DIR/modules" "$SOURCE_DIR/Sources/PanelPlacement.swift" \
  "$SOURCE_DIR/Tests/PanelPlacementTests.swift" -o "$BUILD_DIR/placement-tests"
"$BUILD_DIR/placement-tests"
python3 - "$APP/Contents/MacOS/screenlight-ddc" <<'PY'
import json,subprocess,sys
for args in [[], ['set','x','-1'], ['set','x','101'], ['set','x','nan'],
             ['set','x','inf'], ['set','x',''], ['set','x','30abc'], ['set','x'],
             ['read'], ['list','extra'], ['unknown']]:
    p=subprocess.run([sys.argv[1],*args],text=True,capture_output=True,timeout=3)
    assert p.returncode==2, (args,p.returncode,p.stdout)
    assert json.loads(p.stdout)['ok'] is False
print('11 invalid CLI inputs rejected before accessing hardware.')
PY
