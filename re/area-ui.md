# Área D — Lógica de alarmas y requisitos de UI (Q7, Q8)

Fuentes: `work/apk/base.apk` (LibreLink ES 2.13.1, SHA-256 `35bf1d76…01ce`), recursos
`work/apk/split_config.es.apk`, `docs/guia-de-usuario.pdf` (147 págs.). Solo análisis estático;
no se ejecutó el APK ni se abrieron bibliotecas nativas.

Convención: **O** observado, **D** derivado (de código/recurso observado), **I** inferido,
**?** desconocido. Evidence IDs de REA abreviados a 12 hex (`ev_xxxxxxxxxxxx`, ID completo
disponible en la sesión). Páginas de la guía = número de página del PDF (la numeración impresa
es PDF − 4). Extracciones sin ID REA: **[STR]** = tabla de cadenas `resources.arsc` de
`base.apk` (default EN) y `split_config.es.apk` (`es`), leída con un parser propio de
`resources.arsc` (apktool no está instalado; `decode_android_resources` falló con
`capability_unavailable`); **[CFG]** = `assets/config/ES_bld_cfg.json` dentro de `base.apk`
(configuración de build para España).

## 1. Resumen

1. **La "guía de usuario" del repo es el manual del LECTOR FreeStyle Libre 2, no de la app
   LibreLink.** Sirve para umbrales, textos, flechas, historial y avisos; pero la app móvil
   difiere en detalles (lecturas automáticas cada minuto, alarma "baja grave", fondo de color,
   permisos del teléfono). Donde ambos coinciden, la confianza es alta; donde solo está uno,
   se indica la fuente.
2. **Umbrales de alarma** (O, ambos): baja 60–100 mg/dL (paso 5), por defecto 70; alta
   120–400 mg/dL (paso 10), por defecto 240; todas **desactivadas por defecto**. En mmol/L el
   selector de la app va de 3,3 a 5,6 (baja) y de 6,7 a 22,2 (alta), pasos de 0,1.
3. **Pérdida de señal**: aviso tras **20 min** sin comunicación (guía; en el código hay una
   constante de 1 200 000 ms, I). Se activa sola al activar la primera alarma baja/alta.
4. **Repetición**: si se descarta una alarma y la condición persiste, vuelve a sonar a los
   **5 min** (guía p.44; constantes de 300 000 ms en el código, I). Solo una alarma por episodio
   de baja/alta (guía p.43).
5. **LO/HI**: LO = lectura < 40 mg/dL, HI = > 500 mg/dL (guía p.32; `GlucoseMin=40`,
   `GlucoseMax=500` en [CFG]; cadenas `low="LO"`, `high="HI"` en [STR]). El gráfico recorta a
   350 mg/dL; el número actual puede llegar a 500 (guía p.30).
6. **Flechas**: 5 categorías + "no determinada" (O); umbrales en mg/dL/min según la guía (p.31).
7. **Alarmas solo en el dispositivo que inició el sensor** (O, cadenas): relevante para el
   diseño iPhone (NFC) + Mac (BLE). Ver "Desconocidos".
8. Cálculo de la condición de alarma (`SasCalculatedAlarmCondition`, incl. proyectadas) viene de
   la capa nativa SAS: **fuera de este alcance**; la UI solo recibe la condición.

## 2. Tabla de hallazgos — Q7 (APK)

