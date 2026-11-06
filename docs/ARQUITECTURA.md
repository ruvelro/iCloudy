# Arquitectura de iCloudy

Descripción viva de cómo está organizado el código. Si cambias algo de lo que aquí se cuenta, cambia también este
documento en el mismo commit. El histórico (auditorías, la guía del refactor 0.5.0) está en `docs/historial/`.

## Paquete y destinos

Un único paquete SwiftPM sin dependencias externas (`Package.swift`, `swift-tools-version: 6.0`, macOS 14):

| Destino | Qué es |
|---|---|
| `iCloudy` (librería) | Toda la aplicación: modelo, proveedores, persistencia, vistas. Modo de lenguaje Swift 6 con comprobación completa de concurrencia. |
| `iCloudyMain` | El ejecutable: un `main.swift` que cede el control a la librería. |
| `iCloudyFileProvider` | La extensión del Finder; entra por `NSExtensionMain` y comparte proveedores, cuentas y Llavero con la app. |
| `iCloudyTests` | Las pruebas (modo Swift 5). `iCloudyTestBootstrap` es un destino en C cuyo constructor de carga prepara el aislamiento antes de que corra nada. |

## Carpetas de `Sources/iCloudy`

| Carpeta | Contenido |
|---|---|
| `App/` | `AppModel`, el delegado, la escena SwiftUI y `AppEnvironment` (si el proceso es la batería de pruebas). |
| `Accounts/` | `AccountDirectory`, `O2SessionKeeper`, el registro de clientes, las cuotas y las extensiones de `AppModel` para conectar y desconectar. |
| `Explorer/` | Pestañas, paneles, navegación, operaciones de archivo, deshacer, versiones, sin conexión y `ExplorerPresentation`. |
| `Transfers/` | `TransferQueue`, `TransferWalker`, el planificador, los reflejos (`MirrorManager`, `TwoWaySync`), el historial, la recuperación y la verificación. |
| `Persistence/` | `LocalStore`, `StoreWriter`, `StoreEnvelope`, el Llavero (`KeychainStorage`/`Vault`), favoritos, copias locales y sin conexión, caché de listados. |
| `Providers/` | El protocolo `CloudProvider`, la fábrica y un subdirectorio por proveedor (Google, OneDrive, Dropbox, Box, WebDAV, FTP, SFTP, volumen, Mega, O2, pCloud, S3). |
| `Networking/` | `CloudSession` (la clase base de los proveedores: token, reintentos, descargas HTTP), errores de servicio, sockets y TLS. |
| `Authentication/` | OAuth con PKCE y bucle local, configuración de clientes, renovación de tokens. |
| `Models/` | Tipos de valor: `Account`, `Cloud` y `CloudCapabilities`, `CloudFile`, `Transfer`, `CloudError`… |
| `Encryption/` | Bóvedas Cryptomator: criptografía propia (AES-SIV, scrypt…), el proveedor que cifra sobre otro y sus vistas. |
| `Demo/` | `DemoStore` (archivos simulados en una carpeta local) y `DemoProvider`. |
| `Compare/`, `Search/`, `Preview/`, `Integration/`, `Diagnostics/`, `FileProvider/`, `Utilities/` | Comparar carpetas y duplicados; búsqueda global y guardada; vista previa y miniaturas; Spotlight, menú, Atajos, notificaciones, el aviso de versiones nuevas (`UpdateChecker`, ver [DISTRIBUCION.md](DISTRIBUCION.md)); registro de diagnóstico; el lado de la app del File Provider; utilidades. |
| `Views/` | Las vistas SwiftUI, agrupadas por área. |

`CloudAPI.swift` y sus extensiones, en la raíz, son la fachada que la app usa para hablar con un proveedor.

## `AppModel` y sus subsistemas

`AppModel` (`App/AppModel.swift` y unas veinte extensiones `AppModel+…`) es el objeto que ven las vistas. Es
`@MainActor @Observable`: cada vista se redibuja por las propiedades que lee, no por cualquier cambio del modelo. No
guarda estado suelto: lo reparte en subsistemas con dueño, y las propiedades que quedan en el modelo son fachadas.

