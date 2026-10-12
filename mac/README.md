# LibreBar — glucosa en la barra de menú (vía LibreLinkUp)

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
- `swift run LibreBar --demo`, o `open dist/LibreBar.app --args --demo`.

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
swift run LibreBar                               # app de barra de menú (sin notificaciones)
scripts/make-app.sh --install                    # arma LibreBar.app y la copia a ~/Applications
```

Para alarmas y "Abrir al iniciar sesión" hay que usar **`LibreBar.app`**; con `swift run`
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

La primera vez, LibreBar pide email y contraseña de LibreLinkUp y los guarda en el
**llavero** de macOS. La región (Argentina → `LA`) se detecta sola por redirección.

## Estructura

- `Sources/LibreKit` — cliente `LibreLinkUpClient` (login con redirect, header
  `account-id` = SHA-256 del user id, `/llu/connections`, `/llu/connections/{id}/graph`)
  y modelos. Referencia: `pylibrelinkup` 0.11.1.
- `Sources/LibreBar` — `MenuBarExtra`: valor + flecha, edad de la lectura, gráfico de
  ~12 h con rango 70–180, selector de paciente, actualización cada 60 s.
- `Sources/llu` — CLI de diagnóstico.

## Pendiente (Fase 5)

Historial persistente (SwiftData), estadísticas (tiempo en rango), mmol/L, persistir el
estado de los episodios entre reinicios. Las notificaciones usan nivel "time sensitive",
pero sin firma de Apple Developer pueden quedar silenciadas por Concentración / No Molestar.
