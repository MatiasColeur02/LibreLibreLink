# Area B — Bluetooth LE (Q3, Q4 lado Java) — LibreLink ES 2.13.1

APK: `work/apk/base.apk` (sha256 `35bf1d76…01ce`). Método: REA 6.4.0 (JADX headless 0.7.1) sobre el APK, sin
ejecutarlo. Convención de la columna *Tipo*: **O** observado (código/manifiesto estático), **D** derivado
(deducción directa de código observado), **I** inferido, **?** desconocido. `ext` = referencia externa (DiaBLE,
código abierto; **nunca** observado en el APK).

Notas de método:
- Los IDs `Exx` son Evidence IDs REA completos (apéndice A). Las clases ofuscadas se citan con su nombre REA
  (`defpackage.xh`); JADX, al exportar a disco, las llama `C4623xh.java` (conflicto mayúsc./minúsc.).
- Para leer el código de forma eficiente se decompiló el APK completo con el mismo motor JADX 0.7.1
  (`re/tools/Dec.java`, usa `jadx.api.JadxDecompiler` del JAR de REA). Esa salida es **derivada** (misma
  decompilación, sin ID REA propio); cada afirmación clave se re-verificó con una llamada REA con Evidence ID.
- Búsqueda negativa acotada `X1`: `grep -a` sobre las tablas de strings de `classes.dex` y `classes2.dex`
  (únicos dex del base.apk) — sin ID REA.

## 1. Resumen

1. **La pila BLE entera es una sola clase**, `defpackage.xh` (log "[BLEM]"), con su `BluetoothGattCallback`
   `defpackage.uh`. `AlarmBLEService` (`i6`, `j6`) **no contiene lógica BLE**: es sólo un servicio en primer plano
   (`foregroundServiceType=connectedDevice`, notificación id 1) para mantener viva la app. `i6` = `Binder` vacío,
   `j6` = `Companion` vacío (E36, E37, E41; `k6` arranca el FGS tras 800 ms).
2. **La app NO escanea.** No hay `startScan`, `BluetoothLeScanner`, `ScanFilter`, ni permiso `BLUETOOTH_SCAN`
   (X1, E39). Conecta directamente con `BluetoothDevice.connectGatt(ctx, autoConnect=false, cb)` a la **dirección
   MAC de 6 bytes que el sensor devuelve por NFC** al habilitar el streaming (`Sensor.getBleAddress()`, bytes en
   orden inverso → `AA:BB:CC:DD:EE:FF`) (E07, E17, E25, E30). **Consecuencia crítica para macOS:** CoreBluetooth no
   expone MAC, hay que escanear y reconocer el sensor por otros medios (ver §7).
3. GATT: servicio `0000fde3-…`, característica de login/auth `0000f001-…` (notify + write), datos `0000f002-…`
   (notify), CCCD `00002902`. Sin MTU, sin bonding/pairing, sin PHY, sin prioridad de conexión (E06, X1).
4. Hay **dos protocolos de desbloqueo** según `securityGeneration` del sensor (derivada del `patchInfo[2]`, E33):
   - **Gen1** (`SECURITY_GENERATION_1`): una escritura de un payload de desbloqueo generado por nativo
     (`getStreamingUnlockPayload(uid, patchInfo, persIdx, enableTime, unlockCount)`) en F001, luego notificaciones
     en F002. Los datos de F002 se pasan **sin descifrar en Java** a `processStream` (el descifrado ocurre en nativo).
   - **Gen2** (`SECURITY_GENERATION_2`): handshake en F001 (enable notify → escribir `0x20` → challenge de 14 B →
     comando autenticado de 19 B → info de sesión 7+18 B → `createSecureSession`), luego notificaciones F002 que se
     descifran con `gen2Process2(773, ctx, 46 B)` y después `processStream`. Todo el cripto es **JNI/SKB (opaco)**.
5. Datos: cada lectura llega como **3 notificaciones F002 de 20 + 18 + 8 = 46 bytes**, ensambladas por **longitud**
   (no por orden ni cabecera) con timeout de 10 s (E02, E18). Se procesan en el hilo `BLEHandlerThread` (E19).
6. Salida: `processStream` (nativo) → `AlgorithmResults` (glucosa tiempo real + lista histórica + tasa de cambio +
   `TrendArrow` + `Alarm`) → BD SQLite (`CurrentReadingEntity`, `HistoricReadingEntity`, `RawStreamingEntity`) →
   `K6.A(I6,…)` (alarmas/UI/subida).
7. Política de reconexión: inmediata e indefinida (sin backoff), más un **watchdog de 120 s** sin ninguna callback GATT
   que reinicia la conexión con 6 s de espera (E04, E11, E38; `App` fija `c=120`).

## 2. Tabla de hallazgos

