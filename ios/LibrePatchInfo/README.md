# LibrePatchInfo — mini-app iOS para leer la generación del sensor

Lee por NFC el **UID** y el **patchInfo** de tu FreeStyle Libre 2 Plus y dice si
es **gen1** (camino directo Mac↔sensor posible) o **gen2** (bloqueado por la caja
blanca de Abbott → nube o puente). **No activa el sensor ni habilita streaming:
solo lee.** Podés escanear tu sensor ya puesto sin afectar a LibreLink.

## Requisito que condiciona todo

Core NFC con comandos ISO 15693 personalizados necesita la **capability "Near
Field Communication Tag Reading"**, y firmar esa app en tu iPhone requiere una
**cuenta de Apple Developer de pago (US$99/año)**. Con un Apple ID gratuito,
Xcode no deja agregar la capability NFC. (Ver fuentes en el chat.)

Si no querés pagar: la alternativa de costo cero es un **teléfono Android con
NFC** y una app libre (Glimp / Juggluco / xDrip+) que muestra el patchInfo sin
cuenta de desarrollador. Decime si tenés un Android a mano.

## Crear el proyecto en Xcode (26.6)

1. Xcode → **File ▸ New ▸ Project… ▸ iOS ▸ App**. Product Name: `LibrePatchInfo`,
   Interface: **SwiftUI**, Language: **Swift**. Guardalo donde quieras.
2. Borrá los `ContentView.swift` y `LibrePatchInfoApp.swift` que genera y
   **arrastrá** los tres archivos de `Sources/` de esta carpeta al proyecto
   (Copy items if needed).
3. **Signing & Capabilities** (selección del target):
   - Team: tu cuenta **de pago**.
   - **+ Capability ▸ Near Field Communication Tag Reading**.
4. **Info** del target → agregá la clave
   **`NFCReaderUsageDescription`** (Privacy - NFC Scan Usage Description) con un
   texto como: `Leer la generación de tu sensor Libre`.
5. Conectá el iPhone, elegilo como destino y **Run (⌘R)**. La primera vez:
   Ajustes ▸ General ▸ VPN y gestión de dispositivos → confiá en tu perfil.

## Usar

Abrí la app → **Escanear sensor** → acercá la parte de atrás del iPhone (arriba)
al sensor. Te muestra UID, patchInfo, familia, generación y el veredicto.
Tocá **Compartir** y pasame el texto: con esos bytes confirmo el camino.

## Qué hace con los bytes (misma regla que la app de Abbott)

`patchInfo[2]`: nibble alto 3 → bajo < 9 = gen1, si no gen2; nibble alto 7 →
bajo < 4 = gen1, si no gen2. (Hallazgo del área B, Evidence E01–E45.)
