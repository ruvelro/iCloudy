# FTP, FTPS y SFTP en iCloudy

## Lo que hay implementado

**FTP** con usuario y contraseña, en modo pasivo siempre. La conexión de control se abre una vez por cuenta y se reutiliza; cada listado o transferencia abre su propia conexión de datos con `EPSV`, o con `PASV` si el servidor no admite la primera.

Esa conexión de control la comparten el explorador y la cola de transferencias, y FTP no admite dos órdenes a la vez en el mismo canal: las respuestas se mezclarían. Por eso las operaciones se ejecutan de una en una, en el orden en que llegan. Renombrar y mover son una sola operación aunque lleven dos órdenes: el servidor olvida el `RNFR` en cuanto recibe cualquier otra cosa, así que `RNFR` y `RNTO` se envían seguidas sin soltar el canal, y un listado que el explorador pida mientras tanto espera a que terminen las dos. Y como los servidores cierran la conexión de control tras unos minutos sin uso (vsftpd, a los cinco), la siguiente orden detecta que está muerta, o lee el `421` de despedida, y se vuelve a conectar sola una vez antes de rendirse.

Ese reintento automático solo vale para lo que no cambia nada en el servidor: listados, descargas, `PWD`, `NOOP` y también `RNFR`, que solo nombra el elemento y se olvida al cerrar la conexión. Una orden que cambia algo (`STOR`, `DELE`, `RMD`, `MKD`, `RNTO`) se repite únicamente si no llegó a salir, o si el servidor la rechazó con `421`. Si la conexión se corta después de enviarla y antes de su respuesta, no se sabe si el servidor la aplicó: repetirla daría un error falso (un segundo `DELE` o `RNTO` ya no encuentra el original) o la haría dos veces. En ese caso no se repite y el mensaje dice exactamente eso, que el resultado es incierto y conviene actualizar la carpeta antes de volver a intentarlo. En una subida pasa lo mismo cuando ya salieron todos los bytes y lo que se pierde es la confirmación `226`; si la conexión cae a mitad de la transferencia, el archivo del servidor está incompleto con seguridad y el error es el normal. Como un socket muerto casi nunca falla al enviar sino al esperar la respuesta, antes de un cambio en una conexión que lleva unos segundos callada se envía un `NOOP`: si la conexión había caído, se reabre ahí, donde repetir no cuesta nada. En una subida no hace falta, porque su `EPSV` va primero y cumple ese papel.

Los identificadores de los elementos son rutas absolutas del servidor, igual que en WebDAV, y la raíz es la ruta base que el usuario escribe al conectar. Las migas de pan se construyen a partir de la ruta, sin peticiones adicionales; la raíz no tiene migas propias, porque «root» es un alias de iCloudy y no una carpeta del servidor.

Al autenticarse se pide `OPTS UTF8 ON`. Los servidores de Windows más antiguos contestan en la página de códigos local si no se les dice otra cosa, y los nombres con acentos llegaban destrozados; el que no conoce la orden contesta 500 y se sigue igual.

Listados: se usa `MLSD` cuando `FEAT` lo anuncia, que es el formato con tipos, tamaños y fechas fiables. Si no está, se analiza `LIST` en su variante Unix (`ls -l`) y en la variante DOS de algunos servidores Windows. Un enlace simbólico se muestra con su nombre, nunca como carpeta: iCloudy no puede comprobar a dónde apunta.

**FTPS implícito**, es decir, TLS desde el primer byte, normalmente en el puerto 990. Tras autenticarse se envían `PBSZ 0` y `PROT P` para que el canal de datos también viaje cifrado. Se guarda como `ftps://`.