| # | Afirmación | Tipo | Evidencia | Notas |
|---|---|---|---|---|
| F1 | `AlarmBLEService` sólo es FGS (connectedDevice, `startForeground(1, n, 16)` en API≥29) y no contiene GATT | O | E36 E37 E39 | `onStartCommand` devuelve 1 (START_STICKY); `i6`=`Binder`, `j6`=`Companion` sin miembros |
| F2 | `xh` = gestor BLE singleton (Dagger `App.p`); `uh` = `BluetoothGattCallback`; `wh` = elemento de la cola de escrituras | O | E06 E01–E05 E44 E40 | 67 clases lo referencian (UI, NFC, alarmas) |
| F3 | Servicio `0000fde3-0000-1000-8000-00805f9b34fb` | O | E06 | `UUID.fromString` literal |
| F4 | Característica F001 `0000f001-…` (la app la loguea como "LOGIN"); F002 `0000f002-…` ("RAW_DATA"); CCCD `00002902-…` | O | E06 | nombres de log en `xh.i()` |
| F5 | No hay escaneo: ni `startScan`/`BluetoothLeScanner`/`ScanFilter`/`getBondedDevices`; manifiesto sin `BLUETOOTH_SCAN` | O | X1 E39 | búsqueda acotada a strings de dex + permisos |
| F6 | Dispositivo = `adapter.getRemoteDevice(MAC)`, MAC = `sensor.getBleAddress()` (6 B) formateado `b[5]…b[0]` | O | E07 E10 | MAC inválida → `Unknown`/null → sin conexión |
| F7 | La MAC (6 B) y el `streamingAuthenticationData` (12 B, sólo gen2) se obtienen del NFC "enable streaming" y se guardan en `SensorEntity` | O | E25 E29 E30 | NFC gen1: bytes 1..6 de la respuesta = MAC; gen2: ver F27 |
| F8 | Conexión: `connectGatt(app, false, cb)`; sin `requestMtu`, sin `createBond`, sin `setPreferredPhy`, sin `requestConnectionPriority` | O | E17 X1 | `autoConnect=false` |
| F9 | Tras `STATE_CONNECTED` se llama de inmediato `discoverServices()` (sin retardo, sin MTU) | O | E04 | |
| F10 | Si falta el servicio FDE3: `xh.q()` (reset GATT); si falta F001/F002: abortar ("a required characteristic is missing") | O | E01 | |
| F11 | El sensor se busca por **número de serie** (`_activeDeviceSerialNumber_` en SharedPreferences) entre `SAS.getSensors()`; `securityGeneration = sensor.getSecurityGeneration()` | O | E01 E07 | pref `_activeDeviceAddress_` guarda la MAC |
| F12 | `securityGeneration` se calcula de `patchInfo[2]`: nibble alto 3 → (bajo<9 ? gen1 : gen2); nibble alto 7 → (bajo<4 ? gen1 : gen2); otro → 0 (ninguna) | O | E33 E34 | `patchInfo` = `initialPatchInformation` |
| F13 | Cola de escrituras: una operación pendiente a la vez (bit 1 = escritura de característica, bit 2 = escritura de descriptor); al completarse la callback se saca la siguiente | O | E08 E09 E12 | sin reintentos; fallo → `c("write operation failed")` → disconnect |
| F14 | Suscripción: `setCharacteristicNotification(ch,true)` + CCCD `ENABLE_NOTIFICATION_VALUE` (0x0100, **notificación, no indicación**) | O | E08 | |
| F15 | Tipo de escritura: `setValue`+`writeCharacteristic` sin `setWriteType` → depende de las propiedades GATT de F001 | O/? | E08 X1 | propiedades reales de F001: **desconocidas** (leer en el prototipo) |
| F16 | **Gen1**: tras `onServicesDiscovered` → `SAS.getStreamingUnlockPayload(sensor)` → se escribe el resultado tal cual en F001 | O | E01 E20 | `incrementStreamingUnlockCount` (+1, persistido) **antes** de generar el payload |
| F17 | Gen1: en `onCharacteristicWrite` se encola suscripción a F002 y `state=4` | O | E03 | sin esperar respuesta de F001 |
| F18 | Gen1 payload nativo: `getStreamingUnlockPayload(uid, patchInfo, (byte)persIdx, enableStreamingTimestamp, streamingUnlockCount)`; devuelve `null` si `enableStreamingTimestamp==0` (no se escribe nada) | O | E20 | tamaño no observable en Java; ext: 12 B (`enableTime+unlockCount` LE + 8 B) |
| F19 | **Gen2** secuencia: state1 suscribir F001 → `onDescriptorWrite` (state==1) → state2, escribir `{0x20}` en F001 | O | E01 E05 | `0x20` = 32; mismo valor que el comando NFC "readSecurityChallenge" (`02 A1 mfr 20`) |
| F20 | Gen2 state2: notificación de F001 de **exactamente 14 B** = challenge; otro tamaño → abortar | O | E02 | |
| F21 | Gen2: `getStreamingUnlockPayload(sensor, challenge)`: `in = authData[0..10) ‖ challenge(14)` (24 B); `keyId = authData.length==12 ? (authData[11]<<8 \| authData[10]) & 0xFFFF : -1`; `ctx = getNfcAuthenticatedCommandBLE(31, uid, keyId, in, out[19])`; si ctx≤0 → `SensorNotCompatibleException`; escribe `out` (19 B) en F001; `state=3` | O | E21 E26 E02 | `authData.length<10` → RuntimeException |
| F22 | `getNfcAuthenticatedCommandBLE` = `gen2Process1(28960, keyId, uid, null)`→ctx; luego `gen2Process2(6505, ctx, {1, 31}, in24)` → 19 B; null → `endSession` y −99 | O | E26 | `{1,31}`: 1 = transporte BLE; en NFC es `{0,cmd}` con 6440 |
| F23 | Gen2 state3: respuestas de F001 de **7 B** y luego **18 B** → se concatenan en `x[25]` (`x[0..7)`, `x[7..25)`); otro tamaño → abortar | O | E02 | el orden 7→18 es el esperado, no se valida |
| F24 | Con 25 B: `createSecureStreamingSession(sensor, x)` = `gen2Process1(29465, ctx, {1}, x25)`; 0 = éxito, devuelve `ctx` (>0); si falla → `endSession`, 0 → "Error creating session context" | O | E22 E28 E02 | `ctx` es un manejador de sesión nativo (entero) |
| F25 | Tras la sesión: `state=4` y se suscribe F002 | O | E02 | |
| F26 | Gen2 F002: `decryptStreamingData(ctx, 46 B)` = `gen2Process2(773, ctx, data46, null)`; null → `SensorResponseCorruptException`; el plano se pasa a `processStreamingData(sensor, plain)` | O | E23 E27 | longitud del plano: **?** (nativo) |
| F27 | NFC gen2 enable streaming (cmd 30): `verifyEnableStreamingResponse` → 9 B verificados: `[0..6)` = **MAC BLE**; `P=gen2Process2(6145,ctx,{9},null)`; `authData[12]` = `P[0..L-2) ‖ v[6..9) ‖ P[L-2..L)` (L=9 por aritmética → 12 B) | D | E29 E30 E25 | `authData[10..11]` LE = keyId usado luego por BLE |
| F28 | Ensamblado de datos F002 (state 4): la **longitud** decide el trozo: 20 → `o`, 18 → `p`, 8 → `q`; con los tres presentes se concatenan `o‖p‖q` = **46 B** y se postea al handler. Otra longitud → "DEV ERROR: unexpected PDU length" (se ignora) | O | E02 | no hay número de secuencia; un trozo repetido sobreescribe |
| F29 | Timeout de ensamblado: al llegar el primer trozo de un paquete nuevo se programa 10 000 ms; si al vencer queda algo incompleto → descartar (`ERROR: incomplete composite data`) | O | E02 E18 | |
| F30 | Procesado (hilo `BLEHandlerThread`): wakelock `App.U`; gen2 → `processStreamingData(ctx, sensor, 46 B)`; gen1 → `processStreamingData(sensor, 46 B)` (**datos crudos, descifra el nativo**) | O | E19 E23 E24 | |
| F31 | `processStreamingData(sensor, bytes)`: carga `SensorEntity`; `lsaDetected`→Terminated(80,0); guarda `bytes` en `RawStreamingEntity` (descifrado en gen2, crudo en gen1); llama `DataProcessing.processStream(...)` (ver §6) | O | E24 | tiempos como segundos desde 2010-01-01 UTC (`BASE_YEAR=2010`) |
| F32 | Salida: `AlgorithmResults{historicGlucose[], realTimeGlucose(id,dq,value), rateOfChange(float), trendArrow, alarm, isActionable, esaMinutesToWait, lsaDetected}` | O | E43 E24 | `TrendArrow` 0..5 (NOT_DETERMINED, FALLING_QUICKLY, FALLING, STABLE, RISING, RISING_QUICKLY); `Alarm` 0..5 (NOT_DETERMINED, LOW, PROJECTED_LOW, OK, PROJECTED_HIGH, HIGH) |
| F33 | El **timestamp de cada lectura es el reloj del teléfono en la recepción** (`TimeOsFunctions.getCurrentTime()`); el id/`recordNumber` viene del sensor | D | E24 | histórico: `fecha = ahora − (idRT − idHist) minutos` ⇒ ids en minutos (I) |
| F34 | Histórico por streaming: sólo si `sensor.isOperatingInStreamingMode` (config `Streaming`=true en ES) y DQ==OK por muestra | O | E24 | |
| F35 | Calidad de dato (`DataQuality` bitmask): 0 = OK; TEMP_HIGH 8192, TEMP_LOW 16384, etc.; no-OK → excepción y se guarda `addStreamingError` | O | E24 | |
| F36 | Se descarta el paquete si el sensor terminó antes (`last_logged_sensor_ended`, `endedEarly`) o `SensorState.ENDED` | O | (xh.t) E06 | |
| F37 | Éxito → `K6.A(I6(timestampMs, mg/dL, recordNumber, true), C2460iQ(...))`; `I6.a()` valida rango `GlucoseMin−1 … GlucoseMax+1` (ES: 40–500) | O | E19 | luego `DataUploadJob.n` y `SensorAlarmService` acción `SENSOR_STATE_CHANGED` |
| F38 | No hay sondeo: tras suscribirse la app sólo reacciona a notificaciones ⇒ la cadencia la fija el sensor | D | E02 E19 | ext: 1 lectura/min |
| F39 | Desconexión (`state 0`): `gatt.close()`, `h(0)`: `q()` + reconexión inmediata (0 ms), sin backoff ni límite; vacía cola de escrituras; `state=0` | O | E04 E11 | si se desconecta en gen2 state3 / gen1 state5 → evento analytics `AUTH_FAILURE type=ble` |
| F40 | Bluetooth OFF → `q()`; ON → `h(500)` + `j()` (reiniciar FGS) | O | `pa` case 2 (derivado) E11 | |
| F41 | Watchdog `WATCHDOG_BLUETOOTH`: cada callback GATT (`a.a.a("onX")`) "acaricia" al perro: cancela y re-arma `AlarmManager` a `now + 120 s` (`App` fija `c=120`); al ladrar: `i=null` y `r(serial, MAC, TRUE)` ⇒ `q()`, **sleep 6000 ms** en el hilo de llamada, nueva `connectGatt` | O | E38 E10 (+ derivado `s80`, `xZ0`) | |
| F42 | Puerta BLE: `g()` = (`EnableAlarms` ∨ `Streaming`) ∧ adaptador encendido; `j()` arranca el FGS si hay sensor en estado activo y `getStreamingAvailable()` | O | E16 E15 | `getStreamingAvailable()` = `enableStreamingTimestamp != 0` |
| F43 | Un único `DataProcessingNative` (parserType `APOLLO_PG2` = FourCC `'AP2X'` = 1095774808) sirve a NFC, gen1 y gen2 | O | E42 (+JI0) | |
| F44 | `BleDisconnectedEvent`/`BleReconnectEvent` son DTOs de telemetría (rssi, secondsSinceDisconnect…), sin uso en el protocolo (sólo `UniversalUploadFactory` los referencia) | O | E45 | |
| F45 | Config ES: `AlgoGeneration=3`, `Streaming=true`, `ProductType3="0,1,2,5,6,7,9,A,B"`, `ProductType0="0,3"`, tipo 7 = 0 (no soportado) | O | `assets/config/ES_bld_cfg.json`, JI0 | pasa a `isPatchSupported`/`DefaultSensorAbstractionService(…, maxAlgo, type0, type3, type7=0)` |
| F46 | Contador de desbloqueo gen1 `streamingUnlockCount` empieza en 0 en `SensorEntity` y se incrementa+persiste en **cada** `getStreamingUnlockPayload` (o sea en cada conexión/reconexión) | O | E20 E35 | si el sensor valida monotonía del contador: **?** |
| F47 | `enableStreamingTimestamp` = segundos desde 2010-01-01 UTC del **reloj del teléfono** en el momento de generar el payload NFC de activar-streaming (`getEnableStreamingPayload(uid,patchInfo,persIdx,that)`) | D | E25 (smali de `processActivation`) | se guarda en `SensorEntity` y se reutiliza en cada unlock gen1 |