| Subsistema | Responsabilidad | Cómo se usa |
|---|---|---|
| `directory: AccountDirectory` | Las cuentas, su caducidad y renovación, los clientes vivos y **la única escritura** de la lista en el Llavero. | `adopt`, `replace`, `reorder`, `update`, `remove`, `markExpired`, `forgetSessions`. `model.accounts` lee y asigna (sin guardar) a través de él. |
| `o2: O2SessionKeeper` | Mantener vivas las sesiones de O2, renovarlas en silencio, completar el inicio de sesión y separar los almacenes de WebKit. | Reloj, espera, sondeo de identidad y renovación inyectables. `model.completeO2` y `model.o2LoginEnded` siguen siendo la entrada desde la ventana de O2. |
| `ui: ExplorerPresentation` | Alertas, confirmaciones y hojas de la ventana (27 propiedades). | Las vistas leen `model.ui.…` y enlazan con `Bindable(model.ui)`. `model.error` y `model.info` reenvían a `ui`, porque el modelo informa por ahí. |
| `favoriteStore: FavoritesStore` | Favoritos, su archivo y su publicación en Spotlight. | `toggle`, `remove`, `moved`, `apply(change)`; `model.favorites` es de solo lectura. |
| `queue: TransferQueue` | La cola de transferencias. | `add`, `retry`, `cancel`…; cada trabajo se recorre con un `TransferWalker`. |
| `mirrors: MirrorManager` | Reflejos en un sentido (subida o descarga), sincronizaciones bidireccionales y pares de nubes. | Un archivo por reflejo. |
| `jobs: JobStore` | Trabajos guardados y su programación. | `runJob(id:)`, `runJob(named:)`; `jobs.json`. |
| `offline`, `localCopies`, `quotas`, `history`, `remoteCopies`, `spotlight`, `listings`, `cryptomator`, `planner`, `savedSearches`, `globalSearch`… | Copias sin conexión, copias locales, cuotas, historial, copias asíncronas de OneDrive, Spotlight, caché de listados, bóvedas, planes de transferencia y búsquedas. | Cada uno con su estado y su persistencia. |
| `workspace: ExplorerWorkspace` | Paneles y pestañas, cada una con su lugar, su listado y su selección. | Las propiedades `files`, `path`, `selectedIDs`… del modelo reenvían a la pestaña activa del panel enfocado. Cada pestaña guarda también su orden (`sortMode` y `sortAscending`) y su modo de vista (lista, iconos o columnas). |
| `explorer: ExplorerSettings` | Cómo se dibujan las listas: las columnas de la tabla (un `TableColumnCustomization`, que edita también el menú de su cabecera) y la agrupación, de las carpetas y de la búsqueda global. | En las preferencias (`Prefs.defaults`). |
| `recents: RecentLocationsStore` | Las veinte últimas carpetas de «Mis archivos» abiertas en cualquier pestaña. | `go(to:)` y atrás/adelante llaman a `note`; `recent-locations.json` con sobre y `StoreWriter.later`. |
| `editor: ExternalEditor` | «Abrir con»: copias privadas en `Caches/iCloudy/Editing`, vigiladas con el `FolderWatcher` de los reflejos. | `AppModel.openWith` descarga por la fachada; `uploadEdits` encola una subida normal de una copia preparada, y conserva las dos versiones si la nube cambió. |
| `columnListings: ColumnListings` | Los listados de las carpetas que la vista en columnas enseña por encima de la abierta. | `AppModel.columns(inPane:)` es puro; la vista pide los que faltan. |

Observación: `TransferQueue`, `OfflineStore`, `LocalCopyIndex`, `StorageQuotaController`, `MirrorManager`,
`SavedSearches` y `TransferPlanCoordinator` son `@Observable`. La cola expone además `structuralItems`, que solo cambia
con transiciones de estado: el explorador (insignias, menús) lo lee para no redibujarse con cada bloque transferido;
el panel de transferencias lee `items` y sí se redibuja con el progreso. Quedan en `ObservableObject` el historial,
las copias de OneDrive, la búsqueda global, la vista previa, la conectividad, las bóvedas y `CompareCenter`.

Para abrir un lugar por su ruta (Ir a la carpeta, la barra de ruta, y lo que llegue por URL o por Atajos) la entrada
es `AppModel.open(path:in:tab:)`, que recorre la ruta como `FileShortcuts.resolve(path:in:)` y, si acaba en un
archivo, abre su carpeta con él seleccionado; `goToFolder(_:defaultAccount:)` lee antes la forma `cuenta:/ruta`
(`FolderAddress`). El inspector lee `inspectorSummary()`, que solo cuenta las filas visibles de la selección.

## Proveedores y capacidades

