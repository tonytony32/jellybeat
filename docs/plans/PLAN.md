# JellySleeve — Plan de implementación v3

Documento de trabajo para Claude Code. Autocontenido. Léelo entero antes de empezar a crear archivos.

Las decisiones marcadas como **DECIDIDO** no se cuestionan, se ejecutan. Si encuentras un bloqueo no cubierto aquí, para y pregunta al usuario en lugar de improvisar.

**Versión 3** introduce el sistema de themes/layouts como ciudadano de primera desde Fase 4, motivado por el hecho de que en Sleeve los "themes" no son cosméticos sino layout presets estructurales (Prestige horizontal, Stack vertical, Minim sin artwork, Elegant prominente, etc.). El plan v2 los degradaba a toggles sueltos de Fase 6, lo cual no permitía replicar la experiencia que el usuario valora más.

**Versión 2** (previa) incorporó una auditoría arquitectural que corrigió errores técnicos del v1 (APIs inexistentes, filtros de sesión insuficientes, manejo de errores), explicitó zonas ambiguas (Window setup, concurrencia), y reordenó prioridades (tests y Keychain antes, no después).

---

## 1. Brief del proyecto

**Qué es.** App macOS standalone, tipo overlay flotante de escritorio, inspirada visualmente en Sleeve 3 (replay.software/sleeve), que muestra el "now playing" de un servidor Jellyfin remoto y permite control básico de reproducción (play/pause/next/prev). **No reproduce audio.** El audio sale del cliente que el usuario use (en este caso, web player de Jellyfin en Safari).

**Por qué existe.** El usuario tiene toda su música en un servidor Jellyfin en una Raspberry Pi. Quiere experiencia UI tipo Sleeve, pero Sleeve solo soporta Apple Music, Spotify y Doppler via AppleScript local. Esta app evita AppleScript, evita depender de Replay (devs de Sleeve), y trabaja contra el REST API del server. Funciona con cualquier cliente Jellyfin del usuario (web, móvil, otro Mac), no solo el del Mac local.

**Para quién.** Uso personal del autor, distribución directa (sin Mac App Store).

---

## 2. Stack y target técnico (DECIDIDO)

- **Lenguaje:** Swift 6.0 con strict concurrency
- **UI:** SwiftUI principalmente, con AppKit para `NSWindow` borderless flotante (`NSHostingView` para puente)
- **Target OS:** macOS 26.0 Tahoe mínimo
- **Arquitectura:** Apple Silicon only (arm64)
- **Concurrencia:** async/await. `PlayerStore` y vistas en `@MainActor`. Cliente REST no aislado, puede correr en cualquier executor
- **Persistencia:**
  - Settings no sensibles: `UserDefaults` via wrapper `@Observable`
  - **API key: Keychain desde Fase 3**, no UserDefaults
- **Networking:** `URLSession` con configuración custom (timeout 5s en polling, 15s en validación/control), `URLSessionDelegate` para trust opcional de self-signed certs
- **Imágenes:** descarga manual con caching en disco + memoria. Clave de cache = `itemId + imageTag` (ver Fase 2)
- **Logging:** `os.Logger` con subsistema `software.trypwood.jellysleeve` y categorías por capa (`networking`, `state`, `ui`). API key marcada `.private` en formatters
- **Dependencias externas SPM:** ninguna por defecto. Si la necesitas, justifícala en el PR con motivo concreto

**Nombre del proyecto:** `JellySleeve`. Bundle ID: `software.trypwood.jellysleeve`.

---

## 3. Arquitectura general

Tres capas, sin frameworks de DI complicados, pero con responsabilidades estrictas para evitar God Objects.

### 3.1 Capa de red (`Networking/`)

`JellyfinClient` es un actor o struct sin estado mutable salvo `Configuration` (baseURL, apiKey, userId, allowSelfSigned). Métodos async que devuelven modelos `Codable` o lanzan `NetworkError`. **No** mantiene polling, **no** decide qué sesión es la activa, **no** cachea. Solo hace una llamada y devuelve una respuesta.

### 3.2 Capa de estado (`State/`)

`PlayerStore` (`@MainActor`, `@Observable`) es la fuente única de verdad de la UI. Expone:
- `connectionState: ConnectionState` (`.idle | .connecting | .connected | .error(String)`)
- `currentTrack: TrackSnapshot?`
- `isPaused: Bool`
- `selectedSessionId: String?`
- `availableSessions: [SessionSummary]` (para el selector manual de la Fase 4)

`PlaybackPoller` es otro objeto (`actor`) que ejecuta el polling loop, llama al `JellyfinClient`, aplica políticas de error (backoff, stop en 401), aplica la heurística de "qué sesión es activa", y commitea cambios al store via `await MainActor.run`. Separar el poller del store evita que el store haga networking.

`SettingsStore` (`@MainActor`, `@Observable`) envuelve UserDefaults. La API key se lee/escribe via `KeychainHelper`, no aparece en UserDefaults.

`ArtworkCache` (actor) hace download bajo demanda y mantiene cache LRU en memoria + disco. Clave: `"\(itemId)_\(imageTag)"`.

### 3.3 Capa de UI (`UI/`)

`PlayerStore` y `SettingsStore` se inyectan en el `@main` App como `@State` y se pasan via `.environment(...)`. Las vistas las leen con `@Environment(PlayerStore.self)` y similar. No singletons globales.

