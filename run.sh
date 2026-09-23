#!/bin/sh
# Target: Alpine /bin/sh (BusyBox ash)
set -Eeuo pipefail

###############################################################################
# 0) UNIFIED LOGGING
###############################################################################
ALL_LOG="/var/log/stack.log"
LOG_FIFO="/tmp/stack.log.fifo"

mkdir -p /var/log /run
: >"$ALL_LOG"

# Keep the original container stdout available for cleanup.
exec 3>&1

rm -f "$LOG_FIFO"
mkfifo "$LOG_FIFO"

tee -a "$ALL_LOG" <"$LOG_FIFO" >&3 &
TEE_PID=$!

MAIN_PID=$$
AUTOSSH_PIDS=""

cleanup_all() {
  # Cleanup must never abort halfway because of set -e/-u.
  set +e

  # Stop writing to the FIFO from PID 1 before killing tee.
  exec 1>&3 2>&3

  # Stop AutoSSH supervisors. Docker will also tear down remaining children
  # when PID 1 exits, but asking AutoSSH to exit first gives it a clean path.
  for pid in ${AUTOSSH_PIDS:-}; do
    kill "$pid" >/dev/null 2>&1 || true
  done

  for pid in \
    "${WATCHDOG_PID:-}" \
    "${TINYPROXY_PID:-}" \
    "${SOCKD_PID:-}" \
    "${SSHD_PID:-}"
  do
    [ -n "$pid" ] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done

  # Give OpenConnect SIGTERM so it can log out and run vpnc-script cleanup.
  if [ -n "${OPENCONNECT_PID:-}" ]; then
    kill "$OPENCONNECT_PID" >/dev/null 2>&1 || true
  fi

  if [ -n "${SSH_AGENT_PID:-}" ]; then
    kill "$SSH_AGENT_PID" >/dev/null 2>&1 || true
  fi

  rm -f \
    /run/openconnect.pid \
    /run/original_gw \
    /run/original_iface

  if [ -n "${TEE_PID:-}" ]; then
    kill "$TEE_PID" >/dev/null 2>&1 || true
  fi

  rm -f "$LOG_FIFO"
}

trap cleanup_all EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Mirror all subsequent stdout/stderr to stack.log + Docker logs.
exec >"$LOG_FIFO" 2>&1

###############################################################################
# 1) VALIDATION / BASICS
###############################################################################
validate_env() {
  missing=0

  for name in ROOT_PASSWORD_BASE64 VPN_SERVER VPN_USERNAME VPN_PASSWORD_BASE64; do
    value="$(printenv "$name" 2>/dev/null || true)"
    if [ -z "$value" ]; then
      echo "ERROR: $name must be set"
      missing=1
    fi
  done

  [ "$missing" -eq 0 ] || exit 1

  printf '%s' "$ROOT_PASSWORD_BASE64" | base64 -d >/dev/null 2>&1 || {
    echo "ERROR: ROOT_PASSWORD_BASE64 is not valid base64"
    exit 1
  }

  printf '%s' "$VPN_PASSWORD_BASE64" | base64 -d >/dev/null 2>&1 || {
    echo "ERROR: VPN_PASSWORD_BASE64 is not valid base64"
    exit 1
  }

  VPN_PORT="${VPN_PORT:-443}"
  VPN_RECONNECT_TIMEOUT="${VPN_RECONNECT_TIMEOUT:-0}"

  case "$VPN_PORT" in
    ''|*[!0-9]*)
      echo "ERROR: VPN_PORT must be numeric"
      exit 1
      ;;
  esac

  case "$VPN_RECONNECT_TIMEOUT" in
    ''|*[!0-9]*)
      echo "ERROR: VPN_RECONNECT_TIMEOUT must be a non-negative integer"
      exit 1
      ;;
  esac

  if [ "$VPN_PORT" -lt 1 ] || [ "$VPN_PORT" -gt 65535 ]; then
    echo "ERROR: VPN_PORT must be between 1 and 65535"
    exit 1
  fi

  export VPN_PORT VPN_RECONNECT_TIMEOUT
}

