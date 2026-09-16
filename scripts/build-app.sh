#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
oauth_config="${ICLOUDY_OAUTH_CONFIG:-$PWD/Configuration/OAuth.local.plist}"
if [[ ! -f "$oauth_config" ]]; then
    oauth_config="$PWD/Configuration/OAuth.example.plist"
fi
swift scripts/configure-oauth.swift --validate "$oauth_config" "${1:-}"

# Keychain items are bound to the signing identity. An ad hoc signature ("-") changes with every build, so macOS
# asks for Keychain access or refuses the stored accounts after each rebuild. Prefer any stable code-signing
# identity found in the Keychain; docs/OAUTH.md explains how to create a local one.
identity="${ICLOUDY_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    # First choice: an identity Apple itself validates.
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application|Apple Development|Mac Developer/ { print $2; exit }')"
fi
if [[ -z "$identity" ]]; then
    # Second choice: the local development certificate. `codesign` accepts it even though the system does not trust
    # a self-signed root, which is why this lookup drops the -v flag that filters out untrusted identities.
    identity="$(security find-identity -p codesigning 2>/dev/null \
        | awk -F'"' '/iCloudy Development/ { print $2; exit }')"
fi
if [[ -z "$identity" ]]; then
    identity="-"
    echo "Aviso: no hay identidad de firma; se usa firma ad hoc. Tras cada compilación macOS pedirá acceso al Llavero para las cuentas guardadas." >&2
    echo "       Define ICLOUDY_SIGNING_IDENTITY o crea un certificado local de firma de código (docs/OAUTH.md, sección Firma local)." >&2
fi

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/dist/iCloudy.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/iCloudy" "$app_dir/Contents/MacOS/iCloudy"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -n "${ICLOUDY_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${ICLOUDY_BUNDLE_ID}" "$app_dir/Contents/Info.plist"
fi
if [[ ! -f Resources/AppIcon.icns ]]; then
    swift scripts/make-icon.swift Resources
fi
cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
cp "$oauth_config" "$app_dir/Contents/Resources/OAuth.plist"
# Localizations live in Bundle.main so both SwiftUI's LocalizedStringKey and String(localized:) find them.
for lproj in Resources/*.lproj; do [[ -d "$lproj" ]] && cp -R "$lproj" "$app_dir/Contents/Resources/"; done
# Self-signed certificates cannot be timestamped by Apple; Developer ID builds get a timestamp automatically.
codesign --force --options runtime --timestamp=none --entitlements Resources/iCloudy.entitlements --sign "$identity" "$app_dir"
echo "Aplicación creada: $app_dir (firma: ${identity})"
