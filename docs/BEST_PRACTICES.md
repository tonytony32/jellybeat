# JellyBeat: recomendaciones y best practices

Guía para reconstruir el proyecto desde cero sin repetir los errores que ya
costó corregir. Complementa a [`PLAN.md`](plans/PLAN.md) (el *qué* y el orden de
fases) explicando el *cómo*: las decisiones de diseño que hacen el código
testeable, concurrente-seguro y fácil de evolucionar.

Todo lo de aquí está destilado de una auditoría arquitectural real del propio
código. Donde digo "evita X", es porque X ya apareció y hubo que arreglarlo.

---

## 0. Principios rectores

1. **Una clase, una responsabilidad.** Si describes lo que hace una clase y
   usas "y" más de una vez, divídela.
2. **Las capas fluyen en un sentido:** `Networking → State → UI`. Una capa
   inferior nunca conoce a una superior.
3. **Una sola fuente de verdad** por dato. Si el mismo valor vive en dos
   sitios, acabarán desincronizándose.
4. **El compilador es tu primer test.** Swift 6 strict concurrency, tipos
   `Sendable`, value types por defecto. Que los errores de hilos sean de
   compilación, no de runtime.
5. **Sin dependencias externas** salvo justificación concreta. `URLSession`,
   `Observation`, `os.Logger` y Keychain cubren casi todo.

---

## 1. Stack base (decidido)

- **Swift 6** con strict concurrency activada desde el primer commit. Activarla
  tarde es una migración dolorosa; activarla desde el inicio es gratis.
- **SwiftUI** para la UI, **AppKit** solo donde SwiftUI no llega (la `NSWindow`
  borderless flotante), puente con `NSHostingView`.
- **Sin SPM externo.** Cero dependencias por defecto.
- **`os.Logger`** con subsistema único y categorías por capa
  (`networking`, `state`, `ui`).

---

## 2. Arquitectura por capas

```
┌─────────────────────────────────────────────────────────────┐
│ UI            SwiftUI views + themes. Solo leen el estado.    │
│               No conocen JellyfinClient ni el socket.         │
├─────────────────────────────────────────────────────────────┤
│ State         PlayerStore (@MainActor, @Observable) = fuente  │
│               única de verdad. SettingsStore, caches, poller. │
├─────────────────────────────────────────────────────────────┤
│ Networking    JellyfinClient (REST), JellyfinSocketClient     │
│               (WebSocket), modelos. Stateless, value types.   │
└─────────────────────────────────────────────────────────────┘
                          flujo de datos ▲
```

**Regla de oro:** los datos suben. Networking decodifica modelos crudos →
`PlayerStore` aplica la heurística de sesión activa y publica un snapshot →
las vistas lo renderizan. Nunca al revés.

**Anti-patrón a evitar:** que un tipo de `State` referencie un tipo de `UI`.
Si el store necesita un vocabulario (p. ej. `PlaybackAction` para el feedback
de comandos), ese enum vive en `State`, no dentro de una `View`. La vista mapea
el tipo de dominio a iconos/labels en su lado de la frontera.

---

## 3. Evita el God Object (la lección más cara)

El `AppDelegate` es un imán de responsabilidades porque
`NSApplicationDelegateAdaptor` lo construye sin argumentos y todo el mundo
puede leerlo. Resístelo.

**Patrón: coordinador delgado + colaboradores enfocados.**

```
AppDelegate (coordinador)
  ├── posee los stores compartidos
  ├── OverlayWindowController          ← toda la geometría de ventana
  └── PlaybackConnectionCoordinator    ← toda la máquina de transporte
```

- `AppDelegate` casi no tiene lógica: instancia stores, crea los colaboradores,
  los conecta y delega.
- **Comunicación entre colaboradores por closures, no por referencias directas.**
  Cuando la ventana se minimiza y eso debe pausar el feed, el window controller
  expone `onPauseRequested: (String) -> Void` y el coordinador lo conecta. Así
  ninguno conoce al otro y cada uno se puede testear aislado.

Síntoma de que llegaste tarde: un archivo de 700+ líneas con MARKs para
"Window setup", "Snap", "Poller helpers", "Lifecycle observers"… esos MARKs
son las clases que deberían existir.