### Reconciliación con DiaBLE (ext)

| Hecho | Tipo | Concordancia |
|---|---|---|
| Servicio FDE3, F001 "bleLogin", F002 "compositeRawData" | ext | coincide con F3/F4 |
| Estados gen2 1..4 (notif → challenge 14 B → sessionInfo 7+18 B → authenticated), gen1 = state 5 "bleLogin" | ext | coincide con F19–F25 |
| `AUTH_COMMAND_PAYLOAD_LENGTH = 19` | ext | coincide con F21 |
| "Libre 2 siempre envía 46 B en 3 paquetes de 20+18+8" | ext | coincide con F28 |
| Gen1: payload de desbloqueo de 12 B (`enableTime+unlockCount` LE u32 ‖ 8 B), descifrado BLE = XOR con keystream, 44 B útiles = 42 datos + CRC16 | ext | compatible con F18/F30 |
| `patchInfo` UE Libre 2+ = `C6 09 31 01`; US Libre 2+ = `2C 0A 3A 02`; LA = `2B 0A 3A 08` | ext | aplicando F12: `0x31`→gen1; `0x3A`→gen2 (**I**) |
| NFC `A1 1E` devuelve la MAC (6 B, invertida) | ext | coincide con F7 |
| Manufacturer data anunciada incluye bytes del UID (gen1); en gen2 **no** coincide con el UID | ext | ver §7 |