set_root_password() {
  root_password="$(printf '%s' "$ROOT_PASSWORD_BASE64" | base64 -d)"
  printf 'root:%s\n' "$root_password" | chpasswd
  unset root_password
}

ensure_ssh_host_keys() {
  # Generate keys at runtime so a published image does not contain a shared
  # SSH server private key.
  ssh-keygen -A
}

start_ssh_agent() {
  AGENT_ENV_FILE="/root/.ssh/agent.env"

  (
    umask 077
    ssh-agent -s >"$AGENT_ENV_FILE"
  )

  sed -i '/^echo Agent pid/d' "$AGENT_ENV_FILE"
  # shellcheck disable=SC1090
  . "$AGENT_ENV_FILE"
}

load_private_key() {
  if [ -n "${SSH_PRIVATEKEY_BASE64:-}" ]; then
    KEYFILE="$(umask 077; mktemp /root/.ssh/key.XXXXXX)"

    if ! printf '%s' "$SSH_PRIVATEKEY_BASE64" | base64 -d >"$KEYFILE"; then
      rm -f "$KEYFILE"
      echo "ERROR: SSH_PRIVATEKEY_BASE64 is not valid base64"
      exit 1
    fi

    chmod 600 "$KEYFILE"
    ssh-add "$KEYFILE"
    shred -u "$KEYFILE" || rm -f "$KEYFILE"
  fi

  ssh-add -l || true
}

set_authorized_keys() {
  if [ -n "${SSH_PUB_KEY_BASE64:-}" ]; then
    if ! printf '%s' "$SSH_PUB_KEY_BASE64" | base64 -d >/root/.ssh/authorized_keys; then
      rm -f /root/.ssh/authorized_keys
      echo "ERROR: SSH_PUB_KEY_BASE64 is not valid base64"
      exit 1
    fi

    chmod 600 /root/.ssh/authorized_keys
    echo "Public key added to /root/.ssh/authorized_keys"
  else
    echo "WARNING: No SSH_PUB_KEY_BASE64 provided. Container SSH will rely on password authentication."
  fi
}

###############################################################################
# 2) SERVICES
###############################################################################
start_sshd() {
  /usr/sbin/sshd -D &
  SSHD_PID=$!
}

start_tinyproxy() {
  /usr/bin/tinyproxy -d &
  TINYPROXY_PID=$!
}

start_sockd() {
  /usr/sbin/sockd -D &
  SOCKD_PID=$!
}

###############################################################################
# 3) OPENCONNECT / ROUTING
###############################################################################
pin_server_cert() {
  # Prefer a fixed user-supplied pin. Automatic discovery is retained for
  # backwards compatibility, but is TOFU on every fresh container.
  if [ -n "${VPN_SERVERCERT:-}" ]; then
    case "$VPN_SERVERCERT" in
      pin-sha256:*|sha256:*|sha1:*)
        echo "Using configured VPN server certificate pin."
        export VPN_SERVERCERT
        return 0
        ;;
      *)
        echo "ERROR: VPN_SERVERCERT must start with pin-sha256:, sha256:, or sha1:"
        exit 1
        ;;
    esac
  fi

  echo "WARNING: VPN_SERVERCERT is not set; discovering the current server public-key pin."

  # Bound certificate discovery so an unreachable VPN endpoint cannot hang
  # container startup forever.
  VPN_SERVERCERT="$(
    (
      timeout 15 openssl s_client \
        -connect "${VPN_SERVER}:${VPN_PORT}" \
        -servername "$VPN_SERVER" \
        </dev/null 2>/dev/null \
      | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
      | openssl x509 -pubkey -noout \
      | openssl pkey -pubin -outform DER \
      | openssl dgst -sha256 -binary \
      | openssl base64 -A \
      | awk '{print "pin-sha256:" $0}'
    ) || true
  )"

  [ -n "$VPN_SERVERCERT" ] || {
    echo "ERROR: VPN server certificate pin generation failed"
    exit 2
  }

  export VPN_SERVERCERT
}

