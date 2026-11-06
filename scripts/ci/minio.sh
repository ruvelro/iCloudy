#!/usr/bin/env bash
# A throwaway MinIO on 127.0.0.1 for S3IntegrationTests.
#
#     scripts/ci/minio.sh start   # downloads MinIO if needed, starts it, creates the bucket, prints ICLOUDY_S3_URL
#     scripts/ci/minio.sh stop
#
# Everything lives under $ICLOUDY_CI_ROOT (default: $RUNNER_TEMP or the system temp folder, /icloudy-ci/minio). The
# binary is fetched from dl.min.io for this Mac's architecture and checked against the SHA-256 published next to it;
# MINIO_URL picks another build, MINIO_BIN an existing binary. Inside GitHub Actions the URL is also appended to
# $GITHUB_ENV, so the test step sees it. The keys are fixed and only valid for this local, temporary server.
set -euo pipefail

command="${1:-start}"
base="${ICLOUDY_CI_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/icloudy-ci}"
root="$base/minio"
port="${MINIO_PORT:-9000}"
user="icloudy-ci"
secret="icloudy-ci-secret"
bucket="pruebas"

stop() {
    if [[ -f "$root/pid" ]]; then
        kill "$(cat "$root/pid")" 2>/dev/null || true
        rm -f "$root/pid"
    fi
}

binary() {
    if [[ -n "${MINIO_BIN:-}" ]]; then echo "$MINIO_BIN"; return; fi
    if command -v minio >/dev/null 2>&1; then command -v minio; return; fi
    # MinIO stopped publishing binaries (dl.min.io answers 410 Gone since late 2026). Homebrew still has a bottle of the
    # last community release, deprecated but installable; the download below stays for a MINIO_URL mirror.
    if [[ -z "${MINIO_URL:-}" ]] && command -v brew >/dev/null 2>&1; then
        if HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install --quiet minio >&2 && command -v minio >/dev/null 2>&1; then
            command -v minio; return
        fi
        echo "Homebrew could not install minio; trying the download." >&2
    fi
    local arch url
    case "$(uname -m)" in
        arm64) arch=arm64 ;;
        x86_64) arch=amd64 ;;
        *) echo "Unsupported architecture $(uname -m)" >&2; exit 1 ;;
    esac
    url="${MINIO_URL:-https://dl.min.io/server/minio/release/darwin-$arch/minio}"
    if [[ ! -x "$root/bin/minio" ]]; then
        mkdir -p "$root/bin"
        echo "Downloading $url" >&2
        curl -fsSL --retry 3 -o "$root/bin/minio.download" "$url"
        expected="$(curl -fsSL --retry 3 "$url.sha256sum" | awk '{print $1}')"
        actual="$(shasum -a 256 "$root/bin/minio.download" | awk '{print $1}')"
        if [[ -z "$expected" || "$expected" != "$actual" ]]; then
            echo "MinIO checksum mismatch: expected '$expected', got '$actual'" >&2
            exit 1
        fi
        chmod +x "$root/bin/minio.download"
        mv "$root/bin/minio.download" "$root/bin/minio"
    fi
    echo "$root/bin/minio"
}

start() {
    stop
    mkdir -p "$root/data"
    local minio
    minio="$(binary)"
    "$minio" --version
    MINIO_ROOT_USER="$user" MINIO_ROOT_PASSWORD="$secret" MINIO_BROWSER=off \
        nohup "$minio" server "$root/data" --address "127.0.0.1:$port" >"$root/minio.log" 2>&1 &
    echo $! >"$root/pid"
    for _ in $(seq 1 60); do
        if curl -fsS "http://127.0.0.1:$port/minio/health/live" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    if ! curl -fsS "http://127.0.0.1:$port/minio/health/live" >/dev/null; then
        echo "MinIO did not start:" >&2; cat "$root/minio.log" >&2; exit 1
    fi
    # Creating the bucket is one signed PUT; curl signs it with SigV4 itself, so no MinIO client is needed.
    status="$(curl -sS -o "$root/bucket.out" -w '%{http_code}' -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" \
        --user "$user:$secret" "http://127.0.0.1:$port/$bucket")"
    if [[ "$status" != 200 ]] && ! grep -q BucketAlreadyOwnedByYou "$root/bucket.out"; then
        echo "Could not create the bucket (HTTP $status):" >&2; cat "$root/bucket.out" >&2; exit 1
    fi
    url="http://$user:$secret@127.0.0.1:$port/$bucket"
    echo "ICLOUDY_S3_URL=$url"
    if [[ -n "${GITHUB_ENV:-}" ]]; then echo "ICLOUDY_S3_URL=$url" >>"$GITHUB_ENV"; fi
}

case "$command" in
    start) start ;;
    stop) stop ;;
    *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