## 3. Diagrama de secuencia (texto)

```
[NFC, iPhone/Android]  scan: patchInfo(≥6 B), UID(8 B)                      -> SensorEntity.{uniqueIdentifier, initialPatchInformation}
[NFC]  persIdx (salida nativa de processScan) , enableStreamingTimestamp = secs desde 2010 UTC (reloj teléfono)
[NFC gen1] cmd A1 <mfr> <getEnableStreamingPayload(uid,patchInfo,persIdx,ts)>  -> resp[1..6] = MAC  (authData = null)
[NFC gen2] cmd A1 <mfr> 1E + auth 19 B (gen2Process2 6440)  -> verifyEnableStreamingResponse -> MAC(6) + authData(12)
App: SAS.selectSensor; xh.r(serial, MAC, false) ; xh.h(0)

xh.h(0) --q()--> post y3(7):  device = getRemoteDevice(MAC);  gatt = device.connectGatt(ctx, autoConnect=false, uh)
uh.onConnectionStateChange(CONNECTED)  --> gatt.discoverServices()                     [watchdog pet en cada callback]
uh.onServicesDiscovered:
   svc  = getService(FDE3)              (null -> reset)
   F001 = svc.char(F001); F002 = svc.char(F002)   (null -> abort)
   sensor = SAS.getSensors().find(serial == _activeDeviceSerialNumber_)
   gen = sensor.securityGeneration  (patchInfo[2], F12)

 ── GEN1 ──────────────────────────────────────────────────────────────────────────
   unlock = SAS.getStreamingUnlockPayload(sensor)            // count++ ; native (uid, patchInfo, persIdx, enableTs, count)
   write F001 <- unlock                                      // si enableTs==0: null, no se escribe
   uh.onCharacteristicWrite: enable notify F002 (CCCD 0x0100); state=4

 ── GEN2 ──────────────────────────────────────────────────────────────────────────
   state=1; enable notify F001 (CCCD 0x0100)
   uh.onDescriptorWrite (state 1): state=2; write F001 <- {0x20}
   notify F001 (14 B)  challenge                              (state 2)
        in24 = authData[0..10) ‖ challenge
        ctx  = gen2Process1(28960, keyId, uid, null)
        out19= gen2Process2(6505, ctx, {1,31}, in24)
        write F001 <- out19 ; state=3
   notify F001 (7 B) then notify F001 (18 B)  -> sess25       (state 3)
        r = gen2Process1(29465, ctx, {1}, sess25) ; r==0 ok
        state=4 ; enable notify F002 (CCCD 0x0100)

 ── STREAMING (state 4) ─────────────────────────────────────────────────────────
   notify F002: 20 B, 18 B, 8 B (cualquier orden, por longitud; 10 s timeout) -> raw46 = o‖p‖q
   post Z2(8): wakelock;
        gen2: plain = gen2Process2(773, ctx, raw46, null) ; data = plain
        gen1: data = raw46
        out = DataProcessing.processStream(alarmCfg, nonActionableCfg, gluRange, attenCfg,
                  uid, patchInfo, persIdx, data, sensorStart(s/2010), now(s/2010), warmupMin, wearMin,
                  streamingMode, compositeState, attenuationState, measurementState)
        persist (RawStreaming / CurrentReading / HistoricReading) ; new states saved to SensorEntity
        K6.A(I6(now_ms, mg/dL, recordNumber, true), …)  -> UI / alarmas / subida
   (sin sondeo; el sensor empuja ~1/min [ext])

 ── ERRORES / RECONEXIÓN ──────────────────────────────────────────────────────────
   disconnect -> gatt.close(); h(0) -> reconexión inmediata (sin backoff) ; state=0
   120 s sin callbacks GATT -> watchdog -> q(); sleep 6 s; connectGatt de nuevo
   BT OFF -> q() ; BT ON -> h(500)
```

## 4. Roles de clases ofuscadas (nombre REA → rol)

