# Registro de cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/). Mientras el número mayor sea `0`, la app se considera
en desarrollo: puede haber cambios que rompan cosas entre versiones menores, y así se dirá aquí.

## 0.6.0 — 1 de octubre de 2026

Doce funciones nuevas, dos nubes más y la deuda que quedaba de la auditoría. 789 pruebas, todas en verde salvo las
tres que necesitan un servidor real (SFTP, FTPS y MinIO), y ningún aviso al compilar, tampoco con la comprobación
estricta de concurrencia. Lo nuevo se ha probado con respuestas simuladas, no contra cuentas reales.

### Nubes nuevas

- **pCloud**, por OAuth, con la región de la cuenta, subidas por bloques reanudables, papelera, enlaces públicos y
  verificación con `checksumfile` — [PCLOUD.md](docs/PCLOUD.md).
- **S3 y compatibles** (AWS, Backblaze B2, Wasabi, Cloudflare R2, MinIO, Scaleway, DigitalOcean Spaces), con firma
  SigV4 propia, subidas multiparte reanudables, ETag verificado y enlaces prefirmados temporales — [S3.md](docs/S3.md).

### Funciones

- Pestañas y doble panel, con copiar y mover al otro panel, también entre nubes: el original solo se quita después de
  una copia completa y verificada.
- Cola en paralelo con límites globales y por cuenta, límite de ancho de banda, prioridad, horario permitido y pausa en
  redes caras o limitadas.
- Plan antes de las transferencias grandes, informe archivo por archivo exportable a CSV y JSON, «Reintentar solo lo
  pendiente», «Verificar lo copiado» y «Empezar de cero».
- Descargas verificadas contra el tamaño y la suma del proveedor; QuickXorHash implementado, también para verificar
  las subidas de OneDrive empresarial.
- Copias «Disponible sin conexión» que se mantienen al día dentro de un límite de espacio.
- Historial de versiones en Drive, OneDrive, Dropbox, Box y Nextcloud.
- Gestión de enlaces públicos: caducidad, contraseña, descarga y revocación, por elemento y para toda la cuenta.
- Comparador de carpetas entre nubes o con el Mac, y buscador de duplicados.
- Bóvedas cifradas compatibles con Cryptomator (formato 8) — [CIFRADO.md](docs/CIFRADO.md).
- Exclusiones, pausa y vista previa de cambios en reflejos y sincronización.
- Diagnóstico estructurado de todos los proveedores, sin secretos y exportable — [DIAGNOSTICO.md](docs/DIAGNOSTICO.md).
- Integración continua en GitHub Actions.

### Correcciones

- Mega: la operación RSA del inicio de sesión pasa de unos 5 s a unos 45 ms, y una base más ancha que el módulo ya no
  da un resultado erróneo.
- WebDAV: dos servidores que solo se distinguen por puerto o esquema son dos cuentas, sin renombrar las existentes.
- FTP: `RNFR` y `RNTO` van juntos, y un cambio cuya respuesta se pierde no se repite: se avisa de que el resultado es
  incierto.
- O2: dominios de cookies con frontera, renovación cancelable al desconectar y un almacén de WebKit por cuenta,
  migrando las sesiones existentes.
- Spotlight ordena sus peticiones y retira lo que expulsa; el Dock, Servicios y Atajos esperan a las cuentas en un
  arranque en frío.
- Interfaz en inglés sin restos en castellano, y acciones ofrecidas según el tipo de elemento.
- Los errores de Dropbox dicen lo que pasa en lugar de «HTTP 409».
- Arreglar los permisos de un archivo que no se pudo leer ya no deja su subida bloqueada.
- Errores que se perdían en silencio (Llavero, índices, marcadores de volúmenes, borrados en bóvedas) ahora se dicen.
- Las pruebas ya no leen las cuentas reales del Llavero de quien las ejecuta.
- Detalle completo en [CORRECCIONES-P3-2026-10-01.md](docs/CORRECCIONES-P3-2026-10-01.md).