Ventanas:
- **Overlay window:** `NSWindow` borderless creada manualmente en `AppDelegate`, contenido SwiftUI con `NSHostingView`. Ver Fase 1.
- **Settings:** scene SwiftUI `Settings { SettingsView() }` que da `Cmd+,` y entrada de menú automáticas.
- **MenuBarExtra** con "Open Overlay", "Settings...", "Quit".

```
JellySleeve/
├── App/
│   ├── JellySleeveApp.swift          # @main, Settings scene, MenuBarExtra
│   └── AppDelegate.swift             # NSWindow setup, NSWorkspace observers
├── Networking/
│   ├── JellyfinClient.swift          # actor o struct, métodos REST
│   ├── Endpoints.swift               # paths constantes
│   ├── NetworkError.swift
│   ├── TrustingURLSessionDelegate.swift  # self-signed opt-in
│   └── Models/
│       ├── ServerInfo.swift
│       ├── Session.swift
│       ├── NowPlayingItem.swift
│       └── PlayState.swift
├── State/
│   ├── PlayerStore.swift             # @MainActor @Observable, fuente de verdad UI
│   ├── PlaybackPoller.swift          # actor, polling loop + heurística sesión
│   ├── SettingsStore.swift           # @MainActor @Observable, settings
│   ├── KeychainHelper.swift          # CRUD API key
│   ├── ArtworkCache.swift            # actor, LRU memoria + disco
│   └── ConnectionState.swift         # enum
├── UI/
│   ├── Overlay/
│   │   ├── OverlayWindowController.swift  # NSWindow custom
│   │   ├── OverlayView.swift              # root, recibe el theme actual
│   │   ├── Components/                    # piezas reutilizables entre themes
│   │   │   ├── ArtworkView.swift
│   │   │   ├── TrackInfoView.swift
│   │   │   ├── ControlsView.swift         # hover-revealed
│   │   │   ├── ConnectionDotView.swift
│   │   │   └── GlassBackground.swift
│   │   └── Themes/
│   │       ├── OverlayTheme.swift         # protocol + specs
│   │       ├── ThemeRegistry.swift        # registro de built-ins
│   │       ├── ElegantTheme.swift         # default, Fase 4
│   │       ├── StackTheme.swift           # Fase 6
│   │       ├── ClassicTheme.swift         # Fase 6
│   │       ├── MinimTheme.swift           # Fase 6
│   │       └── AeroTheme.swift            # Fase 6
│   └── Settings/
│       ├── SettingsView.swift             # TabView
│       ├── ServerTab.swift
│       ├── AppearanceTab.swift            # theme switcher
│       └── DiagnosticsTab.swift           # log viewer
├── Tests/
│   ├── JellyfinClientTests.swift
│   ├── ModelsTests.swift
│   └── Fixtures/                          # JSON de respuestas Jellyfin
└── Resources/
    ├── Assets.xcassets
    └── Info.plist
```

---

## 3bis. Sistema de themes / layouts (decisión estructural)

Sleeve trata los "themes" como layout presets completos, no como cambios cosméticos. JellySleeve hace lo mismo. Esta sección define el contrato.

### 3bis.1 Conceptos

**Theme** = layout completo del overlay. Define qué componentes se muestran, dónde, con qué tamaños relativos, y con qué estilo tipográfico. Cambiar de theme cambia el árbol de vistas.

**LayoutSpec** = parámetros estructurales (orientation, artwork size, controls position, padding, corner radius, window aspect).

**TypographySpec** = parámetros tipográficos por línea (title, artist, album): font weight, size, opacity, max lines.

**BehaviorSpec** = parámetros de comportamiento (controls always vs on-hover, glass material, shadow intensity).

### 3bis.2 Protocol

```swift
protocol OverlayTheme: Identifiable, Hashable {
    var id: String { get }              // "elegant", "stack", etc.
    var displayName: String { get }     // "Elegant"
    var author: String { get }          // "Built-in"
    var layout: LayoutSpec { get }
    var typography: TypographySpec { get }
    var behavior: BehaviorSpec { get }

    @ViewBuilder
    func body(track: TrackSnapshot?, store: PlayerStore) -> AnyView
}

struct LayoutSpec {
    enum Orientation { case vertical, horizontal, minimal }
    enum ControlsPosition { case below, overlayBottom, hidden, beside }
    let orientation: Orientation
    let artworkSize: CGFloat?           // nil = no artwork (Minim)
    let controlsPosition: ControlsPosition
    let windowSize: CGSize
    let padding: CGFloat
    let cornerRadius: CGFloat
}

struct TypographySpec {
    struct LineStyle {
        let font: Font
        let weight: Font.Weight
        let opacity: Double
    }
    let title: LineStyle
    let artist: LineStyle
    let album: LineStyle
    let showAlbum: Bool
}

struct BehaviorSpec {
    let controlsAlwaysVisible: Bool
    let glassMaterial: NSVisualEffectView.Material
    let shadowOpacity: Double
}
```

### 3bis.3 ThemeRegistry

`ThemeRegistry` es un actor MainActor que mantiene la lista de built-in themes y el theme seleccionado actualmente:

```swift
@MainActor
@Observable
final class ThemeRegistry {
    let builtIn: [any OverlayTheme]    // populado en init con los disponibles
    var selectedId: String              // persistido en UserDefaults

    var current: any OverlayTheme { /* lookup por selectedId */ }

    func select(_ id: String) { /* asigna + persiste */ }
}
```

### 3bis.4 OverlayView

`OverlayView` ya no es un layout fijo. Observa `ThemeRegistry.current` y delega a `theme.body(track:, store:)`. Cambiar de theme en Settings re-renderiza inmediatamente.