| # | Hallazgo | Tag | Evidencia |
|---|----------|-----|-----------|
| A1 | `AlarmConfiguration` = `(highGlucoseAlarmThreshold:int, lowGlucoseAlarmThreshold:int)`; `GlucoseValueRange` = `(g_min, g_max)` ints | O | ev_4ae29ac1a065, ev_fbb9c0fe06bd |
| A2 | Enum `Alarm` (capa SAS): GLUCOSE_OK, HIGH_GLUCOSE, LOW_GLUCOSE, NOT_DETERMINED, PROJECTED_HIGH_GLUCOSE, PROJECTED_LOW_GLUCOSE (con `fromValue/toValue` numérico; valores numéricos no decompilados) | O / ? | ev_459b97b51966 |
| A3 | `SasCalculatedAlarmCondition`: mismas 6 condiciones + `errorCode/errorIcon/errorTitle/errorMessage/isStreaming/useNextDialog` (cada condición puede mapear a un diálogo de error) | O | ev_c1518d0a2eff |
| A4 | `TrendArrow`: FALLING_QUICKLY, FALLING, STABLE, RISING, RISING_QUICKLY, NOT_DETERMINED; `fromValue(int)/toValue()`; valores enteros no recuperados (`<clinit>` sin cuerpo decompilado) | O / ? | ev_81554dc47d56, ev_2ab618cbe354 |
| A5 | `AlarmSettingEntity` (BD): `lowGlucoseAlarmEnabled`, `highGlucoseAlarmEnabled`, `signalLossAlarmEnabled`, `lowGlucoseThresholdMgdl`, `highGlucoseThresholdMgdl`, `isAlarmNotificationEnabled`, `timestampUTC`, `timeZoneLocal` → los umbrales se guardan **siempre en mg/dL** | O | ev_147b1c7e7fe3 |
| A6 | `AlarmsStateEntity` guarda episodios en curso: `isHighEpisodeOngoing`, `isLowEpisodeOngoing`, `isFixLowEpisodeOngoing`, `isSignalLossEpisodeOngoing` (se restaura tras reinicio) | O | ev_40cc6b1c8822 (K6.`<init>`) |
| A7 | Existen **tres alarmas de glucosa**: baja, alta y "baja grave/fija" (`FixLow`, `alarm_serious_low_glucose`) + pérdida de señal. La UI de selección de valor (`SetGlucoseAlarmValueActivity`) solo edita baja y alta | O | ev_40cc6b1c8822, ev_fb93cb056b0c, [STR] |
| A8 | Rangos del selector (mg/dL): baja 60→100 paso 5; alta 120→400 paso 10. mmol/L: baja 3,3→5,6; alta 6,7→22,2, paso 0,1. El valor elegido en mmol/L se convierte a mg/dL con `GlucoseUnit.MMOL_PER_LITER_APPROXIMATE` (factor ≈ 18; I) | O (rangos) / I (factor) | ev_fb93cb056b0c, ev_b175c5c2ba57 |
| A9 | Defaults de build ES: `LowAlarmDefaultThreshold=70`, `HighAlarmDefaultThreshold=240`, `FixedLowAlarmDefaultThreshold=60`; `…DefaultEnabled=false` para baja, alta, baja fija y pérdida de señal. Las prefs `pref_low_glucose_alarm_value` / `pref_high_glucose_alarm_value` / `pref_*_alarm_status` toman estos defaults vía la tabla `Wr` (enlace Wr→clave de [CFG]: I) | O ([CFG]) / I (enlace) | [CFG], ev_40cc6b1c8822, ev_c0a600361225 |
| A10 | Rango de lectura: `GlucoseMin=40`, `GlucoseMax=500`; `MinActionable=70`, `MaxActionable=500` (semántica de "actionable" no confirmada) | O / ? | [CFG] |
| A11 | Constantes de tiempo del motor de alarmas (`H6`, inicializadas en `K6.<init>`): 300 000 ms (×4 campos: t, p, r, B), 1 200 000 ms (q), 1 800 000 ms (o), 86 400 000 ms (m, n), `s=7`. Significado por campo no confirmado; q=20 min coincide con la pérdida de señal y 300 000 con la repetición de 5 min de la guía | O (valores) / I (significado) | ev_40cc6b1c8822, ev_0c4ec8f43918 |
| A12 | Modelo de episodio: cada tipo (alta, baja, baja fija, pérdida de señal) tiene un objeto con estado `"On Going"` / `"Ended"`; descartar una alarma crea un "periodo de descarte" (`dismiss period started for low alarm`); guarda `pref_last_*_alarm_dismiss_time` y `pref_last_*_presentation_time`; hay contador `signal_loss_consecutive_presentation_count` | O | ev_407f50e6f9ed, ev_c97b5ae14d42, ev_8ac5a420d0c2, ev_7dda011eafa1, ev_190da1b16966, ev_2d045b0c29bf, ev_40cc6b1c8822 |
| A13 | Receptores: `SignalLossCheckAlarmReceiver`, `SignalLossAlarmsUnavailableReceiver`, `AutoClearanceCheckAlarmReceiver`, `SensorExpireCheckAlarmReceiver`, `BootCompletedReceiver`, y receptor de `RINGER_MODE_CHANGED` → comprobaciones programadas con `AlarmManager`; restauración tras reinicio | O | ev_a255411d0df7, ev_40cc6b1c8822 |
| A14 | Estados del sensor en la app: `SensorState` = NONE, IN_WARMUP, READY, ENDED. `getMillisInSensorWarmup = warmupEndTime − sensorStartTime`; `getMillisInSensorLife = expireTime − sensorStartTime` (los tiempos vienen del objeto `Sensor`, es decir de la capa SAS) | O | ev_bc1bd1eeb979, ev_5a47e3711231, ev_0cc28d9b157a |
| A15 | Notificaciones de sensor: `SensorNotificationType` = NONE, WARMUP, READY, EXPIRES_3DAYS, EXPIRES_1DAY, EXPIRES_1HOUR, EXPIRED, TERMINATED. Aviso de terminación se programa 5 min en el futuro (`scheduleTerminationAlarm`) | O | ev_10d97b3263a7, ev_7a60a705e2a6, ev_a8892b7efde7 |
| A16 | Vida del sensor Libre 2 Plus = 15 días; Libre 2 = 14 (guía). El tiempo real de caducidad lo da el sensor (`Sensor.getExpireTime`) | O (guía) | guía p.8, p.126 |
| A17 | Calentamiento = 60 min; tras él, la app espera la primera lectura (< 60 s habitual) y luego muestra una lectura automática cada minuto | O | guía p.28, p.93; [STR] `sensor_please_wait_msg`, `automatic_glucose_title`, `sensorReadyIn` |
| A18 | Alarmas no disponibles se explican por: Bluetooth apagado, notificaciones desactivadas, No Molestar activo (hay que permitir "Alertas críticas"), sensor sin comunicar con la app, banners desactivados, sonido desactivado; si la app se cierra: "LibreLink se ha cerrado. No recibirá las alarmas." | O | [STR] `alarms_unavailable_*`, `notification_app_closed`, `alarms_unavailable_dnd_on` |
| A19 | Las alarmas solo existen si el sensor Libre 2 se inició con **este** dispositivo ("Las alarmas solo están disponibles si se inicia el sensor FreeStyle Libre 2 con este dispositivo"); un sensor iniciado por otro dispositivo se puede usar solo si se escanea en su primera hora ("late join"); build ES: `EnableUnlimitedLateJoin=true`, `EnableLimitedLateJoin=false`. Texto late join: "puede escanear el sensor con su teléfono y el dispositivo usado para iniciarlo… no se comparten datos entre dispositivos" | O | [STR] `alarm_config_instruction_unavailable`, `error_sensor_already_started_msg_llj`, `sensorLateJoinMessage`; [CFG] |
| A20 | Config ES adicional: `EarlyTerminationAlarm=true`, `Streaming=true`, `EnableAlarms=true`, `NAITrendArrow=false`, `NAIProjectedGlucose=false` (flechas/proyección "no accionables" desactivadas) | O | [CFG] |
| A21 | Texto de selección: "Receive a Signal Loss Alarm when your glucose alarms are not available because the Sensor is not communicating with the App"; se activa automáticamente al activar la 1ª alarma de glucosa | O | [STR] `alarm_config_signal`, `alarm_config_signal_loss_auto_on` |
| A22 | Selección de tono por alarma (`pref_{low,high,signal_loss}_alarm_tone`); el volumen/vibración los controla el teléfono | O | ev_40cc6b1c8822, [STR] `alarm_config_choose_sound` |
| A23 | Unidades: `GlucoseUnit` = MG_PER_DECILITER, MMOL_PER_LITER, MMOL_PER_LITER_APPROXIMATE (`convert = valor·factorOrigen/factorDestino`; factores no mostrados). En build ES la unidad está fijada por país (mg/dL); otras builds permiten elegir en el asistente y luego **no** se puede cambiar | O / ? | ev_b175c5c2ba57, [CFG] `UnitOfMeasure`, [STR] `unitOfMeasurementFixedTopText`, `unitOfMeasurementTopTextForSetup` |
| A24 | Rango objetivo guardado en mg/dL (`valueGlucoseTargetRangeLowInMgPerDl`, `…HighInMgPerDl`); se dibuja en gráficos y calcula tiempo en rango; **independiente de las alarmas** ("The Target Glucose Range setting will not set glucose alarm levels"). Valor por defecto: no recuperado | O / ? | cadenas del DEX, [STR] `glucose_range_caution`, `targetGlucoseRangeTopText` |