save_original_route() {
  ORIGINAL_GW="$(ip route show default | awk 'NR == 1 {print $3}')"
  ORIGINAL_IFACE="$(ip route show default | awk 'NR == 1 {print $5}')"

  [ -n "$ORIGINAL_GW" ] && [ -n "$ORIGINAL_IFACE" ] || {
    echo "ERROR: could not determine original default gateway/interface"
    exit 1
  }

  printf '%s\n' "$ORIGINAL_GW" >/run/original_gw
  printf '%s\n' "$ORIGINAL_IFACE" >/run/original_iface
}

start_openconnect() {
  echo "Starting OpenConnect..."

  # Build argv safely in POSIX sh and do not pass an empty auth group.
  set -- \
    openconnect \
    --timestamp \
    --non-inter \
    "--reconnect-timeout=$VPN_RECONNECT_TIMEOUT" \
    "--user=$VPN_USERNAME" \
    --passwd-on-stdin \
    "--servercert=$VPN_SERVERCERT"

  if [ -n "${VPN_AUTHGROUP:-}" ]; then
    set -- "$@" "--authgroup=$VPN_AUTHGROUP"
  fi

  if [ "$VPN_PORT" -eq 443 ]; then
    set -- "$@" "$VPN_SERVER"
  else
    set -- "$@" "${VPN_SERVER}:${VPN_PORT}"
  fi

  VPN_PASSWORD="$(printf '%s' "$VPN_PASSWORD_BASE64" | base64 -d)"

  # BusyBox ash sets $! to the last process of this background pipeline,
  # i.e. openconnect in the Alpine image used here.
  printf '%s\n' "$VPN_PASSWORD" | "$@" &
  OPENCONNECT_PID=$!
  unset VPN_PASSWORD

  printf '%s\n' "$OPENCONNECT_PID" >/run/openconnect.pid
  echo "OpenConnect PID: $OPENCONNECT_PID"
}

openconnect_process_alive() {
  pid="$1"

  [ -r "/proc/$pid/stat" ] || return 1

  state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
  case "$state" in
    ''|Z|X)
      return 1
      ;;
  esac

  [ -r "/proc/$pid/comm" ] || return 1
  IFS= read -r comm <"/proc/$pid/comm" || return 1
  [ "$comm" = "openconnect" ]
}

wait_for_openconnect() {
  echo "Waiting for tun0 IPv4..."

  i=1
  while [ "$i" -le 60 ]; do
    if ip -o -4 addr show dev tun0 2>/dev/null | grep -q 'inet '; then
      echo "tun0 has IPv4."
      return 0
    fi

    if ! openconnect_process_alive "$OPENCONNECT_PID"; then
      echo "ERROR: OpenConnect exited before tun0 received IPv4."
      return 1
    fi

    sleep 1
    i=$((i + 1))
  done

  echo "ERROR: tun0 did not get IPv4 in 60 seconds"
  return 1
}

add_routes() {
  # Sparse numbering is supported:
  # KEEP_LOCAL_IP1, KEEP_LOCAL_IP2, KEEP_LOCAL_IP999, ...
  for idx in $(
    printenv \
      | awk -F= '/^KEEP_LOCAL_IP[0-9]+=/{sub(/^KEEP_LOCAL_IP/,"",$1); print $1}' \
      | sort -n -u
  ); do
    cidr="$(printenv "KEEP_LOCAL_IP${idx}" 2>/dev/null || true)"
    [ -n "$cidr" ] || continue

    # A configured exception is important. Fail startup rather than silently
    # routing it through the VPN if the route cannot be installed.
    ip route replace "$cidr" via "$ORIGINAL_GW" dev "$ORIGINAL_IFACE"
    echo "Pinned $cidr via $ORIGINAL_GW on $ORIGINAL_IFACE"
  done
}

