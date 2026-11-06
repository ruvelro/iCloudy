# Registro de cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/). Mientras el número mayor sea `0`, la app se considera
en desarrollo: puede haber cambios que rompan cosas entre versiones menores, y así se dirá aquí.

## Sin publicar

### Proveedores e integración

Lo nuevo de esta sección no se ha probado contra cuentas reales de cada servicio: lo cubren las pruebas con servidores
simulados y la documentación de cada uno. Se marca como 🆕 hasta que alguien lo use de verdad.

- **«Más servidores» al añadir una nube.** Hetzner Storage Box (SFTP y WebDAV), Koofr, Yandex Disk, Infomaniak
  kDrive, IONOS HiDrive, Fastmail Files, Seafile, ownCloud Infinite Scale y Nextcloud llegan con la dirección, el
  puerto y la ruta ya puestos, lo que hay que saber antes (la contraseña de aplicación, el protocolo que hay que
  activar en su panel) y un enlace a sus instrucciones. En S3 se añaden Storj e iDrive e2 a Backblaze, Wasabi y R2.
  Por debajo son cuentas WebDAV, SFTP o S3 normales: una tabla de datos, no proveedores nuevos.
- **Nextcloud inicia sesión en el navegador** (Login Flow v2): se escribe la dirección, se abre la página del propio
  servidor, se entra con lo que pida (dos pasos, SSO, llave de seguridad) y Nextcloud entrega a iCloudy una contraseña
  de aplicación solo para él, revocable desde su seguridad. Los archivos se buscan bajo el id del usuario aunque se
  entre con el correo. El formulario de usuario y contraseña sigue a mano para los servidores que lo tengan apagado.
- **Subidas grandes a Nextcloud por trozos que se reanudan** (chunking v2). Desde 32 MB, el archivo sube en trozos
  numerados a una carpeta de subida propia y un MOVE final lo deja en su sitio de una vez. Si la conexión cae, el
  reintento pregunta si la subida sigue en el servidor y continúa por el siguiente trozo; cancelar la borra. Antes
  era un único PUT que volvía a empezar desde cero.
- **WebDAV habla Digest y acepta tokens.** Un servidor que pide autenticación Digest (algunos NAS, IIS) ya no se
  rechaza: se responde con MD5 o SHA-256 y la contraseña no viaja, y una cuenta Básica cuyo servidor cambia a Digest
  lo sigue sin volver a conectarla. En «Avanzado» se puede conectar con un token de acceso OAuth (`Bearer`), para
  servidores como ownCloud Infinite Scale; iCloudy no lo renueva. Los certificados de cliente quedan fuera por ahora.
- **SFTP reanuda subidas y descargas por donde iban.** La subida guarda cada 16 MB cuánto ha confirmado el servidor
  en el parcial oculto (`.nombre.icloudy-part`) y el reintento sigue desde ahí, si el origen no ha cambiado. La
  descarga deja junto al destino un parcial con la versión que estaba bajando; si el archivo sigue igual en el
  servidor, se continúa, y si cambió, se empieza de cero. Cancelar borra los parciales.
- **iCloud Drive** 🆕, como carpeta de este Mac: se confirma una vez su carpeta y la cuenta muestra, archivo a
  archivo, si está solo en iCloud, bajando, descargado o subiendo. Abrir, previsualizar, descargar o copiar un archivo
  que solo está en iCloud pide antes la descarga y espera, sin bloquear y con opción de cancelar, y lo lee coordinado
  con iCloud. «Descargar de iCloud a este Mac» y «Quitar la descarga» están en el menú; «Mantener descargado» no,
  porque macOS no lo ofrece a las apps. Por debajo es un volumen, sin cuota: la de iCloud no se puede leer.

### Robustez

- **La ventana ya no se traba guardando ni leyendo.** La cola, los reflejos, las copias sin conexión y locales, el
  índice de Spotlight y el historial se escriben en segundo plano, en orden y sin escrituras repetidas. Las
  respuestas grandes (una página de mil archivos, el árbol de pCloud o de Mega) se leen fuera del hilo principal.