Las piezas concretas (`ArtworkView`, `TrackInfoView`, `ControlsView`) son los building blocks reutilizables que cada theme compone como prefiera.

### 3bis.5 Modificaciones de themes (Fase 7, no MVP)

En Fase 7 se introduce `ThemeOverride`, una struct serializable que guarda solo los campos cambiados respecto a un built-in. La UI permite tocar parámetros sobre un theme base. Al aplicar el override:

```
finalTheme = builtIn.applying(override)
```

Persistencia: `~/Library/Application Support/JellySleeve/themes/overrides/{themeId}.json`. Export a un archivo `.jellysleevetheme` (JSON con metadata + override) que puede importarse por drag-and-drop sobre la app.

**No MVP. Solo Fase 7 si tras uso real lo echas de menos.**

---

## 4. Endpoints Jellyfin

Base URL: configurable en runtime (ej. `http://192.168.1.50:8096` o `https://jellyfin.mi-dominio.com`).

**Auth.** Header `X-Emby-Token: {apiKey}` en TODAS las requests. Alternativa equivalente: `Authorization: MediaBrowser Token="{apiKey}"`. Usar `X-Emby-Token`, es más simple y funciona en Jellyfin 10.7+.

**Validación de conexión.**
```
GET /System/Info
```
Devuelve `Id`, `ServerName`, `Version`. 200 OK = válida. 401 = key incorrecta. Cualquier otro fallo = unreachable o mal configurado.

**Polling principal.**
```
GET /Sessions
```
Array de sesiones. Filtrado en cliente (no en server, no soporta query) para encontrar la sesión activa con esta lógica:

1. Quedarte con sesiones donde `UserId == settings.userId` Y `NowPlayingItem != nil`.
2. De ellas, preferir la que el usuario haya seleccionado manualmente (`selectedSessionId`).
3. Si no hay selección manual o esa sesión ya no existe, coger la más reciente por `LastActivityDate`.
4. Si no hay ninguna, `currentTrack = nil`, connectionState sigue `.connected`.

Campos relevantes del `NowPlayingItem`:
- `Id` (item ID)
- `Name` (título)
- `Artists` (array) o `AlbumArtist` (string)
- `Album`
- `RunTimeTicks` (Int64, ticks de 100ns: dividir por 10_000_000 para segundos)
- `ImageTags.Primary` (string, tag para cache busting)

Campos del `PlayState`:
- `PositionTicks`
- `IsPaused`
- `VolumeLevel` (0-100, opcional)

Del top-level de la sesión:
- `Id` (sessionId, para mandar comandos)
- `Client` (ej. "Jellyfin Web")
- `DeviceName`
- `LastActivityDate`

**Artwork.**
```
GET /Items/{itemId}/Images/Primary?tag={imageTag}&fillHeight=600&quality=90
```
Devuelve binario. Cachear con clave `"\(itemId)_\(tag)"`. Cuando el tag cambia (porque el artwork se actualizó server-side), la URL es nueva y la cache lo refleja automáticamente.

**Control de reproducción.**
```
POST /Sessions/{sessionId}/Playing/PlayPause
POST /Sessions/{sessionId}/Playing/NextTrack
POST /Sessions/{sessionId}/Playing/PreviousTrack
```
Cuerpo vacío. Header `X-Emby-Token`. Respuesta esperada 204. Tras comando OK, refresh inmediato (no esperar al próximo poll) para feedback rápido.

**(Nivel 2) Favoritos.**
```
POST /Users/{userId}/FavoriteItems/{itemId}
DELETE /Users/{userId}/FavoriteItems/{itemId}
```

**(Evolución futura, no MVP) WebSocket push.**
```
GET /socket?api_key={key}&deviceId={uuid}
```
Eventos `Sessions` con cambios push. Latencia subsegundo, sin polling. Implementar en Fase 7 si el polling resulta insuficiente. No MVP.

---

## 5. Políticas de errores y ciclo de vida

### 5.1 Backoff exponencial en errores transitorios

Si una llamada de polling falla por timeout o 5xx, el siguiente intento dobla el delay base hasta un máximo. Tabla:
- Intento 1 fallido: siguiente delay = base * 2 (típicamente 3s)
- Intento 2: base * 4 (6s)
- Intento 3+: cap a 30s

Tras un éxito, vuelve al delay base configurado (1.5s default).

### 5.2 Stop hard en 401

Si una llamada devuelve 401, **detener polling**. Cambiar `connectionState = .error("Unauthorized")`. La app muestra un banner en Settings invitando a revisar la API key. No reintenta hasta que el usuario guarde una nueva key.

### 5.3 Pausa en sleep, reanudación en wake

`AppDelegate` se suscribe a `NSWorkspace.shared.notificationCenter`:
- `NSWorkspace.willSleepNotification`: pausar `PlaybackPoller`
- `NSWorkspace.didWakeNotification`: reanudar `PlaybackPoller` con un primer poll inmediato (no esperar el delay)

### 5.4 Pausa cuando el overlay está oculto

Si la ventana overlay no es visible (usuario la cerró desde MenuBar), el polling pausa. Cuando se vuelve a mostrar, reanuda.

### 5.5 Debounce en controles

Cada botón de control tiene un cooldown de 300ms. Click repetido dentro de la ventana se ignora. Visualizar el estado disabled brevemente para que se note.

### 5.6 Connection state visible

`ConnectionDotView` en una esquina del overlay (4pt de diámetro, posición top-right):
- `.connected`: verde sutil (opacidad 0.6)
- `.connecting`: amarillo
- `.error`: rojo, click abre Settings con el mensaje
- `.idle` (sin config): gris