## 3. Flechas de tendencia (Q7/Q8)

| Categoría (código) | Texto app (ES) | Significado (guía p.31) | Tag |
|---|---|---|---|
| RISING_QUICKLY | "aumentando rápidamente" | > +2 mg/dL/min | O |
| RISING | "aumentando" | +1 a +2 mg/dL/min | O |
| STABLE | "cambiando lentamente" | −1 a +1 mg/dL/min | O |
| FALLING | "disminuyendo" | −1 a −2 mg/dL/min | O |
| FALLING_QUICKLY | "disminuyendo rápidamente" | < −2 mg/dL/min | O |
| NOT_DETERMINED | "con tendencia no disponible" | sin flecha | O |

Cadenas ES: `trendExplanation*`, `resultWithTrend*` [STR]. Cómo calcula el sensor/capa nativa la
categoría (ventana, suavizado) es **?**; el cliente no recalcula (se recibe como enum).

## 4. Mensajes y textos del sensor (ES, [STR])

| Estado | Título / texto |
|---|---|
| Sin sensor | "Sin sensor activo" |
| Calentamiento | "Iniciando nuevo sensor"; "El sensor puede utilizarse en %s"; listo: "Sensor listo / El sensor está listo para su uso" |
| Espera 1ª lectura | "ESPERE — … suele demorar menos de 60 segundos" |
| Termina | "El sensor se agota dentro de: %s"; "Sensor agotándose"; aviso a 3 días, 1 día y 1 hora (enums, A15) |
| Caducado | "Sensor agotado — Inicie un nuevo sensor para comprobar la glucosa" |
| Falla definitiva | "Sustituir el sensor — Su sensor no funciona. Quite su sensor e inicie uno nuevo." (+ variante DSPC "se ha desconectado por su seguridad") |
| Temporal | "Error del sensor — Lectura de glucosa no está disponible. Intente de nuevo en 10 minutos."; DSPC: "Lecturas de glucosa en pausa" |
| Temperatura | "Sensor muy frío" / "Sensor muy caliente" |
| Inserción | "Comprobar sensor" (punta no bajo la piel) |
| Otro dispositivo | "Sensor ya en uso" / "iniciado por otro dispositivo" |
| Pérdida de señal | "Pérdida de señal"; "Alarmas no disponibles. Escanear sensor."; "Las alarmas de glucosa no están disponibles" |
| Alarmas | "Alarma de glucosa baja/alta/baja grave/pérdida de señal"; botón "Descartar alarma y comprobar glucosa" |
| Seguridad | "La glucosa baja/alta puede ser peligrosa. … Haga una prueba de glucosa en sangre antes de tomar decisiones de tratamiento." |