**FTPS explícito** (`AUTH TLS` sobre el puerto 21), la variante más extendida. Se guarda como `ftpes://`, la grafía de FileZilla y curl. `Network.framework` fija el cifrado al crear la conexión y no deja elevarla más tarde, pero sí permite que un *framer* inserte un protocolo por debajo de sí mismo mientras la conexión todavía se está estableciendo. `StartTLSFramer` aprovecha justo eso: hace él mismo el diálogo en claro (lee el saludo `220`, envía `AUTH TLS`, espera el `234`), coloca TLS debajo y solo entonces declara la conexión lista. La sesión FTP ve una conexión ya cifrada, sin saludo que leer, y continúa con `PBSZ`, `PROT P` y la contraseña, que nunca viaja en claro. Si el servidor contesta otra cosa a `AUTH TLS`, la conexión falla antes de enviar ninguna credencial y el mensaje dice que ese servidor no admite FTPS explícito. Las conexiones de datos son TLS desde su primer byte, como en la variante implícita.

Dos detalles de ambas variantes de FTPS. El primero: cada conexión de datos negocia su propio TLS, sin reutilizar la sesión del canal de control. Los servidores que exigen esa reutilización, como vsftpd con `require_ssl_reuse` o FileZilla Server con sus ajustes por omisión, autentican bien y luego rechazan el primer listado; `Network.framework` no expone la sesión TLS para reutilizarla. El segundo: el certificado lo valida macOS con su política normal, y no hay forma de aceptar uno autofirmado desde la app. Si el servidor usa uno propio, hay que instalarlo en el Llavero y marcarlo como de confianza; el mensaje de error lo dice en lugar de limitarse a un código de TLS. Al terminar una subida cifrada, la conexión de datos se cierra con un *close_notify* de TLS y no con un simple FIN: un servidor con `PROT P` espera ese cierre para dar la transferencia por completa.

**SFTP**, que no es FTP sobre TLS sino un subsistema de SSH. El SDK de Apple no trae ninguna implementación de SSH y el proyecto no tiene dependencias externas, así que iCloudy lleva la suya, escrita sobre las primitivas que sí trae el sistema: CryptoKit para el acuerdo de claves, las firmas, AES-GCM y HMAC; CommonCrypto para AES en modo contador; Security para las claves RSA. Nada de lo criptográfico es propio; lo propio es la fontanería que RFC 4253 pide alrededor, y cada pieza de esa fontanería tiene su prueba.

- **Transporte** (`SSHTransport`): intercambio de versiones, `KEXINIT`, `curve25519-sha256` (también con el sufijo `@libssh.org`) y `ecdh-sha2-nistp256`; claves de servidor `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ecdsa-sha2-nistp384`, `rsa-sha2-512` y `rsa-sha2-256` (nunca `ssh-rsa` a secas, que es SHA-1); cifrados `aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`, `aes256-ctr` y `aes128-ctr`; integridad `hmac-sha2-256-etm@openssh.com` y `hmac-sha2-256`. Sin compresión. Si el servidor pide renovar claves a mitad de una transferencia larga, como hace OpenSSH cada hora o cada pocos gigabytes, se renuevan sin cortar nada. Un solo canal de sesión con el subsistema `sftp`, con control de ventana en los dos sentidos.
- **Inicio de sesión**: contraseña, y `keyboard-interactive` como alternativa para los servidores que solo aceptan la contraseña a través de PAM. Con claves todavía no.
- **Clave del servidor**: al conectar la cuenta se guarda la clave que presentó el servidor y su huella en formato `SHA256:` de OpenSSH. Cada sesión posterior tiene que presentar la misma; si cambia, la conexión se rechaza antes de enviar la contraseña, y el mensaje enseña las dos huellas y explica que puede ser un servidor reinstalado o alguien en medio. No se lee `~/.ssh/known_hosts`: el sandbox no lo permite.
- **SFTP versión 3** (`SFTPClient`): listados, `stat`, crear y borrar carpetas, borrar archivos, renombrar y mover (con `posix-rename@openssh.com` cuando el servidor lo anuncia), descargas y subidas con dieciséis peticiones en vuelo, para que una transferencia vaya a la velocidad del enlace y no a la de la latencia. Espacio libre con `statvfs@openssh.com`, que OpenSSH y la mayoría de NAS ofrecen.
- **Lo que no tiene**, como FTP: búsqueda, enlaces públicos, papelera, copia en el servidor ni sumas de verificación. Borrar es definitivo y el diálogo lo advierte.