---

## 6. Fases de implementación

Cada fase tiene **criterio de éxito objetivo** y **estimación de tiempo realista**. No pases a la siguiente hasta verificar el criterio. Commit granular dentro de cada fase, en inglés, imperativo.

### Fase 0: Setup proyecto Xcode (1-2h)

- Crear `.xcodeproj` macOS App, SwiftUI, Swift 6
- Deployment target macOS 26.0
- Architectures arm64
- App Sandbox: OFF
- Hardened Runtime: ON
- Code signing: development team del usuario (configurable, pedir si no se sabe)
- Swift strict concurrency: ON
- Crear estructura de carpetas del punto 3.3
- Archivos placeholder con `// TODO Fase N`

**Criterio:** `xcodebuild build` OK, app se lanza con ventana en blanco.

### Fase 1: NSWindow flotante real (3-5h)

Reemplazar el WindowGroup por una NSWindow custom creada en `AppDelegate.applicationDidFinishLaunching`:

```swift
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 300, height: 380),
    styleMask: [.borderless, .fullSizeContentView],
    backing: .buffered,
    defer: false
)
window.level = .floating
window.isMovableByWindowBackground = true
window.backgroundColor = .clear
window.isOpaque = false
window.hasShadow = true
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
window.contentView = NSHostingView(rootView: OverlayView()...)
window.center()
window.makeKeyAndOrderFront(nil)
```

`OverlayView` placeholder: rectángulo redondeado 16pt con `NSVisualEffectView` material `.hudWindow` (envuelto en `NSViewRepresentable` `GlassBackground`), texto "JellySleeve" centrado.

`@main JellySleeveApp` usa `NSApplicationDelegateAdaptor` y declara la escena `Settings { SettingsView() }` (vacía por ahora) más un `MenuBarExtra("JellySleeve", systemImage: "music.note")` con menú "Open Overlay", "Settings...", "Quit".

**Criterio:**
1. Al ejecutar, aparece cuadrado flotante translúcido sin chrome
2. Se arrastra desde cualquier punto con click and drag
3. Está siempre por encima de otras ventanas, incluido apps full-screen (verifica abriendo Safari en full-screen y comprobando que sigue visible)
4. Cmd+, abre la ventana Settings (vacía)
5. El menubar item aparece

### Fase 2: Cliente REST con tests desde el día 1 (6-10h)

Implementar `JellyfinClient` con:
- `func validateConnection() async throws -> ServerInfo`
- `func fetchSessions() async throws -> [Session]`
- `func fetchArtwork(itemId: String, tag: String) async throws -> Data`
- `func playPause(sessionId: String) async throws`
- `func nextTrack(sessionId: String) async throws`
- `func previousTrack(sessionId: String) async throws`

Modelos `Codable` con `CodingKeys` explícitos (Jellyfin usa PascalCase). Decoder configurado con `keyDecodingStrategy = .useDefaultKeys` y CodingKeys a mano (más seguro que `.convertFromPascalCase` que no existe nativamente).

`NetworkError`:
```swift
enum NetworkError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case notFound
    case serverError(Int)
    case decodingFailed(Error)
    case transport(Error)
    case selfSignedCert
}
```

`URLSessionConfiguration`:
- `timeoutIntervalForRequest = 5` (polling)
- Una segunda config con timeout 15 para validación y comandos
- `TrustingURLSessionDelegate` que acepta self-signed solo si `Configuration.allowSelfSigned == true`

**Tests obligatorios en esta fase:**
- Decode de JSON fixture de `/System/Info` real
- Decode de JSON fixture de `/Sessions` con NowPlayingItem
- Decode de JSON fixture de `/Sessions` vacío
- Error mapping: 401 → `.unauthorized`, 404 → `.notFound`, 500 → `.serverError(500)`
- Auth header presente en todas las requests (usar mock URLProtocol)

Fixtures: grabar respuestas reales del server Jellyfin del usuario una vez y guardarlas en `Tests/Fixtures/*.json`.

Test manual al final de la fase: botón temporal en `OverlayView` que llama a `validateConnection` con datos hardcoded y loggea por consola.

**Criterio:**
1. Todos los tests verdes
2. Botón temporal devuelve `ServerName` correcto contra el server real
3. `fetchSessions` devuelve datos parseados correctamente cuando suena música en el web player

### Fase 3: Settings con Keychain (5-7h)

`SettingsView` como `TabView` con tres tabs: Server, Appearance (vacía por ahora), Diagnostics (vacía por ahora).

**Server tab:**
- TextField "Base URL" con validación URL en cada cambio
- SecureField "API key", lee/escribe via `KeychainHelper`
- TextField "User ID" con helper text: "Dashboard → Users → tu usuario → URL termina en /userId/{este valor}"
- Toggle "Allow self-signed certificates" (default OFF)
- Slider "Refresh rate" 1.0 a 5.0s, default 1.5s
- Botón "Test connection" que llama a `validateConnection`, muestra spinner y luego check verde o error rojo con mensaje

`KeychainHelper`:
- `func save(apiKey: String) throws`
- `func load() -> String?`
- `func delete() throws`
Usar Security framework, account `software.trypwood.jellysleeve.apikey`.

Migration: en primer launch de v2, si hay API key en UserDefaults (de un v1 anterior), moverla a Keychain y borrar de UserDefaults. En esta fase fresh install, no aplica.

