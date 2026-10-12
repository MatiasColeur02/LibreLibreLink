# Plan — LibreLibreLink (macOS, Libre 2 Plus por BLE)

Metodología: REA (`docs/rea`, skill `reverse-engineer-anything`). Cada hallazgo
separa **observado / inferido / desconocido** y cita Evidence IDs.

## Contexto

- Sensor: FreeStyle Libre 2 Plus (15 días). Teléfono: iPhone (paso NFC).
- Objetivo: app macOS con barra de menú en vivo, gráfico/historial y alarmas,
  leyendo el sensor directo por Bluetooth (CoreBluetooth).
- Fuentes: `docs/FreeStyle LibreLink ES 2.13.1.apkm`, `docs/guia-de-usuario.pdf`,
  `docs/family-glucose-monitor` (referencia de la API en la nube).

## Artefactos (ignorados por git en `work/`)

| Archivo | SHA-256 |
| --- | --- |
| `work/apk/base.apk` | `35bf1d76bcf2ebbea7f24cbcf41059c21cd8dd4911a5aaa5df5ee6cd76d901ce` |
| `work/apk/split_config.arm64_v8a.apk` | `1a207fb7dcc91e1a75d6c53ec1718226ea571c0a1171eeaac27fd310551544d9` |
| `work/native/lib/arm64-v8a/*.so` | `libDataProcessing.so`, `libSecureKeyBoxJava.so`, `libsas.so`, ... |

## Fases

0. **Herramientas** ✅ — REA 6.4.0 (MCP en Claude Code), JADX headless 0.7.1,
   Ghidra 12.1.4 con decompilador `mac_arm_64` compilado, Node 22, JDK 21.
1. **Checklist + inventario** — manifiesto/permisos (`inspect_android_package`),
   clases NFC/BLE/sensor (`search_android_classes`), requisitos de la guía.
2. **Investigación en paralelo** (agentes Sonnet 5.5, esfuerzo alto):
   - A. NFC: lectura de `patchInfo`, comando de habilitación BLE → generación del sensor.
   - B. BLE: servicios/UUIDs, autenticación, formato de paquetes, descifrado.
   - C. Nativo (Ghidra): `libDataProcessing.so` (crudo → mg/dL, tendencia), crypto.
   - D. Lógica/UI: alarmas, rangos, textos.
   Resultado: `re/findings.md`.
   **Punto de decisión:** según la generación del sensor, seguir / cambiar alcance / nube.
   **Decisión (2026-10-12):** serial `3MH0M1…` (Argentina) → gen2 inferido → **camino A:
   nube LibreLinkUp**. La RE de NFC/BLE queda archivada (`re/`).
3. **Prototipo (nube)** ✅ — `mac/`: `LibreKit` (cliente LibreLinkUp) + `LibreLibreLink`
   (MenuBarExtra) + CLI `llu`. Pendiente: probar con la cuenta real.
4. **Barra de menú con estado y alarmas** ✅ (código; falta probar con datos reales) — el ícono de arriba a la derecha muestra
   la medición actual y, si hay un problema, lo señala sin abrir nada:
   - Valor + flecha (`123 ↗`); `LO` < 40 y `HI` > 500 (R2).
   - Estados con ícono y color (solo cuando hay problema; en normal, monocromo):
     glucosa **muy baja** (< 55, baja grave fija), **baja** (< umbral, def. 70),
     **alta** (> umbral, def. 240), **sin señal del sensor** (sin lectura nueva
     ≥ 20 min: el iPhone no sube datos), **sin conexión con LibreLinkUp**
     (falla la red/API), **lectura vieja** (≥ 10 min), **hay que iniciar sesión /
     aceptar términos**.
   - El panel lista los problemas activos y su explicación; el sensor muestra días
     restantes (de `connection.sensor.a`, 15 días asumidos).
   - Notificaciones de macOS (R9–R13): desactivadas por defecto; una por episodio,
     se repite cada 5 min mientras persiste; señal perdida a los 20 min.
   - Ajustes en el panel: umbrales (baja 60–100 paso 5, alta 120–400 paso 10),
     activar alarmas, abrir al iniciar sesión.
   - Empaquetado como `LibreLibreLink.app` (`mac/scripts/make-app.sh`): sin ícono en el
     Dock, necesario para notificaciones y arranque automático (R16).
   - Lógica de estado y de episodios en `LibreKit` con tests.
5. **App completa** ✅ (código; probado con el modo demo) — ventana "Hoy" + "Informes":
   historial persistente (SQLite en lugar de SwiftData: más simple y testeable),
   tiempo en rango, promedio, GMI, CV, uso del sensor, episodios de baja, patrones
   diarios (R24), mmol/L (R20), rango objetivo (R21). Colores: los del panel de LibreLibreLink.
   Modo demo (`--demo`) con escenarios para probar sin cuenta.
6. **Verificación** — tests + días de comparación con LibreLink. Lo no verificado
   queda marcado como pendiente.

Archivado (solo si apareciera un sensor gen1): prototipo NFC/BLE y registro de
reconstrucción (`build_reconstruction_obligation_ledger`).

⚠️ No reemplaza las alarmas oficiales; no usar para decidir dosis antes de la Fase 6.
