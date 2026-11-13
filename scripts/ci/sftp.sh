#!/usr/bin/env bash
# A throwaway OpenSSH server on 127.0.0.1:2222 for the SFTP integration test, using the sshd that ships with macOS.
#
#     scripts/ci/sftp.sh check   # writes the host key and sshd_config and has sshd validate them; no root needed
#     scripts/ci/sftp.sh start   # CI only: creates a local test user, starts sshd, prints ICLOUDY_SFTP_URL
#     scripts/ci/sftp.sh stop    # stops sshd and deletes the test user
#
# The test signs in with a password, and an sshd that does not run as root can only check the password of the user
# running it, which a CI runner does not have. So `start` needs root and creates a dedicated user with a random
# password; it refuses to run outside CI (CI=true), because it changes the accounts of the Mac. Locally, use
# `check` to validate the configuration, or point ICLOUDY_SFTP_URL at any server (docs/FTP.md).
set -euo pipefail

command="${1:-start}"
base="${ICLOUDY_CI_ROOT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/icloudy-ci}"
root="$base/sftp"
port="${SFTP_PORT:-2222}"
user="${SFTP_USER:-icloudyci}"
sshd=/usr/sbin/sshd

configure() {
    mkdir -p "$root"
    chmod 700 "$root"
    if [[ ! -f "$root/ssh_host_ed25519_key" ]]; then
        ssh-keygen -q -t ed25519 -N '' -C icloudy-ci -f "$root/ssh_host_ed25519_key"
    fi
    cat >"$root/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $root/ssh_host_ed25519_key
PidFile $root/sshd.pid
AuthorizedKeysFile none
PubkeyAuthentication no
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitRootLogin no
AllowUsers $user
StrictModes no
UseDNS no
X11Forwarding no
AllowTcpForwarding no
Subsystem sftp internal-sftp
EOF
    "$sshd" -V 2>&1 | head -1
    # -t validates the file and the key without starting anything.
    "$sshd" -t -f "$root/sshd_config"
    echo "sshd_config is valid: $root/sshd_config"
}

stop() {
    if [[ -f "$root/sshd.pid" ]]; then sudo kill "$(cat "$root/sshd.pid")" 2>/dev/null || true; fi
    if [[ "${CI:-}" == "true" ]] && id "$user" >/dev/null 2>&1; then
        sudo sysadminctl -deleteUser "$user" >/dev/null 2>&1 || true
    fi
}

start() {
    if [[ "${CI:-}" != "true" ]]; then
        echo "start creates a user account on this Mac; it only runs in CI (CI=true). Use '$0 check' locally." >&2
        exit 2
    fi
    configure
    password="ci-$(openssl rand -hex 12)"
    if ! id "$user" >/dev/null 2>&1; then
        sudo sysadminctl -addUser "$user" -fullName "iCloudy CI" -password "$password" -home "/Users/$user" >/dev/null 2>&1
        sudo createhomedir -c -u "$user" >/dev/null 2>&1 || true
    else
        sudo dscl . -passwd "/Users/$user" "$password"
    fi
    sudo mkdir -p "/Users/$user/sftp"
    sudo chown "$user" "/Users/$user/sftp"
    # macOS's sshd honours the Remote Login access list when it exists; the test user has to be on it.
    sudo dseditgroup -o edit -a "$user" -t user com.apple.access_ssh >/dev/null 2>&1 || true
    sudo "$sshd" -f "$root/sshd_config" -E "$root/sshd.log"
    for _ in $(seq 1 30); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
        sleep 1
    done
    if ! nc -z 127.0.0.1 "$port"; then echo "sshd did not start:" >&2; sudo cat "$root/sshd.log" >&2; exit 1; fi
    url="sftp://$user:$password@127.0.0.1:$port/Users/$user/sftp"
    echo "ICLOUDY_SFTP_URL=sftp://$user:***@127.0.0.1:$port/Users/$user/sftp"
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        echo "::add-mask::$password"
        echo "ICLOUDY_SFTP_URL=$url" >>"$GITHUB_ENV"
    else
        echo "ICLOUDY_SFTP_URL=$url"
    fi
}

case "$command" in
    check) configure ;;
    start) start ;;
    stop) stop ;;
    *) echo "usage: $0 check|start|stop" >&2; exit 2 ;;
esac
