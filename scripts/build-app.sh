#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
oauth_config="${ICLOUDY_OAUTH_CONFIG:-$PWD/Configuration/OAuth.local.plist}"
if [[ ! -f "$oauth_config" ]]; then
    oauth_config="$PWD/Configuration/OAuth.example.plist"
fi
swift scripts/configure-oauth.swift --validate "$oauth_config" "${1:-}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$PWD/dist/iCloudy.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/iCloudy" "$app_dir/Contents/MacOS/iCloudy"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp "$oauth_config" "$app_dir/Contents/Resources/OAuth.plist"
codesign --force --options runtime --entitlements Resources/iCloudy.entitlements --sign "${ICLOUDY_SIGNING_IDENTITY:--}" "$app_dir"
echo "Aplicación creada: $app_dir"
