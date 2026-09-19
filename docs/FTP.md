# FTP, FTPS y SFTP en iCloudy

## Lo que hay implementado

**FTP** con usuario y contraseña, en modo pasivo siempre. La conexión de control se abre una vez por cuenta y se reutiliza; cada listado o transferencia abre su propia conexión de datos con `EPSV`, o con `PASV` si el servidor no admite la primera.

Esa conexión de control la comparten el explorador y la cola de transferencias, y FTP no admite dos órdenes a la vez en el mismo canal: las respuestas se mezclarían. Por eso las operaciones se ejecutan de una en una, en el orden en que llegan. Y como los servidores cierran la conexión de control tras unos minutos sin uso (vsftpd, a los cinco), la siguiente orden detecta que está muerta, o lee el `421` de despedida, y se vuelve a conectar sola una vez antes de rendirse.

Los identificadores de los elementos son rutas absolutas del servidor, igual que en WebDAV, y la raíz es la ruta base que el usuario escribe al conectar. Las migas de pan se construyen a partir de la ruta, sin peticiones adicionales; la raíz no tiene migas propias, porque «root» es un alias de iCloudy y no una carpeta del servidor.

Al autenticarse se pide `OPTS UTF8 ON`. Los servidores de Windows más antiguos contestan en la página de códigos local si no se les dice otra cosa, y los nombres con acentos llegaban destrozados; el que no conoce la orden contesta 500 y se sigue igual.

Listados: se usa `MLSD` cuando `FEAT` lo anuncia, que es el formato con tipos, tamaños y fechas fiables. Si no está, se analiza `LIST` en su variante Unix (`ls -l`) y en la variante DOS de algunos servidores Windows. Un enlace simbólico se muestra con su nombre, nunca como carpeta: iCloudy no puede comprobar a dónde apunta.

**FTPS implícito**, es decir, TLS desde el primer byte, normalmente en el puerto 990. Tras autenticarse se envían `PBSZ 0` y `PROT P` para que el canal de datos también viaje cifrado.

Dos límites de esa variante, que conviene saber antes de configurarla. El primero: cada conexión de datos negocia su propio TLS, sin reutilizar la sesión del canal de control. Los servidores que exigen esa reutilización, como vsftpd con `require_ssl_reuse` o FileZilla Server con sus ajustes por omisión, autentican bien y luego rechazan el primer listado. `Network.framework` no expone la sesión TLS para reutilizarla, así que arreglarlo pasa por la misma pila externa que haría falta para el FTPS explícito. El segundo: el certificado lo valida macOS con su política normal, y no hay forma de aceptar uno autofirmado desde la app. Si el servidor usa uno propio, hay que instalarlo en el Llavero y marcarlo como de confianza; el mensaje de error lo dice en lugar de limitarse a un código de TLS.

## Lo que no hay, y por qué

**FTPS explícito** (`AUTH TLS` sobre el puerto 21) no está. Es la variante más extendida, pero requiere empezar la conexión en claro y negociar TLS después. `Network.framework`, que es la capa de red de este proyecto, fija el cifrado al crear la conexión y no permite elevarla más tarde. Añadirlo exige otra pila de TLS.

**SFTP** no está. No es FTP sobre TLS sino un subsistema de SSH, y el SDK de Apple no incluye ninguna implementación de SSH. Hacerla a mano significa escribir el intercambio de claves, los cifrados y la verificación de la clave del servidor, que es justo el tipo de código criptográfico que no debe improvisarse. La vía razonable es añadir dependencias: `swift-nio-ssh` para el transporte y una capa propia para el subsistema SFTP, o `Citadel`, que ya trae ambas cosas.

Esa misma pila resolvería el FTPS explícito, porque `swift-nio-ssl` sí admite elevar una conexión en claro. Sería la primera dependencia externa del proyecto, que hasta ahora no tiene ninguna.

## Límites del protocolo, reflejados en la interfaz

FTP no tiene búsqueda, enlaces públicos, papelera, cuota ni sumas de verificación. La tabla de capacidades lo declara y la interfaz oculta o explica cada una de esas acciones en lugar de fallar al intentarlas.

- Eliminar es definitivo. El diálogo de confirmación lo dice, y las carpetas se vacían de dentro hacia fuera porque `RMD` exige que estén vacías. Cancelar detiene el borrado, que en una carpeta profunda son muchas órdenes seguidas.
- No hay copia en el servidor: `COPY` no existe en FTP. Para duplicar un archivo hay que descargarlo y volver a subirlo.
- Las subidas son un `STOR` completo. El protocolo tiene `REST` para reanudar, pero no hay una sesión que sobreviva a una caída como en Drive o Graph, así que un reintento empieza de cero.
- Ninguna subida queda verificada: el servidor no informa de ninguna suma.
- Mover y renombrar sí funcionan, con `RNFR` y `RNTO`.

## Seguridad

Sin FTPS, **la contraseña y los archivos viajan sin cifrar**. El formulario de conexión lo advierte y recomienda reservar esa opción para la red local. Las credenciales se guardan en el Llavero de este Mac y solo se envían al servidor que el usuario escribe.

Toda lectura tiene límite de tiempo, así que un servidor que deja de responder a mitad de una transferencia falla con un mensaje en lugar de dejar la operación colgada. Cancelar una subida detiene el envío en el siguiente bloque.

Una orden FTP termina en el salto de línea. Un nombre de archivo con un retorno de carro dentro, cosa que APFS permite, colaría una segunda orden al servidor (`informe\rDELE /web/index.html`). Los nombres con saltos de línea se rechazan antes de empezar la transferencia, y la sesión se niega a enviar cualquier línea que los contenga.

Si la dirección se escribe con las credenciales dentro (`ftp://ana:secreta@nas`), se extraen antes de guardarla: la dirección va a `accounts.json`, la contraseña solo al Llavero.
