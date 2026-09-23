#!/bin/sh
# Target: Alpine /bin/sh (BusyBox ash)
set -u

errors=0
tunnels=0
e2e_tests=0
TMPDIR_HC="/tmp/healthcheck.$$"

cleanup() {
    rm -rf "$TMPDIR_HC"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail_now() {
    echo "HEALTHCHECK FAILED: $*" >&2
    exit 1
}

report_error() {
    echo "HEALTHCHECK FAILED: $*" >&2
    errors=$((errors + 1))
}

###############################################################################
# Dependencies
###############################################################################
for cmd in ip ss awk grep printenv sort timeout ncat; do
    command -v "$cmd" >/dev/null 2>&1 ||
        fail_now "'$cmd' command is missing"
done

mkdir -p "$TMPDIR_HC" || fail_now "cannot create temporary healthcheck directory"

###############################################################################
# Helpers
###############################################################################
is_listening_by_process() {
    port="$1"
    process="$2"

    ss -Hlntp 2>/dev/null |
        awk -v port="$port" -v process="$process" '
            {
                port_match = 0

                for (i = 1; i <= NF; i++) {
                    if ($i ~ (":" port "$")) {
                        port_match = 1
                        break
                    }
                }

                if (port_match && index($0, "\"" process "\"") > 0) {
                    found = 1
                    exit
                }
            }
            END {
                exit !found
            }
        '
}

route_device_for() {
    target="$1"

    ip route get "$target" 2>/dev/null |
        awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }'
}

###############################################################################
# Local services
###############################################################################
is_listening_by_process 8222 sockd ||
    fail_now "dante/sockd is not listening on 8222"

is_listening_by_process 8223 sshd ||
    fail_now "sshd is not listening on 8223"

is_listening_by_process 8224 tinyproxy ||
    fail_now "tinyproxy is not listening on 8224"

###############################################################################
# OpenConnect / tun0
###############################################################################
[ -s /run/openconnect.pid ] ||
    fail_now "/run/openconnect.pid is missing"

IFS= read -r openconnect_pid </run/openconnect.pid ||
    fail_now "cannot read OpenConnect PID"

case "$openconnect_pid" in
    ''|*[!0-9]*)
        fail_now "invalid OpenConnect PID '$openconnect_pid'"
        ;;
esac

[ -r "/proc/$openconnect_pid/stat" ] ||
    fail_now "OpenConnect PID $openconnect_pid does not exist"

openconnect_state="$(
    awk '{print $3}' "/proc/$openconnect_pid/stat" 2>/dev/null
)" || fail_now "cannot read OpenConnect process state"

case "$openconnect_state" in
    Z|X|'')
        fail_now "OpenConnect PID $openconnect_pid is not alive (state=$openconnect_state)"
        ;;
esac

[ -r "/proc/$openconnect_pid/comm" ] ||
    fail_now "cannot identify OpenConnect process"

IFS= read -r openconnect_comm <"/proc/$openconnect_pid/comm" ||
    fail_now "cannot read OpenConnect process name"

[ "$openconnect_comm" = "openconnect" ] ||
    fail_now "PID $openconnect_pid is '$openconnect_comm', not openconnect"

ip link show dev tun0 >/dev/null 2>&1 ||
    fail_now "tun0 does not exist"

ip -o -4 addr show dev tun0 2>/dev/null | grep -q 'inet ' ||
    fail_now "tun0 has no IPv4 address"

###############################################################################
# Dynamic AutoSSH tunnels
#
# TEST_HOST is optional. If present, TEST_PORT defaults to 22 and the
# healthcheck verifies an actual TCP connection THROUGH the SOCKS tunnel.
###############################################################################
seen_ports=" 8222 8223 8224"
e2e_pids=""

tunnel_ids="$(
    printenv |
        awk -F= '
            /^SSH_TUNNEL[0-9]+_(NAME|HOST|USER|BIND|OPTS|TEST_HOST|TEST_PORT)=/ {
                name=$1
                sub(/^SSH_TUNNEL/,"",name)
                sub(/_(NAME|HOST|USER|BIND|OPTS|TEST_HOST|TEST_PORT)$/,"",name)
                print name
            }' |
        sort -n -u
)"

