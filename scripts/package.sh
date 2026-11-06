#!/bin/bash
# Packages a built iCloudy.app as a .zip and a .dmg, with their SHA-256 sums.
#
#     bash scripts/build-app.sh && bash scripts/package.sh                 # dist/iCloudy.app
#     ICLOUDY_BUILD_CONFIGURATION=debug bash scripts/package.sh             # dist/debug/iCloudy.app
#     bash scripts/package.sh path/to/iCloudy.app
#
# Writes to dist/release (or ICLOUDY_PACKAGE_DIR):
#   iCloudy-<versión>.zip, iCloudy-<versión>.dmg   names carry "-unsigned" unless the app is Developer ID signed
#                                                  and has its notarization ticket stapled
#   SHA256SUMS.txt                                  `shasum -a 256 -c SHA256SUMS.txt` checks both
#   package.env                                     VERSION, BUILD, SIGNED, ZIP, DMG, for the release workflow
# The disk image is signed and notarized by scripts/notarize.sh when the app was; otherwise it is left as it is.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-}"
if [[ -z "$app" ]]; then
    if [[ "${ICLOUDY_BUILD_CONFIGURATION:-release}" == "debug" ]]; then app="dist/debug/iCloudy.app"; else app="dist/iCloudy.app"; fi
fi
if [[ ! -d "$app/Contents" ]]; then
    echo "No hay ningún paquete en $app. Compílalo antes con scripts/build-app.sh." >&2
    exit 1
fi
out="${ICLOUDY_PACKAGE_DIR:-$PWD/dist/release}"
mkdir -p "$out"

info="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info")"
if [[ "$version" != "$(scripts/version.sh)" ]]; then
    echo "Aviso: el paquete dice $version y VERSION dice $(scripts/version.sh). Vuelve a compilar si no es lo que quieres." >&2
fi
codesign --verify --deep --strict "$app"

signed=false
if codesign -dvv "$app" 2>&1 | grep -q '^Authority=Developer ID Application' \
    && xcrun stapler validate -q "$app" >/dev/null 2>&1; then
    signed=true
fi
suffix=""
[[ "$signed" == true ]] || suffix="-unsigned"
base="iCloudy-${version}${suffix}"
zip="$out/$base.zip"
dmg="$out/$base.dmg"
rm -f "$zip" "$dmg" "$out/SHA256SUMS.txt" "$out/package.env"

# ditto keeps what a plain zip loses (extended attributes, the stapled ticket, symlinks inside frameworks).
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

# A plain window: the app and a link to /Applications, no background picture to maintain.
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/iCloudy.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "iCloudy ${version}" -srcfolder "$staging" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$dmg"
hdiutil verify -quiet "$dmg"
if [[ "$signed" == true ]]; then
    scripts/notarize.sh dmg "$dmg"
fi

(cd "$out" && shasum -a 256 "$base.zip" "$base.dmg" > SHA256SUMS.txt)
cat > "$out/package.env" <<EOF
VERSION=$version
BUILD=$build
SIGNED=$signed
ZIP=$zip
DMG=$dmg
EOF

echo "Paquetes en $out:"
(cd "$out" && ls -l "$base.zip" "$base.dmg" SHA256SUMS.txt && cat SHA256SUMS.txt)
if [[ "$signed" != true ]]; then
    echo "Aviso: el paquete no lleva firma Developer ID con notarización grapada; los archivos se marcan «-unsigned»." >&2
fi
