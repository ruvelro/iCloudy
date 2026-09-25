# Refactor interno de iCloudy 0.5.0

La versión de la aplicación sigue siendo **0.5.0**, con el número de compilación existente. No se han cambiado las claves de las cuentas, del Llavero ni de las transferencias persistidas.

## Organización

- `Sources/iCloudy/Providers/CloudProvider.swift`: contrato de las operaciones remotas. `CloudProviderFactory.swift` selecciona una implementación al crear el cliente.
- `Providers/GoogleDrive`, `OneDrive`, `Dropbox`, `Box`, `WebDAV`, `FTP`, `Volume`, `Mega` y `O2`: cada proveedor tiene su implementación, autenticación específica y auxiliares. Las sesiones FTP, los árboles de Mega, la sesión O2 y el acceso al volumen pertenecen exclusivamente a sus proveedores.
- `CloudAPI.swift`: fachada que conserva los puntos de entrada de la aplicación, incluida la demo. No contiene rutas de las APIs de las nubes.
- `Networking/`: transporte HTTP, protección de redirecciones, descargas y lectura de respuestas. `Authentication/`: renovación de credenciales y flujo OAuth compartido. Los parámetros OAuth están junto a cada proveedor.
- `Models/`: tipos de dominio y decodificación compatible con datos anteriores. `Persistence/`: almacenamiento local, Llavero, cachés y copias locales. `Utilities/`: nombres de archivos, trabajo de disco y localización.
- `Transfers/`: planificación de la cola, historial, copias entre nubes, espejos y validación de las fuentes. Los protocolos de subida y reanudación están en los proveedores; Mega decide cuándo puede completar una operación sin volver a leer el origen.
- `Accounts/`: registro de clientes, invalidación de sesiones y consultas de cuotas. El controlador de cuotas rechaza respuestas de peticiones canceladas, sustituidas o de cuentas eliminadas.
- `App/AppModel.swift`: estado observable y conexiones entre servicios. Sus extensiones se agrupan por cuentas, navegación, operaciones, transferencias e integración. Conservan un único estado observable para las vistas.
- `Views/`: pantallas y componentes agrupados por función. El explorador separa estado y hojas, navegación, representación de archivos y acciones.

Los `switch` de identificación, presentación y capacidades siguen siendo explícitos. La selección de implementaciones se concentra en la factoría; las operaciones remotas delegan en el contrato común.

## Validación

La batería inicial tenía 348 tests. La validación final ejecuta **360 tests, con 0 fallos**. Se añaden pruebas de aislamiento entre proveedores y cuentas, invalidación y caducidad de sesiones, recuperación de subidas ya confirmadas remotamente, compatibilidad de cuentas y checkpoints guardados, autenticación y carreras entre consultas de cuotas.

```bash
swift test
```

Las pruebas usan respuestas HTTP simuladas, servidores FTP locales y directorios temporales. No sustituyen la comprobación manual con cuentas reales de cada servicio.

Comprobación final del 20 de septiembre de 2026:

- 360 tests ejecutados, sin fallos.
- Bundles release y debug compilados con Xcode 27.0, firmados con `iCloudy Development` y verificados con `codesign --verify --deep --strict`.
- Versión `0.5.0` y número de compilación `2` conservados en ambos bundles.
- Metadatos de App Intents presentes: seis acciones y cinco accesos directos en ambos bundles. El script admite tanto la distribución tradicional de SwiftPM como sus intermediarios de Xcode.
- `get-task-allow` activo solo en debug; release mantiene sus permisos originales.


## Compilar y depurar

Compilación habitual, con la configuración OAuth local y la identidad de firma que utiliza el proyecto:

```bash
bash scripts/build-app.sh
open dist/iCloudy.app
```

Compilación de depuración, sin optimizaciones de release y con permiso de conexión del depurador:

```bash
ICLOUDY_BUILD_CONFIGURATION=debug bash scripts/build-app.sh
open dist/debug/iCloudy.app
```

El bundle debug conserva el identificador de la aplicación y utiliza **los mismos datos y credenciales locales**. Abrirlo por separado, con la otra copia de iCloudy cerrada. El permiso `get-task-allow` se añade únicamente a la firma de debug; no modifica los entitlements de release.

Para arrancarlo con LLDB:

```bash
lldb dist/debug/iCloudy.app/Contents/MacOS/iCloudy
# En LLDB:
# breakpoint set --name swift_willThrow
# run
```

También se puede abrir `Package.swift` en Xcode y usar el esquema iCloudyMain. Desde la extensión del Finder el paquete tiene tres targets: la librería `iCloudy` (toda la app, con el módulo del mismo nombre que siempre tuvo), el lanzador `iCloudyMain`, que es el binario del `.app`, y `iCloudyFileProvider`, la extensión, que enlaza la misma librería. Los binarios y bundles quedan en `.build/` y `dist/`, excluidos de Git.

## Puntos de entrada para la depuración

| Problema | Punto de entrada |
| --- | --- |
| Listado, búsqueda, copia o subida de una nube | Su `Providers/<nube>/<nube>Provider.swift` |
| Subidas de Drive o OneDrive | `GoogleDriveUpload.swift` / `OneDriveUpload.swift` |
| Renovación, 401 o redirecciones | `Networking/CloudSession.swift`, `Authentication/TokenRefresher.swift`, `Networking/RedirectGuard.swift` |
| Reconexiones y consultas de espacio | `Accounts/AccountClientRegistry.swift`, `Accounts/StorageQuotaController.swift` |
| Cola y recuperación de transferencias | `Transfers/TransferQueue.swift`, `Transfers/ResumableUpload.swift` |
| Navegación y acciones del explorador | `Explorer/AppModel+Navigation.swift`, `Explorer/AppModel+FileOperations.swift` |
| Interfaz | `Views/Explorer/` y la carpeta de la pantalla correspondiente |

Las auditorías anteriores documentan el estado previo al refactor: sus números de línea deben consultarse en el commit `b9ef7b2`, que conserva las correcciones locales con las que empezó esta reorganización.
