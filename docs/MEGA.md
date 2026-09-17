# Mega

Mega es el único proveedor de iCloudy marcado como **experimental**, y conviene entender por qué antes de
confiarle nada importante.

## Por qué experimental

Mega no publica una API para terceros. No hay documentación, ni registro de aplicación, ni compromiso de
estabilidad. Lo que iCloudy habla es el mismo protocolo que usa el cliente web de Mega, deducido de su
comportamiento y de las implementaciones libres que existen desde hace años. Funciona, pero Mega puede
cambiarlo cualquier día sin anunciarlo, y entonces dejará de funcionar de golpe.

La interfaz lo dice en la tarjeta de conexión y en el formulario de inicio de sesión, con una etiqueta
«Experimental», para que una rotura repentina no parezca un fallo de iCloudy.

## Qué lo hace distinto de los demás

Mega cifra de extremo a extremo. El servidor no conoce los nombres de los archivos, ni la estructura de
carpetas, ni el contenido: todo llega cifrado y se descifra en este Mac con claves derivadas de la
contraseña. Eso tiene dos consecuencias buenas y una mala.

- **El árbol entero llega en una sola respuesta.** Buscar y construir las migas de pan no cuesta ninguna
  petición, porque los datos ya están aquí. Es el proveedor más rápido de iCloudy en ambas cosas.
- **Las descargas se verifican de verdad.** Cada archivo lleva dentro de su propia clave el resumen de su
  contenido. Si un byte no coincide, iCloudy borra la descarga y avisa en lugar de dejar un archivo corrupto.
- **Las subidas no se pueden verificar de forma independiente.** El único resumen que Mega guarda es el que
  calculó iCloudy al subir, así que compararlo consigo mismo no demostraría nada. El resumen de la
  transferencia las marca «sin verificar», que es lo honesto.

## La criptografía, en orden

1. **La contraseña nunca se envía.** Las cuentas creadas desde 2018 derivan la clave con PBKDF2-HMAC-SHA512,
   cien mil iteraciones sobre la sal que da el servidor. Los primeros 16 bytes son la clave; los últimos 16
   son la prueba que se envía. Las cuentas anteriores usan la derivación original, mucho más débil, con 65 536
   rondas de AES. Las dos están implementadas.
2. **La clave maestra** llega cifrada con la clave derivada, en AES-ECB.
3. **La clave privada RSA** de la cuenta llega cifrada con la clave maestra, en el formato de enteros de Mega:
   longitud en bits y luego los bytes. Los dos factores primos vienen en el orden contrario al habitual, lo
   que da igual para una exponenciación modular porque el producto es el mismo.
4. **El identificador de sesión** se obtiene descifrando con RSA un desafío que manda el servidor y quedándose
   con sus primeros 43 bytes. Eso demuestra que quien pregunta tiene la clave privada de la cuenta.
5. **Cada nodo** tiene su clave, cifrada con la maestra. Un archivo empaqueta tres cosas en 32 bytes: la clave
   AES, el contador y el resumen esperado del contenido. Los nombres viajan cifrados con prefijo `MEGA`, lo
   que permite distinguir una clave equivocada de un nombre raro.
6. **El contenido** va en AES-CTR, con el contador formado por el nonce y el número de bloque, de modo que
   cada trozo se descifra por su cuenta. El resumen se calcula sobre los trozos que define Mega: 128 KiB, y
   creciendo hasta 1 MiB.

La aritmética de números grandes es propia, porque hacía falta una sola exponenciación modular y no merecía
una dependencia. Usa multiplicación de Montgomery en vez de división, que es la parte fácil de equivocar.

## La prueba de trabajo

Desde 2025 Mega protege los puntos finales de cuenta con una prueba de trabajo. En vez de contestar, devuelve un
402 con el cuerpo vacío y una cabecera `X-Hashcash` que dice versión, dificultad, cuándo se emitió y un token de 48
bytes. La petición no se acepta hasta que el cliente encuentra un prefijo de cuatro bytes tal que el SHA-256 de ese
prefijo seguido del token repetido 262 144 veces empieza por un número menor que el umbral que marca la dificultad.

Con la dificultad que usa hoy al iniciar sesión hacen falta unos 256 intentos, y cada intento son 12,5 MB de
SHA-256. Ronda el segundo en este Mac, fuera del hilo principal. El algoritmo está comprobado contra los propios
servidores de Mega: resolver el desafío convierte su 402 en un 200.

Esto fue durante un tiempo la causa de que el proveedor no funcionase en absoluto. El cuerpo venía vacío y el
mensaje que veía el usuario era «Mega devolvió una respuesta que no se entiende», que no decía nada útil. Ahora el
mensaje incluye el código HTTP, por si vuelve a aparecer algo así.

## Números sueltos como respuesta

Mega contesta a bastantes órdenes con un número y nada más: un `0` después de renombrar o mover, un código negativo
cuando algo falla, y un `-3` que significa «espera, todavía no está listo». Un número suelto es un fragmento de
JSON, y el analizador estricto de Foundation lo rechaza por no ser ni objeto ni lista.

Eso hacía que el árbol de la cuenta no cargase nunca, porque justo después de iniciar sesión Mega suele contestar
`-3` al pedirlo, y que renombrar y mover fallasen aunque hubieran funcionado. Se permiten fragmentos, y hay una
prueba que falla si alguien quita esa opción.

## El árbol se actualiza en memoria, no recargando

Mega manda la cuenta entera en una sola respuesta. Eso es lo que hace que buscar salga gratis, pero también
significa que volver a pedirla después de cada cambio es caro: en una cuenta con muchos archivos, renombrar algo
tardaba lo que tarda descargar y descifrar todo otra vez.

