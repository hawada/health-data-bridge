# HealthDataBridge 0.3.0 (7) — informe de validación

Fecha: 15 de septiembre de 2026. Base: 0.2.0 (6), commit
`db6866ecf57578316e581b9a7532ebb4f6c5c680`.

Estado: candidata de código, no una nueva instalación física aceptada. La matriz
distingue comprobación automatizada de aceptación completa. Una omisión no cuenta
como aprobación. No se ha contactado con WHOOP real, instalado esta candidata en el
iPhone personal, publicado un IPA ni distribuido por TestFlight/App Store.

## Implementación revisada

Se conservan bundle, equipo de firma, Keychain, directorio y esquema de persistencia,
identificadores/huellas/versiones/metadatos HealthKit y la identidad del App Intent.
No hay consultas de histórico ni escrituras de Salud al abrir la aplicación.

El formulario utiliza un borrador. La petición conjunta devuelve la escritura por
tipo y fronteras observables de lectura; ni petición completada ni consulta vacía
equivalen a permiso de lectura. HRV denegada permite conservar la autorización base
y continuar sin ella. Las confirmaciones se revisan de nuevo y ninguna frontera
nativa se sustituye por una declaración manual. No se identifica WHOOP por nombre.

Cuenta inicial, selección HRV y marcador se guardan en una única escritura protegida
y atómica. El fallo revierte la memoria a la instantánea confirmada. El runtime
revalida cuenta, permisos y fuente al guardar y ejecutar. La primera configuración
inicia una sola sincronización reciente; guardar una configuración existente no
sincroniza ni cambia su fecha/cursor. Una configuración guardada sobrevive al fallo
posterior de red. Los fallos globales conservan resultados de fases confirmadas.

El histórico tiene inicio, corte, siguiente ventana y fase propios. La ampliación
explícita de HRV se guarda conjuntamente con su recorrido; se conservan registros,
pendientes y WAL. El corte también limita la fase reciente de HRV al reanudar; no
retrocede su descubrimiento cotidiano. Una respuesta vacía con lectura limitada no
confirma la ventana. La sincronización diaria y Atajos no reanudan el recorrido.

## Evidencia ejecutada

Entorno: macOS 26.6.2, Xcode 27.0 (27A266a), Swift 6.4; simuladores aislados iOS
27.0 e iOS 26.4. Fixtures y muestras de integración son sintéticos. Los binarios
físicos excluyen las fixtures de UI por condiciones de compilación.

| Evidencia | Resultado | Límites |
| --- | --- | --- |
| E01: `swift test --jobs 2` | 85 aprobadas, 0 fallos | Núcleo, no WHOOP ni Salud reales |
| E02: `bash scripts/verify_local.sh` | Todas las comprobaciones aprobadas; motor 22 escenarios, ViewModel 13 | Auth/MFA, transporte/401/429, repositorio, motores, ViewModel, Atajos, muestras y capacidades; dobles de servicios |
| E03: suite nativa/UI iOS 27 | 21 aprobadas, 2 omitidas, 0 fallos | Perfil de lectura existente del simulador; protección física y caso exclusivo de iOS anterior omitidos |
| E04: suite nativa/UI iOS 26.4 | 12 aprobadas, 11 omitidas, 0 fallos | RMSSD no disponible; casos específicos de iOS 27 y protección física omitidos |
| E05: compilación Release iPhone | Aprobada; firma válida y misma identidad; sin fixtures UI | No implica instalación ni ejecución física |
| E06: actualización binaria en iOS 26.4 | 0.2.0 (6) → 0.3.0 (7), HRV activa y desactivada: almacén y WAL idénticos tras arrancar | Estado sintético; sin token real, muestras Salud previas ni sincronización posterior |
| E07: QA visual | Configuración ES/EN, confirmaciones, resultado, histórico y texto grande inspeccionados | No sustituye un recorrido hablado completo con VoiceOver |

Tras el último endurecimiento de lectura del WAL, se repitió además la suite nativa
en iOS 26.4: 6 aprobadas, 6 omitidas, 0 fallos. Es una repetición, no seis tests
adicionales al total E04. E01/E02, la pasada final iOS 27 y Release incluyen ese cambio.

Las ejecuciones intermedias también aprobaron 9 tests UI iOS 27 y, después de añadir
casos, 21 tests nativos/UI iOS 27 con 2 omisiones, y 12 nativos/UI iOS 26.4 con 11
omisiones. No se suman a las ejecuciones finales ni se presentan como tests únicos.
Se corrigieron durante la revisión guardado por pasos, clasificación corrupta,
selección de fuente por nombre, predeterminado que anulaba un opt-out, pérdida del
resultado parcial, corte HRV variable y confirmación vacía bajo lectura limitada.

