# Cifrado

iCloudy puede guardar archivos cifrados en cualquier nube conectada, dentro de una **bóveda**: una carpeta normal
cuyo contenido solo se entiende con una contraseña. El cifrado ocurre en este Mac, antes de que nada salga hacia la
nube, y el descifrado también. El proveedor guarda bytes que no puede leer.

Las bóvedas usan el **formato 8 de Cryptomator**, el mismo que escriben sus aplicaciones de escritorio, de iOS y de
Android desde la versión 1.6. Una bóveda creada en iCloudy se abre con Cryptomator en otro dispositivo, y una
creada con Cryptomator se abre en iCloudy.

## Cómo se usa

- **Crear.** En el menú de una carpeta, «Crear bóveda cifrada…». Se pide un nombre y una contraseña de al menos ocho
  caracteres, dos veces, y una confirmación de que perderla es perder los datos. Se crea una carpeta nueva dentro
  de la elegida.
- **Abrir.** En el menú de la carpeta de la bóveda, «Abrir bóveda…». Al entrar en una carpeta que es una bóveda
  bloqueada aparece además una franja con «Desbloquear…».
- **Usar.** Una bóveda abierta aparece en la barra lateral, bajo «Bóvedas abiertas», y se recorre como cualquier
  cuenta: subir, descargar, ver, renombrar, mover, crear carpetas y eliminar. Las transferencias pasan por la misma
  cola que las demás.
- **Bloquear.** Con el botón «Bloquear» de la franja verde o del menú de la bóveda en la barra lateral. Se bloquean
  también solas al salir de iCloudy, al desconectar la cuenta que las guarda y tras un rato sin uso, que se ajusta
  en Configuración › Cifrado (15 minutos por omisión). Una bóveda con transferencias en curso no se bloquea sola.

La contraseña no se guarda en ningún sitio salvo que se marque «Recordar la contraseña en el Llavero de este Mac».
Entonces va al Llavero con acceso solo desde este Mac y solo con el Mac desbloqueado, y se prueba antes de pedirla.
Si deja de abrir la bóveda, porque se cambió con Cryptomator, se olvida y se vuelve a pedir.

## Qué queda protegido

- **El contenido de los archivos.** Cada archivo lleva su propia clave aleatoria, cifrada con la clave maestra de
  la bóveda, y el contenido va en trozos de 32 KiB cifrados con AES-GCM. Cada trozo está atado a su posición y a su
  archivo: cambiar un byte, reordenar trozos o pasar un trozo de un archivo a otro se detecta al descargar, y la
  descarga se descarta entera en vez de dejar un archivo a medias.
- **Los nombres.** Archivos y carpetas se guardan con nombres cifrados con AES-SIV, atados a la carpeta en la que
  están: un archivo movido a otra carpeta sin volver a cifrar su nombre no se puede leer.
- **La jerarquía.** Las carpetas cifradas no se anidan como las de verdad: todas viven al mismo nivel bajo `d/`, con
  un nombre derivado de un identificador aleatorio. Desde fuera no se ve qué carpeta está dentro de cuál.

## Qué no queda protegido

Conviene saberlo antes de confiarle nada a una bóveda:

- **La forma de la estructura.** Quien vea la nube sabe cuántas carpetas y cuántos archivos hay en cada carpeta,
  aunque no sepa cuáles son ni cómo se llaman.
- **Los tamaños, aproximadamente.** Cada archivo cifrado ocupa lo mismo que el original más 68 bytes de cabecera y
  28 por cada trozo de 32 KiB. El tamaño real se deduce con bastante precisión.
- **Las fechas.** El proveedor sigue viendo cuándo se subió o se modificó cada archivo.
- **Un archivo recortado justo al final de un trozo.** Es un límite del formato, no de iCloudy: nada marca cuál es
  el último trozo, así que quitar trozos enteros del final no se distingue de un archivo más corto. Cualquier otro
  recorte falla al descifrar.