###############################################################################
# 4) AUTOSSH TUNNELS: DYNAMIC / SPARSE ENV DISCOVERY
###############################################################################
start_autossh_dynamic() {
  export AUTOSSH_GATETIME=0
  export AUTOSSH_LOGLEVEL=1
  export AUTOSSH_LOGFILE="$ALL_LOG"

  SSH_COMMON_OPTS='
    -o BatchMode=yes
    -o ConnectTimeout=20
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o ExitOnForwardFailure=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -q -o LogLevel=ERROR
  '

  found=0
  # 8222-8224 are reserved by dante/sshd/tinyproxy.
  seen_ports=" 8222 8223 8224"

  # Discover complete and partial definitions. Numbering may be sparse:
  # SSH_TUNNEL1_*, SSH_TUNNEL2_*, SSH_TUNNEL999_*, ...
  for idx in $(
    printenv \
      | awk -F= '
          /^SSH_TUNNEL[0-9]+_(NAME|HOST|USER|BIND|OPTS|TEST_HOST|TEST_PORT)=/ {
            name=$1
            sub(/^SSH_TUNNEL/,"",name)
            sub(/_(NAME|HOST|USER|BIND|OPTS|TEST_HOST|TEST_PORT)$/,"",name)
            print name
          }' \
      | sort -n -u
  ); do
    name="$(printenv "SSH_TUNNEL${idx}_NAME" 2>/dev/null || true)"
    host="$(printenv "SSH_TUNNEL${idx}_HOST" 2>/dev/null || true)"
    user="$(printenv "SSH_TUNNEL${idx}_USER" 2>/dev/null || true)"
    bind="$(printenv "SSH_TUNNEL${idx}_BIND" 2>/dev/null || true)"
    opts="$(printenv "SSH_TUNNEL${idx}_OPTS" 2>/dev/null || true)"
    test_host="$(printenv "SSH_TUNNEL${idx}_TEST_HOST" 2>/dev/null || true)"
    test_port_raw="$(printenv "SSH_TUNNEL${idx}_TEST_PORT" 2>/dev/null || true)"

    [ -n "$name" ] || name="SSH_TUNNEL${idx}"

    if [ -z "$host" ] || [ -z "$user" ] || [ -z "$bind" ]; then
      echo "ERROR: $name requires HOST, USER and BIND"
      return 1
    fi

    port="${bind##*:}"
    case "$port" in
      ''|*[!0-9]*)
        echo "ERROR: ${name} BIND has invalid port: $bind"
        return 1
        ;;
    esac

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      echo "ERROR: ${name} BIND port is outside 1..65535: $port"
      return 1
    fi

    case " $seen_ports " in
      *" $port "*)
        echo "ERROR: duplicate AutoSSH local port $port"
        return 1
        ;;
    esac
    seen_ports="$seen_ports $port"

    if [ -z "$test_host" ] && [ -n "$test_port_raw" ]; then
      echo "ERROR: $name has TEST_PORT but no TEST_HOST"
      return 1
    fi

    if [ -n "$test_host" ]; then
      test_port="${test_port_raw:-22}"
      case "$test_port" in
        ''|*[!0-9]*)
          echo "ERROR: $name TEST_PORT must be numeric"
          return 1
          ;;
      esac

      if [ "$test_port" -lt 1 ] || [ "$test_port" -gt 65535 ]; then
        echo "ERROR: $name TEST_PORT must be between 1 and 65535"
        return 1
      fi
    fi

    found=1
    echo "autossh: starting $name -> SOCKS on $bind via ${user}@${host}"

    # Keep the legacy SSH session behavior for SCB compatibility.
    # A/B testing showed that -M 0 -tt -A permits end-to-end SOCKS forwarding
    # on SCBs where the -N variant can create a listener but cannot reach the
    # destination behind the SCB.
    #
    # SSH_TUNNEL<N>_OPTS intentionally undergoes shell word splitting, so keep
    # it to simple SSH tokens such as: -p 2222
    set -f
    autossh -M 0 -tt -A \
      -D "$bind" \
      $SSH_COMMON_OPTS \
      $opts \
      "${user}@${host}" \
      </dev/null >/dev/null &
    autossh_pid=$!
    set +f

    AUTOSSH_PIDS="$AUTOSSH_PIDS $autossh_pid"
  done

  [ "$found" -eq 1 ] || echo "No SSH_TUNNEL<N>_* definitions found. AutoSSH is disabled."
}

