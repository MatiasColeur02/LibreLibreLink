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
3. **Prototipo** — app iOS mínima (Core NFC) + CLI macOS (CoreBluetooth) que registra
   paquetes; comparar contra LibreLink. Decidir convivencia teléfono ↔ Mac.
4. **Registro de reconstrucción** — cada pieza con módulo responsable, fixtures
   anonimizados y test verificador (`build_reconstruction_obligation_ledger`).
5. **App** — `LibreKit` (Swift package compartido macOS/iOS), MenuBarExtra,
   Swift Charts, SwiftData, notificaciones, reconexión.
6. **Verificación** — tests + días de comparación con LibreLink. Lo no verificado
   queda marcado como pendiente.

⚠️ No reemplaza las alarmas oficiales; no usar para decidir dosis antes de la Fase 6.