- **El archivo de la cola deja de crecer sin límite**: el panel conserva las 300 transferencias terminadas más
  recientes, y el historial, todas. Antes guardaba cada pasada de cada reflejo con su informe completo.
- **Cada vista se redibuja solo por lo que muestra.** El modelo de la app pasa a Observation: antes, cualquier cambio
  (una cuota que llega, una transferencia que avanza) redibujaba las 24 vistas que lo miraban. De paso, olvidar una
  copia local ya quita su marca al momento.
- **Swift 6**: la app, la librería y la extensión del Finder compilan en el modo de lenguaje Swift 6, con la
  comprobación completa de carreras de datos.
- **Singular y plural** en castellano y en inglés para los recuentos que pueden ser uno: «1 seleccionado», «1
  conflicto», «Queda 1 por transferir», en lugar de «1 seleccionados». Las reglas viven en `.stringsdict`, generados
  con `scripts/make-plurals.py`.

### Correcciones de la revisión

Lo que encontró la revisión del 5 de noviembre (`docs/REVISION-2026-11-05.md`), salvo lo que es de arquitectura.

- **Google Drive ve las unidades compartidas desde una cuenta personal.** Cada llamada lleva `supportsAllDrives` y los
  listados y búsquedas, `includeItemsFromAllDrives`: una carpeta de una unidad compartida que alguien te comparte
  aparece en «Compartido conmigo» y se abre, en lugar de faltar o dar 404 al entrar.
- **Una descarga SFTP larga ya no se queda parada tras la renovación de claves** que OpenSSH pide cada hora: la
  ampliación de ventana que salía en mitad del intercambio, y que el servidor descartaba, espera ahora a `NEWKEYS`.
- **La cola no se pierde entera por un punto de reanudación que no entiende**: las subidas a medias que escribió una
  versión más nueva se descartan solas, como ya pasaba con las descargas.
- **WebDAV reintenta**: un 429 o el 503 de un Nextcloud en mantenimiento se esperan, respetando `Retry-After`, en
  lugar de fallar a la primera. Solo se repite lo que se puede repetir sin efectos dobles.
- **La papelera propia de OneDrive avisa si no se pudo apuntar** lo enviado, en vez de callarlo; y si su archivo no se
  puede leer, se aparta en lugar de sobrescribirse con una lista vacía.
- **`Retry-After` en forma de fecha** se entiende, y la espera máxima sube de 30 a 120 segundos: Box y Graph piden a
  menudo uno o dos minutos, y volver antes era encontrarse otra vez la negativa. Los cinco lectores de la cabecera son
  ahora uno.
- **Un bloque que falla ya no tira la subida.** Un 5xx, un 429 o una conexión cortada en mitad de un bloque de Google,
  OneDrive, Dropbox, Box o de los servidores de almacenamiento de Mega se espera y se repite; en Google y OneDrive,
  preguntando antes cuánto llegó y enviando solo lo que falta. Antes la sesión se perdía y la cola empezaba el archivo
  otra vez desde su punto de control. Google y OneDrive comparten ahora el mismo bucle de subida.
- **SFTP y FTP suben con un nombre provisional** (`.nombre.icloudy-part`) y lo renombran al terminar: una caída ya no
  deja un archivo cortado con el nombre definitivo. Si falla, el provisional se borra cuando la conexión lo permite.
- **La papelera de Dropbox se recorre carpeta a carpeta**, como en dropbox.com: lo borrado en cada carpeta y las
  carpetas por las que seguir. Antes cada visita listaba la cuenta entera, archivo a archivo.
- **La búsqueda de pCloud reutiliza el árbol cinco minutos**, como la de Mega, en vez de bajarlo entero en cada
  consulta; cualquier cambio hecho desde iCloudy lo descarta.
