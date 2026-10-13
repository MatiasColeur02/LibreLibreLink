# Traspaso — LibreLibreLink (para continuar en una sesión nueva)

Última actualización: 2026-10-12. Metodología: REA (`docs/rea`, skill
`reverse-engineer-anything`). Estado: **ingeniería inversa (Fase 2) COMPLETA;
decisión de rumbo PENDIENTE de confirmar la generación del sensor.**

## 1. Objetivo

App nativa de **macOS** para ver la glucosa del Libre 2 Plus del usuario:
barra de menú con valor + flecha, gráfico/historial y alarmas. El usuario tiene
**iPhone** y está en **Argentina**. Aviso: no reemplaza las alarmas oficiales.

## 2. Resultado decisivo de la RE

- **El sensor habla:** NFC (ISO 15693) para identidad + habilitar streaming, luego
  **BLE** para los datos. La Mac **no tiene NFC**, así que el paso de habilitación
  siempre necesita un dispositivo NFC (iPhone/Android), una vez por sensor.
- **Dos generaciones de seguridad, decididas por `patchInfo[2]`:**
  - **gen1** → el desbloqueo y el descifrado BLE **no** usan caja blanca.
    Reimplementable → **la Mac podría leer casi directo** (tras el enable NFC).
  - **gen2** → usa la caja blanca **WhiteCryption SKB** dentro de
    `libDataProcessing.so` + un token firmado de ~72 B. **No reimplementable**;
    solo se puede usar el binario de Abbott como *oracle* corriendo en Android.
- **Regla (observada en la app):** `g = getSecurityGeneration(patchInfo)` mira solo
  `patchInfo[2]`: nibble alto 3 → gen2 si bajo ≥ 9; nibble alto 7 → gen2 si bajo ≥ 4;
  resto gen1.
- **Señal para Argentina:** reportes comunitarios → Libre 2 Plus argentino
  (serial `3MH0…`) es **gen2** (xDrip directo falla; solo Juggluco/oracle anda).
  **NO confirmado en el sensor del usuario.**

## 2b. Dato del usuario (2026-10-12)

- Serial de los sensores: **`3MH0M1…`**, comprados en Argentina.
- Lectura (área NFC N14): char0 `3` = índice de familia nativo (`getProductFamily`);
  el resto es el UID codificado en base32 → **el serial no contiene `patchInfo[2]`**.
  Indicio fuerte de gen2 (región LA `2B 0A 3A 08` → 0x3A → gen2, más reportes
  comunitarios), pero **no es prueba**. Clasificación de trabajo: **gen2 (I)**.

## 2c. Decisión (2026-10-12): camino A — nube LibreLinkUp

