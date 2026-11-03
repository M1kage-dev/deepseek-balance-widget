#!/bin/bash
# Собирает universal (arm64 + x86_64) .app в dist/DeepSeek Balance.app
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DeepSeek Balance"
APP="$DIR/dist/$APP_NAME.app"
BUNDLE_ID="io.github.mikage777.deepseekbalance"
VERSION="1.0.0"

command -v swiftc >/dev/null 2>&1 || { echo "swiftc not found — run: xcode-select --install" >&2; exit 1; }

mkdir -p "$DIR/.build" "$DIR/dist"
SOURCES=("$DIR"/src/*.swift)

echo "→ compiling arm64"
swiftc -O -target arm64-apple-macos13.0 -o "$DIR/.build/app-arm64" "${SOURCES[@]}"
echo "→ compiling x86_64"
swiftc -O -target x86_64-apple-macos13.0 -o "$DIR/.build/app-x86_64" "${SOURCES[@]}"
lipo -create "$DIR/.build/app-arm64" "$DIR/.build/app-x86_64" -o "$DIR/.build/DeepSeekBalance"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/.build/DeepSeekBalance" "$APP/Contents/MacOS/DeepSeekBalance"
cp "$DIR/src/widget.html" "$APP/Contents/Resources/widget.html"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>DeepSeekBalance</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. Not affiliated with DeepSeek.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "built: $APP"
