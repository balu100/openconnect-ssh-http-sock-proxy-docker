#!/bin/sh
set -Eeuo pipefail

###############################################################################
# 0) UNIFIED LOGGING (no feedback loop)
###############################################################################
ALL_LOG="/var/log/stack.log"
mkdir -p /var/log
: >"$ALL_LOG"

# Save original stdout for console-only prints (bypass tee)
exec 3>&1

# FIFO-based tee: mirror all stdout/stderr to file + original stdout (docker logs)
LOG_FIFO="/tmp/stack.log.fifo"
rm -f "$LOG_FIFO"
mkfifo "$LOG_FIFO"

# Start tee reader FIRST (so writers won't block)
tee -a "$ALL_LOG" <"$LOG_FIFO" >&3 &
TEE_PID=$!

cleanup_logging() {
  # close redirected fds (best-effort), stop tee, remove fifo
  kill "$TEE_PID" >/dev/null 2>&1 || true
  rm -f "$LOG_FIFO" >/dev/null 2>&1 || true
}
trap cleanup_logging EXIT INT TERM

# Redirect all subsequent stdout/stderr into fifo
exec >"$LOG_FIFO" 2>&1

###############################################################################
# 1) BASICS: ROOT PASSWORD, SSH AGENT, AUTHORIZED KEYS
###############################################################################
set_root_password() {
  echo "root:$(echo "$ROOT_PASSWORD_BASE64" | base64 -d)" | chpasswd
}

start_ssh_agent() {
  AGENT_ENV_FILE="/root/.ssh/agent.env"
  ssh-agent -s > "$AGENT_ENV_FILE"
  sed -i '/^echo Agent pid/d' "$AGENT_ENV_FILE"
  # shellcheck disable=SC1090
  . "$AGENT_ENV_FILE"
  trap 'kill $SSH_AGENT_PID >/dev/null 2>&1' EXIT
}

load_private_key() {
  if [ -n "${SSH_PRIVATEKEY_BASE64:-}" ]; then
    umask 177
    KEYFILE="$(mktemp /root/.ssh/key.XXXXXX)"
    echo "$SSH_PRIVATEKEY_BASE64" | base64 -d > "$KEYFILE"
    chmod 600 "$KEYFILE"
    ssh-add "$KEYFILE"
    shred -u "$KEYFILE" || rm -f "$KEYFILE"
  fi
  ssh-add -l || true
}

set_authorized_keys() {
  if [ -n "${SSH_PUB_KEY_BASE64:-}" ]; then
    echo "$SSH_PUB_KEY_BASE64" | base64 -d > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "Public key added to /root/.ssh/authorized_keys"
  else
    echo "WARNING: No SSH_PUB_KEY_BASE64 provided. SSH login might fail."
  fi
}

###############################################################################
# 2) SERVICES: SSHD, TINYPROXY, SOCKD
###############################################################################
start_sshd() {
  /usr/sbin/sshd -D &
}

start_tinyproxy() {
  # Tip: set User/Group in /etc/tinyproxy/tinyproxy.conf to drop root
  /usr/bin/tinyproxy -d &
}

start_sockd() {
  # Tip: set 'user.notprivileged: nobody' in danted.conf to drop root
  /usr/sbin/sockd -D &
}

###############################################################################
# 3) OPENCONNECT: CERT PIN, START, ROUTES
###############################################################################
pin_server_cert() {
  VPN_SERVERCERT=$(
    openssl s_client -connect "$VPN_SERVER:443" -servername "$VPN_SERVER" </dev/null 2>/dev/null \
    | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
    | openssl x509 -pubkey -noout \
    | openssl pkey -pubin -outform DER \
    | openssl dgst -sha256 -binary \
    | openssl base64 -A \
    | awk '{print "pin-sha256:" $0}'
  )
  [ -n "$VPN_SERVERCERT" ] || { echo "pin generation failed"; exit 2; }
  export VPN_SERVERCERT
}

validate_vpn_env() {
  if [ -z "${VPN_SERVER:-}" ] || [ -z "${VPN_USERNAME:-}" ] || [ -z "${VPN_PASSWORD_BASE64:-}" ]; then
    echo "VPN_SERVER, VPN_USERNAME and VPN_PASSWORD_BASE64 environment variables must be set"
    exit 1
  fi
}

