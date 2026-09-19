# Registro de cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/). Mientras el número mayor sea `0`, la app se considera
en desarrollo: puede haber cambios que rompan cosas entre versiones menores, y así se dirá aquí.

## 0.5.0 — 19 de septiembre de 2026

La primera versión numerada. Recoge una auditoría completa de la app y la tanda de correcciones que salió de ella,
proveedor por proveedor. 303 pruebas, todas en verde, sin red: las respuestas de los servidores están simuladas.

### O2 Cloud

- La subida y la descarga usan la misma política de sesión que el resto. Antes montaban sus propias peticiones: una
  clave rotada a mitad de una subida perdía el archivo, un `401` no marcaba la cuenta como caducada y las cookies
  renovadas se tiraban.
- La sesión ya no viaja a cualquier servidor. La dirección de descarga puede apuntar a otra flota, y hasta ahora se
  le entregaban las cookies de la cuenta.
- Un toque de mantenimiento que no obtiene respuesta ya no cuenta como hecho, y recuperar la red dispara uno
  inmediato. Antes, un fallo justo al despertar compraba otro cuarto de hora de silencio.
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
