#!/bin/bash
# Extrae los textos localizables del código (como hace Xcode) y los agrega a
# Localization/Localizable.xcstrings. Las traducciones existentes se conservan;
# las claves que ya no están en el código quedan marcadas como "stale".
# Uso: scripts/sync-strings.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG=Localization/Localizable.xcstrings
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Build aparte (scratch propio) para que compile todos los archivos y emita todo.
swift build --scratch-path "$OUT/build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT/strings" >/dev/null

[[ -f "$CATALOG" ]] || echo '{"sourceLanguage":"es","strings":{},"version":"1.0"}' > "$CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$OUT"/strings/*.stringsdata
echo "Actualizado: $CATALOG ($(xcrun xcstringstool print "$CATALOG" | grep -c .) líneas)"
