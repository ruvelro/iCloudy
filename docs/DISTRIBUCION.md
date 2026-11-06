# Distribución

Cómo se convierte el código en algo que se descarga, se abre con doble clic y avisa cuando hay una versión nueva. Hoy
no hay identificador de equipo de Apple (Team ID), así que todo lo que sigue funciona en dos modos: **sin firmar**,
que es lo que sale ahora, y **firmado y notarizado**, que sale solo en cuanto existan los secretos. Las mismas
órdenes sirven para los dos; lo que cambia es si hay identidad o no.

## Las piezas

| Pieza | Qué hace |
|---|---|
| `VERSION` | El único sitio donde se escribe la versión a mano (`0.7.0`). |
| `scripts/version.sh` | Lee `VERSION`; con `--build`, el número de compilación: `git rev-list --count HEAD`. |
| `scripts/build-app.sh` | Compila el `.app` y escribe esas dos cifras en `CFBundleShortVersionString` y `CFBundleVersion`. El `Info.plist` del repositorio lleva `0.0.0` y `0` a propósito, para que no haya una segunda fuente. |
| `scripts/release.py` | `check`: `VERSION`, el último encabezado de `CHANGELOG.md`, el distintivo del README y, si se le da, la etiqueta coinciden. `notes`: la sección del registro de cambios de una versión. `appcast`: el aviso de versiones. `cask`: la fórmula de Homebrew rellena. |
| `scripts/notarize.sh` | Firma con Developer ID, notariza y grapa el `.app` o el `.dmg`. Sin identidad no hace nada y lo dice. |
| `scripts/package.sh` | Crea el `.zip`, el `.dmg` y `SHA256SUMS.txt` en `dist/release/`. |
| `.github/workflows/release.yml` | Lo junta todo al empujar una etiqueta `v*` y publica la versión en GitHub. |
| `packaging/homebrew/icloudy.rb` | La plantilla del cask. |

El README y el `CHANGELOG.md` siguen escritos a mano; `release.py check` corre en la CI de cada PR y falla si dicen
otra versión que `VERSION`.

## Publicar una versión

1. En `CHANGELOG.md`, «Sin publicar» pasa a ser `## 0.9.0 — 20 de noviembre de 2026`, y se abre otra «Sin publicar»
   vacía encima.
2. `VERSION` dice `0.9.0`; en el README, el distintivo (`versión-0.9.0-`) y el aviso («**Versión 0.9**»).
3. `python3 scripts/release.py check` tiene que decir que coinciden.
4. Commit en `master`, y la etiqueta: `git tag v0.9.0 && git push origin master v0.9.0`.
5. El flujo **Release** hace el resto: comprueba que la etiqueta es `v` + `VERSION`, compila en release, firma y
   notariza si puede, empaqueta, y crea la versión de GitHub con la sección del `CHANGELOG.md` como notas y estos
   archivos adjuntos:
   - `iCloudy-0.9.0.zip` y `iCloudy-0.9.0.dmg` (con `-unsigned` en el nombre si no hay firma Developer ID con la
     notarización grapada);
   - `SHA256SUMS.txt`, que se comprueba con `shasum -a 256 -c SHA256SUMS.txt`;
   - `appcast.json` (lo que lee la app) y `appcast.xml` (lo mismo en el formato de Sparkle);
   - `icloudy.rb`, el cask relleno con la versión y la suma del `.zip`.
6. Copiar `icloudy.rb` al tap de Homebrew (más abajo).

Una versión con guion (`1.0.0-rc.1`) se publica como *pre-release*. GitHub no la cuenta como «la última», así que
el comprobador de actualizaciones no la ofrece a nadie: sirve para probar.

Sin secretos, la versión sale igual, con «(sin firmar)» en el título, `-unsigned` en los nombres y un aviso al
principio de las notas que explica cómo abrirla (botón derecho › Abrir) y cómo comprobar la suma.

### En local

```sh
ICLOUDY_BUILD_CONFIGURATION=debug bash scripts/build-app.sh   # o sin la variable, en release
ICLOUDY_BUILD_CONFIGURATION=debug bash scripts/package.sh
open dist/release
```

Para firmar y notarizar desde tu Mac, con la identidad en el llavero y un perfil de `notarytool`:

```sh
xcrun notarytool store-credentials icloudy --apple-id tu@correo --team-id TEAMID   # una vez; pide una contraseña de app
bash scripts/build-app.sh
ICLOUDY_DEVELOPER_ID="Developer ID Application: Nombre (TEAMID)" ICLOUDY_NOTARY_PROFILE=icloudy \
    scripts/notarize.sh app dist/iCloudy.app
ICLOUDY_DEVELOPER_ID="Developer ID Application: Nombre (TEAMID)" ICLOUDY_NOTARY_PROFILE=icloudy \
    bash scripts/package.sh
```

`package.sh` llama a `notarize.sh dmg` por su cuenta cuando el `.app` ya está notarizado.

## Los secretos de GitHub

En *Settings › Secrets and variables › Actions* del repositorio. Ninguno es obligatorio: el que falta hace que esa
parte se salte con un aviso en el registro del flujo.

| Secreto | Qué es | De dónde sale |
|---|---|---|
| `APPLE_DEVELOPER_ID` | El nombre exacto de la identidad: `Developer ID Application: Nombre (TEAMID)`. | `security find-identity -v -p codesigning` |
| `APPLE_DEVELOPER_ID_P12` | El certificado Developer ID Application **con su clave privada**, exportado como `.p12` y en base64. | Acceso a Llaveros › Exportar; `base64 -i certificado.p12 \| pbcopy` |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | La contraseña con que se exportó el `.p12`. | |
| `APPLE_TEAM_ID` | Los diez caracteres del Team ID. `notarize.sh` comprueba que la firma lleva justo ese. | developer.apple.com › Membership |
| `APPLE_NOTARY_KEY` | La clave de la API de App Store Connect (`AuthKey_XXXX.p8`), en base64. | App Store Connect › Usuarios y acceso › Integraciones › Claves; rol «Developer» basta |
| `APPLE_NOTARY_KEY_ID` | El identificador de esa clave. | La misma página |
| `APPLE_NOTARY_ISSUER_ID` | El identificador del emisor. | La misma página, encima de la lista |
| `ICLOUDY_OAUTH_PLIST` | `Configuration/OAuth.local.plist` en base64, con los clientes OAuth del proyecto. Sin él, la versión publicada lleva la configuración de ejemplo y solo conecta los proveedores que no necesitan registro. | `swift scripts/configure-oauth.swift` ([OAUTH.md](OAUTH.md)) |

Y una **variable** (no secreto), `ICLOUDY_APP_GROUP`, que incrusta la extensión del Finder cuando tenga sentido
(ver «Cuando haya Team ID»).

El flujo crea un llavero temporal para el certificado y lo borra al terminar, pase lo que pase.

## Cómo funciona la notarización

Apple solo deja abrir sin preguntas una app descargada si está firmada con un certificado **Developer ID** y lleva un
**ticket de notarización**: Apple ha escaneado ese binario exacto y lo ha dado por bueno. `notarize.sh`:

1. Se niega si no hay identidad, si no es «Developer ID Application» o si no está en ningún llavero; y si el paquete
   lleva `get-task-allow` (es uno de depuración: la notarización lo rechaza y nadie debería publicarlo).
2. **Vuelve a firmar de dentro afuera**: los ejecutables sueltos de `Contents/MacOS` y `Contents/Helpers` (una
   herramienta de línea de órdenes, por ejemplo), luego cada `.appex`, `.xpc`, `.framework` o `.dylib`, y al final la
   app. Usa `--options runtime` (el *hardened runtime*, obligatorio para notarizar) y `--timestamp` (el sello de
   tiempo de Apple, también obligatorio). Conserva los permisos que puso `build-app.sh` a cada pieza
   (`--preserve-metadata=entitlements`); no usa `--deep`, que les daría a todas los de la app.
3. Comprime la app con `ditto`, la envía con `xcrun notarytool submit --wait` y, si Apple no la acepta, imprime el
   registro de la notarización.
4. Grapa el ticket (`xcrun stapler staple`) para que Gatekeeper no tenga que preguntar a Apple con el Mac sin red, y
   comprueba el resultado con `spctl --assess`.

El `.dmg` se firma y notariza aparte, después de crearlo, y las sumas se calculan al final, sobre los archivos ya
grapados.

### Permisos y hardened runtime

Revisado `Resources/iCloudy.entitlements` para el *hardened runtime*: no hace falta ninguna excepción.

- `app-sandbox`, `network.client`, `files.user-selected.read-write` y `files.bookmarks.app-scope` son los del sandbox
  y no chocan con el runtime endurecido.