| Nombre REA (archivo JADX) | Rol |
|---|---|
| `com.librelink.app.services.AlarmBLEService` | FGS (`connectedDevice`) «AlarmForegroundServiceScope»; sin lógica BLE |
| `defpackage.i6` (`BinderC2420i6`) | `Binder` vacío de `AlarmBLEService` |
| `defpackage.j6` (`C2658j6`) | `Companion` vacío |
| `defpackage.k6` (`C2788k6`) | corrutina que construye la notificación (canal `sensorStatusChannelId`) y llama `startForeground` tras `delay(800)` |
| `defpackage.xh` (`C4623xh`) | **BLE manager** `[BLEM]`: UUIDs, máquina de estados `v`, cola de escrituras, reconexión, MAC/serial activos (prefs `_activeDeviceSerialNumber_`, `_activeDeviceAddress_`), errores SAS→`ErrorCondition` |
| `defpackage.uh` (`C4233uh`) | `BluetoothGattCallback` (todo el protocolo GATT) |
| `defpackage.wh` (`C4493wh`) | elemento de cola {characteristic, value, enableNotification} |
| `defpackage.y3` (`RunnableC4671y3`) | multiplexor de `Runnable`; `case 7` = `connectGatt` |
| `defpackage.Z2` | multiplexor de `Runnable`; `case 8` = procesar paquete de 46 B |
| `defpackage.xc0` (`RunnableC4614xc0`) | multiplexor; `case 12` = timeout de paquete incompleto |
| `defpackage.pa` (`C3570pa`) | `BroadcastReceiver` multiplexor; `case 2` = `ACTION_STATE_CHANGED` del adaptador |
| `defpackage.Bh` / `s80` / `xZ0`(+`yZ0`) / `WatchDogReceiver` | watchdog Bluetooth (120 s) |
| `defpackage.fH0` (`C2053fH0`), `cH0` | coordinador NFC (scan/activación) → llama `xh.r(...)` |
| `defpackage.II0` | implementación `SAS` (extiende `DefaultSensorAbstractionService`) |
| `defpackage.JI0` | proveedor Dagger de `SAS`: crea `DataProcessingNative(APOLLO_PG2)`, configs y `DefaultNfcRfModuleGen2` |
| `defpackage.K6` (¡distinto de `k6`!) | gestor de alarmas/lecturas; `A(I6, C2460iQ)` |
| `defpackage.I6` | lectura (ts ms, mg/dL, recordNumber, válida); `a()` valida rango |
| `defpackage.C2460iQ`, `YN0` | modelo de UI (SensorGlucose + tendencia + estado) |
| `defpackage.InterfaceC3312nb` (`nb`) | configuración por defecto `AlarmConfiguration(70,240)`, `NonActionable…`, `Attenuation…` |
| `defpackage.EnumC1184Wr` (`Wr`) | claves de configuración (`*_bld_cfg.json`) |
| `defpackage.C0263Ey` (`Ey`) | parser de "product type bits" (`"0,1,2,5,…"` → máscara de nibbles) |
| `defpackage.av` / `com.librelink.app.core.App` | grafo Dagger / aplicación (`App.p = xh`, `App.s`/`a` = watchdog) |

## 5. Argumentos del lado Java (procedencia exacta)

Valores persistidos (`SensorEntity`, SQLite, E35) y su origen:

| Campo | Origen | Usado en |
|---|---|---|
| `uniqueIdentifier` (8 B) | UID NFC ISO15693 (`NfcRfModule.getPatchUid`) | unlock gen1, auth gen2, processStream |
| `initialPatchInformation` | `getPatchInfo` NFC (`02 A1 mfr`), en enable-streaming se guarda `enableStreamingPatchInfo` | unlock gen1, processStream, `getSecurityGeneration` |
| `personalizationIndex` (byte) | salida nativa del procesado de scan (`DataProcessingScanOutputs.getPersonalizationIndex`) | unlock gen1, processStream |
| `enableStreamingTimestamp` (int) | F47 | unlock gen1 |
| `streamingUnlockCount` (int) | +1 por intento de unlock (F46) | unlock gen1 |
| `streamingAuthenticationData` (12 B o null) | NFC gen2 enable-streaming (F27) | unlock gen2 (F21) |
| `bleAddress` (6 B) | NFC enable-streaming | `getRemoteDevice` |
| `compositeState`/`attenuationState`/`measurementState` | salidas previas de `processStream`/`activationComplete` | entradas de `processStream` |
| `sensorStartTimestampUTC`, `warmupPeriodInMinutes`, `wearDurationInMinutes` | NFC (`getPatchTimeValues`, tiempos de activación) | `processStream` |

`processStream` (Java, `DataProcessing.processStream`, E24, E32) — orden exacto de argumentos:

`(AlarmConfiguration{low=70, high=240}, NonActionableConfiguration{enabled=EnableNonActionableIcon, velocityCheck=NAITrendArrow, projLowCheck=NAIProjectedGlucose, minActionableId=MinimumActionableId, minActionableValue=MinActionable, maxActionableValue=MaxActionable, minNegVel=-2.0, maxPosVel=+2.0}, GlucoseValueRange{GlucoseMin, GlucoseMax}, AttenuationConfiguration{esaDetect, lsaDetect, esaCorr, lsaCorr}, byte[] uid, byte[] patchInfo, byte persIdx, byte[] data(46 B crudo gen1 / descifrado gen2), int sensorStartSecs(2010), int nowSecs(2010), int warmupMin, int wearMin, boolean isOperatingInStreamingMode, byte[] compositeState, byte[] attenuationState, byte[] measurementState)` → `DataProcessingOutputs{estSensorStart/End, insertionConfirmed, sensorHasBeenRemoved, newComposite/Attenuation/MeasurementState, AlgorithmResults, extendedErrorCode, dqValue}`; el resultado nativo `DataProcessingResult` (0 SUCCESS … 7 FATAL_VITAMINC) lanza `DataProcessingException`.

Valores ES (de `assets/config/ES_bld_cfg.json`): `EnableNonActionableIcon=false`, `NAITrendArrow=false`, `NAIProjectedGlucose=false`, `MinimumActionableId=0`, `MinActionable=70`, `MaxActionable=500`, `GlucoseMin=40`, `GlucoseMax=500`, `AttenuationEnableEsaDetection=false`, `EsaCorrection=true`, `LsaDetection=true`, `LsaCorrection=true`, `AlgoGeneration=3`, `Streaming=true`, `lowVitCCheck=false`.

## 6. Objetivos JNI para el worker nativo

Todos en `DataProcessingNative` (E32). Las variantes públicas son `native` y delegan en las privadas con un `int parserType` (`AP2X`) y un `byte[] token` final (`TokenHandler.getToken()`, también nativo en `libsas.so`) — **I**: por la correspondencia de firmas `gen2Process1(a,b,c,d)` ↔ `P1(int,int,byte[],byte[],byte[])`. Libs: `libDataProcessing.so`, `libsas.so`, `libSecureKeyBoxJava.so` (+`com.whitecryption.skb`).

**Gen2 (`Gen2SecurityNativeInterface`, constantes en `Gen2SecurityInterfaceSkb`, E31 E26–E29)**

