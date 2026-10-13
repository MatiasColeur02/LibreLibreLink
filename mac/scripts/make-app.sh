#!/bin/bash
# Compila LibreLibreLink.app con sus widgets y acciones de Atajos (Xcode, firma local) y la
# deja en dist/. Requiere Xcode (no alcanzan las Command Line Tools) y xcodegen
# (`brew install xcodegen`), que genera el proyecto desde project.yml.
# Uso: scripts/make-app.sh [--install]   (--install la copia a ~/Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Falta xcodegen. Instalalo con:  brew install xcodegen" >&2
    echo "(si no tenés Homebrew: https://brew.sh)" >&2
    echo "O, sin Xcode (sin widgets ni Atajos):  scripts/make-app-lite.sh ${1:-}" >&2
    exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Falta Xcode completo (no alcanzan las Command Line Tools)." >&2
    echo "Instalalo desde la App Store y después:  sudo xcode-select -s /Applications/Xcode.app" >&2
    echo "O, sin Xcode (sin widgets ni Atajos):  scripts/make-app-lite.sh ${1:-}" >&2
    exit 1
fi

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