## 5. Hallazgos — Q8 (guía del lector)

| # | Hallazgo | Tag | Guía |
|---|----------|-----|------|
| G1 | Pantalla de lectura: glucosa actual (grande, mg/dL), flecha de tendencia, gráfico de lecturas actuales y almacenadas, mensaje, y botón de notas | O | p.19 |
| G2 | Gráfico: eje 50–350 mg/dL; lecturas > 350 se dibujan en 350; el número actual puede ser hasta 500; muestra rango objetivo sombreado y símbolos de notas (comida, insulina rápida); símbolo de "hora cambiada" y huecos | O | p.30, p.50 |
| G3 | LO < 40 mg/dL; HI > 500 mg/dL; si sale LO/HI: comprobar con tira; si se repite, contactar con profesional | O | p.32 |
| G4 | Mensajes de lectura: glucosa > 240 o < 70 mg/dL muestra mensaje; si se prevé > 240 o < 70 en < 15 min muestra mensaje de tendencia. **No dependen de la configuración de alarmas** | O | p.32–33 |
| G5 | Alarmas: DES por defecto; baja 70 (rango 60–100), alta 240 (rango 120–400), pérdida de señal tras 20 min sin comunicar; la alarma no incluye el valor: hay que escanear/abrir para verlo; una alarma por episodio; ignorada → repite a los 5 min si persiste | O | p.34–40, p.43–44 |
| G6 | Alcance del sensor 10 m sin obstáculos; el sensor solo no suena, requiere el lector (o app) cerca; sin comunicación no hay alarmas de glucosa; la pérdida de señal avisa; icono de "sensor se comunica / no se comunica" | O | p.12, p.34, p.36 |
| G7 | El rango objetivo de glucosa (configuración de informes) se muestra en gráficos y calcula "período en objetivo"; **no** es el nivel de alarma. Ejemplo mostrado 80–140 mg/dL (no es un valor por defecto) | O | p.31, p.85, p.52 |
| G8 | Notas: insulina de acción rápida, insulina de acción lenta, alimentos (la guía del lector); la app añade ejercicio y medicación [STR]. Cada nota admite dato adicional (unidades, gramos/raciones). Notas de comida e insulina rápida salen como símbolos en gráficos y libro de registro. Se puede añadir en el momento o hasta 15 min después; editar solo la entrada más reciente dentro de 15 min (reader) | O (lector) / I (aplica igual en app) | p.45–46, p.49 |
| G9 | Historial: libro de registro (cada escaneo/prueba, con notas), gráfico diario (24 h, huecos si no se escaneó en 8 h), patrones diarios (mediana + percentiles 10–90, requiere ≥ 5 días), glucosa promedio (total + 4 franjas de 6 h), período en objetivo (% arriba/en/abajo), sucesos de glucosa baja (< 70 mg/dL durante ≥ 15 min, por franjas), uso del sensor (lecturas/día, % datos captados); ventanas 7/14/30/90 días; el lector guarda ~90 días | O | p.47–52; [STR] `days7/14/30/90` |
| G10 | Colores: lecturas fuera del objetivo en naranja, dentro en azul (promedio) | O | p.51 |
| G11 | Memoria del sensor: 8 h con una muestra cada 15 min; escanear al menos cada 8 h para no perder datos (sin streaming) | O | p.126, p.86 |
| G12 | Sensores: Libre 2 (14 d, ≥ 4 años) y Libre 2 Plus (15 d, ≥ 2 años); calentamiento 60 min; reemplazo si hay irritación, se afloja o el sistema avisa | O | p.8, p.28, p.54 |
| G13 | Advertencias: no ignorar síntomas; confirmar con pinchazo si la lectura no concuerda; la glucosa intersticial difiere de la sangre en cambios rápidos (tras comidas, insulina, ejercicio); no usar las alarmas como única detección; usarlas junto con valor, flecha y gráfico; sonido/vibración y batería suficientes; quitar el sensor para RM/TAC/rayos X | O | p.10–12, p.35–36 |
| G14 | Solución de problemas de alarmas: no activadas, sin comunicación, sonido/vibración off, umbral mal puesto, alarma ya descartada en ese episodio, sensor agotado, batería agotada | O | p.95–97 |
| G15 | Hora/fecha: importante que sea correcta; afecta datos y configuración; cambio de hora se refleja en gráficos | O | p.22, p.88 |
| G16 | Unidades en la guía: mg/dL (sensor); mmol/L solo para cuerpos cetónicos. Cambio de unidad no descrito en la guía del lector | O | p.126–128 |

