# Cómo contribuir a iCloudy

Gracias por querer echar una mano. Esta guía cuenta cómo compilar, probar y proponer cambios. Para entender el código,
empieza por [docs/DETALLES.md](docs/DETALLES.md) y por el documento del proveedor que vayas a tocar (`docs/S3.md`,
`docs/FTP.md`, `docs/MEGA.md`…). Lo que hay en [docs/historial/](docs/historial/README.md) es contexto, no el estado
actual.

## Requisitos

- macOS 14 o posterior.
- Xcode 16 o posterior (Swift 6). La CI compila con Xcode 16.2 en macOS 14 y con Xcode 16.4 en macOS 15; si usas una
  versión más nueva, comprueba antes de abrir la PR que no dependes de nada que esas dos no tengan.
- Nada más: el paquete no tiene dependencias externas.

## Compilar

```sh
swift build -Xswiftc -warnings-as-errors   # lo mismo que la CI: ningún aviso
swift run iCloudyMain                       # el ejecutable suelto, para iterar sobre la interfaz
```

El ejecutable suelto no lleva la configuración OAuth ni la firma. Para probar inicios de sesión, el Llavero o los
Atajos hace falta el paquete `.app`:

```sh
bash scripts/make-signing-cert.sh                     # una vez, si no tienes certificado de Apple (docs/OAUTH.md)
ICLOUDY_BUILD_CONFIGURATION=debug bash scripts/build-app.sh
open dist/debug/iCloudy.app
```

Las credenciales OAuth propias se configuran con `swift scripts/configure-oauth.swift` (ver [docs/OAUTH.md](docs/OAUTH.md));
se guardan en `Configuration/OAuth.local.plist`, que Git ignora. La extensión de Finder solo se empaqueta con
`ICLOUDY_APP_GROUP` ([docs/FILEPROVIDER.md](docs/FILEPROVIDER.md)).

## Probar

```sh
swift test                 # toda la batería, en serie
swift test --parallel      # cada prueba en su propio proceso; es lo que corre la CI
swift test --filter MegaProviderTests
swift test --enable-code-coverage && scripts/ci/coverage.sh   # cobertura por carpeta y coverage.lcov
```

Las pruebas no tocan la red, el Llavero, tus preferencias ni tu carpeta de Application Support: cada prueba recibe
una suite de `UserDefaults` y una carpeta temporal propias. Si una prueba se cuelga, un vigilante detiene el proceso a
los 120 s y dice cuál era (`ICLOUDY_TEST_TIMEOUT=300` para cambiar el límite).

### Servidores reales

Tres pruebas recorren la pila completa contra servidores de verdad y se saltan si no hay uno. Los scripts de
`scripts/ci/` los levantan en `127.0.0.1` y escriben la variable que la prueba lee:

| Prueba | Servidor | Cómo |
|---|---|---|
| `S3IntegrationTests` | MinIO | `scripts/ci/minio.sh start` descarga el binario oficial (comprobando su SHA-256) y crea el bucket. Imprime `ICLOUDY_S3_URL=…`. |
| `SFTPTests` | OpenSSH de macOS | `scripts/ci/sftp.sh check` valida la configuración sin privilegios. `start` crea un usuario temporal con contraseña y necesita `sudo`, así que solo se ejecuta en CI (`CI=true`); en local usa `ICLOUDY_SFTP_URL` con cualquier servidor, como cuenta [docs/FTP.md](docs/FTP.md). |
| `FTPSTests` | pyftpdlib con TLS | `scripts/ci/ftps.sh start` crea un certificado autofirmado y un entorno virtual con pyftpdlib. Imprime `ICLOUDY_FTPS_URL=…`. |

```sh
eval "$(scripts/ci/minio.sh start | grep ICLOUDY_S3_URL)" && export ICLOUDY_S3_URL
swift test --filter S3IntegrationTests
scripts/ci/minio.sh stop
```

