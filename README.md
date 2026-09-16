# iCloudy — MVP para macOS

Explorador nativo de Google Drive y OneDrive, escrito con SwiftUI, para macOS 14 o superior. Conexión directa desde el Mac a los proveedores; no requiere un backend propio ni instala componentes de sincronización.

## Ejecutar

Requiere Xcode con las herramientas de línea de comandos seleccionadas.

```sh
swift test
bash scripts/build-app.sh
open dist/iCloudy.app
```

También puedes abrir `Package.swift` en Xcode o ejecutar `swift run iCloudy` para desarrollar la interfaz. Para OAuth usa el paquete `.app`, que incorpora la configuración. El script firma con la primera identidad de firma de código que encuentre en el Llavero y avisa si tiene que recurrir a ad hoc, porque esa firma cambia en cada compilación y obliga a reautorizar el acceso al Llavero. La guía OAuth explica cómo crear un certificado local y los procesos de GitHub y Mac App Store.

## Funciones

- Varias cuentas de Google y Microsoft con selección independiente en la barra lateral.
- Búsqueda entre cuentas desde la barra lateral o ⇧⌘F, con filtros por cuenta, tipo, fecha de modificación y tamaño. Resultados progresivos, cancelación, errores independientes y «Cargar más resultados». Vista previa, descarga/exportación e ir a la carpeta desde el resultado. Los proveedores pueden buscar también en contenido indexado: iCloudy no descarga contenidos para buscar.
- Alias, ocho colores e iconos por cuenta: clic derecho → «Personalizar nube…». Predefinidos Drive/OneDrive, trabajo, personal, casa, estudios y otros; símbolo de macOS por nombre o imagen propia (PNG/JPEG/HEIC/GIF/TIFF, hasta 10 MB). Se conserva una copia PNG reducida a 256 px y se guarda todo localmente, sin modificar la cuenta remota. Los ajustes se conservan al desconectar y reconectar la misma cuenta.
- Gráfico circular y texto de espacio usado/total por cuenta. Se consulta al conectar y tras cada transferencia; al navegar por carpetas se reutiliza el valor durante cinco minutos para no duplicar peticiones, y «Actualizar espacio» en el menú contextual fuerza la consulta. Si no hay cuota disponible no se inventa un porcentaje. Google informa del almacenamiento de todos sus servicios (o de la organización si es compartido); OneDrive personal puede incluir otros servicios Microsoft. La demo simula 5 GB.
- «Desconectar cuenta…» en el menú contextual de cada nube, con confirmación. Elimina la sesión local, no archivos ni permisos concedidos al proveedor. Conserva favoritos y cola pausada para reconectar; requiere pausar o terminar las transferencias de esa cuenta.
- Tres vistas por cuenta en la cabecera: «Mis archivos», «Recientes» (lo último abierto según el proveedor, ordenado por fecha, sin carpetas) y «Compartido conmigo». Las dos listas son de solo lectura hasta abrir una carpeta real dentro de ellas; los favoritos recuerdan en qué vista se crearon. En OneDrive los elementos compartidos son remotos y se abren en el navegador.
- Exploración paginada de carpetas de Mi unidad / OneDrive propio, migas de pan, actualización y filtro de nombres de la carpeta actual. Las carpetas grandes se muestran página a página mientras siguen cargando; el filtro y el orden se recalculan solo al cambiar los datos, no en cada redibujado.
- Las subidas de carpetas listan cada carpeta de destino una sola vez por transferencia, y las carpetas recién creadas no se listan. Los puntos de control por bloque se agrupan en una escritura cada dos segundos; las transiciones de estado, las nuevas sesiones de subida y la salida de la app escriben al instante. La lectura de bloques, el recorrido de carpetas locales y los movimientos de archivos se hacen fuera del hilo principal.
- Doble clic para entrar en carpetas, descargar binarios o abrir documentos nativos en el navegador.
- Arrastrar archivos/carpetas desde Finder al listado para subir copias a la carpeta actual. También hay un botón Subir.
- Subida recursiva de carpetas y archivos por bloques de 5 MiB, sin cargar todo el archivo en memoria.
- Descarga explícita a una carpeta elegida, incluyendo carpetas recursivas. Ningún listado descarga contenidos automáticamente.
- Google Docs: PDF/Word; Sheets: Excel/PDF; Slides: PowerPoint/PDF. Exportación individual.
- «Copiar enlace» pone en el portapapeles el enlace web del proveedor, que solo abre quien ya tiene acceso. «Crear enlace público de solo lectura…» pide confirmación, concede acceso de lectura a cualquiera con el enlace (permiso `anyone/reader` en Drive, `createLink` anónimo en OneDrive) y lo copia; revocarlo se hace desde la web del proveedor. Disponible en el explorador y en la búsqueda global.
- Vista previa con Espacio, botón de ojo o menú contextual, en lista y cuadrícula: PDF, imágenes y texto/código en solo lectura. Descarga temporal cancelable, limpieza al cerrar y al arrancar, consentimiento por encima de 100 MB o tamaño desconocido, y «Guardar copia…». Detalles y límites en [Vista previa](docs/PREVIEW.md).
- Cola secuencial con estados, progreso por bloques en subidas y por elementos en carpetas; descarga individual con indicador de actividad.
- Botones «Continuar con Google» y «Continuar con Microsoft», sin campos técnicos para el usuario. OAuth con navegador externo, PKCE y validación de state, con hasta diez minutos para completar el inicio de sesión. Tokens y cuentas en el Llavero; configuración del desarrollador incorporada al paquete.
- Sesiones caducadas o revocadas: un 401 fuerza una renovación del token y, si el proveedor sigue rechazando la cuenta o el refresh token ya no vale, la cuenta se marca en la barra lateral con «Sesión caducada» y un botón «Volver a conectar…». Los errores del endpoint de tokens (`invalid_grant` y similares) se muestran con el detalle del proveedor en lugar de un mensaje genérico.
- Los archivos guardados en Application Support y el Llavero toleran propiedades nuevas: al añadir un campo a los modelos, los datos anteriores siguen leyéndose con valores por defecto. Si la cola guardada no se puede leer, el panel de transferencias ofrece «Descartar cola guardada», que aparta el archivo con una copia `.corrupt-<fecha>` y vuelve a permitir transferencias.

