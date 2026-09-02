#!/bin/bash
# Monta TokenBar.app sem Xcode: swift build + bundle manual + codesign ad-hoc.
# Uso: ./scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/tokenbar"
APP="build/TokenBar.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/tokenbar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>tokenbar</string>
  <key>CFBundleIdentifier</key><string>app.tokenbar.TokenBar</string>
  <key>CFBundleName</key><string>TokenBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>TokenBar</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# ícone: PNG → iconset → icns (sips + iconutil: presentes no macOS base, sem Xcode)
swift scripts/genicon.swift build/icon-1024.png
mkdir -p build/TokenBar.iconset
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s build/icon-1024.png --out "build/TokenBar.iconset/icon_${s}x${s}.png" >/dev/null
done
iconutil -c icns build/TokenBar.iconset -o "$APP/Contents/Resources/TokenBar.icns"
codesign --force --sign - "$APP"
echo "OK: $APP"
