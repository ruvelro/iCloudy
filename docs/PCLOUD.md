# pCloud

pCloud se conecta como Dropbox o Box: el usuario pulsa **Continuar con pCloud**, inicia sesión en la web de pCloud
y autoriza a iCloudy. No escribe ninguna contraseña en la app. A diferencia de Mega y O2, pCloud sí publica una API
para terceros ([docs.pcloud.com](https://docs.pcloud.com)), así que no va marcado como experimental. El registro de
la aplicación, que hace una vez el desarrollador, está en [OAuth](OAUTH.md#5-pcloud).

## Lo que lo hace distinto

### Dos regiones, dos servidores

pCloud guarda cada cuenta en uno de sus dos centros de datos y solo responde por ella desde el servidor de esa
región: `api.pcloud.com` para las cuentas de Estados Unidos y `eapi.pcloud.com` para las de Europa. Una cuenta
europea preguntada en el servidor americano se rechaza como si no existiera.

iCloudy aprende la región al iniciar sesión y la guarda con la cuenta (`options["apiHost"]`, más el número de región
en `options["locationid"]`). Al volver del navegador, pCloud añade a la dirección de vuelta `hostname` y
`locationid`; el código de autorización se canjea en ese servidor, y si la respuesta del canje indica otra región,
manda la respuesta. Si la vuelta no trae región, el código se prueba en Estados Unidos y, si pCloud dice que no lo
conoce, en Europa: un código que el servidor equivocado no reconoce sigue sin usar.

Solo esos dos nombres reciben nunca el token o el secreto de la aplicación. Una vuelta del navegador que nombre
cualquier otro servidor se rechaza antes de enviar nada, y un nombre desconocido en una respuesta se ignora. Una
cuenta guardada sin región, o con un nombre que no es de pCloud, habla con `api.pcloud.com`.

### Un token que no caduca

pCloud no admite PKCE: el código se canjea con el identificador y el secreto de la aplicación, que viajan dentro
del binario igual que con Box. A cambio, el token que entrega **no caduca y no trae token de refresco**. iCloudy lo
guarda en el Llavero como credencial permanente (`Credential.permanent`) y lo usa tal cual. El renovador de tokens
lo reconoce: no intenta renovarlo nunca, y si pCloud deja de aceptarlo (lo revocó el usuario desde su cuenta, o la
cuenta cambió de contraseña) la cuenta pasa a «Sesión caducada» y hay que volver a conectarla. El secreto no se
guarda con la cuenta, porque sin refresco no hay nada para lo que haga falta.

### La vuelta sin `state`

pCloud pierde el parámetro `state` en algunos de sus recorridos de inicio de sesión; otros clientes de pCloud lo
toleran por el mismo motivo. iCloudy acepta para pCloud, y solo para pCloud, una vuelta **sin ningún** `state`. Si
la vuelta trae uno, tiene que ser exactamente el esperado, como con todos los demás. La exposición es pequeña: el
puerto de vuelta solo escucha en `127.0.0.1` mientras dura un inicio de sesión que el usuario ha pedido, y como mucho
diez minutos.

### Respuestas HTTP 200 con un código dentro

Cada llamada de pCloud contesta HTTP 200, haya ido bien o mal. Lo que cuenta es el campo `result` del JSON: 0 es
éxito y cualquier otro número es un error, con una explicación en inglés en `error`. iCloudy traduce esos códigos a
los errores que el resto de la app ya entiende:

| Código | Significado | Qué hace iCloudy |
|---|---|---|
| 1000, 2000, 2094, 2095 | Hace falta iniciar sesión, o el token ya no vale | Marca la cuenta como caducada; no hay renovación posible |
| 2002, 2005, 2009 | La carpeta de la ruta, la carpeta o el archivo no existen | Se trata como un 404: la verificación de descargas lo distingue de un archivo dañado |
| 2001 | Nombre no válido | Aviso, sin reintento |
| 2003 | Acceso denegado | Aviso, sin reintento |
| 2004 | Ya existe un elemento con ese nombre | Aviso, sin reintento |
| 2008 | La cuenta no tiene espacio | Aviso, sin reintento |
| 2012 | Código de autorización no válido | Aviso al conectar |
| 4000 | Demasiados intentos desde esta dirección | Reintentable, esperando un minuto |
| 5000, 5001 | Error interno de pCloud | Reintentable |
| Otro | — | Aviso con el código y la explicación de pCloud |

Las lecturas (listar, cuota, sumas, enlaces) se repiten solas ante un error interno o un exceso de intentos. Las
escrituras (crear, renombrar, mover, copiar, borrar) no se repiten nunca desde aquí, porque pCloud puede haber
actuado antes de fallar; la cola de transferencias decide después con sus propias reglas.

## Operaciones

Los elementos se identifican con los números de pCloud, no con rutas: una carpeta es `d` más su `folderid` y un
archivo `f` más su `fileid`, que es como los escribe el propio campo `id` de pCloud. La raíz es la carpeta 0
(`d0`). Esos números no cambian al renombrar ni al mover, así que favoritos, reflejos y la cola no tienen que
reescribir nada.

| Acción | Método de pCloud |
|---|---|
| Listar una carpeta | `listfolder` con `folderid` |
| Migas de pan | `listfolder` con `nofiles=1`, subiendo por `parentfolderid` |
| Crear carpeta | `createfolder` |
| Renombrar | `renamefile` / `renamefolder` con `toname` |
| Mover | `renamefile` / `renamefolder` con `tofolderid`, que conserva el nombre |
| Copiar | `copyfile` / `copyfolder` con `noover=1`, que nunca sobrescribe |
| Enviar a la papelera | `deletefile` / `deletefolderrecursive` |
| Listar la papelera | `trash_list` |
| Restaurar | `trash_restore` |
| Eliminar definitivamente | Papelera primero si hace falta y después `trash_clear` del elemento |
| Vaciar la papelera | `trash_clear` de la carpeta 0 |
| Descargar | `getfilelink` y descarga del primer servidor, por https |
| Espacio | `userinfo` (`quota` y `usedquota`) |
| Enlace público | `listpublinks` y, si no existe, `getfilepublink` / `getfolderpublink` |

Las descargas van a un servidor de contenido distinto con un enlace que pCloud firma para esa dirección y por un
tiempo limitado. Ese enlace es la credencial, así que el token no se envía con él.

pCloud crea un enlace nuevo cada vez que se le pide uno, y cada enlace se revoca por separado. Por eso, antes de
crear uno, iCloudy busca entre los que ya existen y devuelve el del mismo elemento si lo hay. El proveedor sabe
también listar y borrar enlaces (`listpublinks`, `deletepublink`), pero la interfaz todavía no tiene dónde
ofrecerlo: por ahora se revocan desde la web de pCloud.

## Subidas

- **Menos de 8 MiB**: un único `PUT` a `uploadfile`, con el archivo como cuerpo y el nombre como parámetro. Así no
  hace falta un cuerpo multiparte ni meter un nombre con acentos en una cabecera.
- **Desde 8 MiB**: una sesión de subida en bloques de 4 MiB. `upload_create` da un `uploadid`, que se guarda en el
  punto de control de la transferencia (`UploadCheckpoint.sessionID`) junto con el desplazamiento; cada bloque va
  con `upload_write`, y `upload_save` crea el archivo al final.
- **Reanudar**: una sesión guardada se retoma preguntando a `upload_info` cuánto tiene ya el servidor, que es quien
  manda, porque un bloque puede haber llegado aunque su punto de control no llegara al disco. Si pCloud ya no
  conoce la sesión (caducó, o se guardó antes de que el punto de control lo dijera), se empieza otra desde el primer
  byte. Cancelar una transferencia borra su sesión con `upload_delete`.
- **Nombres repetidos**: un archivo nuevo se sube con `renameifexists=1`, de modo que un nombre que alguien haya
  ocupado después de la comprobación de conflictos no se pisa nunca. Solo cuando la cola pide reemplazar se
  permite sobrescribir, y pCloud guarda entonces la versión anterior en su historial.

## Integridad

El listado de pCloud no trae ninguna suma del contenido: su campo `hash` es una marca de cambios propia, no un
resumen de los bytes. La suma real la da `checksumfile` para cada archivo: **SHA-256 en Europa, SHA-1 en Estados
Unidos** (allí, además, MD5).

- **Subidas**: iCloudy calcula SHA-1 y SHA-256 sobre los mismos bloques que envía y compara el que pCloud informe.
  `uploadfile` ya devuelve las sumas en su respuesta; tras una sesión por bloques se piden a `checksumfile`. Una
  subida reanudada vuelve a leer del disco lo ya enviado para que el resumen cubra el archivo entero, así que
  también queda verificada. Si las sumas no coinciden la transferencia falla con aviso; si pCloud no contesta con
  ninguna, la subida queda «sin verificar» en lugar de repetirse y duplicar el archivo.
- **Descargas**: el proveedor declara `downloadChecksum(of:)`, un punto de enganche común nuevo que la verificación
  compartida usa cuando el listado no trae suma. Justo antes de descargar se pide `checksumfile`, de modo que la suma
  describe la misma versión que va a viajar; después la verificación de siempre compara, descarta la copia si no
  coincide y vuelve a preguntar por el archivo para distinguir un cambio en la nube de un archivo dañado. La vista
  previa por encima de su límite, que no calcula sumas, tampoco hace esa pregunta.

## Lo que no hay, y por qué

- **Búsqueda**: la API documentada de pCloud no tiene un método de búsqueda para terceros, así que la capacidad está
  apagada y la búsqueda global no incluye estas cuentas.
- **«Recientes» y «Compartido conmigo»**: pCloud no los expone como listas. Las carpetas que otros comparten y ya
  se aceptaron aparecen dentro del árbol, como en la web.
- **Compartir con personas**: pCloud solo comparte carpetas con otras cuentas, con su propio flujo de invitaciones.
  Queda para más adelante.
- **Versiones**: pCloud guarda revisiones (`listrevisions`, `revertrevision`), pero iCloudy todavía no tiene un
  contrato común para ellas. Queda para más adelante.

## Sin comprobar con una cuenta real

Las pruebas cubren todo lo anterior contra respuestas simuladas: el canje con región, la elección de servidor, el
listado, la subida por bloques y su reanudación, la traducción de errores, las sumas y la papelera. No sustituyen
una cuenta de verdad. Antes de distribuir conviene confirmar con cuentas de las dos regiones:

- Que pCloud acepta la dirección de vuelta `http://127.0.0.1:53682/callback` registrada en la aplicación, y si
  tolera otro puerto (iCloudy supone que no, como con Microsoft y Dropbox).
- Que `oauth2_token` acepta el canje por `POST` con formulario, y que la vuelta trae `hostname` y `locationid`.
- Los nombres exactos de los campos de `upload_info` (iCloudy lee `size`) y el código con el que pCloud responde a
  una sesión de subida que ya no conoce.
- Que `trash_list` acepta `timeformat=timestamp` como el resto de métodos.