- **Un listado que repite la misma página se corta** en lugar de pedirla para siempre.
- **El README dice la verdad**: sin recuentos de pruebas fijos, `swift run iCloudyMain`, Automator solo a través de
  «Ejecutar atajo», la extensión del Finder en «En camino» porque nunca se ha cargado, qué indexa Spotlight y qué
  papeleras se pueden restaurar.

### Seguridad

- **pCloud ya no puede conectar en silencio la cuenta de otro.** pCloud no devuelve el `state` de OAuth, así que una
  página cualquiera podía mandar al puerto local un código de su propia cuenta. Ahora solo vale la primera vuelta sin
  `state`, en los cinco minutos siguientes a abrir el navegador, y antes de guardar nada se te pregunta si la cuenta
  que ha vuelto (con su correo) es la tuya. Google, Microsoft, Dropbox y Box siguen exigiendo `state`.
- **SFTP enseña la huella del servidor la primera vez** y no envía la contraseña ni la firma de la clave hasta que la
  aceptas. La clave aceptada pasa al Llavero; la que guardaban en `accounts.json` las cuentas anteriores se mueve allí
  en la primera conexión, y desde entonces manda el Llavero.
- **Intercambio estricto de claves SSH** (`kex-strict-c-v00@openssh.com`, contra Terrapin): se anuncia, se rechaza
  cualquier paquete ajeno al primer intercambio y los contadores vuelven a cero tras cada `NEWKEYS` cuando el servidor
  también lo admite. Además: claves RSA de servidor de al menos 2048 bits y relleno mínimo de cuatro bytes.
- **Las claves RSA del usuario firman con Security.framework**, con la clave PKCS#1 completa y sus parámetros CRT, en
  lugar de con la aritmética propia de Mega, cuyo tiempo dependía del exponente.
- **keyboard-interactive** solo contesta con la contraseña a un aviso oculto que la pide, y una vez. Un segundo factor
  se rechaza con un mensaje claro en vez de recibir la contraseña.
- **El segundo factor de Mega se pide cuando Mega lo pide**, en un campo propio, en lugar de adivinarlo de «contraseña,
  espacio y seis cifras», que rompía cualquier contraseña que acabase así.
- **FTPS explícito** lleva el nombre del servidor en las opciones de cada conexión y lo comprueba de forma explícita
  contra el certificado, también cuando es una dirección IP. Antes salía de una tabla compartida que no se vaciaba y
  que, con dos sesiones a la vez, podía darle a una el nombre de la otra.
- **`SECURITY.md`** explica qué criptografía es del sistema y cuál está escrita aquí, y cómo avisar de un fallo. Se
  añaden los vectores oficiales que faltaban: el resto de ejemplos del RFC 3394, el último del RFC 4493 y los de
  regresión de OpenBSD para bcrypt_pbkdf.
- Un **servidor SSH falso** en las pruebas ejercita todo lo anterior sin red.

### Arquitectura

- **Los favoritos ya no se pierden si su archivo se estropea.** Antes, un `favorites.json` ilegible empezaba con la
  lista vacía y la primera estrella la escribía encima de todos los demás; ahora se aparta como `.corrupt-<fecha>` y
  se avisa, como ya hacía la lista sin conexión. Todos los cambios de favoritos pasan por un único `FavoritesStore`
  y se guardan en segundo plano.
- **Menos tirones mientras se transfiere.** La cola ya no espera en el hilo principal a que se escriba su archivo
  tras cada cambio de estado (un árbol de F carpetas eran al menos 2F escrituras síncronas), y cada almacén se
  escribe en su propia cola, así que uno grande no retrasa a los demás.
- **Las sincronizaciones bidireccionales dejan de reescribir todos los reflejos tras cada paso.** Cada reflejo tiene
  su archivo y su línea base se guarda cada dos segundos y al terminar. El `mirrors.json` de versiones anteriores se
  migra solo y se conserva como `mirrors.json.migrated`.
- **Las insignias de las filas ya no se redibujan con cada bloque transferido** ni cuando llega una cuota: la cola,
  las cuotas y las copias locales y sin conexión usan Observation y cada fila depende solo de lo que muestra.
