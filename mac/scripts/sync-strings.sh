#!/bin/bash
# Extrae los textos localizables del código (app, LibreKit, widgets y acciones de Atajos) y los
# agrega a Localization/Localizable.xcstrings. Las traducciones existentes se conservan; las
# claves que ya no están en el código quedan marcadas como "stale".
# Uso: scripts/sync-strings.sh   (requiere Xcode y xcodegen, como make-app.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG=Localization/Localizable.xcstrings
xcodegen --quiet
xcodebuild -project LibreLibreLink.xcodeproj -scheme LibreLibreLink -configuration Release \
    -derivedDataPath .build/xcode build -quiet

[[ -f "$CATALOG" ]] || echo '{"sourceLanguage":"es","strings":{},"version":"1.0"}' > "$CATALOG"
find .build/xcode/Build/Intermediates.noindex -name '*.stringsdata' -print0 \
    | xargs -0 xcrun xcstringstool sync "$CATALOG" --stringsdata
echo "Actualizado: $CATALOG ($(xcrun xcstringstool print "$CATALOG" | grep -c .) líneas)"
