# Telegram

Telegram no vende almacenamiento: lo regala. Una cuenta cualquiera puede subir archivos sin límite de espacio, con
un tope de 2 GB por archivo, o 4 GB con Premium. De ahí nació una familia de proyectos —teldrive, teledrive,
TGDrive— que usan un canal privado como disco duro y una base de datos aparte para recordar qué archivo es qué.

iCloudy ofrece dos caminos hacia eso. El primero no necesita código de iCloudy y ya funciona; el segundo es un
proveedor nativo, sin servidor ni dependencias, con los límites que eso impone.

> [!WARNING]
> Los dos caminos usan Telegram para algo que Telegram no anuncia como producto. Sus condiciones permiten cerrar
> cuentas y borrar canales por acumulación abusiva, y ninguno de los dos proyectos lo esconde: el aviso de teldrive
> es literalmente «se te baneará al instante si abusas de la API de Telegram». No metas ahí lo único que tengas de
> algo.

<br>

## Camino 1 — teldrive por WebDAV, con lo que iCloudy ya tiene

[teldrive](https://github.com/tgdrive/teldrive) habla **MTProto con una sesión de usuario real**, que es lo que le
permite subir archivos de 2 GB de una pieza y leer el historial del canal. Guarda el árbol de carpetas en
PostgreSQL y reparte la carga entre varios bots. Nada de eso cabe dentro de iCloudy —ni la criptografía de MTProto
ni una base de datos—, pero sí cabe **al otro lado de un WebDAV**.

El puente son tres piezas, todas suyas, ninguna de iCloudy:

1. **teldrive**, apuntando a tu canal, con su sesión iniciada.
2. **rclone** con el backend `teldrive` (lo publica el propio proyecto), configurado como remoto.
3. `rclone serve webdav`, que expone ese remoto con usuario y contraseña.

```bash
# En la máquina donde corre teldrive. El usuario y la contraseña son tuyos: invéntalos aquí.
rclone serve webdav teldrive: --addr 127.0.0.1:8080 --user ana --pass "una-contraseña-larga"
```

Y en iCloudy: **Añade tu nube → Conectar WebDAV**, con `http://127.0.0.1:8080` y esas credenciales.

A partir de ahí es una cuenta WebDAV normal, con lo que eso trae y lo que no: navegar, subir, bajar, renombrar,
mover, copiar y transferir de nube a nube, todo sí; búsqueda, enlaces públicos y papelera, no, porque WebDAV a secas
no los tiene.

**Lo que hay que saber antes de montarlo:**

- **Si sale del `localhost`, que sea con TLS.** WebDAV se autentica con Basic, es decir, usuario y contraseña en
  cada petición, protegidos solo por la capa de transporte. Sobre `http://` en una red que no sea la tuya, eso es
  la contraseña en claro. `rclone serve webdav` acepta `--cert` y `--key`; úsalos, o deja el servicio escuchando
  únicamente en `127.0.0.1`.
- **El propio rclone desaconseja `serve webdav`** para uso intensivo, por fugas de memoria conocidas; para un
  explorador de archivos que lista y transfiere a ratos va bien, para reproducir vídeo en bucle no.
- **iCloudy no verifica nada de esta cadena.** Los hashes que informa WebDAV son los que devuelva rclone, y el
  puente entero es software de terceros. La etiqueta de experimental de este documento se queda corta aquí: esto
  no es un proveedor de iCloudy, es un servidor tuyo que iCloudy sabe leer.

Es el camino recomendado **si quieres los 2 GB por archivo** y no te importa mantener un servicio encendido.

<br>

## Camino 2 — el proveedor nativo, con el Bot API

Es el que trae iCloudy dentro, marcado **🧪 Experimental** como Mega y O2. No necesita servidor, ni base de datos,
ni dependencias: el Bot API es HTTPS y JSON, que es lo que la app ya sabe hablar.

### Cómo se conecta

1. En Telegram, habla con **@BotFather** y crea un bot. Te da un token con la forma `123456789:AA…`.
2. Crea un **canal privado** y añade el bot como **administrador con permiso para publicar**.
3. En iCloudy: **Añade tu nube → Conectar Telegram**. Pega el identificador del canal y el token.

El identificador se acepta como quieras copiarlo: `-1001234567890`, `@nombre` si el canal es público, o el enlace
que la propia app de Telegram ofrece (`https://t.me/c/1234567890/45`), del que se saca el número.

Antes de guardar nada, iCloudy comprueba las tres cosas que si fallan solo se notan después: que el token es
válido (`getMe`), que el canal existe **para ese bot** (`getChat`), y que el bot es administrador y puede publicar
(`getChatMember`). Un bot que solo está añadido al canal no ve nada y no escribe nada, y sin esa comprobación la
cuenta quedaría conectada y rechazando cada subida sin decir por qué.

El token se guarda en el **Llavero**, con el mismo acceso que el resto de credenciales. El identificador del canal
no es un secreto y vive junto a la cuenta. Como el Bot API lleva el token en la ruta de cada dirección
(`/bot<token>/…`), el registro de diagnóstico trata `api.telegram.org` igual que un enlace temporal: no guarda nada
de la ruta, ni siquiera en el nivel detallado, y los mensajes de error de Telegram se limpian del token antes de
mostrarse.

### Qué hay en el canal

Dos clases de mensaje, y nada más:

- **Los trozos.** Cada archivo se corta en partes de **19 MiB** y cada parte es un `sendDocument`. Nunca
  `sendVideo` ni `sendPhoto`: esos recodifican el contenido. Un archivo que cabe en una parte se sube con su propio
  nombre; si son varias, van numeradas (`informe.pdf.001`, `.002`…), para que un rescate a mano desde la app de
  Telegram sea posible.
- **El índice**, un `icloudy-index.json` **fijado** en el canal. Dentro está el árbol entero: carpetas, nombres,
  tamaños, fechas, el SHA-256 de cada archivo y la lista de `file_id` de sus trozos.

El índice está fijado porque **el Bot API no puede leer el historial de un canal**. Un bot ve los mensajes que
llegan mientras escucha y ninguno más, y no existe ningún método para pedir un mensaje por su identificador. El
mensaje fijado es lo único que se puede encontrar sin saber de antemano dónde está, y por eso es el arranque en
frío: otro Mac conecta el mismo canal, lee el mensaje fijado y tiene el árbol completo.

### Por qué 19 MiB

Porque **un bot descarga como mucho 20 MB por `getFile`**, suba lo que suba. Ese es el techo real, no el de subida,
que son 50 MB. Una parte por encima de 20 MB se guardaría y no se podría volver a leer nunca. Los 19 MiB dejan
sitio para el sobre `multipart` y hacen que todas las partes menos la última midan exactamente lo mismo, que es lo
que permite reanudar una subida sin releer lo ya enviado.

### Velocidad

Telegram limita a un bot a **veinte mensajes por minuto en el mismo chat**. iCloudy espera tres segundos entre
partes para no acercarse a ese límite, lo que pone el techo en unos **6 MB/s** en el mejor caso. Si aun así llega
un `429`, se respeta el `retry_after` que manda Telegram en la respuesta.

Por lo mismo, y porque cada cambio reescribe el único índice fijado, la cuenta hace **un trabajo a la vez**, como
FTP, SFTP, Mega y O2: dos subidas en paralelo solo competirían por los mismos veinte mensajes y por el índice.

Para fotos y documentos va sobrado. Para una biblioteca de vídeo, no: para eso está el camino 1.

### Lo que sale gratis, y lo que no hay

Como el árbol es un índice propio, **renombrar, mover, copiar y buscar son cambios locales**. Se escribe el índice
y ya está: copiar un archivo de cuatro gigas duplica una lista de identificadores y no envía un solo byte. Buscar
no cuesta ni una petición.

**La verificación de integridad es de verdad, y en los dos sentidos.** Telegram no informa de ninguna suma, así que
iCloudy calcula el SHA-256 del archivo entero al subirlo y lo anota en el índice; al descargar, compara. Si no
coincide, la descarga falla y no deja el archivo. Es el único proveedor de la app donde la comprobación de bajada
es tan real como la de subida. La suma no se anuncia en el listado como las de los demás proveedores, porque no es
de Telegram: la comprueba el propio proveedor al terminar cada descarga.

**No hay cuota**: Telegram no publica ninguna para lo que cabe en un canal, y la app no se inventa un porcentaje.
**No hay enlaces públicos**: un canal privado no tiene dirección pública, y hacerlo público publicaría todo lo que
hay dentro.

### La papelera no borra nada

Enviar algo a la papelera **marca la entrada en el índice y deja de listarla. Los mensajes se quedan en el canal.**
Desde la app de Telegram siguen viéndose y descargándose. iCloudy no llama a `deleteMessage` en ningún momento, y
hay una prueba que falla si algún día lo hiciera.

Lo mismo al reemplazar un archivo: la versión anterior va a la papelera, no a la basura.

### Dos Macs sobre el mismo canal

Antes de escribir el índice, iCloudy comprueba que el mensaje fijado sigue siendo el que leyó, comparando el
`file_unique_id`. Si otro equipo ha escrito, **se niega a sobrescribir** y lo dice: hay que pulsar «Actualizar» y
repetir. No es un bloqueo, es un detector de colisiones; sin él, dos Macs se irían borrando los cambios el uno al
otro sin que ninguno se enterase.

### Los peros, sin maquillar

- **El bot es la llave.** Un `file_id` pertenece al bot que subió el archivo, y no hay forma de pedir un mensaje
  por su identificador. Si borras el bot en BotFather, los mensajes siguen en el canal y se ven desde Telegram,
  pero iCloudy ya no puede descargarlos. Guarda el token en algún sitio más.
- **Si alguien fija otro mensaje en el canal**, iCloudy recuerda cuál era el índice y lo vuelve a fijar solo. Si no
  lo recuerda —un Mac nuevo, por ejemplo— se niega a seguir en lugar de empezar con un árbol vacío, que es el único
  fallo aquí que se llevaría por delante una cuenta entera.
- **Una subida cancelada deja sus trozos en el canal**, invisibles para iCloudy. No se borran, porque borrar es
  justo lo que este proveedor no hace; se ven desde la app de Telegram y se pueden quitar allí.
- **El índice tiene que caber bajo el mismo techo de 19 MB.** Son decenas de miles de archivos, y si se llega ahí
  la app lo dice antes de escribir en lugar de romper el índice.
- **El SHA-256 se calcula leyendo el archivo otra vez** desde el disco, en una pasada aparte. Cuesta una lectura
  local y nada de red, y es lo que permite verificar una subida reanudada, cuyos primeros trozos salieron de este
  Mac en otra sesión.
- **Las condiciones de Telegram.** Es lo primero de este documento y también lo último.
