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

### Antes de empezar: hace falta un directorio

Desde junio de 2024 **toda aplicación nueva tiene que registrarse dentro de un directorio**. Una cuenta personal de
Microsoft, de las de Outlook o Hotmail, ya no puede registrar aplicaciones por su cuenta: el portal responde que
«la capacidad de crear aplicaciones fuera de un directorio está en desuso». Es un cambio permanente y de un solo
sentido. Las aplicaciones registradas así antes siguen funcionando, pero no se pueden mover a un directorio ni se
pueden crear nuevas.

Conseguir ese directorio tiene una sola vía duradera hoy, y conviene saberlo antes de perder la tarde:

| Vía | Sirve | Por qué |
|---|---|---|
| Crear un inquilino desde el portal de Entra | **No** | Microsoft lo reserva a clientes de pago. Con una cuenta gratuita el portal lo rechaza |
| Programa para desarrolladores de M365 | **No** | Exige una suscripción de Visual Studio Professional o Enterprise, o ser socio, o tener soporte Premier. Además pide una cuenta de facturación que, en sus palabras, no se puede saltar, y los inquilinos caducan |
| Cuenta gratuita de Azure | **Sí** | Crea un directorio propio donde eres administrador global. No cobra nada, pero pide una tarjeta no prepago para verificar identidad, con una retención temporal de un euro |
| Pruebas de M365, External ID, Power Apps | **No** | O piden tarjeta igual, o son inquilinos que se borran a los 30 días, o rechazan direcciones personales |

Si la tarjeta es un no rotundo, **hoy no hay forma soportada de registrar una aplicación de Microsoft**. Todo lo
gratuito sin tarjeta es un inquilino desechable de 30 días, que no es sitio para una aplicación que va a durar.

Una advertencia sobre el alta en Azure: crea un directorio nuevo solo si ese correo no es ya miembro, propietario o
invitado de algún inquilino. El seudoinquilino que Entra muestra a las cuentas personales no cuenta como tal, así
que una cuenta limpia de Outlook obtiene su directorio.

El directorio es solo la casa del registro. Para que la cuenta personal pueda iniciar sesión en iCloudy, lo que
importa es la audiencia del registro y el punto de acceso `/common`, no el inquilino donde viva.

### El registro