start_openconnect() {
  echo "Starting OpenConnect..."
  echo "$(echo "$VPN_PASSWORD_BASE64" | base64 -d)" \
    | openconnect --timestamp \
        --user="$VPN_USERNAME" --passwd-on-stdin \
        --authgroup="${VPN_AUTHGROUP:-}" --servercert "$VPN_SERVERCERT" \
        "$VPN_SERVER" &
}

wait_for_openconnect() {
  echo "Waiting for tun0 IPv4..."
  for i in $(seq 1 60); do
    if ip -o -4 addr show dev tun0 2>/dev/null | grep -q 'inet '; then
      echo "tun0 has IPv4."
      return 0
    fi
    sleep 1
  done
  echo "tun0 did not get IPv4 in 60s"; return 1
}

add_routes() {
  i=1
  while :; do
    cidr="$(printenv KEEP_LOCAL_IP$i || true)"
    [ -n "$cidr" ] || break
    ip route replace "$cidr" via "$ORIGINAL_GW" dev "$ORIGINAL_IFACE" || true
    echo "Pinned $cidr via $ORIGINAL_GW on $ORIGINAL_IFACE"
    i=$((i+1))
  done
}

###############################################################################
# 4) AUTOSSH TUNNELS: QUIET BACKGROUND (dynamic from env)
###############################################################################
start_autossh_dynamic() {
  export AUTOSSH_GATETIME=0
  export AUTOSSH_LOGLEVEL=1
  export AUTOSSH_LOGFILE="/var/log/stack.log"

  SSH_COMMON_OPTS='
    -o ServerAliveInterval=60
    -o ServerAliveCountMax=3
    -o ExitOnForwardFailure=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -q -o LogLevel=ERROR
  '

  found=0

  for idx in $(
    printenv | awk -F= '/^SSH_TUNNEL[0-9]+_HOST=/{sub(/^SSH_TUNNEL/,"",$1); sub(/_HOST$/,"",$1); print $1}' | sort -n
  ); do
    eval "host=\${SSH_TUNNEL${idx}_HOST:-}"
    eval "user=\${SSH_TUNNEL${idx}_USER:-}"
    eval "bind=\${SSH_TUNNEL${idx}_BIND:-}"
    eval "opts=\${SSH_TUNNEL${idx}_OPTS:-}"

    if [ -z "$host" ] || [ -z "$user" ] || [ -z "$bind" ]; then
      echo "SSH_TUNNEL${idx}: missing HOST/USER/BIND, skipping (HOST='$host' USER='$user' BIND='$bind')"
      continue
    fi

    found=1
    echo "autossh: starting SSH_TUNNEL${idx} → SOCKS on $bind via ${user}@${host}"

    autossh -M 0 -tt -A \
      -D "$bind" \
      $SSH_COMMON_OPTS \
      $opts \
      "${user}@${host}" \
      </dev/null >/dev/null 2>&1 &
  done

  [ "$found" -eq 1 ] || echo "No SSH_TUNNEL<N>_HOST found. Skipping autossh."
}

###############################################################################
# 5) MONITOR: STREAM LOGS TO CONSOLE, EXIT ON 'BYE'
###############################################################################
monitor_and_exit_on_bye() {
  echo "Setup complete. Monitoring for disconnect signals in $ALL_LOG..." >&3
  tail -Fn0 "$ALL_LOG" | while IFS= read -r line; do
    printf '%s\n' "$line" >&3      # print to original stdout only (no re-append)
    case "$line" in
      *BYE*|*exiting*|*Reconnect\ failed*|*returned\ error*)
        echo "BYE packet detected. Exiting container." >&3
        pkill openconnect || true
        pkill sshd || true
        pkill tinyproxy || true
        pkill sockd || true
        pkill autossh || true
        exit 0
        ;;
    esac
  done
}

###############################################################################
# MAIN
###############################################################################
set_root_password
start_ssh_agent
load_private_key
set_authorized_keys

start_sshd

pin_server_cert
validate_vpn_env
ORIGINAL_GW="$(ip route show default | awk '{print $3; exit}')"
ORIGINAL_IFACE="$(ip route show default | awk '{print $5; exit}')"
start_openconnect
wait_for_openconnect
start_tinyproxy
start_sockd
add_routes
start_autossh_dynamic
monitor_and_exit_on_bye
