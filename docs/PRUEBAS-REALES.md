# Pruebas contra cuentas reales

Las pruebas de iCloudy contestan desde respuestas simuladas. Eso demuestra que la app envía lo que quiere enviar y
entiende lo que espera recibir; no demuestra que el proveedor esté de acuerdo. `LiveAccountTests` es la misma
batería para cualquier nube, contra una cuenta de verdad, y se salta sola mientras no se le diga con cuáles.

## Qué hace

Por cada cuenta configurada, dentro de una carpeta nueva llamada `iCloudy prueba <fecha y hora>`:

1. Lista la raíz, crea la carpeta y comprueba que aparece.
2. Sube un archivo pequeño y uno de varios bloques (6 MB por omisión), y comprueba la verificación donde hay suma.
3. Los descarga por el mismo camino que la app y compara los bytes.
4. **Reanuda una descarga**: deja en disco el primer tercio del archivo grande, como lo dejaría la cola tras un
   corte, y pide solo el resto. Aquí es donde se vería un proveedor que trate mal `Range`.
5. Renombra, crea una subcarpeta, copia y mueve, donde el proveedor lo admite.
6. Pregunta al **registro de cambios** (Drive, OneDrive, Dropbox, Box) desde una posición tomada antes de subir
   nada, y espera hasta un minuto a que diga algo de lo que se acaba de hacer.
7. Consulta el espacio, lanza una búsqueda y pide las migas de una carpeta.
8. Envía un archivo a la papelera y, al final, la carpeta entera. Donde el proveedor deja purgar una carpeta, la
   saca también de la papelera.

Nada se toca fuera de esa carpeta. Aun así, **usa cuentas hechas para probar**: una batería que falla a medias deja
su carpeta en la papelera, y una cuenta con cuota apurada puede quedarse sin sitio.

## Configurarla

Las cuentas se describen en un archivo JSON, fuera del repositorio o con uno de los nombres que `.gitignore` ya
aparta (`live-accounts.json`). [`Configuration/live-accounts.example.json`](../Configuration/live-accounts.example.json)
tiene una entrada de cada tipo.

```bash
ICLOUDY_LIVE_ACCOUNTS=~/live-accounts.json swift test --filter LiveAccountTests
```

| Nube | Campos |
|---|---|
| `google`, `microsoft`, `dropbox`, `box` | `clientID`, `clientSecret` (Google y Box) y `refreshToken` |
| `pcloud` | `accessToken` y `apiHost` (`api.pcloud.com` o `eapi.pcloud.com`) |
| `webdav` | `url`, `user`, `password` y, para Nextcloud u ownCloud, `flavor: "nextcloud"` |
| `sftp`, `ftp` | `url`, con las credenciales dentro o en `user` y `password` |
| `mega` | `user` y `password` |
| `s3` | `accessKey`, `secretKey`, `bucket`, `region` y, si no es AWS, `url` con el punto de acceso |

Opcionales en cualquiera: `folder` (el id de la carpeta bajo la que trabajar), `driveID` (una unidad compartida de
Google o una biblioteca de SharePoint) y `largeMB` (Box solo abre una sesión por bloques a partir de 20).

### De dónde sale el token de refresco

Del propio inicio de sesión de la app, con el cliente de `Configuration/OAuth.local.plist`:

```bash
ICLOUDY_LIVE_SIGNIN=google ICLOUDY_LIVE_ACCOUNTS=~/live-accounts.json swift test --filter LiveAccountTests/testSignInAddsAnAccountToTheFile
```

Abre el navegador, espera a que termines y añade la cuenta al archivo, que queda con permisos `0600`. El token no
se imprime. Vale para `google`, `microsoft`, `dropbox`, `box` y `pcloud`.

Box y Microsoft entregan un token de refresco nuevo cada vez que se usa el anterior. Cuando las cuentas vienen de un
archivo, la batería escribe en él el token nuevo, así que la siguiente ejecución sigue funcionando.

## En GitHub Actions

El flujo de CI pasa el secreto `ICLOUDY_LIVE_ACCOUNTS_JSON` (el contenido del archivo) a las pruebas. Sin el
secreto, como en un fork, la batería se salta. Ahí no hay archivo donde guardar un token rotado: sirve para los
proveedores cuyo token de refresco no caduca al usarse (Google, Dropbox, pCloud y los de usuario y contraseña); Box
necesita que alguien renueve el secreto.

## Lo que no cubre

- **O2 Cloud**: su acceso pasa por la web del operador y no hay credencial que poner en un archivo.
- **Volúmenes**: no hay cuenta; los cubren sus propias pruebas con carpetas temporales.
- Versiones, enlaces públicos y compartir con personas: dependen del plan de cada cuenta y cambian lo que otros
  pueden ver. Siguen probándose con respuestas simuladas.
- La extensión del Finder, que necesita un identificador de equipo de Apple para cargarse.

El propio recorrido se ejecuta siempre contra la demo local (`testTheWalkItselfHoldsAgainstTheDemoStore`), para que
no se rompa sin que nadie lo note hasta el día que se apunte a una cuenta.
