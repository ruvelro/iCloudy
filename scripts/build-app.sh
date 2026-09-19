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

# `-emit-const-values` makes the compiler write the constant values the App Intents processor reads below. Without
# that pass the bundle has no Metadata.appintents, and the Shortcuts app does not list the intents at all.
swift build -c release -Xswiftc -emit-const-values
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
# App Intents metadata. Shortcuts and Automator only list an app's intents when the bundle carries
# Contents/Resources/Metadata.appintents. Xcode generates it as a build phase; `swift build` does not, so the same
# processor is run here over the constant values the compiler just extracted.
metadata_ok=false
processor="$(xcrun --find appintentsmetadataprocessor 2>/dev/null || true)"
if [[ -n "$processor" ]]; then
    const_list="$(mktemp)"; source_list="$(mktemp)"
    find "$binary_dir/iCloudy.build" "$PWD" -maxdepth 1 -name '*.swiftconstvalues' 2>/dev/null > "$const_list" || true
    find "$binary_dir/iCloudy.build" -name '*.swiftconstvalues' 2>/dev/null >> "$const_list" || true
    sort -u -o "$const_list" "$const_list"
    find "$PWD/Sources/iCloudy" -name '*.swift' > "$source_list"
    if [[ -s "$const_list" ]]; then
        toolchain="$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")"
        xcode_build="$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')"
        if "$processor" --output "$app_dir/Contents/Resources" --toolchain-dir "$toolchain" --module-name iCloudy \
            --sdk-root "$(xcrun --show-sdk-path)" --xcode-version "${xcode_build:-0}" --platform-family macOS \
            --deployment-target 14.0 --target-triple "$(uname -m)-apple-macos14.0" \
            --source-file-list "$source_list" --swift-const-vals-list "$const_list" --force --quiet-warnings \
            && [[ -d "$app_dir/Contents/Resources/Metadata.appintents" ]]; then
            metadata_ok=true
        fi
    fi
    rm -f "$const_list" "$source_list"
    # Constant values the compiler may have dropped beside the package instead of inside .build.
    find "$PWD" -maxdepth 1 -name '*.swiftconstvalues' -delete 2>/dev/null || true
fi
if [[ "$metadata_ok" != true ]]; then
    echo "Aviso: no se generó Metadata.appintents; las acciones de iCloudy no aparecerán en Atajos ni en Automator." >&2
fi
# Self-signed certificates cannot be timestamped by Apple; Developer ID builds get a timestamp automatically.
codesign --force --options runtime --timestamp=none --entitlements Resources/iCloudy.entitlements --sign "$identity" "$app_dir"
echo "Aplicación creada: $app_dir (firma: ${identity})"