## Límites del protocolo, reflejados en la interfaz

FTP y SFTP no tienen búsqueda, enlaces públicos, papelera ni sumas de verificación. La tabla de capacidades lo declara y la interfaz oculta o explica cada una de esas acciones en lugar de fallar al intentarlas.

- Eliminar es definitivo. El diálogo de confirmación lo dice, y las carpetas se vacían de dentro hacia fuera porque `RMD` y `RMDIR` exigen que estén vacías. Cancelar detiene el borrado, que en una carpeta profunda son muchas órdenes seguidas.
- No hay copia en el servidor. Para duplicar un archivo hay que descargarlo y volver a subirlo.
- Las subidas son completas: FTP tiene `REST` y SFTP escribe por desplazamientos, pero ninguno de los dos tiene una sesión que sobreviva a una caída como en Drive o Graph, así que un reintento empieza de cero.
- Ninguna subida queda verificada: el servidor no informa de ninguna suma.
- Mover y renombrar sí funcionan, con `RNFR`/`RNTO` en FTP y `rename` en SFTP. Antes de renombrar se comprueba que el destino no exista: ni uno ni otro se piden que sobrescriban.
- FTP no informa del espacio; SFTP sí, cuando el servidor implementa `statvfs@openssh.com`.

## Seguridad

Sin FTPS, **la contraseña y los archivos viajan sin cifrar**. El formulario de conexión lo advierte y recomienda reservar esa opción para la red local. Las credenciales se guardan en el Llavero de este Mac y solo se envían al servidor que el usuario escribe.

Toda lectura tiene límite de tiempo, así que un servidor que deja de responder a mitad de una transferencia falla con un mensaje en lugar de dejar la operación colgada. Cancelar una subida detiene el envío en el siguiente bloque.

Una orden FTP termina en el salto de línea. Un nombre de archivo con un retorno de carro dentro, cosa que APFS permite, colaría una segunda orden al servidor (`informe\rDELE /web/index.html`). Los nombres con saltos de línea se rechazan antes de empezar la transferencia, y la sesión se niega a enviar cualquier línea que los contenga. SFTP es binario y no tiene ese problema.

Si la dirección se escribe con las credenciales dentro (`ftp://ana:secreta@nas`), se extraen antes de guardarla: la dirección va a `accounts.json`, la contraseña solo al Llavero.

## Cómo se prueba

Las piezas puras tienen pruebas unitarias: la codificación de cable de SSH, el formato de paquete bajo cada cifrado (ida y vuelta, alineación y detección de alteraciones), la verificación de claves Ed25519, ECDSA y RSA, la derivación de claves y la negociación de algoritmos. El camino de rechazo del FTPS explícito corre contra el servidor FTP falso de las pruebas.

La pila completa se prueba contra servidores reales cuando se indican con una variable de entorno; sin ella, esas pruebas se saltan:

```bash
ICLOUDY_SFTP_URL="sftp://ana:secreta@127.0.0.1:2222/" swift test --filter SFTPTests
```

```bash
ICLOUDY_FTPS_URL="ftpes://ana:secreta@127.0.0.1:2121/" swift test --filter FTPSTests
```

Como servidores de pruebas sirven `asyncssh` (SFTP, con clave de servidor Ed25519, RSA o ECDSA y la lista de cifrados que se quiera) y `pyftpdlib` con `TLS_FTPHandler` (FTPS explícito con un certificado autofirmado). La prueba de FTPS activa un gancho que solo existe para eso, `StartTLSFramer.trustAnyCertificateForTesting`, porque un certificado autofirmado no lo acepta macOS de otra forma; la app nunca lo activa. El SFTP se ha validado contra las tres claves de servidor y contra AES-GCM, AES-CTR con `hmac-sha2-256-etm@openssh.com` y AES-CTR con `hmac-sha2-256`.