## Configuración real de cuentas

La configuración corresponde al desarrollador y se hace una sola vez. Los usuarios del binario oficial solo eligen una cuenta y autorizan el acceso. **Todavía hacen falta los registros reales de iCloudy en Google y Microsoft**; no se incluyen IDs inventados ni un login simulado.

Consulta [la guía de registro, GitHub y App Store](docs/OAUTH.md). Una vez registrados los clientes:

```sh
swift scripts/configure-oauth.swift --google /ruta/cliente-desktop.json --microsoft APPLICATION_CLIENT_ID
bash scripts/build-app.sh --require-oauth
open dist/iCloudy.app
```

La configuración local queda fuera de Git y se incorpora al `.app` al compilar. Las cuentas Outlook/Hotmail se conectan mediante Microsoft para acceder a OneDrive; no se solicita acceso al correo. Para distribución pública hay que completar la verificación aplicable de Google y respetar las políticas empresariales de Microsoft.

## Semántica y límites de esta versión

- Las subidas siempre copian: no borran el origen. Google crea un archivo nuevo, y puede haber nombres repetidos; OneDrive renombra al haber conflicto. Los archivos vacíos de OneDrive reciben un sufijo único para evitar reemplazos.
- Al descargar, los nombres se adaptan al sistema local y las colisiones usan sufijos. No se reemplazan archivos existentes. Una carpeta descargada puede quedar parcial si falla una operación.
- Al descargar una carpeta, los documentos de Google y elementos remotos se guardan como `.webloc`; exporta cada documento individualmente si necesitas contenido editable o PDF.
- Google shortcuts y elementos compartidos remotos de Microsoft se abren por web. No hay Shared Drives, bibliotecas SharePoint ni Teams; «Compartido conmigo» de OneDrive muestra los elementos como enlaces.
- No hay montaje en Finder, placeholders del sistema, sincronización bidireccional, borrado remoto ni edición de permisos.
- La búsqueda global carga lotes de hasta tres páginas de 100 elementos por cuenta. Los filtros se aplican a los resultados recibidos; usa «Cargar más resultados» para continuar. Las fechas/tamaños ausentes no se inventan. La cobertura y actualidad dependen del índice de cada proveedor; no se incluyen bibliotecas SharePoint ni unidades compartidas de Google.
- Los enlaces simbólicos se rechazan. Se suben archivos ocultos y el contenido de paquetes como carpetas; no se conservan ACL, permisos POSIX, atributos extendidos ni resource forks.
- Los archivos de origen deben permanecer disponibles y sin editar mientras se suben. El progreso de carpetas se pondera por elementos, no por bytes.
- La cola se guarda en Application Support y se recupera en pausa al abrir la app; cada transferencia se puede pausar, cancelar o reintentar, y los fallos transitorios se reintentan hasta tres veces. Las subidas reanudan desde el desplazamiento que confirma el servidor. Las URL de sesión de subida son capacidades preautenticadas y caducan solas; viven en `transfers.json` con permisos 0600 dentro del contenedor y se eliminan al completar o cancelar la transferencia. Un reintento tras un fallo no vuelve a poner el progreso a cero, y las descargas de carpetas suman el total a medida que se listan.
- Los nombres se validan antes de crear carpetas, renombrar o subir: OneDrive rechaza `" * : < > ? / \ |`, espacios en los extremos, punto final y nombres reservados como `CON` o `desktop.ini`; el mensaje lo explica antes de contactar con el servidor.
- Las descargas requieren espacio para el contenido y el temporal de URLSession. No existe una caché persistente de contenidos administrada por la app.
- La exportación con Google `files.export` tiene el límite de 10 MB documentado para ese endpoint. Las cuotas y políticas de proveedores siguen aplicándose.
- No hay integración de pruebas con cuentas reales sin aportar los IDs OAuth y completar el consentimiento. Las pruebas locales usan respuestas HTTP simuladas, incluidas la renovación de tokens con un Llavero en memoria y el flujo loopback completo con un navegador simulado por TCP.
- Una sola ventana. La interfaz está en castellano con `defaultLocalization: es`; las vistas SwiftUI ya reciben claves localizables, pero los mensajes del modelo siguen en código y una traducción requiere extraerlos.
- Con la vista previa abierta, la selección se sigue tras una pausa de 350 ms para que recorrer la lista con las flechas no descargue cada archivo intermedio.

## Estructura

- `Models.swift`: cuentas, archivos, Llavero y nombres locales.
- `OAuth.swift`: login de navegador con loopback, PKCE y canje de tokens.
- `CloudAPI.swift`: listado, renovación de token, descargas y exportación. `ResumableUpload.swift`: la única ruta de subida, por bloques y con puntos de control.
- `AppModel.swift`: navegación, cuentas y cola de transferencias.
- `iCloudyApp.swift`: explorador SwiftUI y formulario de conexión.

## Referencias

- [OAuth para aplicaciones de escritorio de Google](https://developers.google.com/identity/protocols/oauth2/native-app)
- [OAuth con PKCE de Microsoft](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
- [URIs de redirección Microsoft](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url)
- [Subidas reanudables Google](https://developers.google.com/workspace/drive/api/guides/manage-uploads)
- [Sesiones de subida Microsoft](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)
