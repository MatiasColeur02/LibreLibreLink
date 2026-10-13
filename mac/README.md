# LibreLibreLink — glucosa en la barra de menú (vía LibreLinkUp)

Camino A (ver `re/HANDOFF.md`): el iPhone sigue con LibreLink, que sube los datos a
LibreView; esta app de macOS los lee de la API de **LibreLinkUp** (~1 min de retraso).
⚠️ No reemplaza las alarmas oficiales; no usar para decidir dosis.

## Preparar la cuenta (una sola vez)

1. En el iPhone, en **LibreLink**: Menú ▸ **Compartir** ▸ **Conectar a LibreLinkUp** ▸
   invitar a un email (conviene uno distinto al de tu cuenta LibreLink).
2. Instalar **LibreLinkUp** en un teléfono, crear la cuenta con ese email, **aceptar la
   invitación** y los términos. Si la app de Mac dice "aceptar términos", es este paso.

## Probar sin cuenta (modo demo)

Para ver la app sin tener LibreLinkUp: un servidor falso (`LibreKit/DemoServer.swift`)
contesta las peticiones del cliente real, con datos inventados (una curva de un día
típico + el escenario elegido). Entrar al demo:

- en el panel de inicio de sesión: **Probar sin cuenta (datos de demostración)**, o
- `swift run LibreLibreLink --demo`, o `open dist/LibreLibreLink.app --args --demo`.

Arriba del panel aparece **Modo demo** con un selector de escenario: día normal, alta,
bajando hacia la baja, baja, muy baja, LO/HI, lectura vieja, sin señal, sin conexión, aceptar términos, sin
pacientes, sensor por terminar, sensor nuevo (calentando), y **Recorrido automático** (cambia de situación cada
60 s; consulta cada 15 s). Hay dos pacientes para ver el selector. El demo no toca el
llavero ni el paciente/región guardados; los **Ajustes** (umbrales, notificaciones) sí son
los mismos. Las notificaciones del demo dicen "Demo ·". No se recuerda al reiniciar.

`swift run llu --demo high` hace lo mismo por terminal.

## Correr

```bash
cd mac
swift test                                       # tests de LibreKit (fixtures)
LLU_EMAIL=... LLU_PASSWORD=... swift run llu    # prueba rápida por terminal
swift run LibreLibreLink                               # app de barra de menú (sin notificaciones ni widgets)
scripts/make-app.sh --install                    # arma LibreLibreLink.app y la copia a ~/Applications
```

`make-app.sh` usa **Xcode** y **xcodegen** (`brew install xcodegen`): genera
`LibreLibreLink.xcodeproj` desde `project.yml` (no se versiona) y compila la app con dos
extensiones, todo con firma local (sin cuenta de Apple Developer). `LibreKit` se compila como
biblioteca estática para los tres; los tests siguen con `swift test` (`Package.swift`).

## Integración con la Mac (Idea 3)

- **Widgets** (`Widgets/`, extensión WidgetKit con sandbox): chico (valor), mediano (valor +
  3 h) y grande (12 h, tiempo en rango, promedio y bajas de hoy, sensor). Leen
  `~/Library/Application Support/LibreLibreLink/snapshot.json`, que escribe la app
  (`GlucoseSnapshot`, `LibreKit/Shared.swift`) y los recarga con cada cambio; la excepción de
  sandbox `temporary-exception.files.home-relative-path` les da acceso a esa carpeta.
- **Atajos** (`Intents/`, extensión App Intents): obtener glucosa (devuelve el número en la
  unidad elegida), resumen de hoy, anotar en el registro (escribe directo en el SQLite),
  posponer / reactivar alarmas, modo discreto y abrir la ventana. Con firma local, macOS no
  logra comunicarse con acciones que corren dentro de la app (probado), por eso van en una
  extensión. Lo que necesita a la app se lo pide con URLs `librelibrelink://` (`AppCommand`),
  que también la abren si estaba cerrada. Posponer desde Atajos no calla la baja grave.
- **Atajos en alarmas** (Ajustes ▸ Atajos en alarmas): corre un atajo propio al empezar una baja,
  una alta o sin señal, y al volver al rango (`ShortcutTrigger`), con `/usr/bin/shortcuts run`.
  Recibe un texto como «Glucosa baja · 64 mg/dL ↘».
- **Atajo de teclado global** (Ajustes ▸ Barra de menú; ⌥⌘G por defecto): abre el panel.
  Usa `RegisterEventHotKey`, que no pide permiso de Accesibilidad.
- **Modo discreto**: oculta el valor en la barra (queda una gota, o el ícono del problema) y en
  los widgets. A mano con el ojo del panel o desde Atajos; automático mientras alguna app usa la
  cámara o el micrófono (CoreMediaIO / CoreAudio, sin permisos). macOS no tiene una API pública
  para saber si se comparte la pantalla.

