#!/usr/bin/python3
"""Reemplazo de `xcrun xcstringstool compile` para quien no tiene Xcode (solo Command Line Tools).

Uso: xcstrings-to-strings.py Localizable.xcstrings OUT_DIR
Escribe OUT_DIR/<idioma>.lproj/Localizable.strings (plist XML, igual que xcstringstool).
Solo soporta `stringUnit` simples (sin plurales ni variaciones de dispositivo), que es lo que
usa el catálogo del proyecto; si aparece otra cosa, falla en vez de generar mal.
"""
import json
import plistlib
import sys
from pathlib import Path

src, out = Path(sys.argv[1]), Path(sys.argv[2])
catalog = json.loads(src.read_text(encoding="utf-8"))
per_lang: dict[str, dict[str, str]] = {}

for key, entry in catalog["strings"].items():
    for lang, loc in entry.get("localizations", {}).items():
        unit = loc.get("stringUnit")
        if set(loc) != {"stringUnit"} or unit is None:
            sys.exit(f"{key!r} ({lang}): solo se soportan stringUnit simples (usá Xcode: scripts/make-app.sh)")
        per_lang.setdefault(lang, {})[key] = unit["value"]

for lang, strings in per_lang.items():
    d = out / f"{lang}.lproj"
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "Localizable.strings", "wb") as f:
        plistlib.dump(strings, f, fmt=plistlib.FMT_XML, sort_keys=True)