En [Microsoft Entra admin center](https://entra.microsoft.com/):

1. Abre **Entra ID → App registrations → New registration**. El portal ya no pasa por «Identity» ni «Applications».
2. Nombre: **iCloudy**.
3. Supported account types es un desplegable. Elige **Any Entra ID Tenant + Personal Microsoft accounts**, la opción que admite Outlook, Hotmail y Microsoft 365 a la vez. En el manifiesto es `AzureADandPersonalMicrosoftAccount`, y con esa audiencia `requestedAccessTokenVersion` tiene que ser `2`. Elígela bien a la primera: después no se puede cambiar desde la interfaz, solo editando el manifiesto.
4. En **Manage → Authentication → Add a platform** elige **Mobile and desktop applications**. No lo registres como Web ni como SPA.
5. **El portal rechazará `http://127.0.0.1:53682/callback` en el cuadro de texto.** No es un fallo tuyo: Microsoft documenta que ese campo no acepta el esquema `http` con la IP de loopback, y que hay que meterlo por el manifiesto. Ve a **Manage → Manifest** y añade la dirección conservando las que ya haya:
   - Manifiesto en formato Azure AD Graph, que es el que ven las apps registradas con una cuenta personal: `"replyUrlsWithType": [{"url": "http://127.0.0.1:53682/callback", "type": "InstalledClient"}]`.
   - Manifiesto en formato Microsoft Graph: `publicClient.redirectUris`.

   El cuadro de texto sí acepta `http://localhost:53682/callback`, pero iCloudy no la usa: su servidor de vuelta escucha solo en `127.0.0.1`, y `localhost` puede resolverse a `::1` y dejar al navegador sin nadie al otro lado. Google además recomienda la IP literal frente a `localhost` para clientes nativos. El puerto debe coincidir exactamente; la tolerancia de puerto que Microsoft concede es solo para `localhost`. [Restricciones de redirects](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).
6. En **API permissions → Microsoft Graph → Delegated permissions**, añade **User.Read** y **Files.ReadWrite**. La app solicita además `openid profile email offline_access`. **No añadas `Files.ReadWrite.All`**: no hace falta para la unidad del propio usuario y solo amplía el acceso a todo lo que esa persona alcance. Ninguno de los dos exige consentimiento de administrador en cuentas personales. No se necesitan permisos de correo ni permisos Application.
7. Copia el **Application (client) ID**, no el Directory (tenant) ID. No crees un client secret: un cliente público no puede tener secretos, y Microsoft lo dice así de claro.

```sh
swift scripts/configure-oauth.swift --microsoft EL_APPLICATION_CLIENT_ID
```

El endpoint `/common` del código acepta cuentas personales y empresariales según la audiencia registrada. Para reducir advertencias y facilitar la adopción empresarial, configura Branding, dominio del publicador y, si reúnes sus requisitos, **Publisher verification**. Las políticas corporativas pueden requerir consentimiento del administrador incluso con la app verificada; no se puede prometer acceso a todas las organizaciones. [Tipos de cuenta](https://learn.microsoft.com/en-us/entra/architecture/establish-applications), [verificación del publicador](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview).

## 3. Dropbox

En [Dropbox App Console](https://www.dropbox.com/developers/apps):

1. **Create app**, y elige el acceso con scopes. En **Content Access**, **Full Dropbox** (o **App folder** si prefieres limitar iCloudy a su propia carpeta).
2. En **Permissions**, marca `account_info.read`, `files.metadata.read`, `files.content.read`, `files.content.write`, `sharing.read` y `sharing.write`. Guarda antes de salir de esa pestaña.
3. En **Settings → OAuth 2 → Redirect URIs**, añade `http://127.0.0.1:53682/callback`.
4. Copia la **App key**. No hace falta el App secret: iCloudy usa PKCE y pide `token_access_type=offline` para obtener un refresh token.

Una aplicación en estado de desarrollo sirve de sobra para probar, pero tiene un reloj en marcha: admite hasta 500 cuentas enlazadas, y en cuanto llega a 50 quedan dos semanas para conseguir el estado de producción o dejan de poder enlazarse cuentas nuevas. Dropbox no revisa la solicitud antes de esas 50. Conviene saberlo antes de repartir el binario, no después. Y una vez en producción, la aplicación ya no se puede renombrar.

```sh
swift scripts/configure-oauth.swift --dropbox LA_APP_KEY
```

## 4. Box

En [Box Developer Console](https://app.box.com/developers/console):

1. **New App** → tipo **User** → **Create**. Box ha renombrado este flujo: ya no hay «Create Platform App» ni «Custom App». Una aplicación de autenticación de usuario no se puede convertir después en una de servidor.
2. En **Configuration → OAuth 2.0 Redirect URIs**, añade `http://127.0.0.1:53682/callback`.
3. En **Application Scopes**, deja al menos lectura y escritura de todos los archivos y carpetas. iCloudy no envía un parámetro `scope`: usa los permisos configurados aquí.
4. Copia **Client ID** y **Client Secret**. **Box es el único de los cuatro que no admite PKCE**: no documenta `code_challenge` en ninguna parte y exige el secreto al canjear el código. Así que con Box el secreto viaja dentro del binario, como en cualquier otro cliente de escritorio de Box. Es metadato de un cliente instalado, no una credencial de servidor, pero conviene no contarlo como si fuera un cliente público de verdad.
5. Las aplicaciones creadas por una cuenta gratuita de desarrollador se autorizan solas. Si la cuenta es de empresa, un administrador debe aprobarla en **Admin Console → Apps → Platform Apps Manager**, y hay que volver a autorizarla cada vez que cambien los permisos.

Box acepta explícitamente `http://` en loopback, y además tolera que cambie el puerto mientras coincidan esquema, dominio y ruta. Es el más permisivo de los cuatro en esto, así que iCloudy también recurre a un puerto efímero con Box cuando el 53682 está ocupado, igual que con Google. Con Microsoft y Dropbox no: comparan la dirección entera, y cambiar de puerto solo cambiaría el error por otro más confuso.

```sh
swift scripts/configure-oauth.swift --box CLIENT_ID:CLIENT_SECRET
```

## 5. Lo que no se registra en ninguna parte

Cinco de los proveedores no necesitan que el desarrollador dé de alta nada. Si solo vas a usar estos, no hace falta
tocar `Configuration/OAuth.local.plist`.

| Proveedor | Cómo entra el usuario |
|---|---|
| WebDAV | Dirección del servidor, usuario y contraseña |
| FTP y FTPS | Dirección, usuario y contraseña |
| Volúmenes y carpetas | Elige una carpeta; macOS ya hizo el montaje |
| Mega | Correo y contraseña de la cuenta |
| O2 Cloud | Inicia sesión en las páginas de O2, dentro de una ventana |

Mega y O2 no tienen registro para terceros ni siquiera si se quisiera: ninguno de los dos publica una API para otras
aplicaciones, y por eso van marcados como experimentales. Los detalles están en [Mega](MEGA.md) y [O2 Cloud](O2.md).

### WebDAV, Nextcloud y NAS

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

Los elementos del Llavero quedan ligados a la identidad que firmó la app. Una firma ad hoc (`-`) cambia en cada compilación, así que macOS trata cada compilación como una aplicación distinta y vuelve a pedir permiso para leer las cuentas guardadas, o directamente lo niega. Con una identidad estable el requisito designado no cambia y el permiso concedido una vez sigue valiendo.

Comprobado, no supuesto: firmando dos binarios **distintos** con el mismo certificado y el mismo identificador, el
segundo lee un elemento escrito por el primero sin que aparezca ninguna petición. Es decir, recompilar no vuelve a
preguntar.

### Si aun así pide la contraseña una y otra vez

El diálogo tiene tres botones y solo uno sirve. **«Permitir» autoriza ese acceso y nada más**, así que vuelve a
aparecer a la siguiente. El que hay que pulsar es **«Permitir siempre»**, que añade la app a la lista de la entrada
y ya no pregunta más, ni siquiera tras recompilar.

Los elementos creados por compilaciones anteriores a la existencia del certificado conservan la lista de entonces,
así que preguntarán una vez cada uno hasta que se les diga «Permitir siempre». Con una cuenta por elemento, eso son
varias preguntas seguidas la primera vez, y ninguna después.

### Por qué no se usa el Llavero moderno, que no pregunta nunca

El llavero con protección de datos no tiene listas de acceso ni diálogos: el acceso se decide por el identificador
de equipo de la firma. Sería mejor, pero exige una cuenta de desarrollador de Apple. Probado con el certificado
local: `SecItemAdd` devuelve `-34018`, falta el derecho. Sin cuenta de Apple no es una opción, y por eso iCloudy
sigue en el llavero clásico.

```sh
bash scripts/make-signing-cert.sh
bash scripts/build-app.sh
```

El script crea un certificado autofirmado de firma de código llamado `iCloudy Development` en el llavero de inicio de sesión y autoriza a `codesign` a usar su clave. **No se añade nada al almacén de confianza del sistema**: el certificado sigue sin ser de confianza y `codesign` no lo necesita, solo necesita la clave privada. Por eso `build-app.sh` busca la identidad sin el filtro `-v`, que descarta precisamente las no validadas.

La primera vez que abras la app firmada, macOS pedirá una vez acceso al Llavero porque los elementos se guardaron bajo la firma anterior. Elige **Permitir siempre** y no volverá a preguntar en las siguientes compilaciones.

Para quitarlo, abre Acceso a Llaveros, busca `iCloudy Development` y elimina el certificado y su clave. También puedes forzar otra identidad con `ICLOUDY_SIGNING_IDENTITY="Nombre exacto"` o volver a ad hoc con `ICLOUDY_SIGNING_IDENTITY=-`.

Los certificados autofirmados no admiten sello de tiempo de Apple, por eso el script firma con `--timestamp=none`. Sirven para desarrollo; la distribución sigue requiriendo Developer ID o Mac App Store.

## Mac App Store

Se incluye `Resources/iCloudy.entitlements` y el script lo usa al firmar: **App Sandbox**, red de salida, red de entrada para el callback exclusivo de loopback y acceso de lectura/escritura a archivos elegidos por el usuario. Los tests con respuestas simuladas no certifican el funcionamiento real en el sandbox. [App Sandbox de Apple](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).

La firma ad hoc del script es para desarrollo. El `Info.plist` declara categoría, copyright, icono y la exención de cifrado; el bundle ID `dev.icloudy.desktop` es provisional y se sustituye al compilar con `ICLOUDY_BUNDLE_ID=com.tuempresa.icloudy bash scripts/build-app.sh`. El icono se genera con `swift scripts/make-icon.swift` a partir de un símbolo del sistema y puede reemplazarse por un `Resources/AppIcon.icns` propio. Aún hay que elegir el bundle ID definitivo, configurar tu Apple Developer Team, firma y aprovisionamiento de Mac App Store, preparar el archivo de distribución y completar App Store Connect. Una firma Developer ID con notarización corresponde a distribución fuera de la Store; no sustituye el proceso de Mac App Store. El script permite `ICLOUDY_SIGNING_IDENTITY`, pero no crea certificados ni perfiles.

Esta app conecta cuentas externas para acceder a sus contenidos y no crea una cuenta propia de iCloudy. La regla 4.8 contempla una excepción para clientes de servicios de terceros; esa es la justificación que presentaríamos a revisión, no una garantía de aceptación. También se requieren política de privacidad, declaración de tratamiento de datos e instrucciones de prueba para App Review. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## Prueba de aceptación con cuentas reales

1. Compila con `--require-oauth` y abre el `.app`. La primera línea de la compilación dice qué proveedores están configurados.
2. Pulsa Google: selector de cuenta → consentimiento → regreso a iCloudy → listado de Drive.
3. Añade otra cuenta Google y verifica que se mantienen separadas.
4. Repite con una cuenta Outlook/Hotmail y, si procede, Microsoft 365.
5. Repite con Dropbox y con Box. En los dos, el fallo más probable no es el código sino la dirección de vuelta sin registrar, que se reconoce por un error de `redirect_uri` con el identificador de cliente correcto dentro.
5. Reinicia la app: las cuentas deben seguir presentes y los tokens renovarse cuando caduquen.
6. Prueba cancelar el consentimiento y volver a conectar.
7. Selecciona una carpeta local con el diálogo del sistema y prueba subida y descarga bajo el sandbox.

Pendientes hasta contar con registros reales: consentimiento end-to-end, permisos del tenant, renovación de tokens real, acceso al Llavero y transferencias en una distribución firmada/aprovisionada. El Mac debe estar desbloqueado para la prueba interactiva.