Ahora cada cambio se aplica sobre lo que ya está cargado. Renombrar cambia un nombre, mover cambia un padre, borrar
mueve a la papelera, y crear una carpeta o subir un archivo insertan el nodo que devuelve la propia respuesta, que
trae todo lo necesario. Solo lo que no se puede aplicar, porque la respuesta no trae lo que debía, fuerza una
recarga. Hay pruebas que cuentan las peticiones de árbol y fallan si vuelve a haber más de una.

Las subidas también se reintentan trozo a trozo. Los servidores de almacenamiento contestan `-3`, «espera», igual
que la API, y abandonar por eso perdía la subida entera por un momento de retraso.

## Cuando no se llega a Mega

Un error de red no es Mega diciendo que no. Cuando la petición ni siquiera llegaba, el mensaje que veía el usuario
era «Se ha agotado el tiempo de espera», que es la redacción del propio sistema: no nombra a Mega, no dice qué
estaba haciendo la app y no sugiere nada que probar. Borrar un archivo durante un mal rato de Mega se veía
exactamente igual que borrarlo con la cuenta bloqueada.

Lo que hace Mega cuando va mal, medido contra sus servidores de verdad, no es rechazar la petición: es **no decir
nada**. En una tanda de seis peticiones, cuatro contestaron en menos de dos segundos y dos se quedaron colgadas
hasta el tiempo límite, una sin llegar a conectar y otra conectando y sin enviar un solo byte después. Media hora
más tarde, veinticuatro de veinticuatro, ninguna por encima de 2,8 segundos. Esa es la forma del problema: la API
está viva, pero se traga una fracción de las peticiones durante un rato y luego se le pasa.

Conviene decir también qué **no** es, porque despista. Mega filtra el ICMP, así que un `ping` con el 100 % de
pérdida no significa nada, y un `traceroute` que muere en los últimos saltos tampoco. Con esas dos señales es fácil
concluir que el operador bloquea Mega cuando en realidad solo está teniendo un mal rato. Lo único que vale como
prueba es una petición completa:

```bash
curl -sS -m 40 -o /dev/null -w '%{http_code} %{time_total}s\n' \
  -X POST -H 'Content-Type: application/json' --data '[{"a":"us0","user":"nadie@example.com"}]' \
  'https://g.api.mega.co.nz/cs?id=1'
```

De ahí sale el resto. Una petición caída se repite hasta tres veces antes de darse por perdida, que con la tasa de
fallo observada deja la probabilidad de perder un borrado por debajo del dos por ciento. El número de secuencia no
cambia entre reintentos, que es lo que impide que Mega aplique el mismo cambio dos veces. Un 5xx o un 429 se esperan
igual que el `-3`, en vez de entregarle el fallo al usuario al primer intento.

Los tiempos salen de la misma medición. Una petición sin noticias espera 15 segundos, no el minuto del sistema:
sano, Mega contesta muy por debajo de tres, así que los otros cincuenta y tantos se gastaban esperando una respuesta
que no iba a llegar. Una orden completa no pasa de 75 segundos sumando esperas, pruebas de trabajo y reintentos, y
los cuatro intentos caben dentro de ese reloj, de modo que ninguno se queda sin usar. El límite solo se mira antes
de volver a esperar, así que una transferencia lenta pero sana nunca se corta por la mitad.

Y el mensaje, cuando aun así no hay manera, dice lo más probable primero: que es un mal momento de Mega y suele
arreglarse solo. Lo de que hay redes que bloquean mega.nz va después, que es el orden en que ocurren las dos cosas.

## Las transferencias van por otros servidores

Los archivos no se descargan ni se suben contra la API, sino contra una flota aparte cuya dirección da Mega en cada
transferencia. Esa dirección llega en HTTP sin cifrar salvo que se pida lo contrario, y macOS se niega a cargarla,
con razón: aunque el contenido ya viaje cifrado, la dirección, el tamaño y el momento no lo harían.

Se pide cifrada, con el mismo indicador que usan sus propios clientes, y además se eleva el esquema de cualquier
dirección que llegue en claro. No se ha tocado la política de seguridad de transporte de la app: relajarla habría
sido tapar el problema en vez de resolverlo, y para todas las conexiones, no solo para esta.

## Verificación en dos pasos

Mega pide la contraseña y el código en la misma petición, así que se escriben juntos: la contraseña, un
espacio y los seis dígitos. Si la cuenta no tiene segundo factor, no hay nada que añadir.

## Qué está probado y qué no

Probado contra valores de referencia externos (OpenSSL y la especificación de AES): AES en ECB, CBC y CTR, la
derivación de contraseña, el resumen del contenido y la exponenciación modular. Probado de extremo a extremo
contra un servidor de mentira que habla el mismo protocolo: el inicio de sesión completo con el desafío RSA,
el descifrado del árbol, el listado, la búsqueda, las migas, la cuota, los enlaces, la descarga con su
comprobación, una descarga alterada, la subida cifrada y el reintento cuando Mega contesta «espera».

Sin probar: el comportamiento real de los servidores de Mega, que es justo lo que ningún test puede fijar.
En concreto, no se ha podido comprobar contra una cuenta real el inicio de sesión con segundo factor, ni las
cuentas anteriores a 2018, ni los límites de transferencia de las cuentas gratuitas.

## Lo que no hace

No lista «Recientes» ni «Compartido conmigo». Un elemento compartido con la cuenta cuya clave no se puede
abrir aparece como «Elemento sin acceso» en lugar de con un nombre inventado. Copiar solo funciona con
archivos, no con carpetas: Mega adjunta el mismo contenido cifrado a un nodo nuevo sin mover bytes, y eso no
se puede hacer con un árbol entero en una sola petición.
