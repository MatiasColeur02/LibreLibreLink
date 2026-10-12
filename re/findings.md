# Registro de hallazgos — LibreLink ES 2.13.1

Convención: cada fila indica **O** (observado), **D** (derivado), **I** (inferido) o
**?** (desconocido), con Evidence IDs de REA. Los informes detallados por área están
en `re/area-*.md`.

## Artefactos

| Artefacto | SHA-256 |
| --- | --- |
| `work/apk/base.apk` (`com.freestylelibre.app.es` 2.13.1, vc 11596, minSdk 26, targetSdk 35) | `35bf1d76…01ce` |
| `work/apk/split_config.arm64_v8a.apk` | `1a207fb7…44d9` |
| `work/native/lib/arm64-v8a/libDataProcessing.so` | ver `re/area-native.md` |

## Fase 1 — inventario (Evidence)

- `ev_3ef462db…fec7c` inspect_android_package: permisos NFC, BLUETOOTH(_CONNECT/_ADMIN),
  FOREGROUND_SERVICE_CONNECTED_DEVICE, SCHEDULE_EXACT_ALARM, POST_NOTIFICATIONS. **O**
- `ev_1152260a…e8cf` search_android_classes "": 10.586 clases, ~3.091 ofuscadas. **O**
- `ev_7c83cb37…f92d` `DataProcessingNative`: JNI con `getEnableStreamingPayload`,
  `getStreamingUnlockPayload`, `gen2Process1/2`, `P1/P2`, `getDecryptedNorthStarPayload`,
  `getEncryptedNorthStarPayload`, `processStream`, `processScan`, `getProductFamily`,
  `isPatchSupported`, `getActivationPayload`; métodos `$sas$*` (protección `libsas.so`). **O**
- `ev_a9d941e5…6007a` `Gen2SecurityNativeInterface`: `gen2Process1/2(int,int,byte[],byte[])`. **O**
- `ev_a78d0876…71366` `AlarmBLEService`: servicio; lógica BLE en clases ofuscadas (`i6`, `j6`). **O**
- Paquetes relevantes: `com.abbottdiabetescare.flashglucose.sensorabstractionservice`
  (`rf.DefaultNfcRfModule[Gen2]`, `gen2security.*`, `dataprocessing.*`, `database.*`),
  `com.whitecryption.skb` (79 clases, criptografía de caja blanca), `com.librelink.app`. **O**

## Checklist (Fase 2)

| # | Pregunta | Área | Estado |
| --- | --- | --- | --- |
| Q1 | ¿Cómo se lee `patchInfo` por NFC y cómo distingue la app Libre 2 / 2 Plus / Gen2? | NFC | **respondida** (`re/area-nfc.md`) |
| Q2 | ¿Qué comando y payload NFC habilitan el streaming BLE? | NFC | parcial (payload gen1 es nativo) |

## Fase 2 — Área A (NFC) — resuelta (`re/area-nfc.md`, 35 filas)

- **La generación se decide por sensor con `getSecurityGeneration(patchInfo)` leyendo SOLO `patchInfo[2]`** (`ev_4e3517698b…`). Nibble alto 3 → gen2 si bajo ≥ 9; nibble alto 7 → gen2 si bajo ≥ 4; resto gen1. **O**
- `assets/config/ES_bld_cfg.json`: `ProductType3="0,1,2,5,6,7,9,A,B"`, type-7 hard-coded a 0, `Streaming=true` (`ev_73db8daab32b…`). Los gen2 son type-3 gen 9/A/B. **O**
- **ext (DiaBLE):** Libre 2 Plus **EU** `C6 09 31 01` o `7F 0E 31 01` → bajo=1 → **gen1**; **US/LA** `…3A…` → **gen2**. Corrige la suposición de area-native de que el Plus "casi seguro" usa P1/P2. **ext, sin verificar en el sensor del usuario.**
- Transporte NfcV `02 <cmd> 07 …` (0x07 = `uid[6]`). patchInfo = `02 A1 07`, respuesta 6 B. **O**
- Enable streaming gen1 = `02 A1 07 <payload nativo>`; respuesta bytes 1–6 = dirección BLE. gen2 = comando autenticado 19 B `02 A1 07 1E …` (lo arma P1/P2), respuesta = 12 B auth + 6 B dirección BLE. **O**
- `getEnableStreamingPayload(uid, patchInfo, personalizationIndex, secondsSince2010)`; el índice sale de `processScan` nativo; **sin account id ni valor de servidor**. **O**
- Persistido para BLE: UID, patchInfo, personalizationIndex, enable timestamp, unlock count (0,+1/conexión), auth blob (gen2), dirección BLE. **O**
- Streaming solo se habilita en activación/join/"sensor transition"; un re-escaneo normal no lo reenvía. **O**
- Confirmado `gen2Process1 == P1` (opcodes 0x7120/0x7319/0x9218 coinciden con area-native). **D**
- **Test decisivo (read-only):** mandar `A1` (flags 0x02, manuf 0x07, sin parámetros) y evaluar `reply[2]`.

## Veredicto global (checklist)

