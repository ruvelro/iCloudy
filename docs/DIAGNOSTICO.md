# Diagnóstico

> Qué anota iCloudy cuando algo falla, qué no anota nunca y cómo se entrega. Generaliza el registro que O2 ya tenía
> (ver [O2 Cloud](O2.md)) a todos los proveedores.

## Para qué existe

Un fallo de red, una sesión que caduca o un proveedor que empieza a contestar 429 no se ven desde la interfaz: solo
queda el mensaje final. El diagnóstico guarda la secuencia que llevó hasta ahí, para poder explicarla después sin
haber tenido que activar nada antes.

## Niveles

En **Ajustes → Diagnóstico**:

| Nivel | Qué se anota |
|---|---|
| **Desactivado** | Nada. |
| **Normal** (por omisión) | Errores, reintentos, límites de peticiones (429), cambios de red, renovaciones de token, el resumen de cada transferencia y el registro propio de O2. Las rutas se reducen a su forma (`/drive/v3/files/{id}`) y no aparece ningún nombre de archivo. |
| **Detallado** | Además, cada petición y cada orden correctas, con nombres y rutas de archivos y los argumentos de FTP y SFTP. Solo se activa tras aceptar un aviso que lo explica. |

Ningún nivel escribe secretos. Bajar del nivel detallado al normal no deja nombres en lo que se exporte después:
la exportación vuelve a pasar cada evento por el redactor con el nivel vigente.

## Qué contiene un evento

Una línea JSON de `events.jsonl`: fecha, tipo (`error`, `retry`, `summary`, `notice`, `trace`), etapa (`auth`,
`list`, `upload.chunk`, `upload.commit`, `download`, `verify`, `retry`, `rate-limit`, `network-change`, `ftp`,
`sftp`, `mega`, `o2`…), proveedor, cuenta, transferencia, método, servidor, plantilla de la ruta, código de estado,
duración, bytes, intento, dominio y código del error y un mensaje.

- **La cuenta** es un resumen con sal (`cuenta-1a2b3c4d`): estable en este Mac, sin significado fuera de él. La sal
  es aleatoria y propia de cada instalación, así que no sirve comparar con listas de direcciones. La ventana de
  Ajustes la traduce al nombre de la cuenta, pero la exportación no.
- **La transferencia** son los ocho primeros caracteres de su identificador, suficiente para seguir un trabajo.
- **La etapa de una petición** se deduce de lo que se ve de ella: una tarea de subida o un cuerpo con `Content-Range`
  es `upload.chunk`; `/commit` y `upload_session/finish` son `upload.commit`; una tarea de descarga es `download`;
  `PROPFIND` y los listados son `list`. Lo demás hereda la etapa del trabajo en el que ocurre.

## Qué no se escribe nunca

El redactor (`Diagnostics/DiagnosticsRedactor.swift`) es la única puerta entre lo que tiene el código y lo que se
guarda, y falla cerrado: si una de sus reglas no compilara, ocultaría el texto entero.

- Cabeceras `Authorization`, `Proxy-Authorization`, `Cookie` y `Set-Cookie`, y cualquier cabecera con *token*,
  *secret*, *auth*, *session* o *key* en el nombre. Las cabeceras no se anotan; la regla existe para las respuestas
  de error que las repiten.
- Tokens OAuth, de acceso, de refresco e `id_token`, secretos de cliente, verificadores PKCE, contraseñas, `sid`,
  claves de validación, cookies de sesión y pruebas de trabajo, estén en una consulta, un formulario, un JSON o un
  texto libre.
- Los **valores** de cualquier consulta: se conserva el nombre del parámetro (`upload_id=…`), nunca el valor. Eso
  cubre las firmas de las URL prefirmadas (`X-Amz-Signature`, `X-Amz-Credential`).
- **Las direcciones de sesiones de subida y los enlaces temporales**, que son capacidades: quien las tiene puede
  escribir en la cuenta. OneDrive (`/rup/`, `uploadSession`), Mega (`userstorage.mega.co.nz`), Dropbox
  (`dropboxusercontent.com`) y Box (`boxcloud.com`) se reducen a su plantilla incluso en el nivel detallado.
- Usuario y contraseña incrustados en una dirección (`https://ana:clave@nas/dav`).
- `PASS`, `USER` y `ACCT` de FTP, en las órdenes y en las respuestas que los repiten.
- JWT y cualquier cadena larga y opaca con aspecto de credencial, aunque a veces sea un identificador inofensivo.
- Direcciones de correo, que se sustituyen por `correo-<resumen>`.
- En el nivel normal, además: nombres entre comillas o «», rutas absolutas o relativas que no sean vocabulario del
  protocolo (`media/folder` de O2 se queda), nombres con extensión de archivo y los argumentos de FTP y SFTP. Dropbox
  lleva rutas dentro de `Dropbox-API-Arg`: esas claves (`path`, `from_path`…) también se ocultan.

## Dónde se engancha

Para no repartir lógica por el código compartido, cada punto es una línea:

- **HTTP**: todos los delegados de URLSession de la app heredan de `RedirectGuard`, que recibe las métricas de cada
  tarea terminada. `didCreateTask` corre dentro de la tarea que hace la petición, el único momento en que se puede
  leer su contexto (cuenta, transferencia, etapa), y lo deja en la propia tarea. `CloudSession` marca además cada
  petición con su cuenta, como propiedad del objeto (`URLProtocol.setProperty`), nunca como cabecera.
- **Reintentos y tokens**: el bucle de reintentos de `CloudSession.json`, la renovación del token y el paso a
  «sesión caducada».