`SettingsStore` `@Observable`:
- `baseURL: String` (UserDefaults)
- `userId: String` (UserDefaults)
- `apiKey: String` (computed, lee/escribe Keychain bajo demanda)
- `allowSelfSigned: Bool` (UserDefaults)
- `refreshRate: TimeInterval` (UserDefaults)

**Criterio:**
1. Configurar el server real desde la UI, persiste tras reiniciar
2. API key NO está en `~/Library/Preferences/software.trypwood.jellysleeve.plist` (verificar con `defaults read`)
3. Test connection funciona
4. Borrar la API key del Keychain manualmente con `security delete-generic-password ...` deja la app en estado limpio

### Fase 4: PlaybackPoller + sistema de themes + conectar overlay a datos reales (14-22h)

`PlaybackPoller` actor:
- `func start(client: JellyfinClient, store: PlayerStore, refreshRate: TimeInterval)`
- `func stop()`
- `func pause()` / `func resume()` (para sleep/wake/window-hidden)
- Internamente: loop async con backoff, heurística de selección de sesión (ver 4.0 punto 1-4), commit a `PlayerStore` via MainActor.

`PlayerStore` `@MainActor @Observable`:
```swift
@Observable
@MainActor
final class PlayerStore {
    var connectionState: ConnectionState = .idle
    var currentTrack: TrackSnapshot? = nil
    var isPaused: Bool = false
    var selectedSessionId: String? = nil
    var availableSessions: [SessionSummary] = []
}

struct TrackSnapshot: Equatable {
    let itemId: String
    let imageTag: String?
    let title: String
    let artist: String
    let album: String
    let runtime: Duration
    let position: Duration
    let sessionId: String
}
```

`AppDelegate` se suscribe a `NSWorkspace.willSleepNotification` y `didWakeNotification` para pausar/reanudar el poller. También observa visibility de la ventana overlay (`NSWindow.didMiniaturizeNotification` y similares) para pausar cuando esté oculta.

**Sistema de themes (decisión estructural, no opcional):**

Implementa el protocol `OverlayTheme` y las structs `LayoutSpec`, `TypographySpec`, `BehaviorSpec` de la sección 3bis.

Implementa `ThemeRegistry` `@MainActor @Observable` con un único theme inicial: `ElegantTheme` (el que el usuario tiene seleccionado en Sleeve).

**`ElegantTheme` specs (valores iniciales, ajustables después):**
- Orientation: vertical
- Artwork size: 200pt cuadrada
- Controls: overlayBottom (sobre la base del artwork) con fondo glass discreto
- Window size: 280x360 cuando hay track
- Padding: 12pt
- Corner radius: 18pt
- Typography:
  - Title: `.title3 semibold` opacity 1.0
  - Artist: `.callout regular` opacity 0.85
  - Album: `.caption regular` opacity 0.65
  - Show album: true
- Behavior:
  - Controls always visible: false (on hover)
  - Glass material: `.hudWindow`
  - Shadow opacity: 0.35

`OverlayView` observa `ThemeRegistry.current` y delega a `theme.body(track:, store:)`. El cuerpo del theme decide cómo componer `ArtworkView`, `TrackInfoView`, `ControlsView`.

**Componentes `Components/`:**
- `ArtworkView(size: CGFloat, cornerRadius: CGFloat, shadow: Double)` recibe tamaño desde el theme
- `TrackInfoView(track: TrackSnapshot, typography: TypographySpec)` recibe specs tipográficos
- `ControlsView(behavior: BehaviorSpec, store: PlayerStore)` configurable según theme

**Estados especiales (cualquier theme):**
- Si `currentTrack == nil` y `connectionState == .connected`: el theme renderiza estado "Nothing playing". Cada theme puede hacerlo a su manera. En Elegant: texto centrado, ventana 280x180.
- Si `connectionState == .error`: render universal con mensaje + botón "Open Settings". Ventana 280x180. Se ignora el theme actual para este estado.
- Si `connectionState == .idle` (sin config): render universal "Configure your Jellyfin server" + botón. Ventana 280x180.

**`ConnectionDotView`** overlay en top-right como en 5.6. Es universal a todos los themes.

**Persistencia del theme seleccionado:**
- `ThemeRegistry.selectedId` se guarda en UserDefaults clave `"selectedThemeId"`, default `"elegant"`.

`ArtworkCache` actor:
- Memoria: NSCache<NSString, NSImage> con countLimit ~50
- Disco: `~/Library/Caches/software.trypwood.jellysleeve/artwork/{itemId}_{tag}.jpg`
- API: `func image(for itemId: String, tag: String?) async -> NSImage?`. Lee memoria → disco → red.

**Criterio:**
1. Reproduces algo en el web player, overlay muestra título/artista/álbum/carátula en menos de 2s con layout Elegant
2. Cambias de track, el overlay se actualiza
3. Pausas en web player, indicador IsPaused refleja
4. Cierras el web player, overlay muestra "Nothing playing" tras pocos segundos
5. Pones API key mala, overlay muestra error y polling para
6. Duermes el Mac y lo despiertas, polling reanuda sin spam de errores
7. `OverlayView` delega correctamente al theme: si fuerzas en código `themeRegistry.select("elegant")`, se renderiza vía `ElegantTheme.body`, no con código hardcoded en `OverlayView`

### Fase 5: Controles funcionales (3-5h)

`ControlsView` aparece on hover sobre el overlay con cross-fade 0.2s. Tres botones SF Symbol:
- `backward.fill` → `playerStore.previous()`
- `play.fill` / `pause.fill` (según `isPaused`) → `playerStore.playPause()`
- `forward.fill` → `playerStore.next()`