---

## 4. Concurrencia (Swift 6)

- **`@MainActor`** para todo lo que toca UI o publica estado observable:
  `PlayerStore`, `SettingsStore`, `ThemeRegistry`, los controladores de AppKit.
- **`actor`** para bucles de I/O con estado propio: el poller REST y el cliente
  WebSocket. Encapsulan su `task`, `paused`, continuations, etc.
- **Value types `Sendable`** para lo que cruza fronteras de aislamiento:
  configuración, modelos, snapshots. `JellyfinClient` es un `struct` sin estado
  mutable → se comparte libre entre actores.
- **`Data` como moneda de cambio**, no `NSImage`, para que las caches sigan
  siendo `nonisolated`-friendly y la UI construya imágenes en el main actor.

### Tasks: siempre cancelables, siempre `[weak self]`

Cada `Task` de larga vida o reintento se guarda en una propiedad y se cancela
antes de crear el siguiente. **Nunca dispares un `Task` con un `sleep` sin
guardar su handle**, se te acumulan.

```swift
private var reconnectTask: Task<Void, Never>?

func scheduleReconnect() {
    reconnectTask?.cancel()              // ← mata el anterior
    reconnectTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(60))
        guard !Task.isCancelled, let self else { return }
        …
    }
}
```

Y cancélalos en el teardown (`stop()`, `shutdown()`).

---

## 5. Observación: precisa, no firehose

Para reaccionar a cambios de estado, usa el **framework Observation**
(`withObservationTracking`) sobre las propiedades exactas que te importan, no
`NotificationCenter` con `UserDefaults.didChangeNotification`.

```swift
// BIEN: se dispara solo si cambia una propiedad de conexión.
private func watchConnectionSettings() {
    withObservationTracking {
        _ = settings.baseURLString
        _ = settings.apiKey
        _ = settings.userId
    } onChange: { [weak self] in
        Task { @MainActor in
            self?.scheduleDebouncedReconfigure()
            self?.watchConnectionSettings()   // ← re-armar: el callback es one-shot
        }
    }
}
```

- `UserDefaults.didChangeNotification` se dispara con **cualquier** escritura en
  toda la app (incluida la posición de la ventana) → trabajo inútil.
- Recuerda **re-armar**: `withObservationTracking` notifica una sola vez.
- **Debounce** las entradas de texto (un `SecureField` emite una mutación por
  tecla): cancela un `Task` anterior y duerme ~500 ms antes de actuar.

---

## 6. Networking

- **Cliente stateless** (`struct`). Polling, caching y políticas de comando
  viven en capas superiores, no en el cliente.
- **Sesiones URLSession separadas por presupuesto de timeout:** 5 s para el
  polling (debe fallar rápido), 15 s para validación/control/artwork.
- **Inyecta `protocolClasses`** en el init para poder meter un `MockURLProtocol`
  en tests sin levantar un servidor.
- **Mapea errores de forma exhaustiva** a un enum propio (`NetworkError`):
  distingue `unauthorized` (parar el polling), `selfSignedCert`, `serverError`
  con código, `transport`, `decodingFailed`. Quien llama decide la política
  según el caso, no según un `Error` opaco.
- **Decoder tolerante** a las variaciones reales del servidor (Jellyfin emite
  ISO-8601 con y sin fracciones de segundo: prueba ambas estrategias).
- **Nunca logues la URL completa** si la API key viaja como query param; logea
  `host:port`.

---

## 7. Estado y persistencia

- **Secretos al Keychain por defecto** (cifrado en reposo). Permite UserDefaults
  solo como opt-in explícito del usuario.
- **Migraciones idempotentes.** Al arrancar, detecta el estado previo (toggle
  viejo, clave suelta en UserDefaults) y migra una vez, sin romper si se ejecuta
  dos veces. Documenta las reglas de migración junto al código.
- **Wrapper `@Observable`** sobre `UserDefaults`: persiste en `didSet` para que
  cerrar Settings sin un botón "Guardar" mantenga todo en sync.

---

## 8. Caching de imágenes

- **Clave de cache = `itemId + tag`.** Así un cambio de artwork en el servidor
  (tag nuevo) invalida la entrada automáticamente.