- **La demo es un proveedor como los demás**, así que pasa por los mismos puntos de control de subida y las mismas
  comprobaciones de descarga, en lugar de un camino aparte con 34 excepciones.
- Por dentro: las cuentas y su escritura en el Llavero tienen un solo dueño (`AccountDirectory`); el ciclo de vida de
  O2 sale del modelo a `O2SessionKeeper`, con pruebas sobre un reloj simulado; las 27 hojas y alertas viven en
  `model.ui`; los tres recorridos de la cola son uno (`TransferWalker`); las capacidades de cada proveedor están en
  una sola tabla, sin cuatro indicadores muertos; los errores tienen clase (`CloudError.kind`); cada almacén JSON
  lleva `schemaVersion`; y las pruebas dicen que lo son en lugar de que la app lo adivine buscando `XCTestCase`.
  Todo se describe en [ARQUITECTURA.md](docs/ARQUITECTURA.md).

## 0.7.0 — 12 de octubre de 2026

El Llavero deja de preguntar por cada nube, una tanda de mejoras para el uso diario y lo que le faltaba a cada
proveedor. 835 pruebas, en verde también en GitHub Actions, y ningún aviso al compilar, tampoco con la comprobación
estricta de concurrencia. Lo nuevo se ha probado con respuestas simuladas, no contra cuentas reales; las claves SSH,
con claves reales de `ssh-keygen`.

- **Las nubes de la barra lateral se pueden arrastrar** para ordenarlas. Cada fila era un botón, y en macOS un botón
  se queda el ratón desde que se pulsa: el arrastre nunca empezaba y solo funcionaban «Mover arriba» y «Mover abajo».

### Llavero