- `network.server` es para el bucle local de OAuth (`127.0.0.1`), no para escuchar en la red.
- No hay `allow-jit`, `allow-unsigned-executable-memory` ni `disable-library-validation`: el paquete no carga
  bibliotecas de terceros y WebKit (el acceso de O2) corre en sus propios procesos.
- `get-task-allow` solo lo añade `build-app.sh` al paquete de depuración, nunca al archivo de permisos.
- La extensión del Finder tiene sandbox y red de salida; el App Group y el grupo de Llavero los añade el script.

## Actualizaciones: por qué no Sparkle (todavía)

La revisión proponía Sparkle 2. Se ha hecho un **comprobador propio, sin dependencias**, por estos motivos:

- **No se puede verificar aquí.** Sparkle en una app con sandbox necesita sus servicios XPC (Installer y, para
  descargar, Downloader) firmados dentro del paquete, excepciones temporales de `mach-lookup` en los permisos
  (`$(PRODUCT_BUNDLE_IDENTIFIER)-spks` y `-spki`) y que la app y la actualización tengan la misma firma. Sin Team
  ID la firma es local o ad hoc y cambia de una compilación a otra, así que la instalación no se puede probar de
  punta a punta en este paquete hecho a mano. Publicar un actualizador que nunca ha instalado nada no es una opción.
- **Sería la primera dependencia** del paquete (un `binaryTarget` con `Sparkle.framework`), con su `rpath`, su
  firma por piezas y sus excepciones de sandbox. Es razonable el día en que se pueda probar, no antes.
- **Instalar sobre una app sin firmar no aporta**: macOS volvería a pedir confirmación y, sin Team ID, el Llavero
  pediría permiso de nuevo para cada nube tras cada actualización ([OAUTH.md](OAUTH.md), «Firma local»).

Lo que hay (`Sources/iCloudy/Integration/UpdateChecker.swift`):

- Lee `https://github.com/ruvelro/iCloudy/releases/latest/download/appcast.json`, que GitHub redirige al adjunto de
  la última versión publicada que no sea *pre-release*.
- Compara versiones SemVer (`0.10.0` va después de `0.9.0`; `1.0.0-rc.1`, antes de `1.0.0`).
- Si hay una más nueva, abre la ventana **«Hay una versión nueva»** con las notas, el aviso de si está firmada o
  no, el sistema mínimo, el enlace de descarga del `.dmg` y su **SHA-256** con un botón para copiarla.
- **Nunca descarga ni instala nada**: el botón abre el navegador.
- **iCloudy › Buscar actualizaciones…** comprueba al momento. En **Ajustes › Actualizaciones** se activa la
  comprobación automática (una vez al día mientras la ventana está abierta) y se ve cuándo fue la última.
- **La automática viene apagada.** Sería la primera petición de iCloudy a alguien que no es una de tus nubes, y el
  README promete que no hay nada de eso sin que lo pidas. Lo único que se envía es la petición del archivo, con
  `User-Agent: iCloudy/<versión>`.
- «Omitir esta versión» calla la automática para esa versión; la comprobación a mano la sigue enseñando.
- Un fallo en la automática no dice nada y se reintenta; uno a mano se explica. Un enlace que no sea `https` se
  rechaza, y un formato de aviso más nuevo que el que la app entiende solo ofrece la página de la versión.

`appcast.xml` se genera ya en el formato de Sparkle, sin `sparkle:edSignature`. Adoptar Sparkle más adelante
consistiría en: añadir el `binaryTarget`, copiar `Sparkle.framework` a `Contents/Frameworks` en `build-app.sh` y
firmar sus XPC con `notarize.sh` (ya recorre `.xpc` y `.framework`), añadir las excepciones de `mach-lookup` y
`SUEnableInstallerLauncherService`/`SUEnableDownloaderService`, `SUFeedURL` y `SUPublicEDKey` al `Info.plist`, y
firmar el `.zip` con `sign_update` en el flujo de publicación. El comprobador propio se retiraría entonces.

## Homebrew

`packaging/homebrew/icloudy.rb` es la plantilla; `release.py cask` la rellena con la versión, el nombre del `.zip` y
su SHA-256, y añade un aviso (`caveats`) si la versión no está firmada.

El tap todavía **no existe**. Para crearlo, una vez:

```sh
gh repo create ruvelro/homebrew-tap --public --description "Casks de ruvelro"
git clone https://github.com/ruvelro/homebrew-tap && cd homebrew-tap && mkdir Casks
```