## 0.5.0 — 19 de septiembre de 2026

La primera versión numerada. Recoge una auditoría completa de la app y la tanda de correcciones que salió de ella,
proveedor por proveedor. 305 pruebas, todas en verde, sin red: las respuestas de los servidores están simuladas.

### Refactor interno del 20 de septiembre de 2026 (misma versión)

- Implementaciones independientes de las nueve nubes, con su estado y autenticación propios; fachada y contrato comunes.
- Modelos, persistencia, transporte, servicios de cuentas, coordinación y pantallas separados por responsabilidad.
- Pruebas adicionales de aislamiento, compatibilidad de datos y respuestas tardías de cuotas.
- Compilación debug independiente en `dist/debug/iCloudy.app`, manteniendo la versión 0.5.0 y los entitlements de release.
- Detalles y pasos para depurar en [REFACTOR-0.5.0.md](docs/REFACTOR-0.5.0.md).

### O2 Cloud

- La subida y la descarga usan la misma política de sesión que el resto. Antes montaban sus propias peticiones: una
  clave rotada a mitad de una subida perdía el archivo, un `401` no marcaba la cuenta como caducada y las cookies
  renovadas se tiraban.
- La sesión ya no viaja a cualquier servidor. La dirección de descarga puede apuntar a otra flota, y hasta ahora se
  le entregaban las cookies de la cuenta.
- Un toque de mantenimiento que no obtiene respuesta ya no cuenta como hecho, y recuperar la red dispara uno
  inmediato. Antes, un fallo justo al despertar compraba otro cuarto de hora de silencio.
- Las cookies del acceso en Telefónica se guardan junto a la sesión, con su `SameSite`, y se devuelven a la vista
  web antes de renovar. Sin ellas la renovación silenciosa llegaba al SSO como una desconocida y se paraba en la
  página de acceso. Los dominios de los que se recogen están nombrados uno a uno.
- Desconectar borra también el acceso guardado en el contenedor de WebKit, que es con lo que se acuñaban sesiones
  nuevas sin contraseña.
- Renovar conserva la cuenta en lugar de crear una segunda cuando `/profile` responde con otro campo.
- El servidor se puede cambiar desde la ventana de acceso, para los otros operadores que revenden la plataforma.
- El identificador de dispositivo es estable, la raíz es la carpeta sin padre, las páginas se piden mientras traigan
  algo nuevo y nada se sirve desde la caché.

### Mega

- Lo compartido deja de ser inaccesible, las descargas reintentan por trozo y cancelar detiene también la prueba de
  trabajo y el resto del trabajo en curso.

### Google Drive, OneDrive, Dropbox y Box

- Subir a la raíz de una unidad compartida ya no acaba en «Mi unidad», mover dentro de ella deja de dar 404 y la
  búsqueda pide un solo corpus.
- Box compara el resumen que devuelve en lugar de darlo por bueno, y una sesión reanudada vuelve a leer del disco lo
  ya enviado para que el commit lleve el resumen completo.
- Los reintentos respetan el `Retry-After` del proveedor, y un token caducado a mitad de una subida se renueva.

### WebDAV, FTP y volúmenes

- Reemplazar un archivo en un volumen ya no destruye el original cuando la copia falla.
- La conexión de control de FTP se reabre sola, las operaciones sobre una sesión van de una en una y un salto de
  línea en un nombre no llega nunca al servidor.
- Las credenciales escritas dentro de la dirección se extraen antes de guardarla.

### Cola, persistencia e interfaz

- Sin red las transferencias esperan en vez de fallar, y nada queda a medias en disco.
- Las acciones actúan solo sobre lo que el filtro deja a la vista, y dejan de ofrecerse donde no llevan a ninguna
  parte.
- La traducción al inglés vuelve a estar completa.
- El Finder ya entrega los archivos soltados sobre el icono del Dock.
