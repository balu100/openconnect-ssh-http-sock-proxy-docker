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

# Start the SSH daemon
/usr/sbin/sshd -D >> /var/log/openconnect.log &

# Check if necessary environment variables are set
if [ -z "$VPN_SERVER" ] || [ -z "$VPN_USERNAME" ] || [ -z "$VPN_PASSWORD" ] || [ -z "$VPN_SERVERCERT" ]; then
    echo "VPN_SERVER, VPN_USERNAME, VPN_PASSWORD, VPN_AUTHGROUP, and VPN_SERVERCERT environment variables must be set" >> /var/log/openconnect.log >&2 
    exit 1
fi

# Start OpenConnect and log output
echo "Starting OpenConnect..."
echo "$VPN_PASSWORD" | openconnect --user="$VPN_USERNAME" --passwd-on-stdin --authgroup="$VPN_AUTHGROUP" --servercert "$VPN_SERVERCERT" "$VPN_SERVER" >> /var/log/openconnect.log 2>&1 &
sleep 5
/usr/bin/tinyproxy >> /var/log/openconnect.log &
/usr/sbin/sockd -D >> /var/log/openconnect.log &


GW=$(ip route | awk '/default/ {print $3}')
i=1

while [ -n "$(printenv KEEP_LOCAL_IP$i)" ]; do
    ip route add "$(printenv KEEP_LOCAL_IP$i)" via "$GW" dev eth0
    echo "Added route: $(printenv KEEP_LOCAL_IP$i) via $GW"
    i=$((i + 1))
done

# Monitor the OpenConnect log for a BYE packet and exit the container when detected
tail -f /var/log/openconnect.log | while IFS= read -r line; do
    echo "$line"
    if echo "$line" | grep -q "BYE"; then
        echo "BYE packet detected. Exiting container."
        pkill openconnect
        pkill sshd
        pkill tinyproxy
        pkill sockd
        pkill tail
        exit 0
    fi
    if echo "$line" | grep -q "shutting down"; then
        echo "Dante down signal detected. Exiting container."
        pkill openconnect
        pkill sshd
        pkill tinyproxy
        pkill sockd
        pkill tail
        exit 0
    fi
done
