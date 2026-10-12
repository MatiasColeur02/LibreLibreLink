#!/bin/bash
# Compila LibreLibreLink en release y arma dist/LibreLibreLink.app (firma ad-hoc).
# Uso: scripts/make-app.sh [--install]   (--install la copia a ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product LibreLibreLink
BIN="$(swift build -c release --show-bin-path)/LibreLibreLink"

APP=dist/LibreLibreLink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/LibreLibreLink"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.librelibrelink.LibreLibreLink</string>
    <key>CFBundleName</key><string>LibreLibreLink</string>
    <key>CFBundleExecutable</key><string>LibreLibreLink</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>No reemplaza las alarmas oficiales de LibreLink.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/LibreLibreLink.app
    cp -R "$APP" ~/Applications/
    echo "Instalada en ~/Applications/LibreLibreLink.app"
fi