## 6. Requisitos para la app macOS

Prioridad: **M** imprescindible, **S** recomendable, **C** opcional. Origen entre paréntesis.

**Barra de menús / pantalla principal**
- R1 (M). Mostrar valor actual + flecha de tendencia en la barra de menús, con unidad (mg/dL por defecto; mmol/L opcional). (G1)
- R2 (M). Sustituir cifra por "LO" si < 40 mg/dL y "HI" si > 500 mg/dL; nunca mostrar un número fuera de 40–500. (G3, A10)
- R3 (M). Flecha con 5 estados + "sin tendencia" (––) cuando `NOT_DETERMINED`; la categoría viene del sensor/capa nativa, no se recalcula en la app. (A4, §3)
- R4 (M). Marcar como obsoleta la lectura cuando no llegue dato nuevo (el streaming entrega una lectura por minuto; definir "viejo" p. ej. > 5 min) y mostrar estado "sin señal". (A17; umbral 5 min = I)
- R5 (M). Popover/ventana con: valor grande, flecha, gráfico del día, rango objetivo sombreado, hora de la última lectura, estado del sensor (días restantes / "Termina en …"). (G1, G2, [STR] `sensorEndsIn`)
- R6 (S). Fondo/indicador de color por zona: bajo (< 70), entre bajo y objetivo, en objetivo, entre objetivo y alto, alto (> 240) — la app móvil lo hace con "Color de fondo de glucosa". Colores exactos: ?. ([STR] `glucoseBetweenTarget70/240`, `backgroundGlucoseColors*`)
- R7 (M). Gráfico: eje Y con tope visual 350 mg/dL (o equivalente en mmol/L), línea de rango objetivo, huecos visibles cuando falten datos (> ~8 h para el diario del lector), iconos de notas. (G2, G9)
- R8 (S). Mensajes de contexto cuando > 240 o < 70, y de "tendencia a alta/baja" si se prevé cruzar en 15 min; independientes de las alarmas. Esto último requiere definir si la tendencia proyectada viene del sensor (A2 sugiere sí en capa nativa) o se estima localmente (I). (G4)