- **El Llavero pregunta como mucho una vez por compilación**, no una por cada nube conectada. Todo lo que iCloudy
  guarda allí va ahora en un único elemento, que se lee una vez por ejecución. La causa estaba mal medida: el
  certificado local no basta, porque sin Team ID el llavero ata cada elemento al `cdhash` exacto de la compilación
  que lo creó. Con un certificado Apple Development (gratis con un Apple ID) no pregunta nunca —
  [OAUTH.md](docs/OAUTH.md#firma-local-para-desarrollo).
- Los elementos antiguos se mueven solos la primera vez que se leen: esa vez preguntan cada uno, por última vez.

### Uso diario

- **Miniaturas** de fotos, vídeos y PDF en la vista de iconos, dibujadas por Google Drive, OneDrive, Dropbox, Box y
  pCloud, y por Quick Look en los volúmenes. Se guardan en el Mac, se piden de cuatro en cuatro y se apagan en Ajustes.
- **Arrastrar al Finder**: un archivo soltado en el Finder, el Escritorio u otra app se descarga en ese momento, no al
  empezar a arrastrar. Los documentos de Google salen como Word, Excel o PowerPoint. Arrastrar al otro panel ya no
  exige tener la ventana partida.
- **Notificaciones** al terminar cada tanda de transferencias, con cuántas han ido bien y cuántas no, solo si iCloudy
  no está delante. Los reflejos no avisan.
- **Deshacer y rehacer** (⌘Z, ⇧⌘Z) renombrar, mover dentro de una cuenta y enviar a la papelera en Drive, Box,
  pCloud y Mega, donde la papelera devuelve el elemento por su id.
- **Renombrar en lote**: reemplazar texto, añadir antes o después, o numerar, con vista previa de cada nombre y la
  extensión intacta. Comprueba choques antes de enviar nada y resuelve los intercambios de nombre en dos pasos.
- **Ordenar por tipo**, y **flechas en la vista de iconos**: se mueven como en el Finder, ⇧ amplía la selección e
  Intro abre.
- **Abrir al iniciar sesión** y **sin icono en el Dock**, quedándose en la barra de menús.
- **Búsquedas guardadas**, con su texto y sus filtros, también en el menú de la barra de menús. Y **búsqueda en
  WebDAV, Nextcloud, FTP, SFTP y O2**, que no tienen la suya: iCloudy recorre las carpetas de cuarenta en cuarenta y
  «Cargar más» sigue por donde iba. En pCloud basta un listado recursivo.
- **Atajos**: listar una carpeta, descargar un archivo, crear un enlace público y copiar entre nubes, nombrando cada
  cosa por su cuenta y su ruta.

### Huecos por nube

- **SFTP con clave privada**: Ed25519, ECDSA (P-256, P-384, P-521) y RSA en el formato de OpenSSH, con frase o sin
  ella. La frase se descifra con `bcrypt_pbkdf` propio, comprobado contra el vector de OpenBSD y contra claves de
  `ssh-keygen`. La clave vive en el Llavero y solo firma; si el servidor la rechaza y hay contraseña, se usa esta.
- **pCloud**: versiones (listar, leer y restaurar revisiones) y gestión de enlaces públicos, por elemento y de toda
  la cuenta.
- **Nextcloud**: papelera navegable, con restaurar, eliminar definitivamente y vaciar. Borrar en Nextcloud ya no se
  anuncia como definitivo.
- **OneDrive**: papelera con lo eliminado desde iCloudy en los últimos 30 días, restaurable en cuentas personales.
  Graph no deja a otras apps ver la papelera entera, y la pestaña lo dice.
- **S3**: credenciales temporales con token de sesión (también en los enlaces prefirmados), importación de perfiles
  de `~/.aws` y versiones de objetos en buckets con control de versiones: listar, leer, restaurar y borrar.
- **Mega**: las subidas se reanudan desde el último trozo confirmado en lugar de empezar de cero.
- **Proton Drive** sigue fuera: no tiene API pública, necesita OpenPGP y SRP propios, y no se añadirá sin poder
  probarlo contra cuentas reales.

## 0.6.1 — 1 de octubre de 2026

Correcciones que sacó a la luz la primera ejecución de la integración continua, en un Mac con otro idioma y otra
versión de Swift. 792 pruebas, en verde también en GitHub Actions.

- Los códigos de error salen tal cual: en un sistema en inglés decían «TLS -9,807» o «code 1,234», porque el número
  se formateaba con separador de miles. Afectaba a FTP, pCloud y el Llavero.
- Compila con Swift 6.1 y 6.2 (Xcode 16 y 26): una frase traducible de SFTP y dos expresiones de Mega y de las
  pestañas que esos compiladores no resolvían a tiempo.
- La integración continua usa el Xcode más reciente del equipo de GitHub.

## 0.6.0 — 1 de octubre de 2026

Doce funciones nuevas, dos nubes más y la deuda que quedaba de la auditoría. 792 pruebas, todas en verde salvo las
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
- Google: una cuenta conectada sin marcar la casilla de acceso a Drive en la pantalla de permisos se rechaza al
  conectar, y una que ya lo estaba pide volver a conectarse en vez de fallar en cada carpeta con «Request had
  insufficient authentication scopes».
- Detalle completo en [CORRECCIONES-P3-2026-10-01.md](docs/historial/CORRECCIONES-P3-2026-10-01.md).

## 0.5.0 — 19 de septiembre de 2026

La primera versión numerada. Recoge una auditoría completa de la app y la tanda de correcciones que salió de ella,
proveedor por proveedor. 305 pruebas, todas en verde, sin red: las respuestas de los servidores están simuladas.

### Refactor interno del 20 de septiembre de 2026 (misma versión)

- Implementaciones independientes de las nueve nubes, con su estado y autenticación propios; fachada y contrato comunes.
- Modelos, persistencia, transporte, servicios de cuentas, coordinación y pantallas separados por responsabilidad.
- Pruebas adicionales de aislamiento, compatibilidad de datos y respuestas tardías de cuotas.
- Compilación debug independiente en `dist/debug/iCloudy.app`, manteniendo la versión 0.5.0 y los entitlements de release.
- Detalles y pasos para depurar en [REFACTOR-0.5.0.md](docs/historial/REFACTOR-0.5.0.md).

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