Y en cada versión:

```sh
gh release download v0.9.0 --repo ruvelro/iCloudy --pattern icloudy.rb --dir Casks --clobber
brew audit --cask --strict Casks/icloudy.rb   # opcional, con el tap añadido
git commit -am "icloudy 0.9.0" && git push
```

Quien quiera instalarla:

```sh
brew install --cask ruvelro/tap/icloudy
```

El repositorio principal de Homebrew (`homebrew/cask`) no es el sitio mientras la app no esté firmada y notarizada:
allí se exige que las apps pasen Gatekeeper. Automatizar el tap desde el flujo de publicación necesitaría un token con
permiso de escritura en el otro repositorio; se ha dejado fuera a propósito hasta que exista.

## Cuando haya Team ID

Lo que cambia, en orden:

1. **Elegir el bundle ID definitivo antes de la primera versión firmada.** `dev.icloudy.desktop` es provisional
   (`ICLOUDY_BUNDLE_ID` lo cambia). El contenedor del sandbox, los elementos del Llavero y los marcadores de las
   carpetas reflejadas cuelgan de él: cambiarlo después es perder las cuentas y los reflejos de quien ya lo usa.
2. **Los secretos `APPLE_*`.** A partir de ahí las versiones salen firmadas y notarizadas, sin `-unsigned`.
3. **El Llavero deja de preguntar** tras cada actualización: con Team ID, la partición de cada elemento es
   `teamid:…`, que no cambia entre compilaciones ([OAUTH.md](OAUTH.md)).
4. **La extensión del Finder.** El App Group y el grupo de acceso al Llavero que comparte con la app necesitan el
   Team ID ([FILEPROVIDER.md](FILEPROVIDER.md)). Lo probable, y por verificar: un identificador con el prefijo del
   equipo (`TEAMID.dev.icloudy`), que macOS 15 concede a una app Developer ID sin perfil de aprovisionamiento, en la
   variable `ICLOUDY_APP_GROUP`; el grupo de Llavero, en cambio, se apoya en `application-identifier` y probablemente
   pida un perfil de aprovisionamiento Developer ID incrustado (`Contents/embedded.provisionprofile`), que
   `build-app.sh` todavía no copia. Es lo primero que hay que probar con la cuenta, antes de llamar «disponible» a la
   extensión.
5. **Sparkle**, si se quiere instalar en lugar de avisar (sección anterior).

## Mac App Store: no

Decisión: **iCloudy no se publica en el Mac App Store.** Se distribuye fuera de él, con Developer ID y notarización.
Los motivos, de más a menos peso:

- **La licencia.** iCloudy es GPL-3.0, y el artículo 10 prohíbe imponer restricciones adicionales a quien recibe el
  programa. Los términos del App Store las imponen (reglas de uso, límite de dispositivos, prohibición de redistribuir
  el binario tal como se recibe); es el conflicto por el que VLC salió de la tienda en 2011. Solo el titular de los
  derechos de todo el código podría publicarlo con otra licencia, y cada contribución externa bajo GPL lo complica
  más (haría falta el permiso de cada autor o un acuerdo de contribución que hoy no existe).
- **Los clientes OAuth dentro del paquete.** Una versión de la tienda llevaría en claro los identificadores (y los
  secretos, donde el proveedor los da) del proyecto, para cualquiera que la descargue. Es lo normal en una app de
  escritorio, pero en la tienda va unido a una verificación de cada proveedor (la de Google para el acceso completo
  a Drive incluye una auditoría de seguridad anual) y a responder del cliente ante cada uno. Fuera de la tienda,
  quien compila puede usar sus propios clientes, que es lo que hace hoy el README.
- **Las normas de revisión.** Mega y O2 se usan a través de API no documentadas; la guía 5.2.2 exige permiso del
  servicio para eso. El comprobador de actualizaciones tampoco puede existir en la tienda (allí actualiza la tienda),
  y una versión de la tienda tendría que ser otra compilación.
- **El sandbox no es el obstáculo.** La app ya tiene sandbox, sin excepciones temporales; el bucle local de OAuth, los
  Servicios y el File Provider con App Group también se admiten. Si algún día cambian los dos primeros puntos, lo
  técnico es lo de menos.

Se revisará solo si cambia la licencia o los proveedores ofrecen una vía oficial para todo lo que hoy se usa sin
ella.
