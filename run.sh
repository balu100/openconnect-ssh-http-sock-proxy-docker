#!/bin/sh

# Set root password
echo "root:$(echo "$ROOT_PASSWORD_BASE64" | base64 -d)" | chpasswd

# 1) Start agent and create a global environment file
AGENT_ENV_FILE="/root/.ssh/agent.env"
ssh-agent -s > "$AGENT_ENV_FILE"
sed -i '/^echo Agent pid/d' "$AGENT_ENV_FILE"
source "$AGENT_ENV_FILE"
trap 'kill $SSH_AGENT_PID >/dev/null 2>&1' EXIT

# 2) Load private key (if provided)
if [ -n "${SSH_PRIVATEKEY_BASE64:-}" ]; then
  umask 177
  KEYFILE="$(mktemp /root/.ssh/key.XXXXXX)"
  echo "$SSH_PRIVATEKEY_BASE64" | base64 -d > "$KEYFILE"
  chmod 600 "$KEYFILE"
  ssh-add "$KEYFILE"
  shred -u "$KEYFILE" || rm -f "$KEYFILE"
fi

# 3) Verify agent has keys
ssh-add -l || true

# Set SSH public key if provided
if [ -n "$SSH_PUB_KEY_BASE64" ]; then
    echo "$SSH_PUB_KEY_BASE64" | base64 -d > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "Public key added to /root/.ssh/authorized_keys"
else
    echo "WARNING: No SSH_PUB_KEY_BASE64 provided. SSH login might fail."
fi

# Define log files
OPENCONNECT_LOG="/var/log/openconnect.log"
SSHD_LOG="/var/log/sshd.log"
SOCKD_LOG="/var/log/sockd.log"
TINYPROXY_LOG="/var/log/tinyproxy.log"

# Start the SSH daemon
/usr/sbin/sshd -D >> "$SSHD_LOG" >&2 &

# Get servercert via hostname
VPN_SERVERCERT=$(
  openssl s_client -connect "$VPN_SERVER:443" -servername "$VPN_SERVER" </dev/null 2>/dev/null \
  | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | openssl base64 -A \
  | awk '{print "pin-sha256:" $0}'
)
[ -n "$VPN_SERVERCERT" ] || { echo "pin generation failed" >&2; exit 2; }
export VPN_SERVERCERT

# Check if necessary environment variables are set
if [ -z "$VPN_SERVER" ] || [ -z "$VPN_USERNAME" ] || [ -z "$VPN_PASSWORD_BASE64" ]; then
    echo "VPN_SERVER, VPN_USERNAME, VPN_PASSWORD_BASE64 and VPN_AUTHGROUP environment variables must be set" >> "$OPENCONNECT_LOG" >&2 
    exit 1
fi

# Start OpenConnect and log output
echo "Starting OpenConnect..."
echo "$(echo "$VPN_PASSWORD_BASE64" | base64 -d)" | openconnect --user="$VPN_USERNAME" --passwd-on-stdin --authgroup="$VPN_AUTHGROUP" --servercert "$VPN_SERVERCERT" "$VPN_SERVER" >> "$OPENCONNECT_LOG" 2>&1 &

# Give the VPN a few seconds to establish the connection and routes
sleep 2

# Start other proxies
/usr/bin/tinyproxy >> "$TINYPROXY_LOG" >&2 &
/usr/sbin/sockd -D >> "$SOCKD_LOG" >&2 &

# Add custom local routes
GW=$(ip route | awk '/default/ {print $3}')
i=1
while [ -n "$(printenv KEEP_LOCAL_IP$i)" ]; do
    ip route add "$(printenv KEEP_LOCAL_IP$i)" via "$GW" dev eth0
    echo "Added route: $(printenv KEEP_LOCAL_IP$i) via $GW"
    i=$((i + 1))
done

# =================================================================
# START AUTOSSH TUNNELS (INSERTED HERE)
# =================================================================
if [ -n "$SSH_TUNNEL_USER" ] && [ -n "$SSH_TUNNEL_HOST_A" ] && [ -n "$SSH_TUNNEL_HOST_B" ]; then
    echo "Starting persistent tunnels for user $SSH_TUNNEL_USER..."

    # Tunnel for Site A (SOCKS Proxy on port 8225)
    echo "--> Starting tunnel to $SSH_TUNNEL_HOST_A on local port 8225"
    autossh -M 0 -f -tt -A \
        -D 0.0.0.0:8225 \
        -o "ServerAliveInterval=60" \
        -o "ServerAliveCountMax=3" \
        -o "ExitOnForwardFailure=yes" \
        -o "StrictHostKeyChecking=no" \
        "$SSH_TUNNEL_USER@$SSH_TUNNEL_HOST_A"

    # Tunnel for Site B (SOCKS Proxy on port 8226)
    echo "--> Starting tunnel to $SSH_TUNNEL_HOST_B on local port 8226"
    autossh -M 0 -f -tt -A \
        -D 0.0.0.0:8226 \
        -o "ServerAliveInterval=60" \
        -o "ServerAliveCountMax=3" \
        -o "ExitOnForwardFailure=yes" \
        -o "StrictHostKeyChecking=no" \
        "$SSH_TUNNEL_USER@$SSH_TUNNEL_HOST_B"
else
    echo "SSH tunnel environment variables not set. Skipping."
fi

# Monitor the OpenConnect log for a BYE packet and exit the container when detected
echo "Setup complete. Monitoring VPN connection for disconnect signals..."
tail -f "$OPENCONNECT_LOG" | while IFS= read -r line; do
    echo "$line"
    if echo "$line" | grep -q "BYE"; then
        echo "BYE packet detected. Exiting container."
        # Optionally terminate background processes
        pkill openconnect
        pkill sshd
        pkill tinyproxy
        pkill sockd
        pkill tail
        pkill autossh
        exit 0
    fi
done
