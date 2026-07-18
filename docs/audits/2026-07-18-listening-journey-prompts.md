# Prompts de implementación · Auditoría del journey de escucha (2026-07-18)

Cinco prompts autocontenidos, uno por cambio propuesto en
[`2026-07-18-listening-journey-ux.html`](2026-07-18-listening-journey-ux.html).
Cada uno está pensado para pegarse tal cual en una sesión nueva de Claude Code,
sin necesidad de esta conversación ni de la auditoría como contexto.

**Orden y dependencias:**

| # | Cambio | Repo | Depende de |
|---|--------|------|------------|
| 1 | Staleness según estado en el bridge | `yt-safari-bridge` | — |
| 2 | Gracia de colapso asimétrica | `jellybeat` | — |
| 3 | Ambiente honesto (ventana en blanco) | `jellybeat` | — |
| 4 | Con todo idle, volver a home | `jellybeat` | **1 y 2 aterrizados** |
| 5 | Gestos unificados + contrato de relojes en el ABI | `jellybeat` | — |

1 y 2 son independientes y **cada uno elimina el parpadeo por sí solo** (uno en
la raíz, otro como defensa en profundidad). 4 es el único con dependencia dura:
sin 1+2 reintroduce flapping de fuente.

---

## Prompt 1 — yt-safari-bridge: staleness según el último estado

```text
Repo: ~/Code/yt-safari-bridge (app contenedora YTBridge + extensión de Safari).

Contexto: YTBridge sirve el estado de reproducción en GET /v1/now-playing. Hoy
StateStore (YTBridge/YTBridge/StateStore.swift) aplica una regla de staleness
plana: si el último sync desde Safari tiene más de 3 s (stalenessInterval),
sirve {active:false}. Pero con un vídeo EN PAUSA y Safari en segundo plano,
macOS congela los timers del content script y el único pulso que queda es la
alarma keepalive de background.js (cada 30 s), que reenvía el estado cacheado.
Resultado: el bridge emite una onda cuadrada — 3 s «pausado, activo» / 27 s
«idle» — y el consumidor (JellyBeat) hace parpadear su overlay entre portada y
modo ambiente. Una pausa no debe desaparecer por silencio; solo por un stop real.

Cambio pedido — staleness según el último estado conocido, en StateStore:
1. Si el último estado sincronizado era "paused" (campo state del JSON), seguir
   sirviéndolo con active:true hasta un TTL largo (nueva constante, p. ej.
   pausedStalenessInterval = 30 min). Añadir al JSON servido un campo staleMs
   (ms desde el último sync) para que el consumidor pueda representar
   «dormido» si quiere.
2. Si el último estado era "playing", mantener el corte actual de 3 s →
   {active:false}: una pestaña que sonaba y calló de verdad es un cierre o un
   crash y debe desaparecer rápido.
3. Superado el TTL largo, servir {active:false} igual que hoy.
4. NO cambiar la semántica del 503 safari_disconnected de POST /v1/command
   (corte a los 3 s): es una decisión aparte y se queda como está.
5. Actualizar docs/api.md: documentar la regla por estado y el campo staleMs.

Criterio de éxito: tras un sync con state "paused" y sin más syncs,
/v1/now-playing sigue respondiendo active:true (con staleMs creciendo) a los
10 s, 60 s y 10 min; tras un sync con state "playing" y sin más syncs, responde
{active:false} a los ~3 s como hoy. Añade tests si el proyecto tiene target de
tests; si no, deja un plan de prueba manual en la descripción del PR.

Cambios quirúrgicos: no refactorices nada más. Rama nueva + PR contra main.
```

## Prompt 2 — jellybeat: gracia de colapso asimétrica