- **La longitud de los nombres**, a grandes rasgos: un nombre cifrado crece con el original, hasta que pasa de 220
  caracteres y se sustituye por un resumen de longitud fija.
- **Lo que hay en este Mac.** Lo que se descarga de una bóveda se guarda descifrado donde se elija. El historial de
  transferencias y la cola guardada mientras hay transferencias pendientes anotan los nombres de los archivos sin
  cifrar en la carpeta de datos de iCloudy, como con cualquier otra cuenta. La caché de listados y el índice de
  Spotlight, en cambio, no guardan nada de una bóveda, y los favoritos y las carpetas reflejadas no se ofrecen
  dentro de ella.

## Si se pierde la contraseña

**Se pierden los datos.** No hay recuperación, ni puerta trasera, ni copia de la clave en ningún servidor. La clave
maestra está cifrada con otra derivada de la contraseña mediante scrypt, que está hecho a propósito para que
probar contraseñas sea lento, y sin la contraseña correcta lo único que hay en la nube son bytes al azar.

Cryptomator permite generar una clave de recuperación desde su aplicación de escritorio. iCloudy no la genera; quien
la quiera puede abrir la bóveda una vez con Cryptomator y crearla allí.

## Compatibilidad

Lo que iCloudy lee y escribe, todo según la especificación publicada por Cryptomator:

- `masterkey.cryptomator`: scrypt con N = 32768, r = 8, p = 1 y sal de 8 bytes; las dos claves maestras envueltas con
  AES Key Wrap (RFC 3394); y el `versionMac`, un HMAC-SHA256 del campo de versión heredado, que en el formato 8 vale 999.
  La contraseña se normaliza en NFC antes de derivar la clave, como hace Cryptomator.
- `vault.cryptomator`: un JWT firmado con las dos claves maestras concatenadas. Se escribe con HS256, formato 8,
  `cipherCombo` SIV_GCM y umbral de acortamiento 220. Al abrir se aceptan HS256, HS384 y HS512.
- Directorios, nombres `.c9r`, nombres largos `.c9s` con `name.c9s`, `contents.c9r` y `dir.c9r`, y la copia de
  seguridad `dirid.c9r` de cada directorio.
- Contenido con cabecera de 68 bytes (nonce de 12, 40 cifrados —ocho bytes reservados a 0xFF y la clave del archivo—
  y la etiqueta de 16) y trozos de 32 KiB con AES-GCM, cuyo dato asociado es el número de trozo en 64 bits big-endian
  seguido del nonce de la cabecera.
- Se **abren** también las bóvedas de formato 8 con `SIV_CTRMAC`, las que creaba Cryptomator 1.6, y en ellas se
  escribe con ese mismo cifrado. Las nuevas se crean siempre con `SIV_GCM`.

No se abren: las bóvedas de formato 7 o anterior (Cryptomator las actualiza la primera vez que las abre), las que
gestiona Cryptomator Hub, cuya clave no sale de una contraseña, ni los enlaces simbólicos que Cryptomator puede
guardar dentro de una bóveda, que aparecen como carpetas que no se pueden abrir.

## Cómo está hecho

No hay dependencias nuevas. CryptoKit da AES-GCM, SHA y HMAC; CommonCrypto da el cifrado AES de un bloque y
PBKDF2. El resto está escrito aquí: scrypt (Salsa20/8, BlockMix y ROMix sobre PBKDF2-HMAC-SHA256), AES-CMAC, AES-SIV,
AES Key Wrap y el modo contador sobre el bloque entero de 128 bits, como lo hace Java.

La bóveda se presenta como un proveedor más que envuelve al de la nube donde vive. Cada operación se traduce:
listar es listar la carpeta cifrada y descifrar nombres; subir es cifrar a un archivo temporal, trozo a trozo, y
subir ese archivo; descargar es lo contrario. Ningún archivo se carga entero en memoria. Los tamaños que se ven son
los del archivo sin cifrar, calculados a partir del cifrado.

