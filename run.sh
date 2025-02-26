#!/bin/sh

# Set root password
echo "root:$ROOT_PASSWORD" | chpasswd

# Set SSH public key if provided
if [ -n "$SSH_PUB_KEY" ]; then
    echo "$SSH_PUB_KEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    echo "Public key added to /root/.ssh/authorized_keys"
else
    echo "WARNING: No SSH_PUB_KEY provided. SSH login might fail."
fi

# Define log files
OPENCONNECT_LOG="/var/log/openconnect.log"
SSHD_LOG="/var/log/sshd.log"
SOCKD_LOG="/var/log/sockd.log"
TINYPROXY_LOG="/var/log/tinyproxy.log"

# Start the SSH daemon
/usr/sbin/sshd -D >> "$SSHD_LOG" >&2 &

# Check if necessary environment variables are set
if [ -z "$VPN_SERVER" ] || [ -z "$VPN_USERNAME" ] || [ -z "$VPN_PASSWORD" ] || [ -z "$VPN_SERVERCERT" ]; then
    echo "VPN_SERVER, VPN_USERNAME, VPN_PASSWORD, VPN_AUTHGROUP, and VPN_SERVERCERT environment variables must be set" >> "$OPENCONNECT_LOG" >&2 
    exit 1
fi

# Start OpenConnect and log output
echo "Starting OpenConnect..."
echo "$VPN_PASSWORD" | openconnect --user="$VPN_USERNAME" --passwd-on-stdin --authgroup="$VPN_AUTHGROUP" --servercert "$VPN_SERVERCERT" "$VPN_SERVER" >> "$OPENCONNECT_LOG" 2>&1 &
sleep 5
/usr/bin/tinyproxy >> "$TINYPROXY_LOG" >&2 &
/usr/sbin/sockd -D >> "$SOCKD_LOG" >&2 &


GW=$(ip route | awk '/default/ {print $3}')
i=1

while [ -n "$(printenv KEEP_LOCAL_IP$i)" ]; do
    ip route add "$(printenv KEEP_LOCAL_IP$i)" via "$GW" dev eth0
    echo "Added route: $(printenv KEEP_LOCAL_IP$i) via $GW"
    i=$((i + 1))
done

# Monitor the OpenConnect log for a BYE packet and exit the container when detected
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
        exit 0
    fi
done
