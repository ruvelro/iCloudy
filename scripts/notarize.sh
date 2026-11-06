#!/bin/bash
# Signs with Developer ID, notarizes and staples. Without an identity it does nothing and says so, so the same
# release pipeline produces an unsigned build on a fork or before there is an Apple Developer account.
#
#     scripts/notarize.sh app dist/iCloudy.app      # re-sign every piece of code with a timestamp, notarize, staple
#     scripts/notarize.sh dmg dist/release/X.dmg    # sign the disk image, notarize, staple
#
# Environment (docs/DISTRIBUCION.md has where each one comes from):
#   ICLOUDY_DEVELOPER_ID      "Developer ID Application: Nombre (TEAMID)", in a keychain on the search list.
#   ICLOUDY_TEAM_ID           optional; when set, the signature must carry exactly this Team ID.
#   Notary credentials, one of:
#     ICLOUDY_NOTARY_PROFILE  a profile stored with `xcrun notarytool store-credentials` (local use), or
#     ICLOUDY_NOTARY_KEY, ICLOUDY_NOTARY_KEY_ID, ICLOUDY_NOTARY_ISSUER
#                             an App Store Connect API key: the .p8 file's path, its key ID and the issuer ID (CI).
# With an identity and no notary credentials the code is signed but not notarized, and the script says that too.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "Uso: scripts/notarize.sh app <iCloudy.app> | dmg <archivo.dmg>" >&2; exit 2; }
[[ $# -eq 2 ]] || usage
mode="$1"; target="$2"
case "$mode" in app|dmg) ;; *) usage ;; esac
[[ -e "$target" ]] || { echo "No existe: $target" >&2; exit 1; }

identity="${ICLOUDY_DEVELOPER_ID:-}"
if [[ -z "$identity" ]]; then
    echo "Firma y notarización omitidas para $(basename "$target"): ICLOUDY_DEVELOPER_ID no está definida." >&2
    echo "       El paquete queda como estaba (firma ad hoc o local) y se publicará marcado como «sin firmar»." >&2
    exit 0
fi
if [[ "$identity" != "Developer ID Application:"* ]]; then
    echo "ICLOUDY_DEVELOPER_ID debe ser una identidad «Developer ID Application: …»; Apple solo notariza esas." >&2
    exit 1
fi
if ! security find-identity -v -p codesigning | grep -qF "\"$identity\""; then
    echo "La identidad «$identity» no está en ningún llavero de la lista de búsqueda, o no es válida." >&2
    exit 1
fi

notary=()
if [[ -n "${ICLOUDY_NOTARY_PROFILE:-}" ]]; then
    notary=(--keychain-profile "$ICLOUDY_NOTARY_PROFILE")
elif [[ -n "${ICLOUDY_NOTARY_KEY:-}" && -n "${ICLOUDY_NOTARY_KEY_ID:-}" && -n "${ICLOUDY_NOTARY_ISSUER:-}" ]]; then
    notary=(--key "$ICLOUDY_NOTARY_KEY" --key-id "$ICLOUDY_NOTARY_KEY_ID" --issuer "$ICLOUDY_NOTARY_ISSUER")
fi

check_team() {
    [[ -n "${ICLOUDY_TEAM_ID:-}" ]] || return 0
    local team
    team="$(codesign -dv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
    if [[ "$team" != "$ICLOUDY_TEAM_ID" ]]; then
        echo "La firma de $1 lleva el Team ID «$team» y ICLOUDY_TEAM_ID es «$ICLOUDY_TEAM_ID»." >&2
        exit 1
    fi
}

# Sends a file to Apple's notary service and waits for the verdict; prints the log when it is not accepted.
submit() {
    local file="$1" result status id
    result="$(mktemp)"
    xcrun notarytool submit "$file" "${notary[@]}" --wait --timeout 1h --output-format json > "$result" || true
    status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$result" 2>/dev/null || true)"
    id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$result" 2>/dev/null || true)"
    if [[ "$status" != "Accepted" ]]; then
        echo "Apple no ha aceptado la notarización (estado: ${status:-desconocido})." >&2
        cat "$result" >&2
        if [[ -n "$id" ]]; then xcrun notarytool log "$id" "${notary[@]}" >&2 || true; fi
        rm -f "$result"
        exit 1
    fi
    echo "Notarización aceptada (${id})."
    rm -f "$result"
}

sign() {
    # The entitlements each piece was given by scripts/build-app.sh (App Group, keychain group, sandbox) are kept;
    # the designated requirement is not, so codesign derives it from the Developer ID certificate.
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$1"
}

if [[ "$mode" == "app" ]]; then
    # A debug bundle may be attached to by a debugger, which notarization refuses and nobody should ship.
    if codesign -d --entitlements - --xml "$target" 2>/dev/null | grep -q "com.apple.security.get-task-allow"; then
        echo "$target lleva com.apple.security.get-task-allow: es un paquete de depuración. Compila con la configuración release." >&2
        exit 1
    fi
    main="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$target/Contents/Info.plist")"
    # Inside out: loose executables beside the main one (a command-line tool, for instance), then nested bundles
    # deepest first, then the app itself. `--deep` would sign everything with the app's entitlements instead.
    for folder in "$target/Contents/MacOS" "$target/Contents/Helpers"; do
        [[ -d "$folder" ]] || continue
        while IFS= read -r -d '' file; do
            if [[ "$(basename "$file")" == "$main" && "$folder" == "$target/Contents/MacOS" ]]; then continue; fi
            if file -b "$file" | grep -q "Mach-O"; then sign "$file"; fi
        done < <(find "$folder" -maxdepth 1 -type f -print0)
    done
    while IFS= read -r -d '' bundle; do
        sign "$bundle"
    done < <(find "$target/Contents" -depth \( -name '*.appex' -o -name '*.xpc' -o -name '*.framework' -o -name '*.dylib' \) -print0)
    sign "$target"
    codesign --verify --deep --strict --verbose=2 "$target"
    check_team "$target"
    if [[ ${#notary[@]} -eq 0 ]]; then
        echo "Aviso: $target está firmado con «$identity» pero no notarizado: faltan ICLOUDY_NOTARY_PROFILE o ICLOUDY_NOTARY_KEY, _KEY_ID e _ISSUER." >&2
        exit 0
    fi
    archive_dir="$(mktemp -d)"
    trap 'rm -rf "$archive_dir"' EXIT
    # notarytool takes a zip, a dmg or a pkg; the app goes as a zip, and the ticket is stapled to the app itself.
    ditto -c -k --sequesterRsrc --keepParent "$target" "$archive_dir/iCloudy.zip"
    submit "$archive_dir/iCloudy.zip"
    xcrun stapler staple "$target"
    xcrun stapler validate "$target"
    spctl --assess --type execute --verbose=2 "$target"
else
    codesign --force --timestamp --sign "$identity" "$target"
    check_team "$target"
    if [[ ${#notary[@]} -eq 0 ]]; then
        echo "Aviso: $target está firmado pero no notarizado: no hay credenciales de notarización." >&2
        exit 0
    fi
    submit "$target"
    xcrun stapler staple "$target"
    xcrun stapler validate "$target"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
fi
echo "Firmado, notarizado y grapado: $target"