Cada acción del store:
1. Marca `isCommandInFlight = true` (disabled UI)
2. Llama al cliente
3. Refresh inmediato del estado
4. Tras 300ms desde el comando, `isCommandInFlight = false`

Errores en comandos no rompen polling: se loggean y aparecen como toast sutil en el overlay (label de 2s en la parte inferior).

**Criterio:**
1. Hover muestra controles, mouse-out los oculta con fade
2. Pause/play/next/prev funcionan, latencia percibida < 500ms
3. Doble click rápido en next no manda dos requests
4. Si comando falla (red caída momentánea), toast informa, polling sigue

### Fase 6: Polish, themes built-in adicionales, y robustez (18-27h)

Aquí entra el trabajo "del 80 al 95%" que se subestima sistemáticamente.

**UI polish:**
- Animación de cambio de track: cross-fade artwork 0.4s + slide-up sutil del texto
- Sombra de artwork refinada (NSShadow ajustada para "lifted feel")
- Empty state cuidado, no solo texto pelado
- Loading state mientras descarga primer artwork
- Liquid Glass real con `NSGlassEffectView` o fallback `NSVisualEffectView` material `.hudWindow`
- Hover states con scale 1.05 + opacity en controles

**Window behavior:**
- Settings: "Window level" → on top always / normal / behind
- Snap a esquinas y bordes al arrastrar (threshold 40pt). Implementación: `NSWindowDelegate.windowDidMove` que comprueba `NSScreen.screens` y ajusta a la esquina más próxima si está dentro del threshold
- Multi-monitor: posición se guarda por `NSScreen.displayID`
- Posición persistente entre reinicios

**Diagnostics tab en Settings:**
- Lista de últimos 100 eventos os_log de esta sesión
- Botón "Copy to clipboard"
- Botón "Open log file" si guardamos a disco (opcional)

**Themes built-in adicionales (4 themes nuevos, además del Elegant ya existente):**

Implementar las siguientes structs que conforman `OverlayTheme`. Cada una es un archivo en `UI/Overlay/Themes/`:

- **`StackTheme`**: vertical, artwork grande arriba (220pt), info y controles abajo apilados. Window 260x400. Glass material `.popover`.
- **`ClassicTheme`**: horizontal, artwork mediana izquierda (120pt), info a la derecha (título + artista + álbum en stack vertical), controles mini bajo la info. Window 380x140.
- **`MinimTheme`**: sin artwork (`artworkSize = nil`), solo info en una línea (título + dot + artista) y controles a la derecha. Window 360x80. Glass material `.toolTip`.
- **`AeroTheme`**: artwork dominante (260pt), controles superpuestos sobre la base del artwork con backdrop blur intenso, info debajo. Window 300x420.

Registrar las cuatro en `ThemeRegistry.builtIn` junto con Elegant. Orden de aparición en UI: Elegant, Stack, Classic, Minim, Aero.

**Appearance tab en Settings (theme switcher con preview):**

- Grid o lista vertical de los 5 themes built-in
- Cada celda: thumbnail del layout (renderizado en vivo a escala 0.4 con mock data), nombre, autor "Built-in"
- El theme actual marcado con check + borde de acento
- Click selecciona el theme y aplica al overlay inmediatamente
- Sección "Live preview" en la parte inferior: muestra el overlay actual con el theme seleccionado a tamaño real (opcional, si entra en el layout)

**Toggles globales (afectan a todos los themes, complementarios):**
- "Window level": on top always / normal / behind
- "Window opacity" 0.7-1.0
- "Show controls always" (override del `behavior.controlsAlwaysVisible` del theme)

**Acabados:**
- App icon (placeholder genérico aceptable para uso personal)
- About window con créditos
- Verificar accessibility labels en controles (VoiceOver debe leerlos)
- Localizar strings con `String(localized:)`, inicialmente solo inglés. Estructura preparada para añadir español sin refactor

**Criterio:**
1. La usas un día completo y no hay nada que te haga gracia mal
2. Funciona con dos monitores
3. Sobrevive a poner el Mac a dormir, reconectarte a otra red, y volver
4. Los logs te dan info útil cuando algo falla
5. Puedes cambiar entre los 5 themes built-in desde Settings y cada uno renderiza correctamente con track de prueba
6. La ventana se redimensiona al cambiar de theme (los `windowSize` son distintos)
7. El theme seleccionado persiste tras reiniciar la app

### Fase 7 (Nivel 2, opcional): WebSocket push, atajos globales, modificación de themes

Construir solo si tras una semana de uso lo echas en falta. No por adelantado.

- **WebSocket push:** sustituir polling por `/socket` event stream. Reconexión automática, heartbeat cada 30s, fallback a polling si conexión socket falla 3 veces seguidas.
- **Atajos globales:** `NSEvent.addGlobalMonitorForEvents` para play/pause/next/prev/like. Onboarding del permiso Accessibility con UI dedicada.
- **Modificación de themes (overrides):** introducir `ThemeOverride` serializable. UI con sliders y selectores en la Appearance tab para tocar parámetros del theme actual (tamaño artwork, opacidad líneas, fuente, etc.). Indicador "Modified" en la celda del theme. Botón "Reset to default" que borra el override. Persistencia en `~/Library/Application Support/JellySleeve/themes/overrides/{themeId}.json`.
- **Export/import de themes:** formato `.jellysleevetheme` (JSON con metadata + override). Export con NSSavePanel. Import por drag-and-drop en la app o doble click si registramos UTI en Info.plist.
- **HUD de feedback:** ventana auxiliar tipo Sleeve para volume/track changes.
- **Updater Sparkle:** si vas a compartir el binario con alguien más.
- **Crash reporting:** opcional, solo si open source.

