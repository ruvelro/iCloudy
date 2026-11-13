#!/bin/bash
# The app's version, from the one place it is written by hand.
#
#     scripts/version.sh            # CFBundleShortVersionString: the contents of VERSION, e.g. 0.9.0
#     scripts/version.sh --build    # CFBundleVersion: the number of commits up to HEAD
#
# The build number needs the whole history: a shallow clone counts only the commits it fetched, which is why the
# release workflow checks out with fetch-depth 0. Outside a Git checkout (a source tarball) ICLOUDY_BUILD_NUMBER
# supplies it, and failing that it is 0, with a warning.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    "")
        version="$(tr -d '[:space:]' < VERSION)"
        if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
            echo "VERSION no contiene una versión SemVer válida: «${version}»." >&2
            exit 1
        fi
        echo "$version"
        ;;
    --build)
        if [[ -n "${ICLOUDY_BUILD_NUMBER:-}" ]]; then
            echo "$ICLOUDY_BUILD_NUMBER"
        elif count="$(git rev-list --count HEAD 2>/dev/null)"; then
            if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
                echo "Aviso: el clon es superficial; el número de compilación (${count}) no es el definitivo." >&2
            fi
            echo "$count"
        else
            echo "Aviso: no hay historial de Git ni ICLOUDY_BUILD_NUMBER; el número de compilación es 0." >&2
            echo 0
        fi
        ;;
    *) echo "Uso: scripts/version.sh [--build]" >&2; exit 2 ;;
esac