La prueba XXXL detectó inicialmente un control fuera del desplazamiento previsto.
Se amplió la comprobación de alcance y la inspección visual detectó además columnas
estrechas con palabras fragmentadas. Las filas ahora se apilan en tamaños de
accesibilidad; la suite iOS 26.4 y sus capturas finales verificaron alcance y lectura.
El repositorio también bloquea una carga con WAL inaccesible, sin perderlo ni
clasificarla como instalación nueva; la prueba POSIX sintética conserva sus bytes.

El disco interno lleno interrumpió una compilación y ejecuciones intermedias de UI
(incluido un guardado bloqueado). Esas ejecuciones no se cuentan como aprobadas.
Se trasladaron solo los artefactos temporales de este trabajo al volumen externo
y se repitieron las comprobaciones finales con espacio disponible.

## Correspondencia P01–P24

Todos los casos de esta tabla se refieren a la candidata 0.3.0 (7) y al entorno de
E01–E07. «Parcial» significa evidencia útil pero aceptación completa pendiente.

| ID | Resultado y evidencia | Omisiones / pendiente |
| --- | --- | --- |
| P01 | Parcial: login simulado → configuración una vez, E02/E03 | Login WHOOP real |
| P02 | Parcial: MFA/credenciales con transporte simulado, cancelación/reapertura UI, E02/E03/E04 | MFA real y reapertura en dispositivo |
| P03 | Parcial: selección/autorización simulada, guardado único y siete días, E02/E03 | Recorrido completo con permisos nativos base y WHOOP real |
| P04 | Parcial: opt-out, guardado, relanzamiento y reapertura reflejan HRV desactivada, E02/E03 | Sincronización base real tras opt-out |
| P05 | Parcial: iOS 26.4 configura base y explica RMSSD no disponible, E04 | Dispositivo anterior real |
| P06 | Parcial: HRV denegada conserva petición base y permite continuar, E02/E03 | Denegación en el diálogo nativo de Apple |
| P07 | Parcial: desconocida/limitada, frontera prevalente y fuente no observada rechazada, E01/E02/E03 | Perfiles nativos nuevos de lectura denegada/limitada y revocación física |
| P08 | Parcial: preflight vacío bloquea antes de escribir y resultado queda pendiente, E02 | Biblioteca física vacía, UI de reintento con permisos ambiguos reales |
| P09 | Parcial: bundle observado exacto, conciliación/exportador nativo y propiedad, E01/E02 | Exportación WHOOP real y ambigüedad en dispositivo |
| P10 | Parcial: un punto de commit atómico, fallo de escritura/rollback/recarga, E02/E03/E04 | Corte de energía/almacenamiento físico |
| P11 | Parcial: red/401/429, Retry-After y cancelación con dobles, E01/E02 | Fallos reales después del guardado en iPhone |
| P12 | Parcial: fallo FC conserva sueño confirmado; resultados diferenciados, E01/E02 | Resultado parcialmente completado con HealthKit/WHOOP reales |
| P13 | Parcial: estado HRV activo sin marcador, UI incremental y actualización binaria conservan progreso, E02/E03/E06 | Sesión real, metadatos de Salud y actualización física |
| P14 | Parcial: opt-out, esquema antiguo y salvaguarda de cuenta, E02/E03/E04/E06 | Actualización física con cuenta pendiente |
| P15 | Parcial: autorización no mutante/cancelación, estado funcional y bytes preservados, E02/E03 | Diálogo Apple real seguido de cancelación/relanzamiento físico |
| P16 | Parcial: guardar conserva fecha/cursor/corte/checkpoints y no llama sincronización, E02 | Reconfiguración en dispositivo real |
| P17 | Parcial: repetir histórico no duplica y mantiene checkpoints/resolución cotidianos, E01/E02 | Histórico real grande y metadatos antes/después |
| P18 | Parcial: reanudación durable entre ventanas y fase HRV; mismo corte, E01/E02 | Terminación del proceso/teléfono durante escrituras reales |
| P19 | Parcial: ampliar reabre enumeración conservando pendientes; reducir no recorta, E02 | Volumen real y permisos limitados durante ampliación |
| P20 | Parcial: runtime serial, doble-save rechazado, cancelación y cuenta equivocada bloqueadas, E01/E02 | Atajo concurrente con importación física y desconexión entre escrituras |
| P21 | Parcial: identidad App Intent retenida, preflight no mutante para instalaciones nuevas/existentes, E02/E05 | Ejecución del Atajo existente y protección con iPhone bloqueado |
| P22 | Parcial: ES/EN, etiquetas/controles accesibles y XXXL, E03/E04/E07 | Recorrido completo con VoiceOver y XXXL en todas las etapas físicas |
| P23 | Automatizado: E01/E02 y suites nativas/UI; omisiones explícitas | Ninguna prueba física sustituida por mocks |
| P24 | Parcial: E05 identidad/firma y E06 actualización de binarios con estado sintético | Paquete instalado como actualización y comparación física antes/después |