Todo se guarda en `$TMPDIR/icloudy-ci` (o en `ICLOUDY_CI_ROOT`).

### Escribir pruebas

- Cada archivo de `Tests/iCloudyTests/` cubre un área: un proveedor (`DropboxProviderTests`, `S3ProviderTests`…), un
  subsistema (`TransferTests`, `MirrorTests`…) o una función. Una prueba nueva va en el archivo de su área; si no hay
  ninguno, crea uno con el nombre del área.
- Usa lo que hay en [`TestSupport.swift`](Tests/iCloudyTests/TestSupport.swift):
  - `StubProtocol.handler = { request in (200, [:], Data()) }` responde las peticiones HTTP **de la prueba que lo
    instala** y se descarta al terminar; no hace falta limpiarlo en `tearDown`. Crea la sesión con
    `StubProtocol.session()`, `StubProtocol.configuration()` o `makeStubbedClient(.dropbox)`, y una petición que
    quede pendiente de una prueba anterior fallará en vez de llegar a tu manejador.
  - `try await wait(until: { condición }, "mensaje")` en lugar de `Task.sleep` seguido de una aserción; para afirmar
    que algo *no* pasa, `try await assertStays({ condición }, for: .milliseconds(100))`.
  - `temporaryRoot()` para una carpeta que se borra sola, `repositoryURL("Resources/…")` para leer archivos del
    repositorio sin depender del directorio actual, `MemoryCredentials` en lugar del Llavero, `Flag` y `Box` para
    señales que llegan desde otros hilos.
- Los modelos (`AppModel`, la cola, los reflejos) se prueban con la cuenta de demostración (`model.enableDemo()`,
  `DemoStore` en una carpeta temporal): recorre el mismo código que un proveedor real sin red.
- Los mensajes de las aserciones, en inglés.

## Convenciones

- **Comentarios del código en inglés**, en prosa: por qué es así, no qué hace la línea.
- **Textos de la interfaz en castellano**, siempre a través de `L("…")` (o de un literal en una vista de SwiftUI), y
  con su traducción en `Resources/en.lproj/Localizable.strings`. Las frases con un número que puede ser 1 se añaden a
  la tabla de [`scripts/make-plurals.py`](scripts/make-plurals.py) y se regeneran con `python3 scripts/make-plurals.py`.
  `python3 scripts/check-localization.py` lista las claves inglesas que ya no usa nadie.
- **Formato**: `scripts/lint.sh` pasa swift-format con [`.swift-format`](.swift-format). Las reglas activadas deben
  pasar; los avisos de disposición (sangría, saltos de línea) solo se cuentan, porque el estilo del código es más
  compacto que el de swift-format. Sigue el estilo del archivo que tocas.
- La app y la biblioteca compilan en modo Swift 6 con comprobación completa de concurrencia; las pruebas, en modo
  Swift 5 (ver `Package.swift`).
- Nada de dependencias nuevas sin hablarlo antes en un aviso.

## Commits y pull requests

- Mensajes en inglés con el estilo de [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`,
  `perf:`, `test:`, `docs:`, `ci:`, `build:`, `chore:`. La primera línea dice qué cambia para quien usa la app o lee
  el código («fix: let the clouds in the sidebar be dragged into a new order»); el cuerpo cuenta por qué.
- Un commit por cambio lógico. Si el cambio se nota al usar la app, añade una línea en «Sin publicar» de
  [CHANGELOG.md](CHANGELOG.md).
- La PR rellena la [plantilla](.github/pull_request_template.md). La CI tiene que estar en verde: compilación sin
  avisos en macOS 14 y 15, pruebas en paralelo con cobertura, lint, tablas de localización y los paquetes `.app`.

## Seguridad

Si encuentras un fallo de seguridad, no abras un aviso público: usa un
[aviso privado de seguridad](https://github.com/ruvelro/iCloudy/security/advisories/new).