**Alarmas y notificaciones**
- R9 (M). Alarmas: baja, alta, pérdida de señal; todas **desactivadas por defecto**. (G5, A9)
- R10 (M). Umbrales configurables: baja 60–100 mg/dL (paso 5, defecto 70); alta 120–400 mg/dL (paso 10, defecto 240); guardar siempre en mg/dL y convertir para mostrar (3,3–5,6 y 6,7–22,2 mmol/L, paso 0,1). (A5, A8)
- R11 (M). Pérdida de señal tras 20 min sin lectura; se activa automáticamente la primera vez que se activa baja o alta, con aviso explicativo. (G5, A21)
- R12 (M). Una alarma por episodio; si se descarta y la condición persiste, volver a notificar a los 5 min; episodio nuevo cuando la glucosa vuelva a la zona normal y cruce otra vez. Persistir estado del episodio entre reinicios. (G5, A6, A12) *(histéresis de fin de episodio: ?)*
- R13 (M). La notificación **no lleva el valor** en la guía; la nuestra puede incluirlo (decisión de diseño) pero el botón principal debe ser "Descartar alarma y comprobar glucosa". (G5, [STR] `dismiss_alarm`)
- R14 (S). Alarma "baja grave" fija (defecto en [CFG]: umbral 60 mg/dL, desactivada por defecto en ES): ofrecer como opción no editable o con umbral fijo. Comportamiento real en la app: ?. (A7, A9)
- R15 (M). Mostrar claramente cuándo las alarmas **no están disponibles**: Bluetooth apagado, notificaciones denegadas, Focus/No Molestar (pedir notificaciones de "tiempo sensible"/críticas), sin conexión con el sensor, app cerrada, sonido desactivado. (A18)
- R16 (M). Si la app no se está ejecutando no hay alarmas ("LibreLink se ha cerrado. No recibirá las alarmas."): arrancar al iniciar sesión, helper de fondo, avisar al usuario cuando se cierre. (A18)
- R17 (M). Aviso permanente de que **no sustituye** las alarmas oficiales y de que hay que confirmar con pinchazo si los síntomas no concuerdan; dosificar solo con medidor/lector oficial hasta verificación. (G13, PLAN.md)
- R18 (S). Selección de sonido por alarma. (A22)
- R19 (S). Avisos de sensor: calentamiento (60 min), listo, caduca en 3 días / 1 día / 1 hora, caducado, terminado/sustituir. (A15, A17)

**Unidades y ajustes**
- R20 (M). Unidades mg/dL y mmol/L; elegir una vez y conservar; mostrar advertencia "es MUY importante seleccionar la unidad correcta". (A23, [STR] `unitOfMeasureWarning`)
- R21 (M). Rango objetivo configurable, independiente de las alarmas, almacenado en mg/dL; valor por defecto elegido por nosotros (p. ej. 70–180, **I**: no recuperado del APK). (A24, G7)