Para alarmas y "Abrir al iniciar sesión" hay que usar **`LibreLibreLink.app`**; con `swift run`
macOS no permite notificaciones. Si la app pide acceso al llavero la primera vez,
elegí "Permitir siempre".

## Qué muestra la barra de menú (Fase 4)

| Estado | Barra | Cuándo |
| --- | --- | --- |
| Normal | `123 ↗` monocromo | lectura reciente en rango |
| Muy baja | octágono rojo + valor | < 55 mg/dL (fijo) |
| Baja | círculo ↓ rojo + valor | < umbral de baja (def. 70) |
| Alta | círculo ↑ naranja + valor | > umbral de alta (def. 240) |
| Lectura vieja | reloj + valor | 10–20 min sin lectura nueva |
| Sin señal | antena tachada + `––` | ≥ 20 min sin lectura (el iPhone no sube datos) |
| Sin conexión | wifi tachado + valor | falla la red o LibreLinkUp |
| Revisar cuenta | persona + `LibreLink` | sin sesión, términos sin aceptar, nadie a quien seguir |

`LO` < 40 y `HI` > 500. El panel lista cada problema con su explicación y muestra los días
restantes del sensor. Los **Ajustes** están en la ventana grande (**Abrir ventana ▸ Ajustes**,
`Sources/LibreLibreLink/SettingsView.swift`): notificaciones (apagadas por defecto), umbrales
de baja (60–100) y alta (120–400), sin señal, abrir al iniciar sesión. Una notificación
por episodio, repetida cada 5 min mientras dure.

**Alarmas más inteligentes** (`LibreKit/Status.swift`: `AlarmPolicy`, `AlarmSnoozes`, `AlarmEngine`):
- **Bajando rápido** (desactivada): ≤ −2 mg/dL/min (flecha ↓ o recta de 15 min) estando en rango.
- **Alta sostenida**: "Avisar: enseguida / si dura 30 min / 1–3 h". La barra muestra la alta
  enseguida igual; una laguna de más de 30 min en los datos corta la racha.
- **Noche** (desactivada; def. 23:00–7:00): umbrales propios (baja 80, alta 270) y opción de no
  avisar la alta. La baja grave (< 55) no cambia.
- **Acciones en la notificación**: posponer 15/30/60 min; en las bajas, «Ya comí · recordame en
  15 min» (pospone las bajas 15 min y programa "Volvé a medir"). Posponer una baja también calla
  "baja en camino" y "bajando rápido", pero no la baja grave; la baja grave solo se pospone
  tratándola (máx. 15 min). Las pospuestas se ven en el panel ("Reactivar") y no sobreviven a un
  reinicio (vuelven a sonar).
- **Escalada** (activada): baja o baja grave sin atender 10 min (sin tocar la notificación) → se
  repite cada 2 min y se lee en voz alta aunque la voz esté apagada.

**Diagnóstico de alarmas** (arriba de Ajustes ▸ Cómo te avisa): dice si las alarmas pueden avisarte o
por qué no, con el arreglo a mano: notificaciones y voz apagadas, permiso de macOS pendiente o
bloqueado, estilo «Ninguno», sin sonido, notificaciones urgentes desactivadas (Concentración),
Mac en silencio, no se abre al iniciar sesión, sin datos de LibreLinkUp (`LibreKit/AlarmDelivery.swift`).
Si activaste notificaciones o voz pero ninguna puede llegar, el panel lo muestra en naranja
con un botón que abre Ajustes.
No detecta si Concentración está activa (requiere un permiso de Apple) ni si la Mac va a dormir.

**Baja en camino** (Ajustes, bajo el umbral de baja; activada): si la glucosa cae al menos
1 mg/dL/min (recta sobre los últimos 15 min) y a ese ritmo cruzaría el umbral de baja en 15 min o
menos, se marca en rojo y avisa como una alarma más (`LibreKit/Forecast.swift`). Es una estimación.

**Leer las alarmas en voz alta** (Ajustes; desactivado): dice la alarma con la voz del sistema
("Glucosa baja, 64, bajando"). Suena aunque Concentración / No Molestar silencie las
notificaciones (sí depende del volumen) y funciona aunque las notificaciones estén apagadas.

**Avisos del sensor** (Ajustes ▸ Avisos del sensor, activado si las notificaciones lo están): sensor
nuevo (cambia el número de serie), listo tras los 60 min de calentamiento, termina en 3 días /
1 día / 1 hora y terminado. Cada uno sale una sola vez por sensor (se recuerda al reiniciar; si
pasaron varios con la app cerrada, solo el más reciente). Durante el calentamiento la barra y el
panel muestran "Sensor calentando" en lugar de "Sin señal".

La primera vez, LibreLibreLink pide email y contraseña de LibreLinkUp y los guarda en el
**llavero** de macOS. La región (Argentina → `LA`) se detecta sola por redirección.

## Idiomas (inglés y español)