| Llamada | Cmd | Entradas (procedencia) | Salida |
|---|---|---|---|
| `gen2Process1` | 0 | (0, 0, null, null) — init | int |
| `gen2Process1` | 1 | self-test | 1 = OK |
| `gen2Process1` | 28960 (0x7120) | `i2=keyId` (16 b de authData[10..11] LE, o `-1`; en NFC: `patchAttribute[2..3]` leído con `02 A1 mfr 22`), `bArr=UID(8 B)` | `ctx` >0 / <0 error (−13 KEY_NOT_FOUND) |
| `gen2Process2` | 6505 (0x1969) | `ctx`, `{1, 31}`, `in = authData[0..10) ‖ challenge14` | 19 B (≤19) o null |
| `gen2Process2` | 6440 (0x1928) NFC | `ctx`, `{0, cmd}` (cmd 27 activar, 30 enable-streaming, 31 scan), `challenge` NFC (`02 A1 mfr 20`) | 19 B; Java reescribe `[0..4)=02 A1 mfr cmd` |
| `gen2Process1` | 29465 (0x7319) | `ctx`, `{transport: 0 NFC / 1 BLE}`, respuesta (BLE: sessionInfo 25 B) | 0 OK; −15, −9 = fallo auth |
| `gen2Process2` | 773 (0x0305) | `ctx`, `data = 46 B` crudos, null | plano (longitud **?**) o null |
| `gen2Process2` | 22321 (0x5731) | `ctx`, `{idx, outLen}`, respuesta NFC | `outLen` B |
| `gen2Process2` | 6145 (0x1801) | `ctx`, `{9}`, null | 9 B (I por aritmética) |
| `gen2Process2` | 6520 | `ctx`, `{i2,i3}`, FRAM cifrada | FRAM descifrada (NFC, otro worker) |
| `gen2Process1` | 37400 (0x9218) | `ctx` | fin de sesión |

**Gen1 / común (`DataProcessing`)**

| Método | Argumentos (procedencia) | Salida |
|---|---|---|
| `getStreamingUnlockPayload(byte[] uid, byte[] patchInfo, byte persIdx, int enableTs, int unlockCount)` | SensorEntity (F18, F46, F47) | payload escrito en F001 (ext: 12 B) |
| `processStream(...)` | §5; `data` = 46 B **crudos** en gen1 ⇒ el nativo debe descifrar BLE (ext: XOR con keystream derivado de uid+patchInfo) | `DataProcessingOutputs` |
| `getEnableStreamingPayload(byte[] uid, byte[] patchInfo, byte persIdx, int enableTs)` | NFC (lado Área A) | bytes tras `02 A1 mfr` (ext: `1E` + código u32 LE) |
| `getEncryptedNorthStarPayload / getDecryptedNorthStarPayload(byte[], byte[])` | `SAS.encryptForNorthstar/decryptForNorthstar`; **no se usan en la ruta BLE** (otro subsistema) | byte[] |

## 7. Implicaciones para la app macOS (CoreBluetooth)

- **Identificación del sensor:** la app Android usa la MAC (obtenida por NFC) y nunca escanea. En macOS no hay MAC
  (se usa el UUID de periférico asignado por el SO). Opciones: escanear (con o sin filtro de servicio FDE3 — **si FDE3
  se anuncia: ?**), y emparejar por datos anunciados. ext (DiaBLE): los datos de fabricante contienen bytes del UID
  (gen1) y en gen2 no coinciden con el UID. El **nombre anunciado** es **?** (no está en el APK; no inferir
  "ABBOTT+serial" sin verificar).
- **Exclusividad:** un periférico sólo atiende a un central a la vez (I); LibreLink en el teléfono y el Mac competirían.
  El desbloqueo gen1 incrementa un contador persistido: si el Mac reutiliza `enableStreamingTimestamp` y cuenta propia,
  si el sensor lo exige monótono es **?**.
- **Datos que el iPhone debe exportar al Mac** tras NFC: UID, `patchInfo`, `persIdx`, `enableStreamingTimestamp`,
  `streamingUnlockCount` actual, MAC (informativa), y en gen2 `authData(12 B)`; más los estados nativos
  (`composite/attenuation/measurementState`) si se reutiliza `processStream`.
- Si el sensor del usuario es gen1 (hipótesis I: Libre 2 Plus UE `C6 09 31 01` → `patchInfo[2]=0x31`), la ruta BLE es
  la de Libre 2 documentada en abierto (ext) y **no** requiere `gen2Process*`; si es gen2 (`…3A`/`…39`), depende de la
  caja blanca SKB. **Hay que leer `patchInfo` real del sensor** antes de decidir.

## 8. Desconocidos abiertos

1. Propiedades GATT reales de F001/F002 (write con/sin respuesta, notify): sólo se ven en el sensor/PacketLogger. (F15)
2. Si FDE3 aparece en los datos anunciados; formato exacto del nombre y de la manufacturer data. (§7)
3. Longitud del plano de `gen2Process2(773)` y del payload gen1 (nativo; ext dice 12 B/44 B+CRC).
4. Semántica nativa de `P1/P2` + `token`, `TokenKey` y qué verifica `libsas.so` (integridad/anti-tamper) — worker nativo.
5. Si el sensor valida monotonía de `unlockCount` y de `enableTimestamp` (afecta a convivencia teléfono/Mac).
6. Si `securityGeneration` del Libre 2 Plus del usuario es 1 o 2 (depende de su `patchInfo`; ES soporta ambos).
7. Cadencia real (1/min) es **I**: el APK no contiene un temporizador de lectura.
8. `state==5` en la comprobación de desconexión gen1 no se asigna en ningún sitio observado (código muerto o
   estado perdido en el decompilado).
9. Qué contiene exactamente la salida histórica por paquete (cuántas muestras/ids) — vive dentro de `processStream`.
10. Tamaño de MTU negociado en Android (el APK no lo pide; lo decide el SO).

## 9. Veredictos