Cada proveedor es una subclase de `CloudSession` que adopta `CloudProvider` (`Providers/CloudProvider.swift`). El
protocolo tiene implementaciones por defecto que rechazan con el motivo lo que el proveedor no hace, de modo que un
proveedor nuevo solo implementa lo que sabe hacer. `CloudProviderFactory` elige el tipo según `Account.cloud`.

`CloudAPI` es la fachada: añade las comprobaciones comunes (limitaciones por tipo de elemento, verificación de
descargas por tamaño y suma, subida reanudable con puntos de control) y nunca se salta al proveedor. La demo es un
proveedor más (`DemoProvider`), así que recorre el mismo camino que los reales.

Lo que un proveedor puede hacer vive en **una sola tabla**: `CloudCapabilities.of(_:)` en `Models/Cloud.swift`.
Incluye búsqueda, recientes, enlaces (`LinkFeatures`), papelera, versiones, miniaturas, deshacer la papelera, copia
asíncrona (OneDrive), enlaces temporales (S3), límite de trabajos por sesión, forma de iniciar sesión (`signIn`:
`.oauth`, `.password`, `.web`, `.folder`), si hay que mantener viva la sesión y si la API es experimental.
`Cloud.usesWebLogin`, `needsKeepAlive`… son atajos a esa tabla. `Account.capabilities` ajusta la tabla a la cuenta
(Nextcloud, unidades compartidas, la demo, una bóveda). `CapabilityTableTests` comprueba que la tabla de miniaturas
coincide con los proveedores que de verdad las piden.

## Errores

`CloudError` tiene `kind` (`notFound`, `conflict`, `quota`, `refused`, `transient`, `sessionExpired`, `other`):

- `.message(String)` sigue siendo el caso más usado y equivale a `.other`.
- `.sessionExpired(String?)` marca la cuenta como caducada.
- `.classified(kind, texto)`, con atajos `CloudError.conflict(…)`, `.notFound(…)`, `.refused(…)`…
- `CloudError.kind(of:)` clasifica cualquier error: los propios, un `ServiceError` por su estado HTTP o un `URLError`.

Convención de las hojas: la acción **lanza** el error y la hoja muestra `localizedDescription`; quien llama puede
distinguir un fallo de otro por su tipo (por ejemplo, `CryptomatorError.invalidPassphrase`), nunca por el texto. Las
hojas de conexión siguen mostrando `model.ui.connectionError`.

## Persistencia

Todo lo que no es secreto vive en JSON en `~/Library/Application Support/iCloudy/` (`LocalStore.directory`; las
pruebas lo desvían con `LocalStore.directoryOverride`). Lo secreto (cuentas y credenciales) va al Llavero en un único
ítem (`KeychainStorage`), y solo `AccountDirectory` escribe la lista de cuentas.

- **`StoreEnvelope`**: cada almacén se escribe como `{"schemaVersion": 1, "items": …}`. Un archivo de una versión
  anterior, sin sobre, se lee como versión 1.
- **`StoreWriter`**: escribe en segundo plano con **una cola serie por archivo**, de modo que un almacén grande no
  retrasa a otro. `later` descarta una escritura si llega otra más nueva del mismo archivo (una ráfaga cuesta una
  escritura); `now` espera solo a las escrituras anteriores de ese archivo; `write` es asíncrona y devuelve cuando
  los bytes están en disco, sin bloquear el hilo principal. `LocalStore.read` espera antes a las escrituras
  pendientes de ese archivo. Al salir, `AppDelegate` vacía todos los almacenes y el escritor.
- **Archivos ilegibles**: se apartan como `.corrupt-<fecha>` (`LocalStore.setAside`) y se avisa, en lugar de
  sobrescribirlos: favoritos, sin conexión, cola (a petición), reflejos.
- **La cola** (`transfers.json`): los puntos de control por bloque se agrupan cada `flushDelay`; las transiciones se
  entregan al escritor al momento (`later`); las marcas que deben existir antes de una petición (una carpeta cuya
  creación no se ha confirmado, el estado final antes de borrar la copia preparada) se esperan con `write`; solo
  `add` y el vaciado al salir usan `now`.
- **Reflejos**: un archivo por reflejo y un `index.json` con el orden, en la carpeta `mirrors/`. El antiguo
  `mirrors.json` se migra una vez y se conserva como `mirrors.json.migrated`. Una sincronización bidireccional
  actualiza la línea base en memoria tras cada paso y la escribe cada dos segundos y al terminar, pausar o salir.