```text
Repo: ~/Code/jellybeat.

Contexto: PlayerStore (JellyBeat/State/PlayerStore.swift) colapsa el overlay a
modo ambiente cuando un poll llega con track == nil: arma clearTrackTask con
una única gracia defaultIdleCollapseGrace = 8 s, diseñada como deadline
absoluto que los updates siguientes deliberadamente NO reinician (conserva esa
propiedad — está documentada en el comentario de la constante y cubierta por
PlayerStoreIdleCollapseTests). El problema: la fuente YouTube (bridge loopback
en 127.0.0.1:8976) reporta {active:false} de forma intermitente cuando la
pestaña de Safari está EN PAUSA y estrangulada en segundo plano, así que una
pausa viva se convierte en «nada» y el overlay parpadea portada↔ambiente en
ciclos de ~30 s. Regla de producto: una pausa no desaparece por silencio; los
8 s tienen sentido solo para «sonaba y desapareció».

Cambio pedido — gracia asimétrica según el último estado visible:
1. Si cuando llega el nil el snapshot en pantalla estaba EN PAUSA
   (isPaused == true), usar una gracia larga (nueva constante, p. ej.
   pausedIdleCollapseGrace = 10 min).
2. Si estaba SONANDO, mantener los 8 s actuales.
3. Conservar el diseño actual: deadline absoluto armado una sola vez, cancelado
   solo cuando vuelve un track. No añadas maquinaria nueva.
4. Tests: PlayerStoreIdleCollapseTests ya inyecta idleCollapseGrace por el
   init; extiende la inyección a las dos gracias y añade: (a) pausado + nil no
   colapsa tras la gracia corta; (b) sonando + nil colapsa como hoy; (c)
   pausado + nil colapsa tras la gracia larga.

Verifica con:
xcodebuild -project JellyBeat.xcodeproj -scheme JellyBeat \
           -destination 'platform=macOS' test

Cambios quirúrgicos, sin tocar el árbitro ni el bridge. Rama nueva + PR contra
main.
```

## Prompt 3 — jellybeat: ambiente honesto (la ventana en blanco)

```text
Repo: ~/Code/jellybeat.

Contexto: el overlay entra en modo ambiente (nota ♫, ventana 120×120) cuando
connectionState == .connected y currentTrack == nil (OverlayView.isAmbient).
Pero cuando una fuente loopback (YouTube) es la activa, SourceArbiter publica
SIEMPRE .connected y el gate jellyfinIsActiveSource hace que
PlayerStore.updateConnection descarte los .reconnecting/.error reales de
Jellyfin. Resultado: fuera de la red de casa el ambiente muestra la cara de
«todo bien», y su clic (NothingPlayingView.onTapGesture →
ClientLauncher.openJellyfin) abre la web app de Safari contra una URL
inalcanzable → ventana en blanco; encima markAnticipating() deja el chrome
visible 30 s esperando una música que no puede llegar.

Cambio pedido — que el ambiente sepa si Jellyfin está alcanzable:
1. En PlayerStore, expón una señal NO gateada de la salud del enlace Jellyfin
   (p. ej. private(set) var jellyfinLinkHealth, actualizada en
   updateConnection e ingest ANTES del guard del gate, siguiendo el patrón de
   jellyfinHasNowPlaying).
2. En NothingPlayingView (JellyBeat/UI/Overlay/OverlayView.swift): si el enlace
   home está caído (.reconnecting o .error), cambia la representación — glifo
   wifi.slash o badge «Jellyfin unreachable» en lugar de la nota a solas.
3. En el tap del ambiente con el enlace caído: NO lanzar la web app; muestra un
   transient (showTransient) tipo "Can't reach your Jellyfin server from this
   network." y no llames a markAnticipating().
4. Con el enlace vivo, comportamiento exactamente igual que hoy.
5. Tests: añade a PlayerStoreSourceGatingTests el caso «ingest/updateConnection
   gateados siguen actualizando la señal de salud». La capa SwiftUI no está
   bajo test: describe la prueba manual en la descripción del PR.

Copy de UI en inglés, como el resto de la app. Cambios quirúrgicos. Rama nueva
+ PR contra main.
```

## Prompt 4 — jellybeat: con todo idle, la representación vuelve a home