- **Q3 — Respondida (alta confianza, estático).** Pila BLE = `defpackage.xh` + `defpackage.uh`; sin escaneo, conexión directa por
  MAC NFC con `connectGatt(autoConnect=false)`; GATT FDE3/F001/F002/2902, sólo notificaciones; sin MTU ni bonding; dos
  protocolos de desbloqueo (gen1: 1 escritura; gen2: handshake challenge-respuesta de 14→19, 7+18, sesión) elegidos por
  `patchInfo[2]`; reconexión inmediata + watchdog 120 s. Pendientes empíricos: propiedades GATT, anuncio.
- **Q4 (lado Java) — Respondida, con núcleo opaco.** Ensamblado 20+18+8=46 B por longitud; procedencia de todos los
  argumentos nativos documentada; flujo hasta `K6.A`/BD. Lo opaco: descifrado (gen1 dentro de `processStream`, gen2 vía
  `gen2Process2(773)`), generación de payloads (`getStreamingUnlockPayload`, `gen2Process1/2`), y el algoritmo de glucosa.
  Hay referencia abierta (ext) para gen1; gen2 depende de SKB.

## Apéndice A — Evidence IDs

APK sha256 `35bf1d76bcf2ebbea7f24cbcf41059c21cd8dd4911a5aaa5df5ee6cd76d901ce`. Todos con `provider=jadx 0.7.1`,
`confidence` observado/derivado, `authority=shipped-artifact`; la decompilación es estática, no ejecución.