## Transferencias

`TransferQueue` decide qué trabajos arrancan (`TransferScheduler`: límites por cuenta y por sesión, horario, red de
pago), los reintenta y guarda su estado. Cada trabajo se recorre con un `TransferWalker` (`Transfers/TransferWalker.swift`),
que tiene los pasos comunes una sola vez: saltar lo completado, olvidar una carpeta cuya creación no se confirmó,
resolver el nombre (preguntando por el conflicto o usando la respuesta del lote), reservarlo frente a otros trabajos
(`NameClaims`) y crear la carpeta con la marca en disco antes de la petición. Los tres recorridos (`upload`,
`download` y `copy` entre cuentas) solo añaden lo propio de cada uno.

Un trabajo puede llevar `TransferOptions` (`Transfers/TransferOptions.swift`): política de conflictos (en un trabajo,
«este lado» es el origen), exclusiones propias, no repetir lo que el destino ya tiene con la misma suma y, para los
reflejos de descarga, escribir el contenido directamente en la carpeta (`contentsOnly`). El recorrido consulta la
política antes de abrir el diálogo. Los límites de velocidad son cubos (`BandwidthLimiter`): uno por sentido para la
cola y, si se configura, uno por sentido para cada cuenta; cada trabajo recibe un `TransferThrottle` con los de la cola
y los de las cuentas a las que sube y de las que baja, y espera al más lento.

### Reflejos

`MirrorManager` (`FolderMirror.swift` y sus extensiones `DownloadMirror`, `ExactMirror`, `MirrorVerification`,
`MirrorChecksums`, `SyncSchedule`, `CloudPair`) lleva cuatro modos:

| Modo | Cómo corre |
|---|---|
| `upload` | FSEvents → escaneo → `MirrorPlanner.oneWayPlan` → un trabajo de subida de la cola con lo intacto ya marcado. |
| `download` | Sondeo de la nube → `RemoteTree.snapshot` → `DownloadMirrorPlanner` contra una línea base → un trabajo de descarga de la cola (`contentsOnly`); la línea base absorbe lo completado al terminar o fallar. |
| `twoWay` | `TwoWaySyncEngine` sobre `TwoWayPlanner`, fuera de la cola pero por sus cubos de velocidad. |
| `cloudPair` | `CloudPairEngine`: el mismo `TwoWayPlanner`, con la primera carpeta como lado «local»; cada archivo pasa por la carpeta temporal de la cola. Experimental. |

`MirrorOptions` guarda la política de conflictos, el espejo exacto (borrados a la papelera del destino, solo de lo que
puso el reflejo, tras el freno de `ExactMirrorPlanner.checkMassDeletion`), la comparación por suma
(`ContentComparison`), la verificación periódica, no repetir lo idéntico y la programación (`SyncSchedule`). Lo
programado espera mientras la cola está retenida (`currentHold`) y arranca cuando se libera.

### Trabajos guardados

`JobStore` (`Transfers/SavedJobs.swift`, archivo `jobs.json` con sobre, escritura en segundo plano y archivo dañado
apartado) guarda `SavedJob`: orígenes y destino (`JobEndpoint`), `JobOptions` y el resultado de la última pasada. Cada
pasada es una tanda de la cola; al terminar, la tienda verifica lo copiado si se pidió y barre lo sobrante del destino
(`ExtraneousSweep`) si el trabajo lleva los borrados. Las entradas para Atajos y la línea de órdenes son
`AppModel.runJob(id:)` y `AppModel.runJob(named:)`.

## Concurrencia

- La app compila en Swift 6 con comprobación completa. El modelo, los subsistemas, las vistas y los proveedores son
  `@MainActor`; el trabajo pesado (leer árboles locales, sumas, analizar respuestas grandes) sale del hilo principal
  con `blockingIO` o `Task.detached`, y la escritura de almacenes con `StoreWriter`.
- Las respuestas HTTP se esperan con `async/await`; la cola y los reflejos son tareas canceladas al pausar.
- Las pruebas corren en modo Swift 5 y en paralelo (`swift test --parallel`): cada prueba tiene su carpeta de
  almacenes y su dominio de preferencias (`Prefs.defaults`), y `AppEnvironment.isTesting` hace que la app no toque el
  Llavero real, ni lea las cuentas guardadas, ni guarde pestañas, ni deje registro en disco.