## Reproducción y aceptación física

### Revisión adicional de la candidata ya publicada

La implementación 0.3 estaba ya en el commit `4627e6c` al iniciar esta revisión.
Se corrigió un criterio de resultado transversal: la ausencia de errores globales
no basta para presentar una operación como completa si hay fases sin comprobar,
lectura pendiente o recuperaciones pendientes. Panel, Actividad y estado persistido
de la operación utilizan ahora el mismo criterio; las muestras confirmadas siguen
mostrándose por separado. Una respuesta sin datos conserva su etiqueta específica,
sin afirmar que se ha importado todo el histórico.

La repetición del núcleo aprobó 86 tests, cero fallos, incluida una regresión de
HRV pendiente sin errores globales. Las comprobaciones de servicios se repitieron
con el nuevo criterio. La prueba de fronteras de lectura verifica además que el
estado persistido de la operación sea parcial. Los resultados E01–E07 anteriores
pertenecen a su ejecución original; no acreditan por sí solos este ajuste ni una
instalación física nueva.

Repetición adicional con fuentes estables, Xcode 27 y fixtures sintéticas:

| Capa | Resultado del ajuste | Límites |
| --- | --- | --- |
| Núcleo | 86 aprobadas, 0 fallos | No sustituye HealthKit/WHOOP reales |
| Servicios y capacidades | `verify_local.sh` aprobado completo | Incluye regresión de estado parcial bajo lectura limitada |
| iOS 27 nativo/UI | 21 aprobadas, 2 omitidas, 0 fallos | Perfil QA existente; omisiones de protección física y caso exclusivo de iOS anterior |
| iOS 26.4 nativo/UI | 12 aprobadas, 11 omitidas, 0 fallos | RMSSD/casos iOS 27 no disponibles; protección física omitida |
| Release iPhone 0.3.0 (7) | Compilación y firma estricta aprobadas | Misma identidad/equipo; fixtures ausentes del binario; no instalado |

El primer intento adicional de simulador falló al solaparse con la edición y
utilizar un módulo del núcleo anterior. Se repitió con fuentes estables y solo esa
pasada final se cuenta como aprobada. Los avisos de Xcode sobre compilación con
código de salida cero y versión del depurador no produjeron fallos en la pasada
final; ambos xcresult confirman cero fallos y ninguna advertencia de runtime.
Este ajuste refuerza P07/P12 y sus resultados públicos; no cierra sus omisiones
de aceptación física ni repite la comparación binaria E06.

Comandos del núcleo/servicios arriba. Para los simuladores, seguir `TESTING.md` con
el esquema `WHOOPHealthSync`, SDK 27, dispositivos QA aislados y
`DEBUG WHOOP_IOS27_SDK WHOOP_VALIDATION_BUILD`; registrar omisiones. Para Release,
compilar con destino genérico iOS y verificar `codesign --verify --deep --strict`,
Info.plist y ausencia de identificadores/credenciales de fixtures en el Mach-O.

La prueba E06 compiló la base en un worktree separado y la candidata en otro
DerivedData, instaló sin desinstalar y comparó el almacén y WAL resueltos desde el
contenedor actual después de cada instalación. El sistema puede cambiar la ruta
física del contenedor mientras conserva sus datos; no se comparó una ruta obsoleta.

Antes de aceptar la entrega física: conservar una copia privada del estado/metadata,
verificar misma firma y versión, instalar como actualización **sin desinstalar** y
comprobar el estado anterior/posterior. El usuario realiza las pruebas WHOOP reales
en su iPhone. No se introducirán fixtures allí. Deben comprobarse revocación,
biblioteca vacía, coexistencia WHOOP, histórico grande, interrupciones, Atajos y
bloqueo. Hasta entonces P01–P22/P24 no se declaran aceptados exhaustivamente.

Logs, xcresult, capturas, binarios, perfiles de firma, rutas/identificadores de
dispositivos y copias de estado permanecen fuera de Git. Solo se publica código y
este resumen sin datos personales.