---

## 7. No-goals (cosas que NO vamos a hacer)

- No reproducir audio en la app. El audio sale del web player.
- No scrobble a Last.fm desde la app. Lo hace el plugin del server (`danielfariati/jellyfin-plugin-lastfm`).
- No soporte para más servers (Plex, Spotify, Apple Music). Solo Jellyfin.
- No App Store, no sandbox estricto.
- No iCloud sync.
- No formato de archivo propio para themes (`.jellysleevetheme`) en Fases 0-6. JSON simple, sin UTI registrado. Esto llega en Fase 7 si entra.
- No modificación de themes (overrides de parámetros) en MVP. Built-in themes son inmutables en Nivel 1.
- No creación de themes desde cero en MVP ni en Nivel 2. Si llega, Fase 7+.
- No tests UI (XCUITest). Solo unit tests del cliente REST y modelos.

---

## 8. Riesgos conocidos y mitigaciones

| Riesgo | Probabilidad | Mitigación |
|---|---|---|
| API Liquid Glass macOS 26 distinta a la esperada | Media | Fallback siempre a `NSVisualEffectView` material `.hudWindow`. Verificar API exacta al empezar Fase 1 |
| Heurística de "sesión activa" elige la sesión incorrecta | Media | Permitir override manual en Fase 4. Si insuficiente, añadir selector permanente |
| Jellyfin server con HTTPS self-signed (Tailscale, Caddy) | Alta | Toggle en Settings, `URLSessionDelegate` que valida según preferencia |
| Plugin Last.fm del server deja de mantenerse | Baja-Media | Aceptado. Si pasa, considerar scrobble cliente como Fase 7 |
| macOS 27 cambia API de NSWindow level/behavior | Baja | Postergar hasta que pase. Hoy macOS 26 |
| Polling consume mucha batería en MacBook | Media | Pausa cuando overlay oculto + pausa en sleep. Si insuficiente, WebSocket en Fase 7 |
| Protocol `OverlayTheme` queda corto para algún layout exótico (ej. controles laterales) | Media | Aceptar `AnyView` en `body()` deja a cada theme libertad total. Specs son orientativos, no atan |
| Cambio de theme rompe la geometría de la ventana | Media | `OverlayWindowController` observa `themeRegistry.current` y actualiza `window.setContentSize(theme.layout.windowSize)` con animación 0.2s |

---

## 9. Notas operativas para Claude Code

- **Una fase por sesión.** No saltes. Si bloqueas, para y pregunta antes de improvisar.
- **Commits granulares.** Un commit por sub-tarea dentro de cada fase. Mensajes en imperativo y en inglés ("Add JellyfinClient.validateConnection with tests").
- **Tests verdes antes de commitear** en Fase 2 en adelante.
- **Logs.** `os.Logger`, nunca `print` salvo botón temporal de Fase 2 (que se borra antes de Fase 3).
- **Secrets.** API key solo en Keychain desde Fase 3. Nunca en logs (formatter `.private`).
- **No instales nada via Homebrew, pip o SPM** salvo que el plan lo justifique.
- **Si necesitas inspeccionar la API real de Jellyfin**, consulta `https://api.jellyfin.org/` o haz una llamada de prueba contra el server del usuario (te pedirá Base URL y API key).
- **Verifica las APIs nuevas de macOS 26 al empezar Fase 1.** Si `NSGlassEffectView` o `.glassEffect()` no existe o tiene otro nombre, usa `NSVisualEffectView` y déjalo documentado en código.

---

## 10. Cuándo está "terminado Nivel 1"

1. Configurada con server real, muestra correctamente el track sonando en el web player
2. Controles play/pause/next/prev funcionan con feedback inmediato
3. Manejo correcto de errores (401, red caída, sesión inexistente)
4. Sobrevive a sleep/wake del Mac sin spam de logs
5. Settings persisten entre reinicios, API key en Keychain
6. Tests del cliente REST verdes
7. 5 themes built-in (Elegant, Stack, Classic, Minim, Aero) seleccionables desde Settings, persistentes entre reinicios
8. La usas un día completo y no te molesta

**Esfuerzo total estimado Nivel 1: 40-60 horas.**

Lo demás (modificación de themes, export/import, WebSocket push, atajos globales, HUD) es Nivel 2 y se evalúa con uso real.

---

## 11. Datos del autor para configuración

En Fase 3 el usuario configurará en runtime:
- Base URL del server Jellyfin en su Raspberry Pi
- API key (la generará en Dashboard > API Keys del server)
- User ID (lo cogerá del dashboard también)
- Self-signed cert toggle si aplica a su setup

No los hardcodees. Pídelos via Settings UI.

---

## 12. Preparación para open source

JellySleeve se va a publicar como open source tras el MVP Nivel 1, no antes. Pero hay cosas que conviene hacer bien desde el día uno para que abrirlo después sea trivial. Esta sección lista lo que debe estar listo en cada fase.

### 12.1 Decisión pendiente antes de Fase 0

**Bundle ID y namespace.** El plan asume `software.trypwood.jellysleeve`. Antes de empezar Fase 0, confirmar con el usuario si quiere:
- A) Mantener `software.trypwood.jellysleeve` (asociación con su empresa trypwood)
- B) Cambiar a un namespace personal o dedicado (ej. `dev.antonio.jellysleeve` o `software.jellysleeve.app`)

