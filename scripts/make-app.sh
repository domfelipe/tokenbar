#!/bin/bash
# Monta TokenBar.app sem Xcode: swift build + bundle manual + codesign ad-hoc.
# Uso: ./scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
# Versão do app estampada no Info.plist (scripts/release.sh e o job de
# release do CI passam TOKENBAR_VERSION da tag; default = release corrente).
VERSION="${TOKENBAR_VERSION:-1.0.0}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/tokenbar"
APP="build/TokenBar.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/tokenbar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>tokenbar</string>
  <key>CFBundleIdentifier</key><string>app.tokenbar.TokenBar</string>
  <key>CFBundleName</key><string>TokenBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
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
# resources dos targets (SPM .copy("Resources")): sem eles, Bundle.module via
# LaunchServices (`open`) pendura a main thread em NSBundle URLForResource —
# copiar TODOS os *.bundle ANTES do codesign (o selo precisa cobri-los).
for b in ".build/$CONFIG/"*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "$APP/Contents/Resources/"
done
# smoke check: os 3 bundles esperados precisam estar no .app (fail loud).
for b in GRDB_GRDB TokenBar_TokenBarCore TokenBar_TokenBarUI; do
  if [ ! -d "$APP/Contents/Resources/$b.bundle" ]; then
    echo "ERRO: $b.bundle ausente em $APP/Contents/Resources (hang do Bundle.module via open)" >&2
    exit 1
  fi
done
codesign --force --sign - "$APP"
echo "OK: $APP"
