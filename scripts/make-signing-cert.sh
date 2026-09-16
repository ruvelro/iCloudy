#!/bin/bash
# Creates the local code-signing certificate that keeps iCloudy's Keychain items reachable across rebuilds.
#
# Why this exists: an ad hoc signature ("-") changes on every build, so macOS treats each build as a different
# application and asks again for permission to read the stored accounts. Signing with one stable certificate makes the
# designated requirement constant, so the permission granted once keeps working.
#
# The certificate is self-signed and stays untrusted by the system, which is fine: codesign only needs the private key.
# Nothing is added to the system trust store, so no other software becomes more trusted because of this.
#
# Run once:  bash scripts/make-signing-cert.sh
# Remove it: open Keychain Access, search for the name below, delete the certificate and its key.
set -euo pipefail

name="${ICLOUDY_CERT_NAME:-iCloudy Development}"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$name\""; then
    echo "Ya existe una identidad llamada «$name». No se crea otra."
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
password="$(openssl rand -base64 24)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$work/key.pem" -out "$work/cert.pem" \
    -subj "/CN=$name/O=iCloudy/C=ES" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -legacy -out "$work/identity.p12" \
    -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" -passout "pass:$password" 2>/dev/null

# -T authorises codesign to use the key without asking every time; no other program is granted access.
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign

echo "Identidad «$name» creada. Compila con: bash scripts/build-app.sh"
echo "La primera vez que abras la app, macOS pedirá una vez acceso al Llavero: elige «Permitir siempre»."
