#!/bin/bash
# Compila LibreLibreLink.app con sus widgets y acciones de Atajos (Xcode, firma local) y la
# deja en dist/. Requiere Xcode (no alcanzan las Command Line Tools) y xcodegen
# (`brew install xcodegen`), que genera el proyecto desde project.yml.
# Uso: scripts/make-app.sh [--install]   (--install la copia a ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen --quiet
xcodebuild -project LibreLibreLink.xcodeproj -scheme LibreLibreLink -configuration Release \
    -derivedDataPath .build/xcode build -quiet

APP=dist/LibreLibreLink.app
rm -rf "$APP"
mkdir -p dist
cp -R .build/xcode/Build/Products/Release/LibreLibreLink.app "$APP"
# Que macOS no use la copia intermedia de Xcode para las URLs librelibrelink:// ni los widgets.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$LSREGISTER -u .build/xcode/Build/Products/Release/LibreLibreLink.app 2>/dev/null || true
echo "Listo: $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/LibreLibreLink.app
    cp -R "$APP" ~/Applications/
    # Que macOS registre la versión nueva de los widgets y las acciones de Atajos.
    $LSREGISTER -f -R ~/Applications/LibreLibreLink.app
    echo "Instalada en ~/Applications/LibreLibreLink.app"
fi