for i in $tunnel_ids; do
    name="$(printenv "SSH_TUNNEL${i}_NAME" 2>/dev/null || true)"
    host="$(printenv "SSH_TUNNEL${i}_HOST" 2>/dev/null || true)"
    user="$(printenv "SSH_TUNNEL${i}_USER" 2>/dev/null || true)"
    bind="$(printenv "SSH_TUNNEL${i}_BIND" 2>/dev/null || true)"
    test_host="$(printenv "SSH_TUNNEL${i}_TEST_HOST" 2>/dev/null || true)"
    test_port_raw="$(printenv "SSH_TUNNEL${i}_TEST_PORT" 2>/dev/null || true)"

    [ -n "$name" ] || name="SSH_TUNNEL${i}"

    if [ -z "$host" ] || [ -z "$user" ] || [ -z "$bind" ]; then
        report_error "$name requires HOST, USER and BIND"
        continue
    fi

    port="${bind##*:}"

    case "$port" in
        ''|*[!0-9]*)
            report_error "$name has invalid BIND '$bind'"
            continue
            ;;
    esac

    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        report_error "$name has invalid local port $port"
        continue
    fi

    case " $seen_ports " in
        *" $port "*)
            report_error "multiple SSH tunnels are configured on local port $port"
            continue
            ;;
    esac
    seen_ports="$seen_ports $port"

    tunnels=$((tunnels + 1))
    listener_ok=1

    # A successful dynamic forward is owned by the ssh child, not autossh.
    if ! is_listening_by_process "$port" ssh; then
        report_error "$name SOCKS listener on port $port is not owned by ssh"
        listener_ok=0
    fi

    # Numeric gateway addresses must be routed through the VPN.
    case "$host" in
        *[!0-9.]*)
            ;;
        *)
            dev="$(route_device_for "$host")"
            if [ -z "$dev" ]; then
                report_error "cannot determine route to $name gateway $host"
            elif [ "$dev" != "tun0" ]; then
                report_error "$name gateway $host is routed through $dev instead of tun0"
            fi
            ;;
    esac

    if [ -z "$test_host" ] && [ -n "$test_port_raw" ]; then
        report_error "$name has TEST_PORT but no TEST_HOST"
        continue
    fi

    if [ -n "$test_host" ]; then
        test_port="${test_port_raw:-22}"

        case "$test_port" in
            ''|*[!0-9]*)
                report_error "$name TEST_PORT must be numeric"
                continue
                ;;
        esac

        if [ "$test_port" -lt 1 ] || [ "$test_port" -gt 65535 ]; then
            report_error "$name TEST_PORT must be between 1 and 65535"
            continue
        fi

        e2e_tests=$((e2e_tests + 1))

        # 0.0.0.0 is a listen address, not a connect destination.
        bind_addr="${bind%:*}"
        case "$bind_addr" in
            0.0.0.0|'')
                proxy_addr="127.0.0.1"
                ;;
            127.*)
                proxy_addr="$bind_addr"
                ;;
            *)
                proxy_addr="$bind_addr"
                ;;
        esac

        # Run end-to-end tests in parallel so many tunnels do not multiply
        # healthcheck runtime. Only run it when the SOCKS listener exists.
        if [ "$listener_ok" -eq 1 ]; then
            (
                if timeout 8 ncat \
                    -z \
                    --proxy "${proxy_addr}:${port}" \
                    --proxy-type socks5 \
                    "$test_host" "$test_port" \
                    >/dev/null 2>&1
                then
                    : >"$TMPDIR_HC/e2e.${i}.ok"
                else
                    printf '%s\n' \
                        "$name cannot reach ${test_host}:${test_port} through SOCKS ${proxy_addr}:${port}" \
                        >"$TMPDIR_HC/e2e.${i}.fail"
                fi
            ) &
            e2e_pids="$e2e_pids $!"
        fi
    fi
done

# Wait for all parallel end-to-end checks.
for pid in $e2e_pids; do
    wait "$pid" 2>/dev/null || true
done

# Report every failed end-to-end tunnel in one healthcheck run.
for i in $tunnel_ids; do
    if [ -s "$TMPDIR_HC/e2e.${i}.fail" ]; then
        while IFS= read -r line; do
            report_error "$line"
        done <"$TMPDIR_HC/e2e.${i}.fail"
    fi
done

###############################################################################
# KEEP_LOCAL_IP routing exceptions
###############################################################################
if printenv | grep -Eq '^KEEP_LOCAL_IP[0-9]+='; then
    [ -s /run/original_iface ] ||
        fail_now "/run/original_iface is missing"

    IFS= read -r original_iface </run/original_iface ||
        fail_now "cannot read original interface"

    [ -n "$original_iface" ] ||
        fail_now "original interface is empty"

    for i in $(
        printenv |
            awk -F= '/^KEEP_LOCAL_IP[0-9]+=/{sub(/^KEEP_LOCAL_IP/,"",$1); print $1}' |
            sort -n -u
    ); do
        target="$(printenv "KEEP_LOCAL_IP${i}" 2>/dev/null || true)"
        [ -n "$target" ] || continue

        # ip route get expects a host address, not a CIDR.
        probe="${target%%/*}"

        dev="$(route_device_for "$probe")"
        if [ -z "$dev" ]; then
            report_error "cannot determine route for KEEP_LOCAL_IP$i=$target"
        elif [ "$dev" != "$original_iface" ]; then
            report_error "KEEP_LOCAL_IP$i=$target is routed through $dev instead of $original_iface"
        fi
    done
fi

if [ "$errors" -gt 0 ]; then
    echo "HEALTHCHECK FAILED: $errors problem(s) detected across $tunnels SSH tunnel(s)" >&2
    exit 1
fi

echo "OK: VPN + $tunnels SSH tunnel(s) + $e2e_tests end-to-end test(s) + local services + routing healthy"
exit 0
