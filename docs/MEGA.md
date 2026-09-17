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