**Notas y libro de registro**
- R22 (S). Notas por lectura: insulina rápida, insulina lenta, alimentos (gramos/raciones), ejercicio, medicación; iconos en gráfico y libro; editar/borrar. Ventana de 15 min del lector: opcional. (G8)
- R23 (S). Libro de registro: lista cronológica con valor, hora, notas; detalle por entrada. (G9)

**Historial / informes**
- R24 (S). Gráfico diario; patrones diarios (mediana + P10–P90, ≥ 5 días); glucosa promedio (por franjas de 6 h); tiempo en rango (arriba/dentro/debajo); eventos de baja (< 70 mg/dL ≥ 15 min); uso del sensor; ventanas 7/14/30/90 d. (G9)
- R25 (C). Exportar CSV/PDF. (no está en la guía del lector; sí hay informes en la app: `EnableEstimatedA1cReport`)

**Sensor**
- R26 (M). Página de estado del sensor: tipo (Libre 2 Plus 15 d), días restantes, fase (calentamiento/activo/caducado), mensajes de error de §4. (A14–A17)
- R27 (M). Comunicar la restricción del dispositivo iniciador: alarmas/streaming solo con el dispositivo que activó el sensor (iPhone vía NFC) — ver desconocidos. (A19)

## 7. Desconocidos / pendientes

1. **Valores numéricos** de `TrendArrow`/`Alarm`/`SensorNotificationType` (`<clinit>` sin cuerpo): útil solo si aparecen en BLE/BD; no bloquea la UI. Se pueden leer parseando el DEX si se necesita.
2. **Semántica exacta de cada constante `H6`** (cuál es repetición, descarte, caducidad de alarma, 30 min, 24 h). Requiere seguir los usos en `N6`/`SignalLossCheckAlarmReceiver`/`GlucoseAlarmService` (clases ofuscadas); no completado.
3. **Histéresis / fin de episodio** de alarma baja/alta y cuándo se considera "conectado" tras señal perdida: ?
4. **Alarma "baja grave"**: ¿umbral fijo 55/60, activable por usuario, siempre activa en otras regiones? En el build ES: defecto 60, desactivada, sin UI de edición hallada. ?
5. **Alarmas proyectadas** (`PROJECTED_*`) en la UI: existen en el enum, pero `NAIProjectedGlucose=false` y la guía solo habla de "mensajes". ?
6. **Valor por defecto y límites del rango objetivo** en la app: no recuperados. La guía del lector solo da ejemplo (80–140).
7. **Colores** (fondo, zonas, gráfico): sin recuperar (recursos de color no consultados).
8. **Factor exacto** de `MMOL_PER_LITER` frente a `…_APPROXIMATE` (probablemente 18,016 vs 18): ? (I por los rangos del selector).
9. **Dispositivo iniciador y streaming**: ¿puede un segundo dispositivo (Mac) recibir las lecturas BLE de un sensor activado por NFC desde el iPhone? Las cadenas indican que la app móvil solo ofrece alarmas/streaming al dispositivo que lo inició y que otros dispositivos hacen "late join" (solo escaneo, datos no compartidos). Es una cuestión de protocolo (áreas A/B), pero condiciona la decisión de producto. ?
10. **Cálculo de la tendencia y de las condiciones de alarma** (SAS nativo): fuera de este alcance (área C).
11. **Guía sin versión de app**: la guía es del lector; para comportamiento exacto de la app (colores, pantallas) habría que ver el manual de la app o recursos de layout.

## 8. Veredictos

- **Q7 — Alarmas (baja/alta/señal perdida), rangos, tiempos y textos: RESPONDIDA (parcial en tiempos internos).**
  Rangos, defectos, unidades, textos ES, estados del sensor y notificaciones de caducidad: observados
  ([CFG], código, guía). Tiempos: pérdida de señal 20 min y repetición 5 min observados en la guía y
  consistentes con constantes del código (I en el mapeo campo↔función). Pendientes: histéresis, alarma
  baja grave, proyectadas, valores numéricos de enums.
- **Q8 — Requisitos de pantallas según guía: RESPONDIDA** (con la salvedad de que la guía es la del
  lector, no la de la app). Los requisitos R1–R27 cubren pantalla principal, gráfico, rango objetivo,
  alarmas, notas/libro, unidades y advertencias.
