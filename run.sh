#!/bin/sh
set -Eeuo pipefail

###############################################################################
# 0) UNIFIED LOGGING (no feedback loop)
###############################################################################
ALL_LOG="/var/log/stack.log"
mkdir -p /var/log; : >"$ALL_LOG"

# Save original stdout for console-only prints (bypass tee)
exec 3>&1

# Mirror all normal output to file + docker logs
exec > >(tee -a "$ALL_LOG") 2>&1

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
    echo "VPN_SERVER, VPN_USERNAME, VPN_PASSWORD_BASE64 and VPN_AUTHGROUP environment variables must be set"
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
# 4) AUTOSSH TUNNELS: QUIET BACKGROUND
###############################################################################
start_autossh() {
  export AUTOSSH_GATETIME=0
  export AUTOSSH_LOGLEVEL=1
  export AUTOSSH_LOGFILE="/var/log/stack.log"

  if [ -n "${SSH_TUNNEL_USER:-}" ] && [ -n "${SSH_TUNNEL_HOST_A:-}" ] && [ -n "${SSH_TUNNEL_HOST_B:-}" ]; then
    echo "Configuring autossh tunnels..."
    echo "Background mode → Site A:8225, Site B:8226."

    # Site A
    autossh -M 0 -tt -A \
      -D 0.0.0.0:8225 \
      -o ServerAliveInterval=60 \
      -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes \
      -o StrictHostKeyChecking=no \
      -q -o LogLevel=ERROR \
      "$SSH_TUNNEL_USER@$SSH_TUNNEL_HOST_A" \
      </dev/null >/dev/null 2>&1 &

    # Site B
    autossh -M 0 -tt -A \
      -D 0.0.0.0:8226 \
      -o ServerAliveInterval=60 \
      -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes \
      -o StrictHostKeyChecking=no \
      -q -o LogLevel=ERROR \
      "$SSH_TUNNEL_USER@$SSH_TUNNEL_HOST_B" \
      </dev/null >/dev/null 2>&1 &
  else
    echo "SSH tunnel environment variables not set. Skipping."
  fi
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
start_autossh
monitor_and_exit_on_bye
