#!/usr/bin/env bash
# A throwaway explicit-FTPS server on 127.0.0.1:2121 for FTPSTests: pyftpdlib with a self-signed certificate.
#
#     scripts/ci/ftps.sh cert    # only creates the certificate (openssl), to check that part without Python packages
#     scripts/ci/ftps.sh start   # creates a virtualenv with pyftpdlib if needed, starts the server, prints ICLOUDY_FTPS_URL
#     scripts/ci/ftps.sh stop
#
# The packages are pinned and installed into $ICLOUDY_CI_ROOT/ftps/venv, never into the system Python (Homebrew's
# refuses that anyway). The test trusts the certificate through StartTLSFramer.trustAnyCertificateForTesting.
set -euo pipefail

command="${1:-start}"
base="${ICLOUDY_CI_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/icloudy-ci}"
root="$base/ftps"
port="${FTPS_PORT:-2121}"
user="icloudy"
here="$(cd "$(dirname "$0")" && pwd)"
packages=(pyftpdlib==2.0.1 pyOpenSSL==24.2.1)

certificate() {
    mkdir -p "$root"
    if [[ ! -f "$root/cert.pem" ]]; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=127.0.0.1" \
            -keyout "$root/key.pem" -out "$root/cert.pem" >/dev/null 2>&1
    fi
    openssl x509 -in "$root/cert.pem" -noout -subject -enddate
}

stop() {
    if [[ -f "$root/pid" ]]; then kill "$(cat "$root/pid")" 2>/dev/null || true; rm -f "$root/pid"; fi
}

start() {
    stop
    certificate
    if [[ ! -x "$root/venv/bin/python" ]]; then
        python3 -m venv "$root/venv"
        "$root/venv/bin/python" -m pip install --quiet --disable-pip-version-check "${packages[@]}"
    fi
    mkdir -p "$root/files"
    password="ci-$(openssl rand -hex 12)"
    nohup "$root/venv/bin/python" "$here/ftps_server.py" "$root/files" "$root/cert.pem" "$root/key.pem" "$port" "$user" "$password" \
        >"$root/server.log" 2>&1 &
    echo $! >"$root/pid"
    for _ in $(seq 1 30); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
        sleep 1
    done
    if ! nc -z 127.0.0.1 "$port"; then echo "The FTPS server did not start:" >&2; cat "$root/server.log" >&2; exit 1; fi
    url="ftpes://$user:$password@127.0.0.1:$port/"
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "::add-mask::$password"
        echo "ICLOUDY_FTPS_URL=$url" >>"$GITHUB_ENV"
        echo "ICLOUDY_FTPS_URL=ftpes://$user:***@127.0.0.1:$port/"
    else
        echo "ICLOUDY_FTPS_URL=$url"
    fi
}

case "$command" in
    cert) certificate ;;
    start) start ;;
    stop) stop ;;
    *) echo "usage: $0 cert|start|stop" >&2; exit 2 ;;
esac