```text
Repo: ~/Code/jellybeat.

⚠️ Prerequisito: aterrizar DESPUÉS de «staleness según estado» en
yt-safari-bridge y «gracia asimétrica» en PlayerStore. Sin esos dos, este
cambio reintroduce flapping de fuente cuando el bridge parpadea con una
pestaña pausada y estrangulada.

Contexto: SourceArbiter.decide (JellyBeat/App/SourceArbiter.swift) resuelve, en
orden: selección forzada → único sonando → recencia de activación → pausa
pegajosa → homePriority → y, como última regla, «con nada activo en ningún
sitio, mantener la fuente actual». Esa última regla tiene un efecto perverso:
si la última fuente activa fue un loopback y luego TODO queda idle (p. ej.
cierras Safari fuera de casa), jellyfinIsActiveSource se queda en false hasta
relanzar la app, los estados reales de Jellyfin (.reconnecting/.error) quedan
silenciados por el gate, y el overlay se clava en un .connected mentiroso (modo
ambiente) aunque el servidor sea inalcanzable.

Cambio pedido:
1. En decide, regla final: con nada activo en ningún sitio, devolver el primer
   elemento de homePriority (Jellyfin) en vez de current. Así el gate se reabre
   y el overlay vuelve a contar la verdad del transporte home: ambiente de
   verdad en casa, «You're offline» fuera.
2. Verifica el camino del flip: con todo idle, currentStillActive es false, así
   que Self.debounced debe dejar pasar el flip inmediatamente (sin esperar la
   ventana de 1 s). Confirma también que applyKind → coordinator.forceRefresh()
   repuebla el overlay al volver a Jellyfin.
3. Tests: SourceArbiterTests cubre decide exhaustivamente. Actualiza la
   expectativa del caso «nothing active anywhere → keep current» y añade el
   escenario del bug: youtube fue current → todo pasa a idle → decide devuelve
   jellyfin.

Cambios quirúrgicos (la regla + tests). Rama nueva + PR contra main.
```

## Prompt 5 — jellybeat: gestos unificados + contrato de relojes en el ABI

```text
Repo: ~/Code/jellybeat.

Contexto: los gestos del overlay son incoherentes. En modo ambiente UN clic
lanza el cliente Jellyfin (NothingPlayingView.onTapGesture — y un doble clic
dispara el handler dos veces, lanzando dos veces), mientras que sobre la
portada el DOBLE clic trae al frente la fuente activa (PlayerStore.focusSource,
capability canFocusTab, con debounce de 1 s). Además, la regla de relojes que
causó el bug del parpadeo portada↔ambiente no está escrita en ningún sitio: el
ABI loopback (docs/loopback-source-abi-v1.md) no dice nada de staleness ni de
pausas, así que cualquier plugin de terceros heredará el mismo fallo que el
bridge de Safari (TTL de presencia de 3 s frente a un productor que
legítimamente calla 30 s en segundo plano).

Cambio pedido, dos partes pequeñas:
1. Gestos: en el ambiente, absorbe el segundo clic de un doble clic (debounce
   de ~1 s en el tap, análogo al de focusSource) para que no se lance dos
   veces. Documenta los gestos en README.md, en la sección que describe el
   overlay: un clic en ambiente = abrir el cliente home; doble clic en la
   portada = traer la fuente activa al frente.
2. ABI: añade a docs/loopback-source-abi-v1.md una sección «Staleness y
   pausas» con la regla normativa: (a) un TTL de presencia debe ser ≥ 2× el
   heartbeat más lento posible del productor; (b) un estado paused NO debe
   degradar a {active:false} por un silencio corto — debe seguir sirviéndose
   activo, idealmente con un campo staleMs, y expirar solo tras un TTL largo
   (~30 min); (c) referencia como ejemplo real el caso del bridge de Safari
   (throttling en segundo plano, alarma keepalive de 30 s).

Cambios quirúrgicos: no toques el árbitro ni PlayerStore más allá del debounce
del tap. Rama nueva + PR contra main.
```