El usuario eligió la nube. Prototipo (Fase 3) en `mac/` (Swift package: `LibreKit`,
`LibreLibreLink` MenuBarExtra, CLI `llu`); ver `mac/README.md`. 7 tests de decodificación
pasan; **falta probar contra la cuenta real** (`swift run llu`). La RE de BLE/NFC
queda archivada (sirve solo si algún día aparece un sensor gen1).
Fase 4 (barra de menú con estado + alarmas) implementada: lógica en
`LibreKit/Status.swift` (17 tests), app empaquetada con `mac/scripts/make-app.sh`.
Modo demo (sin cuenta): `LibreKit/DemoServer.swift` (URLProtocol que imita la API, con
escenarios), `LibreLibreLink --demo` o botón en el login; `llu --demo <escenario>`.
Fase 5 hecha: ventana Hoy/Informes, historial SQLite (`LibreKit/HistoryDatabase.swift`),
estadísticas (`Statistics.swift`), unidades/rango objetivo (`Display.swift`). 32 tests.
i18n: String Catalog `mac/Localization/Localizable.xcstrings` (base es, + en), sigue el idioma
del sistema; flujo en `mac/README.md` (sync-strings.sh → translations_en.py → make-app.sh).
Idea 2 de `docs/IDEAS.md` (alarmas más inteligentes) hecha: bajando rápido, alta sostenida,
umbrales de noche, posponer / «Ya comí» desde la notificación, escalada (`AlarmPolicy`,
`AlarmSnoozes`, `AlarmEngine` en `LibreKit/Status.swift`; tests en `AlarmRulesTests.swift`).
Los Ajustes se mudaron del panel a la ventana (sección "Ajustes", `SettingsView.swift`).
Idea 3 (Mac) hecha salvo el modo mesa de luz: widgets (`mac/Widgets`), acciones de Atajos en
extensión (`mac/Intents`; dentro de la app fallan con firma local), atajos propios en alarmas,
atajo de teclado global y modo discreto. El build pasó a Xcode + xcodegen (`mac/project.yml`).
Paleta real de LibreLink extraída del APK (verde #8FCB3A, etc.) pero el usuario eligió
mantener los colores propios de LibreLibreLink.

## 3. Lo que FALTA para decidir (histórico; ya decidido arriba)

Confirmar `patchInfo[2]` del sensor real. Caminos gratis:
1. **Serial** (en caja o app LibreLink, sin NFC): prefijo `3MH0…` ⇒ muy probable gen2.
2. **Android con NFC** + app libre (Glimp/Juggluco/xDrip) → leer patchInfo y pegarlo.
   Clasificar con la regla de arriba (helper en `ios/.../SensorReader.swift:generation`).
- iPhone: la app `ios/LibrePatchInfo/` lo lee, pero Core NFC exige **cuenta Apple
  Developer de pago (US$99)**. Código listo por si en el futuro hay cuenta.

## 4. Rumbos posibles según el resultado

- **gen1 (mejor caso):** construir `LibreKit` (Swift, macOS+iOS) con el flujo
  NFC-enable (en iPhone, requiere cuenta de pago) + CoreBluetooth en la Mac.
  Protocolo BLE ya mapeado (abajo). Falta recuperar crudo→mg/dL (ver `re/area-native.md`).
- **gen2 (probable en AR) → elegir uno:**
  - **Nube LibreLinkUp (RECOMENDADO):** app de Mac que lee la nube como
    `docs/family-glucose-monitor` (lib `pylibrelinkup`). Simple, no toca el sensor,
    el iPhone sigue con LibreLink. ~1 min de retraso. **No necesita nada de la RE de BLE.**
  - **Puente Android (oracle):** Juggluco en un Android 24/7 (hace el NFC+BLE con los
    binarios de Abbott) → la Mac lee de ahí (broadcast/API local). Complejo, Android dedicado,
    y el streaming deja de ir al iPhone (solo un dispositivo a la vez).

## 5. Datos técnicos clave (para la build directa, si gen1)

- **BLE:** sin escaneo; `connectGatt(autoConnect=false)` a la MAC de 6 bytes que
  devuelve la respuesta NFC de enable-streaming. Servicio `0000fde3-…`, char login
  `f001` (notify+write), datos `f002` (notify), CCCD `2902`. Reconexión inmediata,
  watchdog 120 s. ⚠️ CoreBluetooth oculta la MAC → identificar por nombre/servicio.
- **Lectura:** 3 notificaciones F002 de 20+18+8 = **46 B**, timeout 10 s, ~1/min.
  gen1 pasa los 46 B crudos a `processStream`; gen2 descifra con `gen2Process2` antes.
- **Persistir del enable NFC:** UID, patchInfo, personalizationIndex, enable timestamp,
  unlock count (+1/conexión), dirección BLE (y auth blob si gen2).
- **crudo→mg/dL:** no recuperado del todo (`re/area-native.md`): factor de temperatura
  `base^(32.5-T)·in` y término de calentamiento; falta el resto.

## 6. Artefactos y toolchain

- APK extraído en `work/` (gitignored): `work/apk/base.apk`
  (`35bf1d76…01ce`), `work/native/lib/arm64-v8a/libDataProcessing.so`
  (`5ebf0458…6bc7`), `libSecureKeyBoxJava.so` (`6b08bbbc…8f2a`). Inventario de
  clases en `work/evidence/classes.txt`.
- REA 6.4.0 (MCP en Claude Code, Node 22), Ghidra 12.1.4 con decompilador
  `mac_arm_64` compilado (`~/tools/ghidra_12.1.4_PUBLIC`), JADX 0.7.1
  (`~/tools/jadx/`). Shell default node = v20 (viejo) → `nvm use 22`.
- Informes por área: `re/area-nfc.md`, `re/area-ble.md`, `re/area-native.md`,
  `re/area-ui.md`. Registro: `re/findings.md`. Plan: `PLAN.md`.
- `re/tools/Dec.java`: decompila el APK completo con JADX (lo generó el área B).

## 7. Primer paso de la próxima sesión

Pedir al usuario el `patchInfo` (o el prefijo del serial). Clasificar gen1/gen2.
Luego elegir rumbo de la sección 4 y arrancar Fase 3+ (prototipo/registro de
reconstrucción/app). Requisitos de UI (R1–R27) en `re/area-ui.md`.