- **Dos niveles:** memoria → disco → red.
- **LRU de verdad, no FIFO.** Si llevas una lista de orden de inserción para
  desalojar, **promueve la clave al final también en cada *hit***, no solo al
  insertar. Si no, la portada más usada (insertada pronto) es la primera en
  caer. Alternativa: `NSCache`, que gestiona presión de memoria gratis.
- **Versiona el directorio de disco** (`artwork_v3/`): si cambias tamaño o
  formato de descarga, subir la versión invalida lo viejo sin código de purga.

---

## 9. Puente AppKit ↔ SwiftUI

La ventana borderless flotante tiene trampas conocidas; documéntalas en el
código porque no son obvias:

- **`canBecomeKey = true`** en una `NSWindow` borderless, o los botones SwiftUI
  dejan de recibir clicks tras cambiar de Space.
- **`hitTest` con fallback a `self`** en el `NSHostingView`, o los clicks pasan a
  través de los huecos transparentes a la ventana de debajo.
- **El `NSWindowDelegate` lo posee el window controller**, no el `AppDelegate`.
- **Flag `suppressMoveCallback`** alrededor de cualquier `setFrame`
  programático, para no retroalimentar el snap con un movimiento que tú mismo
  causaste.

---

## 10. Testing

- **Swift Testing** (`import Testing`, `@Suite`, `@Test`), no XCTest.
- **`MockURLProtocol`** + fixtures JSON reales del servidor para testear el
  cliente sin red.
- **`@Suite(.serialized)`** cuando los tests tocan recursos compartidos del
  proceso (UserDefaults, Keychain): si no, se pisan en paralelo.
- **Qué testear primero:** la capa de red (decoding, mapeo de errores, headers
  de auth) y la lógica de persistencia/migración. Son las que más se rompen en
  silencio.
- **Qué cuesta testear** (y por qué importa la arquitectura): la máquina de
  estados de transporte y la geometría de ventana. Si las extraes a
  colaboradores con dependencias inyectadas (§3), pasan de "intesteable" a
  testeable.

---

## 11. Logging

- `os.Logger` con un subsistema (`software.trypwood.jellybeat`) y **una
  categoría por capa**.
- **Marca los secretos como `.private`** en los formatters; el resto `.public`
  para que sea útil en Console.app.
- Logea las transiciones de la máquina de estados (socket connected/failed,
  fallback a polling, pause/resume), son tu mejor herramienta de diagnóstico
  sin debugger.

---

## 12. Checklist anti-patrones

Los siete errores reales que esta auditoría encontró, como lista de "no hagas":

- [ ] ❌ Una clase que gestiona ventana **y** conexión **y** sleep/wake **y**
      settings. → Divide en colaboradores.
- [ ] ❌ Un tipo de `State` que nombra un tipo de `View`. → Enum de dominio.
- [ ] ❌ El mismo dato (p. ej. `userId`) pasado por dos vías al mismo objeto.
      → Una fuente.
- [ ] ❌ `Task { sleep; retry }` sin guardar el handle. → Task cancelable.
- [ ] ❌ Cache que dice "LRU" pero no promueve en los hits. → Promueve o `NSCache`.
- [ ] ❌ Métodos muertos que duplican a otro vivo. → Bórralos.
- [ ] ❌ Observar `UserDefaults.didChangeNotification` para un cambio concreto.
      → `withObservationTracking` preciso.

---

## 13. Orden de arranque sugerido

1. Modelos + `NetworkError` + `JellyfinClient` stateless, **con tests** y
   `MockURLProtocol` desde el día uno.
2. `SettingsStore` con Keychain y migración, **con tests**.
3. `PlayerStore` (`@MainActor`, `@Observable`) y la heurística de sesión.
4. `PlaybackPoller` (actor) → transporte mínimo funcionando.
5. Ventana borderless + `OverlayView` con un solo theme.
6. `PlaybackConnectionCoordinator`: añade WebSocket con fallback al poller.
7. `OverlayWindowController`: snap, posición por display, modo ambient.
8. Resto de themes, Now Playing del sistema, pulido.

Mantén `AppDelegate` delgado **desde la fase 5**. Es mucho más barato no dejar
que crezca que descomponerlo después.
```
