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
baja, muy baja, LO/HI, lectura vieja, sin señal, sin conexión, aceptar términos, sin
pacientes, sensor por terminar, y **Recorrido automático** (cambia de situación cada
60 s; consulta cada 15 s). Hay dos pacientes para ver el selector. El demo no toca el
llavero ni el paciente/región guardados; los **Ajustes** (umbrales, notificaciones) sí son
los mismos. Las notificaciones del demo dicen "Demo ·". No se recuerda al reiniciar.

`swift run llu --demo high` hace lo mismo por terminal.

## Correr

```bash
cd mac
swift test                                       # tests de LibreKit (fixtures)
LLU_EMAIL=... LLU_PASSWORD=... swift run llu    # prueba rápida por terminal
swift run LibreLibreLink                               # app de barra de menú (sin notificaciones)
scripts/make-app.sh --install                    # arma LibreLibreLink.app y la copia a ~/Applications
```

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

`LO` < 40 y `HI` > 500. El panel lista cada problema con su explicación, muestra los días
restantes del sensor y tiene **Ajustes**: notificaciones (apagadas por defecto), umbrales
de baja (60–100) y alta (120–400), sin señal, abrir al iniciar sesión. Una notificación
por episodio, repetida cada 5 min mientras dure.

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
scripts/sync-strings.sh             # extrae los textos del código al catálogo (como Xcode)
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
  el puntero).
- **Informes** (7/14/30/90 días): glucosa promedio, A1c estimada (GMI), variabilidad (CV),
  uso del sensor, **Tiempo en rango** (por debajo / en rango / por encima, y episodios de
  baja < 70 durante ≥ 15 min) y **Patrones diarios** (mediana y percentiles 25–75 y 10–90;
  hacen falta ≥ 5 días).

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

Libro de registro y notas (insulina, comidas), exportar CSV/PDF, persistir el estado de
los episodios de alarma entre reinicios.
Las notificaciones usan nivel "time sensitive", pero sin firma de Apple Developer pueden
quedar silenciadas por Concentración / No Molestar.