###############################################################################
# 5) HEALTH WATCHDOG
###############################################################################
start_health_watchdog() {
  WATCHDOG_START_DELAY="${WATCHDOG_START_DELAY:-60}"
  WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-30}"
  WATCHDOG_FAILURE_LIMIT="${WATCHDOG_FAILURE_LIMIT:-10}"
  WATCHDOG_CHECK_TIMEOUT="${WATCHDOG_CHECK_TIMEOUT:-20}"

  for value in \
    "$WATCHDOG_START_DELAY" \
    "$WATCHDOG_INTERVAL" \
    "$WATCHDOG_FAILURE_LIMIT" \
    "$WATCHDOG_CHECK_TIMEOUT"
  do
    case "$value" in
      ''|*[!0-9]*)
        echo "ERROR: watchdog settings must be non-negative integers"
        return 1
        ;;
    esac
  done

  [ "$WATCHDOG_INTERVAL" -gt 0 ] || {
    echo "ERROR: WATCHDOG_INTERVAL must be greater than zero"
    return 1
  }

  [ "$WATCHDOG_FAILURE_LIMIT" -gt 0 ] || {
    echo "ERROR: WATCHDOG_FAILURE_LIMIT must be greater than zero"
    return 1
  }

  [ "$WATCHDOG_CHECK_TIMEOUT" -gt 0 ] || {
    echo "ERROR: WATCHDOG_CHECK_TIMEOUT must be greater than zero"
    return 1
  }

  (
    failures=0
    sleep "$WATCHDOG_START_DELAY"

    while :; do
      if health_output="$(
        timeout "$WATCHDOG_CHECK_TIMEOUT" /usr/local/bin/healthcheck.sh 2>&1
      )"; then
        if [ "$failures" -gt 0 ]; then
          echo "WATCHDOG: health recovered after ${failures} consecutive failure(s)."
        fi

        failures=0
      else
        failures=$((failures + 1))
        echo "WATCHDOG: healthcheck failure ${failures}/${WATCHDOG_FAILURE_LIMIT}"
        printf '%s\n' "$health_output" | sed 's/^/WATCHDOG:   /'

        if [ "$failures" -ge "$WATCHDOG_FAILURE_LIMIT" ]; then
          echo "WATCHDOG: persistent health failure; terminating container."
          kill -TERM "$MAIN_PID"
          exit 0
        fi
      fi

      sleep "$WATCHDOG_INTERVAL"
    done
  ) &

  WATCHDOG_PID=$!
}

###############################################################################
# 6) OPENCONNECT IS THE CRITICAL PROCESS
###############################################################################
monitor_openconnect() {
  echo "Setup complete. Monitoring OpenConnect PID $OPENCONNECT_PID..."

  monitored_pid="$OPENCONNECT_PID"

  if wait "$monitored_pid"; then
    rc=0
  else
    rc=$?
  fi

  # Child has been reaped. Avoid signalling a potentially reused PID in cleanup.
  OPENCONNECT_PID=""
  rm -f /run/openconnect.pid

  echo "OpenConnect exited with status $rc. Terminating container for clean restart."
  exit "$rc"
}

###############################################################################
# MAIN
###############################################################################
validate_env

set_root_password
ensure_ssh_host_keys
start_ssh_agent
load_private_key
set_authorized_keys

start_sshd

save_original_route
pin_server_cert
start_openconnect
wait_for_openconnect

start_tinyproxy
start_sockd

add_routes
start_autossh_dynamic
start_health_watchdog

monitor_openconnect
