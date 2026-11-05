#!/bin/bash
set -euo pipefail
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$SOURCE_DIR/..}"
BUILD_DIR="${SCREENLIGHT_BUILD_DIR:-$SOURCE_DIR/.build}"
APP="$OUTPUT_DIR/屏幕亮度.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/modules"
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE_DIR/Vendor/m1ddc/LICENSE" "$APP/Contents/Resources/m1ddc-LICENSE.txt"
clang -O2 -Wall -Wextra -Werror -fmodules -fmodules-cache-path="$BUILD_DIR/modules" \
  -mmacosx-version-min=14.0 -DMAX_DISPLAYS=16 -I "$SOURCE_DIR/Vendor/m1ddc" -I "$SOURCE_DIR/Sources" \
  "$SOURCE_DIR/Sources/DDCHelper.m" "$SOURCE_DIR/Vendor/m1ddc/ioregistry.m" \
  -framework Foundation -framework IOKit -framework CoreGraphics -framework CoreDisplay \
  -o "$APP/Contents/MacOS/screenlight-ddc"
clang -O2 -Wall -Wextra -Werror -fmodules -fmodules-cache-path="$BUILD_DIR/modules" \
  -mmacosx-version-min=14.0 -DMAX_DISPLAYS=16 -I "$SOURCE_DIR/Vendor/m1ddc" -I "$SOURCE_DIR/Sources" \
  -c "$SOURCE_DIR/Sources/LiveDDC.m" -o "$BUILD_DIR/LiveDDC.o"
clang -O2 -Wall -Wextra -Werror -fmodules -fmodules-cache-path="$BUILD_DIR/modules" \
  -mmacosx-version-min=14.0 -DMAX_DISPLAYS=16 -I "$SOURCE_DIR/Vendor/m1ddc" \
  -c "$SOURCE_DIR/Vendor/m1ddc/ioregistry.m" -o "$BUILD_DIR/ioregistry.o"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 -module-cache-path "$BUILD_DIR/modules" \
  -import-objc-header "$SOURCE_DIR/Sources/LiveDDC.h" "$BUILD_DIR/LiveDDC.o" "$BUILD_DIR/ioregistry.o" \
  "$SOURCE_DIR/Sources/ScreenLight.swift" "$SOURCE_DIR/Sources/PanelPlacement.swift" "$SOURCE_DIR/Sources/SoftwareDimmer.swift" -o "$APP/Contents/MacOS/ScreenLight" \
  -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement \
  -framework IOKit -framework CoreDisplay -framework CoreGraphics
swiftc -module-cache-path "$BUILD_DIR/modules" "$SOURCE_DIR/Sources/MakeIcon.swift" -o "$BUILD_DIR/make-icon"
"$BUILD_DIR/make-icon" "$BUILD_DIR/AppIcon.iconset"
python3 - "$BUILD_DIR/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns" <<'PY'
import pathlib,struct,sys
root=pathlib.Path(sys.argv[1])
types=[(b'icp4','icon_16x16.png'),(b'icp5','icon_32x32.png'),(b'icp6','icon_32x32@2x.png'),
       (b'ic07','icon_128x128.png'),(b'ic08','icon_256x256.png'),
       (b'ic09','icon_512x512.png'),(b'ic10','icon_512x512@2x.png')]
parts=[]
for kind,name in types:
    data=(root/name).read_bytes()
    parts.append(kind+struct.pack('>I',len(data)+8)+data)
body=b''.join(parts)
pathlib.Path(sys.argv[2]).write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
PY
# Synced Documents folders may add FinderInfo when an .app directory appears.
# Remove that build artifact metadata before sealing our own bundle.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/MacOS/screenlight-ddc"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "已构建：$APP"