La comprobación de las descargas sigue funcionando por debajo: el archivo cifrado se compara con el tamaño y la suma
que da el proveedor, igual que cualquier otra descarga, y después cada trozo se autentica al descifrarlo. Si la nube
dice que un archivo cambió desde que se listó, se trata como un cambio y no como un daño. En las subidas, la suma
que comprueba el proveedor es la del archivo cifrado, que es justo lo que se envió.

Renombrar o mover vuelve a cifrar el nombre, porque depende de la carpeta. Un nombre que cruza el umbral de 220
caracteres cambia de forma: un archivo pasa a ser una carpeta `.c9s` con su `contents.c9r`, o al revés. Eliminar
una carpeta elimina también las carpetas cifradas de todo lo que tenía dentro, que viven en otro sitio bajo `d/` y
de otro modo quedarían ocupando espacio sin que nada las alcanzara.

## Qué está probado y qué no

Probado contra valores que no salen de iCloudy:

- scrypt, Salsa20/8, BlockMix, ROMix y PBKDF2 contra los vectores del RFC 7914; CMAC contra el RFC 4493; AES-SIV
  contra los dos ejemplos del RFC 5297; Key Wrap contra el RFC 3394.
- Contra los vectores de las pruebas que publica el propio Cryptomator (cryptolib-swift y cryptofs): desbloquear y
  volver a crear un `masterkey.cryptomator` byte a byte, rechazar una contraseña equivocada y un `versionMac`
  alterado, verificar la firma de un `vault.cryptomator`, las rutas cifradas del directorio raíz y de otro
  directorio, la cabecera de un archivo en GCM y en CTR-MAC, un trozo GCM y el cálculo de tamaños.
- Una bóveda escrita a mano en disco con las claves de esos vectores, que iCloudy encuentra en las rutas que calcula
  Cryptomator.
- De extremo a extremo, sobre un proveedor de prueba y sobre una carpeta real: crear, abrir, rechazar una contraseña
  equivocada, subir y bajar archivos de varios tamaños, nombres largos de archivos y de carpetas, renombrar y mover
  cruzando el umbral en los dos sentidos, reemplazar, eliminar carpetas con todo lo de dentro, detectar un trozo
  alterado y un archivo cambiado por debajo, comprobar que ningún nombre en claro llega a la nube, y bloquear a mano,
  por inactividad y al desconectar la cuenta.

Sin probar: no se ha podido abrir una bóveda creada por la aplicación de Cryptomator en un dispositivo real, ni
abrir con Cryptomator una creada por iCloudy. Lo que lo respalda son los vectores anteriores, que cubren cada capa
del formato. Las piezas que ningún vector publicado fija byte a byte son el relleno de Base64url en los nombres (se
conserva, como en los ejemplos de la documentación), el contenido de `name.c9s` y la forma exacta de `dirid.c9r`;
las tres siguen lo que dice la documentación y el código fuente de Cryptomator.

## Lo que no hace

- Las subidas a una bóveda no se reanudan a medias: cada intento vuelve a cifrar el archivo con nonces nuevos, y
  continuar una sesión anterior mezclaría bytes de dos cifrados distintos. Se repiten desde el principio.
- No se busca dentro de las bóvedas, no se crean enlaces públicos ni se comparte con personas: todo eso entregaría el
  archivo cifrado, que nadie podría abrir.
- No se copia dentro de una bóveda. Copiar en la nube duplicaría un nombre cifrado para otra carpeta.
- Mover o renombrar no es atómico. Si se corta a mitad, un elemento puede quedar con un nombre que no corresponde a
  su carpeta y dejar de verse hasta que se arregle con Cryptomator, que lo detecta en su comprobación de salud.
- No se cambia la contraseña ni se genera la clave de recuperación: para eso está la aplicación de Cryptomator.