La app sigue el idioma de macOS: español si el sistema está en español, inglés en
cualquier otro caso. Para probar el otro idioma sin cambiar el sistema:
`open dist/LibreLibreLink.app --args --demo -AppleLanguages "(en)"`.

Se usa un **String Catalog** de Apple (`Localization/Localizable.xcstrings`, se puede abrir
en Xcode). El español es el idioma base: los textos del código son las claves. Al
agregar o cambiar textos:

```bash
scripts/sync-strings.sh             # compila con Xcode y extrae los textos (app, widgets, Atajos)
python3 scripts/translations_en.py  # aplica el inglés; avisa si falta alguna traducción
scripts/make-app.sh                 # compila el catálogo dentro de la .app
```

En la UI, los literales (`Text("…")`, `Button("…")`) se traducen solos; los textos armados
en código usan `String(localized:)`, y lo que no se traduce (valores, unidades), `Text(verbatim:)`.
Con `swift run` no hay bundle, así que se ve siempre en español.

## Estructura

- `Sources/LibreKit` — cliente `LibreLinkUpClient` (login con redirect, header
  `account-id` = SHA-256 del user id, `/llu/connections`, `/llu/connections/{id}/graph`)
  y modelos. Referencia: `pylibrelinkup` 0.11.1.
- `Sources/LibreLibreLink` — `MenuBarExtra`: valor + flecha, edad de la lectura (el gráfico está en la ventana), selector de paciente, actualización cada 60 s.
- `Sources/llu` — CLI de diagnóstico.

## Ventana (Fase 5)

Desde el panel, **Abrir ventana** (mientras está abierta, LibreLibreLink aparece en el Dock):

- **Hoy**: glucosa actual grande, tiempo en rango y promedio del día, días restantes del
  sensor, y **Gráfico diario** (6 h / 12 h / 24 h / por día, con el valor y la hora al pasar
  el puntero). Las anotaciones del registro aparecen como íconos arriba del gráfico (los
  pinchazos, en su valor).
- **Registro** (7/14/30/90 días): **Anotar** comida (g de carbohidratos), insulina rápida o
  lenta (U), ejercicio (min), glucómetro o una nota; tocar una anotación la edita y el menú
  contextual la elimina. Con los datos del sensor muestra:
  - **Después de comer**, por desayuno / almuerzo / merienda / cena: subida desde la glucosa
    al comer, a los cuántos minutos llega el pico (en las 3 h siguientes) y cuánto tarda en
    volver al rango (hasta 5 h).
  - **Glucómetro vs sensor**: diferencia media (sensor − glucómetro), MARD y % dentro de
    15/15 (±15 mg/dL debajo de 100, ±15 % arriba). Sirve para la verificación de la Fase 6.
  Se guarda en la misma base SQLite (tabla `entries`; lógica en `LibreKit/Logbook.swift`).
- **Informes** (7/14/30/90 días): glucosa promedio, A1c estimada (GMI), variabilidad (CV),
  uso del sensor, **Tiempo en rango** (por debajo / en rango / por encima, y episodios de
  baja < 70 durante ≥ 15 min) y **Patrones diarios** (mediana y percentiles 25–75 y 10–90;
  hacen falta ≥ 5 días).
- **Exportar PDF** (en Informes): informe AGP de una página para el médico, del período elegido:
  estadísticas, tiempo en los 5 rangos del consenso internacional (< 54, 54–69, 70–180, 181–250,
  > 250, con sus metas), perfil AGP (percentiles 5–95) y los últimos 14 días. Se abre al guardarlo.

Los colores son los del panel: verde en rango, naranja por encima, rojo por debajo.
En **Ajustes ▸ Visualización**: unidad (mg/dL o mmol/L) y rango objetivo (def. 70–180),
que pinta los gráficos y el tiempo en rango sin cambiar las alarmas.

**Historial:** LibreLinkUp solo da ~12 h, así que LibreLibreLink guarda cada lectura que ve en
`~/Library/Application Support/LibreLibreLink/history.sqlite` (SQLite, una por minuto y paciente).
Los informes se llenan con los días mientras la app está abierta. Para tener meses desde el primer
día: **Informes ▸ Importar** y elegir el CSV de LibreView (libreview.com ▸ Descargar datos de
glucosa); se agrega al paciente elegido sin tocar las lecturas ya guardadas
(`LibreKit/LibreViewCSV.swift`). El demo usa una base en
memoria con 14 días inventados y no toca ese archivo. Estadísticas ponderadas por tiempo
(el historial llega cada 5 min y las lecturas en vivo cada 1 min).

Requiere macOS 15.

## Pendiente

Anotar desde la barra de menú, registro en el PDF, exportar CSV, persistir el estado de
los episodios de alarma entre reinicios.
Las notificaciones usan nivel "time sensitive", pero sin firma de Apple Developer pueden
quedar silenciadas por Concentración / No Molestar.