| ID | REA tool | subject | Evidence ID |
|---|---|---|---|
| E01 | inspect_android_method | defpackage.uh.onServicesDiscovered (BluetoothGattCallback) | `ev_5485be850eb8ddb96a052d04afc2e48722a9060ed219f8e9875c0f44a9fd3638` |
| E02 | inspect_android_method | defpackage.uh.onCharacteristicChanged | `ev_ff78500c3cca24b738eaf7404abe21792914509c1ee76d62810a11b093168f51` |
| E03 | inspect_android_method | defpackage.uh.onCharacteristicWrite | `ev_6d6074ae69bf38bcb613106db5ea7228d04f2ee149c480044233ce9d86b0c42f` |
| E04 | inspect_android_method | defpackage.uh.onConnectionStateChange | `ev_76132ad44e225e72eb336221da1b65c4c441c00670b3b927a5cf63cae75cba59` |
| E05 | inspect_android_method | defpackage.uh.onDescriptorWrite | `ev_9460115ae1b0acdbc0f2f0d844025a6b31de5aa55f7f62f3e99c869a7b4b0b16` |
| E06 | inspect_android_class | defpackage.xh (BLE manager: UUID fields, state) | `ev_26a251618c76250bfa6627315548cdef41d6baa7db521e43601e0a574c75253e` |
| E07 | inspect_android_method | defpackage.xh.l (init, remote device from sensor BLE address) | `ev_1e86def9397aa6ff0596f1fb01c028379d120aa256fa18772b13eb8555826410` |
| E08 | inspect_android_method | defpackage.xh.n (performWriteOperation: CCCD / characteristic write) | `ev_c4b33bb0bada902de1f2582d96ae4b306ee18391d0d351c1b4d99da4c9f8d638` |
| E09 | inspect_android_method | defpackage.xh.o (queueWriteOperation) | `ev_e22e85ab2bccfc55cf96f48a4dc04c73763092699aa73ad85b9b4874475d1227` |
| E10 | inspect_android_method | defpackage.xh.r (setActiveDevice) | `ev_1e792a7b740eb37656477c5d91450bb31db2459423a6a8cfa28567dc9a015b88` |
| E11 | inspect_android_method | defpackage.xh.h (reconnect scheduler) | `ev_a4c7b00a3708ef1983b7575120c8c4254deb6417c994d728387f575064f98f0c` |
| E12 | inspect_android_method | defpackage.xh.a (static: write-queue pump) | `ev_20929976a42f0796c490b9b926ff84e22d99cec49f8e90c73615830b77e66f6f` |
| E13 | inspect_android_method | defpackage.xh.q (reset GATT) | `ev_dcf0028b44b285346fcea17243677e6a9cc0ea1296f4df98d1dfa633afa256a2` |
| E14 | inspect_android_method | defpackage.xh.s (start/stop AlarmBLEService) | `ev_5e9fe0fcd7bdb01d564e143ba1811b2c6b5a05168b1528901b3544f7c3d4d32b` |
| E15 | inspect_android_method | defpackage.xh.j (start FGS if streaming sensor) | `ev_1621ed859d874cf68e8cc9f605ef38c326afbe025551521e90baecdae8fd4e13` |
| E16 | inspect_android_method | defpackage.xh.g (BLE enabled gate) | `ev_b3961fbe8608cb271f4de369615bc90550b9f04265c98ba8d1c2ee904f912518` |
| E17 | inspect_android_method | defpackage.y3.run (switch case 7 = connectGatt(autoConnect=false)) | `ev_4756296c91d0f36ebb311aa533eca1062db8016db27fc53baf4ad2845c42a795` |
| E18 | inspect_android_method | defpackage.xc0.run (case 12 = 10 s incomplete-composite timeout) | `ev_82ae9ceaa5bbfe4ab9a8778defa1cdb67f07427d48ca7440238a237b600671c1` |
| E19 | inspect_android_method | defpackage.Z2.run (case 8 = process 46-byte packet) | `ev_3c629275bc7f15cce2ca2759a6d7d9dfe7c0e42bac547b5e399397b28e150f0a` |
| E20 | inspect_android_method | DefaultSensorAbstractionService.getStreamingUnlockPayload(Sensor) [gen1] ov0 | `ev_6ec7fc778fafa453e731fa9a38ce0759387f1a86c11ad4ed0be51bc9c868385b` |
| E21 | inspect_android_method | DefaultSensorAbstractionService.getStreamingUnlockPayload(Sensor,byte[]) [gen2] ov1 | `ev_dcd1608173dd3d78c31a730d5659d5fa1689acb4cbc7d2292d69ed375ce79095` |
| E22 | inspect_android_method | DefaultSensorAbstractionService.createSecureStreamingSession | `ev_1073c9a596ba807a7e0182d8c4614d6cf10f5dd2f551b99db80be3827013f42c` |
| E23 | inspect_android_method | DefaultSensorAbstractionService.processStreamingData(int,Sensor,byte[]) [gen2] ov0 | `ev_660c9c6084826159e1b8697635f124a4060375780c2fa14f786d767da08e68c3` |
| E24 | inspect_android_method | DefaultSensorAbstractionService.processStreamingData(Sensor,byte[]) ov1 | `ev_ac38ee5e818805dba6dc757e9f426449b732f7a00718a545f381719483ca8ad0` |
| E25 | inspect_android_method | DefaultSensorAbstractionService.activateSensor (stores auth data / BLE addr) | `ev_b7cceabe26df4641f2c15ba9bed57bedbccc00ae3e32def8eadb32c0015fcced` |
| E26 | inspect_android_method | Gen2SecurityInterfaceSkb.getNfcAuthenticatedCommandBLE | `ev_83503cccd9eddfab5a6ae5c0bfa7069668947f196b799bbc80e664e5058cdf7d` |
| E27 | inspect_android_method | Gen2SecurityInterfaceSkb.decryptStreamingData | `ev_1176006e84200068f0142550cf67ed2873ce88b05a982afc733f9816e66f4bf7` |
| E28 | inspect_android_method | Gen2SecurityInterfaceSkb.createSecureSession | `ev_1a26146f6892872faf8891ed3b2f12d4ca07fb22946ac46a389486c05a3acc93` |
| E29 | inspect_android_method | Gen2SecurityInterfaceSkb.verifyEnableStreamingResponse | `ev_5c0c8a9f32c712b1f7fb635c624016713d1038782ea4b0f5227757c27e9141c7` |
| E30 | inspect_android_method | DefaultNfcRfModuleGen2.enableStreaming(Tag,byte[],byte[],byte[]) ov1 | `ev_46e1c015fab47ca4fc8e43a7653650c03efbafe01118ada67d412c38b6dfc360` |
| E31 | inspect_android_class | Gen2SecurityInterfaceSkb (command-ID constants) | `ev_18378b1b1ab8d0ed25493de187e83f100226ce064fae9b9837131c8aceda6887` |
| E32 | inspect_android_class | DataProcessingNative (JNI surface, P1/P2, TokenHandler) | `ev_b7a7abf25fc90c65d8cd8f96c55dcd0770d41b2b9f633f6c71fee4e7f76fc68a` |
| E33 | inspect_android_method | DefaultSensorAbstractionService.getSecurityGeneration(patchInfo) | `ev_bd6f433828ba9f0b59ee71fa23d9d25c769cf9b26085d13fc839e3020770fb27` |
| E34 | inspect_android_class | Sensor (SECURITY_GENERATION_*, bleAddress) | `ev_b181eacda6359bf74b5912ed3d92c40e6515cf129c6c09f8bd7cd04b7c32cfb4` |
| E35 | inspect_android_class | SensorEntity (persisted streaming fields) | `ev_dca1e44be60f22f54c5b7fee54c7cb6ab7ef917e35247d16e1fcec52631f2330` |
| E36 | inspect_android_class | AlarmBLEService (fields b:i6 Binder, Companion:j6) | `ev_d11cedebce0d63237112eaccb584414481ef9837de32e1614892ed33f08da610` |
| E37 | inspect_android_method | AlarmBLEService.onCreate / onStartCommand (MCP calls) | `ev_678d622384a885859c9128e2042d5a824823b637d34c561d25be747869b5549e;ev_5a901594ca278abad8a51e7cfa1f846c793bcf8ab6cc50912048e12f405ab747` |
| E38 | inspect_android_method | defpackage.Bh.c (watchdog wake -> AlarmManager at now+c s) | `ev_3c20ea607f067e03d01306a3197ec8f5b07266949690749c238e4aabdc514d22` |
| E39 | inspect_android_package | manifest permissions (BLUETOOTH, _ADMIN, _CONNECT; no BLUETOOTH_SCAN) | `ev_3ef462db5bb04c34cc3fd189258ab315aa6eec07525daab397484d39422fec7c` |
| E40 | trace_android_references | incoming refs to defpackage.xh (67 classes) | `ev_3e70c2438074cd3e1f292524058e7e115e096f8dab28fc1b4a0e4e56aaee8462` |
| E41 | trace_android_references | incoming refs to AlarmBLEService | `ev_def57caec61a4fbc6c31dd8392c72e10ea39e8b4992a741afb1a18e10405b141` |
| E42 | inspect_android_class | DataProcessingType (parserType FourCC) | `ev_cd5541233220b9db02daa6dd91098b5b302e451f4dc498904c0dcebc46f60d9f` |
| E43 | inspect_android_class | AlgorithmResults | `ev_0912cf8d836736d507f1faff9c5603f4703700655666f3e1992e77fadf6bcff9` |
| E44 | inspect_android_class | defpackage.uh / wh / Bh (callback, queue item, watchdog) | `ev_095794cceeb581ee2aa4ccff6ee4a1e56f58ba898baa46b0b5c90f899dd552da` |
| E45 | trace_android_references | incoming refs to BleDisconnectedEvent (sólo UniversalUploadFactory + Companion) | `ev_61d5302ff25e4e0fadab92dd69464e791341a7ba6ef48e078c88cecddf5f9bc3` |


Notas: X1 = `grep -a` de {startScan, requestMtu, createBond, BluetoothLeScanner, ScanFilter, setPreferredPhy,
requestConnectionPriority, setWriteType, readCharacteristic, getBondedDevices, onMtuChanged, ENABLE_INDICATION_VALUE}
en `classes.dex`/`classes2.dex` = 0 coincidencias; sí aparecen una vez `connectGatt`, `writeCharacteristic`,
`setCharacteristicNotification` (en `xh`/`y3`). Las filas F36, F40, F41, F44 se apoyan además en la decompilación completa
(`re/tools/Dec.java`) de `xh.t`, `pa`, `s80`, `xZ0`, `App`; reproducibles con ese programa.
Referencias externas (no observadas): DiaBLE `Libre2.swift`, `Abbott.swift`, `Libre.swift`
(github.com/gui-dos/DiaBLE), consultadas por WebFetch.
