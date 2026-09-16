# OAuth de iCloudy: configuración del desarrollador

El usuario final solo pulsa **Continuar con Google** o **Continuar con Microsoft**, elige una cuenta y acepta los permisos del proveedor. No crea proyectos, introduce IDs ni copia códigos. Outlook/Hotmail son cuentas Microsoft: se accede a sus archivos de **OneDrive**, no al correo.

Esta configuración se hace una vez por el responsable de iCloudy, antes de distribuir el binario. Los IDs deben ser emitidos por Google y Microsoft; no se pueden generar localmente ni sustituir por valores de ejemplo. Publicar el repositorio en GitHub o subir una app a Apple no registra estos clientes automáticamente.

## 1. Google Drive

En [Google Cloud Console](https://console.cloud.google.com/):

1. Crea o selecciona el proyecto **iCloudy** de tu organización.
2. En **APIs & Services → Library**, habilita **Google Drive API**.
3. En **Google Auth Platform → Branding**, configura el nombre iCloudy, correo de soporte y contacto del desarrollador. Para distribución pública, añade web, política de privacidad y dominios verificados reales.
4. En **Audience**, elige **External** para admitir cuentas ajenas a tu organización. Mientras estés en Testing, añade las cuentas que usarás en la prueba de concepto a **Test users**.
5. En **Data Access**, declara `openid`, `email`, `profile` y `https://www.googleapis.com/auth/drive`. La aplicación navega por todo Mi unidad y sube a sus carpetas: `drive.file` por sí solo no permite ese alcance.
6. En **Clients → Create client**, selecciona **Desktop app** y descarga su JSON. No elijas Web application ni crees una cuenta de servicio.
7. Importa ese archivo desde la raíz del repositorio:

```sh
swift scripts/configure-oauth.swift --google /ruta/al/cliente-desktop.json
```

El flujo Desktop admite la redirección loopback `http://127.0.0.1:53682/callback`, que no sale del Mac. No tienes que alojar esa dirección en un servidor. Google no valida el puerto de una redirección loopback, así que si el 53682 está ocupado por otra instancia o por otra app, iCloudy escucha en un puerto efímero y envía ese `redirect_uri`. La app abre el navegador, verifica `state` y usa PKCE S256 para canjear el código. [Documentación de Google](https://developers.google.com/identity/protocols/oauth2/native-app).

### Abrir el acceso al público

Testing sirve para la PoC; no es una configuración de distribución. El scope `drive` está restringido y exige el proceso de verificación aplicable de Google para el acceso público. Prepara dominio y política de privacidad, justificación de permisos y demostración del flujo. Cambiar Audience a producción no sustituye esa verificación. Si los datos restringidos pasan por servidores propios o de terceros, puede ser necesaria una evaluación de seguridad; la arquitectura actual los procesa directamente en el Mac, pero Google determina los requisitos concretos. [Verificación de scopes restringidos](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification).

## 2. Microsoft: OneDrive, Outlook y Hotmail

En [Microsoft Entra admin center](https://entra.microsoft.com/):

1. Abre **Identity → Applications → App registrations → New registration** en el tenant del desarrollador.
2. Nombre: **iCloudy**.
3. Supported account types: **Accounts in any organizational directory and personal Microsoft accounts**. La audiencia del manifiesto es `AzureADandPersonalMicrosoftAccount`. Esto admite Outlook/Hotmail y Microsoft 365; no uses una app single-tenant.
4. Configura un redirect de **Mobile and desktop applications / cliente público**: `http://127.0.0.1:53682/callback`. No lo registres como Web o SPA. Microsoft exige que el puerto coincida con el registrado, por eso con esta cuenta iCloudy no recurre a un puerto alternativo: si el 53682 está ocupado, pide cerrar la otra instancia.
5. La interfaz del portal puede rechazar una URI HTTP con IP loopback. En ese caso añade la URI a `publicClient.redirectUris` en el manifiesto de Microsoft Graph; en una vista de manifiesto legado aparece como `replyUrlsWithType` con `type: InstalledClient`. Conserva los redirects existentes. El nombre del campo depende de la versión del manifiesto del portal. [Restricciones de redirects](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).
6. En **API permissions → Microsoft Graph → Delegated permissions**, añade **User.Read** y **Files.ReadWrite**. La app solicita además `openid profile email offline_access`. No se necesitan permisos de correo ni permisos Application.
7. Copia el **Application (client) ID**, no el Directory (tenant) ID. No crees un client secret para este cliente de escritorio.

```sh
swift scripts/configure-oauth.swift --microsoft EL_APPLICATION_CLIENT_ID
```

El endpoint `/common` del código acepta cuentas personales y empresariales según la audiencia registrada. Para reducir advertencias y facilitar la adopción empresarial, configura Branding, dominio del publicador y, si reúnes sus requisitos, **Publisher verification**. Las políticas corporativas pueden requerir consentimiento del administrador incluso con la app verificada; no se puede prometer acceso a todas las organizaciones. [Tipos de cuenta](https://learn.microsoft.com/en-us/entra/architecture/establish-applications), [verificación del publicador](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview).

## 3. Dropbox

En [Dropbox App Console](https://www.dropbox.com/developers/apps):

1. **Create app** → **Scoped access** → **Full Dropbox** (o **App folder** si prefieres limitar iCloudy a su propia carpeta).
2. En **Permissions**, marca `account_info.read`, `files.metadata.read`, `files.content.read`, `files.content.write`, `sharing.read` y `sharing.write`. Guarda antes de salir de esa pestaña.
3. En **Settings → OAuth 2 → Redirect URIs**, añade `http://127.0.0.1:53682/callback`.
4. Copia la **App key**. No hace falta el App secret: iCloudy usa PKCE y pide `token_access_type=offline` para obtener un refresh token.

```sh
swift scripts/configure-oauth.swift --dropbox LA_APP_KEY
```

## 4. Box

En [Box Developer Console](https://app.box.com/developers/console):

1. **Create Platform App** → **Custom App** → método de autenticación **User Authentication (OAuth 2.0)**.
2. En **Configuration → OAuth 2.0 Redirect URIs**, añade `http://127.0.0.1:53682/callback`.
3. En **Application Scopes**, deja al menos lectura y escritura de todos los archivos y carpetas. iCloudy no envía un parámetro `scope`: usa los permisos configurados aquí.
4. Copia **Client ID** y **Client Secret**. Box exige el secreto al canjear el código incluso con PKCE; es metadato de un cliente instalado, extraíble del binario, igual que el de Google.
5. Si la cuenta es de empresa, un administrador debe autorizar la aplicación en **Admin Console → Apps → Custom Apps Manager**.

```sh
swift scripts/configure-oauth.swift --box CLIENT_ID:CLIENT_SECRET
```

## 5. WebDAV, Nextcloud y NAS

No hay nada que registrar. Cada usuario escribe en iCloudy la dirección de su servidor, su usuario y su contraseña, que se guardan en el Llavero de este Mac y solo viajan a ese servidor. La dirección es la ruta WebDAV completa; en Nextcloud y ownCloud es `https://servidor/remote.php/dav/files/USUARIO`. Con verificación en dos pasos hay que crear una contraseña de aplicación.

Limitaciones del protocolo, reflejadas en la interfaz: no hay búsqueda, ni enlaces públicos, ni papelera. Eliminar es definitivo y el diálogo de confirmación lo dice. Las subidas son un `PUT` completo, sin reanudación, y el servidor no informa de ninguna suma de verificación. Un servidor `http://` sin cifrar requiere además permitir esa conexión en las políticas de seguridad de transporte de macOS.

## 6. Compilar una app sin configuración para el usuario

Los comandos anteriores guardan `Configuration/OAuth.local.plist`, ignorado por Git. El script conserva el proveedor ya configurado al importar el otro.

```sh
swift test
bash scripts/build-app.sh --require-oauth
open dist/iCloudy.app
```

`--require-oauth` exige clientes válidos de Google y Microsoft; Dropbox y Box se informan como pendientes si faltan, y WebDAV nunca los necesita. No verifica que las aplicaciones existan ni que estén aprobadas: eso se comprueba mediante el login real en cada proveedor. Sin ese argumento se permite compilar para desarrollo de interfaz; los botones explican que el servicio aún no está habilitado, sin pedir acciones técnicas al usuario.

El archivo se copia a `Contents/Resources/OAuth.plist` antes de firmar. Se puede suministrar una ruta alternativa a través de `ICLOUDY_OAUTH_CONFIG` para CI. No edites un paquete ya firmado: vuelve a compilar. El ejecutable suelto de `swift run` no lleva ese recurso; usa el paquete `.app` para probar OAuth.

## GitHub y credenciales

- Los **client IDs son identificadores públicos** y es normal que se incluyan en la app. Puedes decidir publicar una configuración oficial con esos IDs o inyectarla en el proceso de release.
- El campo `client_secret` del JSON **Google Desktop** es metadato de un cliente instalado, extraíble del binario; no lo trates como una credencial confidencial de servidor. El código usa PKCE. Nunca importes un cliente Web ni credenciales de una cuenta de servicio.
- No publiques tokens de usuarios, JSON de cuentas de servicio, secretos de servidor Microsoft, certificados de firma, perfiles de aprovisionamiento ni exportaciones del Llavero.
- Los forks que distribuyan su propia aplicación deben registrar sus propios clientes y políticas de privacidad. Los usuarios del binario oficial usan el registro de iCloudy.
- El repositorio ignora la configuración local, certificados y perfiles. No contiene tokens ni IDs ficticios habilitados.

## Firma local para desarrollo

Los elementos del Llavero quedan ligados a la identidad que firmó la app. Una firma ad hoc (`-`) cambia en cada compilación, así que tras cada `build-app.sh` macOS pedía permiso para las cuentas guardadas o directamente negaba el acceso. El script ahora busca una identidad de firma de código estable en el Llavero y solo recurre a ad hoc, con un aviso, si no encuentra ninguna.

Si no tienes cuenta de desarrollador, crea un certificado local una sola vez:

1. Abre **Acceso a Llaveros → Asistente para Certificados → Crear un certificado…**
2. Nombre `iCloudy Development`, tipo de identidad **Raíz autofirmada**, tipo de certificado **Firma de código**.
3. Compila con `bash scripts/build-app.sh`; el script lo detecta por el nombre. También puedes forzar otra identidad con `ICLOUDY_SIGNING_IDENTITY="Nombre exacto"` o volver a ad hoc con `ICLOUDY_SIGNING_IDENTITY=-`.

Los certificados autofirmados no admiten sello de tiempo de Apple, por eso el script firma con `--timestamp=none`. Sirven para desarrollo; la distribución sigue requiriendo Developer ID o Mac App Store.

## Mac App Store

Se incluye `Resources/iCloudy.entitlements` y el script lo usa al firmar: **App Sandbox**, red de salida, red de entrada para el callback exclusivo de loopback y acceso de lectura/escritura a archivos elegidos por el usuario. Los tests con respuestas simuladas no certifican el funcionamiento real en el sandbox. [App Sandbox de Apple](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).

La firma ad hoc del script es para desarrollo. El `Info.plist` declara categoría, copyright, icono y la exención de cifrado; el bundle ID `dev.icloudy.desktop` es provisional y se sustituye al compilar con `ICLOUDY_BUNDLE_ID=com.tuempresa.icloudy bash scripts/build-app.sh`. El icono se genera con `swift scripts/make-icon.swift` a partir de un símbolo del sistema y puede reemplazarse por un `Resources/AppIcon.icns` propio. Aún hay que elegir el bundle ID definitivo, configurar tu Apple Developer Team, firma y aprovisionamiento de Mac App Store, preparar el archivo de distribución y completar App Store Connect. Una firma Developer ID con notarización corresponde a distribución fuera de la Store; no sustituye el proceso de Mac App Store. El script permite `ICLOUDY_SIGNING_IDENTITY`, pero no crea certificados ni perfiles.

Esta app conecta cuentas externas para acceder a sus contenidos y no crea una cuenta propia de iCloudy. La regla 4.8 contempla una excepción para clientes de servicios de terceros; esa es la justificación que presentaríamos a revisión, no una garantía de aceptación. También se requieren política de privacidad, declaración de tratamiento de datos e instrucciones de prueba para App Review. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## Prueba de aceptación con cuentas reales

1. Compila con ambos clientes y abre el `.app`.
2. Pulsa Google: selector de cuenta → consentimiento → regreso a iCloudy → listado de Drive.
3. Añade otra cuenta Google y verifica que se mantienen separadas.
4. Repite con una cuenta Outlook/Hotmail y, si procede, Microsoft 365.
5. Reinicia la app: las cuentas deben seguir presentes y los tokens renovarse cuando caduquen.
6. Prueba cancelar el consentimiento y volver a conectar.
7. Selecciona una carpeta local con el diálogo del sistema y prueba subida y descarga bajo el sandbox.

Pendientes hasta contar con registros reales: consentimiento end-to-end, permisos del tenant, renovación de tokens real, acceso al Llavero y transferencias en una distribución firmada/aprovisionada. El Mac debe estar desbloqueado para la prueba interactiva.