Esta decisión afecta a: Keychain account name, paths en `~/Library/Application Support/...` y `~/Library/Caches/...`, identificadores de logs, futuro repo URL. Cambio caro después.

### 12.2 Desde Fase 0 (día uno)

Crear estos archivos en la raíz del repo antes del primer commit:

- **`LICENSE`** con el texto íntegro de MIT License. Copyright holder: "Antonio (trypwood)" o lo que se decida en 12.1. Año: 2026.
- **`.gitignore`** estándar para proyectos Xcode/Swift. Incluir explícito: `*.xcuserdata/`, `DerivedData/`, `*.xcworkspace/xcuserdata/`, `.DS_Store`, `build/`, `.swiftpm/`. Y crítico: `**/Secrets.plist`, `**/local.config`, cualquier archivo con `*.local.*`.
- **`README.md`** placeholder muy mínimo: nombre, una frase de descripción, "Work in progress, not yet released". No detalles técnicos hasta que la app funcione.
- **`.editorconfig`** con indent_size = 4, end_of_line = lf, charset = utf-8.

**Reglas de código desde día uno:**
- Cero secrets, paths de máquina del autor, IPs internas, o nombres reales de servers en código. Si necesitas datos de ejemplo en fixtures de tests, usa valores genéricos (`192.0.2.1`, `example-server.local`).
- Cero `print` con datos de usuario. Usar `os.Logger` con `.private` para campos sensibles.
- Cero hardcodes de Base URL, API key, User ID. Todo via Settings runtime.

### 12.3 Durante Fases 1-5

Mantener disciplina. Cada commit que entre debería poder leerse por un extraño sin contexto privado. Revisar al final de cada fase: ¿hay algo en el diff que sería embarazoso o problemático en público?

### 12.4 Fase 6 (preparación para publicación)

Cuando se llegue a Fase 6 (polish), expandir README a versión publicable:

- **Hero section:** una frase clara de qué es ("A floating now-playing overlay for macOS that displays music from your self-hosted Jellyfin server"). Screenshot del overlay funcionando.
- **Status:** versión, requisitos (macOS 26+, Apple Silicon, Jellyfin server reachable).
- **Installation:** descarga del DMG firmado, instrucciones de configuración.
- **Configuration:** Base URL, API key (cómo generarla en el dashboard de Jellyfin), User ID.
- **Themes:** lista de los 5 built-in con capturas.
- **FAQ corta:** ¿soporta video? No. ¿soporta otros servers? No. ¿scrobble Last.fm? Lo hace el plugin del server.
- **Acknowledgements:** "Visual inspiration from Sleeve by Replay (https://replay.software/sleeve), built independently for Jellyfin."
- **License:** MIT.
- **No prometer roadmap.** Si hay ideas futuras, "Possible future work" como sección opcional muy breve.

Añadir también:

- **`CONTRIBUTING.md`** corto: cómo correr el proyecto, cómo formatear, política de PRs (bienvenidos, sin SLA de revisión). Sin CLA.
- **`.github/ISSUE_TEMPLATE/bug_report.md`** minimal: qué pasaba, qué esperabas, versión de macOS, versión de Jellyfin, logs si aplica.
- **`.github/ISSUE_TEMPLATE/feature_request.md`** minimal: qué quieres, por qué.

### 12.5 Release y publicación

Cuando se cumpla el criterio de "terminado Nivel 1" (sección 10):

1. **Code signing:** firmar el binario con Developer ID del usuario. Si no tiene Developer ID Apple ($99/año), distribución sin firmar requiere instrucciones de "abrir desde clic derecho" en el README, viable pero feo.
2. **Notarization:** subir a Apple via `xcrun notarytool submit` para que el primer launch no muestre el aviso de "app no notarizada". Tarda 5-30 minutos.
3. **Staple:** `xcrun stapler staple JellySleeve.app` para que la notarización quede embebida y funcione offline.
4. **Empaquetar como DMG firmado** con `create-dmg` o equivalente. Incluir un fondo simple con el icono y una flecha al Applications folder.
5. **Tag de release:** `v0.1.0` en GitHub con el DMG adjunto y release notes breves.
6. **Hacer público el repo** (`Settings > Change visibility > Public`).
7. **Anuncio mínimo:**
   - Post en X (cuenta del usuario, @antoniomarques o equivalente): screenshot + link al repo + una frase
   - Post en r/jellyfin: misma idea, más texto explicativo
   - Mensaje en Jellyfin Discord canal #showcase o similar
   - Opcional: post en r/macapps si la calidad lo justifica

No saturar con cross-posting agresivo. Una ronda en estos canales basta.

### 12.6 Política de mantenimiento

Documentar internamente (no necesariamente público):

- **Issues:** revisar una vez por semana, máximo. Cerrar duplicados, etiquetar el resto. Cero compromiso de fix.
- **PRs:** revisar cuando haya tiempo. Solo aceptar PRs que pasen los tests existentes, no rompan funcionalidad, y se alineen con los no-goals de la sección 7.
- **Releases:** sin cadencia. Cuando haya algo que merezca tag, tag.
- **Soporte:** README incluye "best effort, no warranty". El propietario es Antonio, los usuarios lo saben.

### 12.7 Qué NO hacer al abrir

- No comprometer roadmap público.
- No prometer mantenimiento a largo plazo.
- No aceptar features que crucen los no-goals (multi-server, scrobble cliente, etc.).
- No responder issues en menos de 24h. Crea expectativa falsa de SLA.
- No crear board de proyecto público.
- No abrir Discussions a menos que llegue tracción real.