El acceso **directo Mac↔sensor** es viable **solo si el sensor del usuario es gen1**.
La Mac **nunca** puede hacer el paso NFC (no tiene NFC): siempre hace falta un
dispositivo NFC (iPhone con cuenta de pago, o Android) para habilitar el streaming
una vez por sensor. Usuario en **Argentina** → reportes comunitarios indican gen2
(serial `3MH0…`, solo Juggluco/oracle funciona). **Pendiente: confirmar `patchInfo[2]` real.**
| Q3 | Servicio/características BLE (UUIDs), conexión y autenticación (incl. desbloqueo) | BLE | **respondida** (`re/area-ble.md`) |
| Q4 | Formato y descifrado de los paquetes BLE | BLE + Nativo | respondida (núcleo opaco) |

## Fase 2 — Área B (BLE) — resuelta (`re/area-ble.md`, E01–E45)

- Stack BLE = `defpackage.xh` (tag "[BLEM]"), callback `defpackage.uh`. `AlarmBLEService` solo es foreground service. **O**
- **No escanea:** `connectGatt(autoConnect=false)` directo a la MAC de 6 bytes que devuelve la respuesta NFC de enable-streaming. Sin bonding, sin MTU. **O**
- GATT: servicio `0000fde3-…`, char login `f001` (notify+write), datos `f002` (notify), CCCD `2902`. Reconexión inmediata; watchdog 120 s. **O**
- **gen1 vs gen2 = `patchInfo[2]`**: nibble alto 3 → bajo <9 = gen1; nibble alto 7 → bajo <4 = gen1; si no, gen2. **O**
  - gen1: un payload de unlock a F001, luego suscribe F002.
  - gen2: notify F001, write `0x20`, challenge 14 B, comando autenticado 19 B, 7+18 B de sesión, luego F002.
- Lectura = 3 notificaciones F002 (20+18+8 = 46 B), timeout 10 s. gen2 descifra con `gen2Process2(773,ctx,46B)` → `processStream`; gen1 pasa los 46 B crudos a `processStream`. ~1 lectura/min (ext). **O/D**

### ⚠️ Corrección al veredicto de Q6
El bloqueo por caja blanca (SKB) aplica al **camino gen2**. **Según DiaBLE (ext), el Libre 2 Plus EU tiene `patchInfo` `C6 09 31 01` → `patchInfo[2]=0x31` → gen1** por la regla de la app, que **no** usaría SKB en el unlock BLE. La generación real solo se confirma leyendo el `patchInfo` del sensor del usuario por NFC (1 escaneo). **I/ext — a verificar.**
| Q5 | Conversión crudo → mg/dL y tendencia (`processStream`) | Nativo | abierta |
| Q6 | Qué depende de la caja blanca SKB / `gen2Process*` y si es portable | Nativo | **respondida: BLOQUEADO** (`re/area-native.md`) |

## Fase 2 — Área C (nativo/Ghidra) — VEREDICTO: BLOQUEADO

Leer un Libre 2 Plus (Gen2) por BLE desde macOS **no es factible sin la caja blanca**. **O/D**
- `libDataProcessing.so` SHA-256 `5ebf0458…6bc7`; `libSecureKeyBoxJava.so` `6b08bbbc…8f2a`.
- Sin exports `Java_*`; 21 natives registrados por tabla (reloc). `P1`@0x4551b4, `P2`@0x45658c (prob. gen2Process1/2, sin confirmar), `processStream`@0x44d870, `processScan`@0x43e0b0.
- `P1` despacha opcodes 0,1,0x7120,0x7319,0x9218 e importa claves por SKB con labels `ADC_*SpeckPatch#`. NorthStar enc/dec también son cifrados SKB. Casi todo native entry valida un token de 72 bytes (~3 s) vía SKB.
- Claves Gen2 por sesión; Juggluco reusa binarios nativos de Abbott (DiaBLE #22, **external-reference**).
- Q5 parcial: `processStream/Scan` no llaman SKB a profundidad 1; recuperados factor de temperatura `base^(32.5-T)*in` y término de calentamiento; crudo→mg/dL, tendencia y layout BLE **sin recuperar (?)**.
| Q7 | Alarmas (baja/alta/señal perdida), rangos, tiempos y textos | Lógica/UI | abierta |
| Q8 | Pantallas y requisitos según la guía de usuario | Lógica/UI | respondida (`re/area-ui.md`) |

## Fase 2 — Área D (alarmas/UI) — resuelta (ver `re/area-ui.md`)

- Umbral bajo 60–100 (def 70), alto 120–400 (def 240), serious-low def 60; todo **off** por defecto; se guardan en mg/dL. Defaults en el asset `ES_bld_cfg.json`. **O/D**
- Señal perdida a 20 min sin datos; alarma ignorada se repite a los 5 min; una por episodio (de la guía; constantes del código **I**).
- "LO" < 40, "HI" > 500, gráfico tope 350; 5 flechas de tendencia + no disponible (umbrales 1 y 2 mg/dL/min, guía p.31). Calentamiento 60 min; avisos de expiración a 3 días / 1 día / 1 h.
- **Diseño:** alarmas y streaming solo funcionan en el dispositivo que inició el sensor; otro dispositivo solo puede escanear en la 1ª hora ("late join"). Impacta el diseño iPhone-NFC + Mac-BLE. **O/D** → ver riesgo abierto.
- 27 requisitos para la app macOS (R1–R27) en `re/area-ui.md`.
- Nota: `docs/guia-de-usuario.pdf` es el manual del lector Libre 2, no de la app.