- **Cola de transferencias**: el contexto de cada trabajo como valor local de la tarea, sus reintentos, la espera de
  red, el resumen al completarse (bytes, duración, verificados y sin verificar) y el fallo, con la etapa `verify`
  cuando lo que falló fue la comprobación de una descarga. Nunca el nombre del archivo.
- **Red**: `Connectivity` anota cada pérdida y recuperación.
- **FTP y SFTP**: cada orden FTP con su código de respuesta y cada petición SFTP por su nombre (`OPEN`, `STAT`,
  `RENAME`…). Los bloques `READ`, `WRITE` y `READDIR` no se anotan ni en el nivel detallado: serían miles.
- **Mega**: las peticiones que no contestan, la prueba de trabajo (402), los 5xx y 429 y los códigos negativos, con
  el nombre de la orden (`a=f`, `a=us0`), que es vocabulario del protocolo.
- **O2**: `O2Log` es ahora la parte de O2 de este registro (ver abajo).

## Almacenamiento y rendimiento

- En memoria, un anillo de los 2000 eventos más recientes, que al arrancar se rellena con los de sesiones
  anteriores.
- En disco, `Application Support/iCloudy/Diagnostics/events.jsonl`, con permisos 0600 en una carpeta 0700. Rota a
  los 512 KiB y se conservan como mucho tres archivos; lo que tiene más de siete días se borra y no se exporta.
- `record` solo lee el nivel bajo un cerrojo y pasa el resto a una cola serie propia, que redacta, guarda y escribe
  en lotes (cada 100 eventos o cada dos segundos, y al cerrar la app). Ni la redacción ni el disco tocan el hilo
  principal, y la ventana de Ajustes lee el anillo fuera de él.
- Mientras corren las pruebas el registro vive solo en memoria y no toca los ajustes del usuario: la batería no se
  ejecuta en caja de arena y escribiría en la carpeta de datos real de quien la lanza, como le pasó una vez a O2.

## Exportar y borrar

**Exportar diagnóstico…** prepara el paquete fuera del hilo principal y lo enseña antes de guardarlo: `summary.txt`
entero y los últimos eventos de `events.jsonl`, con un aviso si el nivel detallado está activo. Al guardar se
escribe un `.zip` (lo hace el sistema, el mismo que «Comprimir» del Finder) con:

- `summary.txt`: versión de la app y de macOS, nivel, cuentas agrupadas por tipo de proveedor con sus capacidades
  (leídas por reflexión de `CloudCapabilities`, así que una capacidad nueva aparece sola), cuántas transferencias hay
  en cada estado y recuentos de eventos por tipo, etapa y proveedor. Ningún nombre de cuenta, dirección ni archivo.
- `events.jsonl`: los eventos de disco dentro del límite de edad, redactados otra vez con el nivel vigente.
- `o2-diagnostico-anterior.txt`, solo si una versión anterior dejó el registro antiguo de O2.

Una app en caja de arena solo puede entregar archivos por un diálogo de guardar: el registro vive en su contenedor,
donde ni el terminal de su propio dueño puede leerlo.

**Borrar diagnóstico…** vacía la memoria, los archivos y el registro antiguo de O2, con confirmación.

## O2

O2 fue el primero en tener registro, porque su servidor cierra sesiones sin explicar por qué y no documenta nada.
Sus líneas (cada llamada con su código, si cambió la clave, qué cookies llegaron por nombre, la renovación
silenciosa y los toques que mantienen viva la sesión) siguen anotándose igual, y en el nivel normal, porque lo que
explica una sesión muerta es justamente lo que pasó cuando todo iba bien. Ya no van a `o2-diagnostico.txt` sino a
este registro, con tipo `notice` y etapa `o2`, que las acota, las redacta como todo lo demás y las exporta. El
botón «Exportar diagnóstico de O2…» de la pestaña Almacenamiento lo sustituye la exportación general. Lo único que
cambia es que el nivel **Desactivado** también las apaga.

## Pruebas

- `DiagnosticsRedactionTests`: URL con tokens en la consulta, identificadores y nombres en la ruta, direccionamiento
  por ruta de OneDrive, sesiones de subida de Google, OneDrive, SharePoint, Mega y Dropbox, URL prefirmadas,
  credenciales en la dirección, cabeceras `Authorization` y `Cookie`, `Dropbox-API-Arg`, respuestas y formularios
  OAuth, JSON cortado, `PASS`/`USER` de FTP, SFTP, cuerpos de error que repiten tokens, correos, nombres en mensajes y
  que los mensajes normales pasen intactos.
- `DiagnosticsLogTests`: niveles, anillo acotado, escrituras por lotes, rotación con permisos 0600 y tope de
  tamaño, caducidad, recarga tras reiniciar, borrado, que registrar no espere al disco, que la batería no escriba en
  la carpeta real, y los enganches de HTTP (contexto, cuenta de destino de una subida entre nubes, 429), de la marca
  de cuenta, de la cola y de la red.
- `DiagnosticsExportTests`: se siembran secretos falsos en cada forma de registrar un evento y se busca en los
  archivos exportados, byte a byte, cada secreto y un trozo de cada uno, en el nivel normal, tras bajar del detallado
  y en el detallado (donde los nombres sí deben estar); el resumen, que el `.zip` lo sea de verdad y que cada línea
  sea un objeto JSON.
- `O2LogTests`: lo de siempre (nombres de cookies sin valores, llamadas tranquilas, acotado, nada en disco durante
  las pruebas) más que sus líneas se conserven enteras en el nivel normal y que el registro antiguo se exporte y se
  borre.
