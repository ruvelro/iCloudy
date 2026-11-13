# Seguridad

iCloudy guarda contraseñas, tokens y claves de cifrado de varias nubes, y habla protocolos (SSH, FTPS, la API de Mega)
para los que macOS no trae cliente. Esta página dice qué criptografía es del sistema y cuál está escrita en el propio
proyecto, qué se ha hecho para que la segunda sea fiable y cómo avisar de un fallo.

## Cómo avisar de un fallo

No abras una incidencia pública para un problema de seguridad. Usa el aviso privado de GitHub
(**Security → Report a vulnerability** en [ruvelro/iCloudy](https://github.com/ruvelro/iCloudy/security/advisories/new))
y cuenta qué versión usas, qué proveedor está implicado y cómo reproducirlo. Si no puedes usar GitHub, abre una
incidencia que diga solo «tengo un fallo de seguridad que contar» y te escribiremos.

Se intenta contestar en una semana. Un fallo confirmado se corrige en la rama principal antes de publicarlo, y el
aviso se publica con la versión que lo corrige y, si quieres, con tu nombre.

Entran: cualquier forma de leer o cambiar credenciales, archivos o claves de bóveda sin permiso; de hacer que iCloudy
se conecte a una cuenta o a un servidor que no es el que la persona eligió; de saltarse una comprobación de integridad
o de identidad del servidor; y cualquier dato personal que acabe en un informe de diagnóstico sin redactar.

## Lo que viene del sistema

Todo lo que es una primitiva (un cifrado, un hash, una firma, un intercambio de claves) lo pone macOS:

| Qué | De dónde |
|---|---|
| TLS de HTTPS, FTPS implícito y explícito | Network.framework / Security (verificación de certificado y de nombre) |
| AES (bloque, CTR, GCM), HMAC, SHA-1/2, PBKDF2 | CryptoKit y CommonCrypto |
| Curve25519, Ed25519, P-256/384/521 | CryptoKit |
| RSA de las claves de servidor SSH y de la firma con claves RSA del usuario | Security (`SecKeyVerifySignature`, `SecKeyCreateSignature` con la clave PKCS#1 completa, parámetros CRT incluidos) |
| Números aleatorios | `SecRandomCopyBytes` y el generador de CryptoKit |
| Llavero | Security (un único ítem por app, comparado y reintentado) |

## Lo que está escrito aquí

Cero dependencias externas significa que algunos formatos se implementan en el proyecto, siempre **sobre** las
primitivas de la tabla de arriba:

| Qué | Dónde | Cómo se comprueba |
|---|---|---|
| bcrypt_pbkdf y su Blowfish (claves privadas OpenSSH con frase) | `Providers/SFTP/BCryptPBKDF.swift` | Vectores de regresión de OpenBSD y claves creadas por `ssh-keygen` en cada prueba |
| scrypt, Salsa20/8, BlockMix, ROMix (Cryptomator) | `Encryption/Scrypt.swift` | Todos los vectores del RFC 7914 |
| AES-SIV, CMAC, envoltura de claves RFC 3394, CTR | `Encryption/AESModes.swift` | RFC 5297, RFC 4493 y RFC 3394 completos; pruebas publicadas de cryptolib |
| Formato de bóveda Cryptomator 8 | `Encryption/Cryptomator*.swift` | Ficheros y vectores publicados por Cryptomator |
| Transporte SSH-2 (RFC 4253/4252/4254) y SFTP v3 | `Providers/SFTP/SSH*.swift`, `SFTPClient.swift` | Vectores de derivación de claves, un servidor SSH falso en las pruebas y, cuando se configura, un servidor real |
| Firma SigV4 de S3 | `Providers/S3/S3Signer.swift` | Ejemplos publicados por AWS |
| Aritmética RSA de la sesión de Mega | `Providers/Mega/MegaBigInt.swift` | Vectores propios y cuentas reales |
| PKCE y el bucle local de OAuth | `Authentication/OAuth*.swift` | RFC 7636 y un navegador simulado sobre TCP |

### Decisiones de seguridad que conviene conocer

- **SSH**: solo algoritmos modernos (curve25519/ECDH, Ed25519/ECDSA/RSA-SHA2, AES-GCM/CTR con HMAC-SHA-256). Intercambio
  estricto de claves (`kex-strict-*-v00@openssh.com`, la respuesta de OpenSSH a Terrapin) cuando el servidor lo admite;
  claves RSA de servidor de al menos 2048 bits; relleno mínimo de cuatro bytes; nada que no sea del intercambio sale
  mientras se renuevan las claves.
- **Clave del servidor SSH**: en la primera conexión se muestra su huella `SHA256:` y no se envía ni la contraseña ni la
  firma de la clave hasta que la persona la acepta. La clave aceptada se guarda en el Llavero, no en `accounts.json`, y
  una distinta en una sesión posterior corta la conexión antes de iniciar sesión.
- **keyboard-interactive**: la contraseña solo responde a un aviso oculto que pide una contraseña, y una sola vez. Un
  segundo factor se rechaza con un mensaje claro en lugar de recibir la contraseña.
- **OAuth**: PKCE y `state` en Google, Microsoft, Dropbox y Box. pCloud no devuelve `state`; para él solo se acepta la
  primera vuelta sin `state` en los cinco minutos siguientes a abrir el navegador, y la cuenta que conecta se enseña a la
  persona para que la confirme antes de guardarla.
- **Mega**: la sesión usa la aritmética RSA de `MegaBigInt`, cuyo tiempo depende del exponente. La operación ocurre en este
  Mac, una vez por inicio de sesión, sobre un desafío que manda Mega; no es una firma que un tercero pueda cronometrar
  repetidamente, pero es el punto más débil que queda y está anotado para sustituirlo.
- **Diagnóstico**: el redactor falla cerrado: lo que no sabe clasificar no se exporta.

## Lo que no se promete

iCloudy no está auditado por terceros. Los proveedores sin API pública (Mega, O2) pueden cambiar sin aviso, y su
integración se marca como experimental en la app.
