# OpenConnect Proxy SSH Container

## Overview
This project provides a Dockerized environment to connect to an OpenConnect VPN and expose services such as SSH, SOCKS5, and HTTP proxy. The container is configured to handle secure authentication and routing while ensuring reliable VPN connectivity.

## Features
- OpenConnect VPN client for establishing secure connections
- SSH server for secure remote access
- SOCKS5 proxy using Dante
- HTTP proxy using TinyProxy
- Automatic route configuration for local IPs
- Logs for monitoring service status

## Prerequisites
- Docker and Docker Compose installed on the system
- VPN credentials
- Public SSH key for secure authentication (optional)

## Installation
1. Clone the repository:
   ```sh
   git clone https://github.com/yourusername/openconnect-proxy-ssh.git
   cd openconnect-proxy-ssh
   ```
2. Configure environment variables in `docker-compose.yml`:
   ```yaml
   environment:
     VPN_SERVER: "VPN_SERVER_DNS_OR_IP"
     VPN_USERNAME: "VPN_USERNAME"
     VPN_PASSWORD: "VPN_PASSWORD"
     VPN_AUTHGROUP: "VPN_AUTHGROUP" # Optional
     VPN_SERVERCERT: "VPN_SERVERCERT_USUALLY_pin-sha256:XYZ123"
     ROOT_PASSWORD: "ROOT_PASSWORD"
     SSH_PUB_KEY: "YOUR_SSH_PUBLIC_KEY"
     KEEP_LOCAL_IP1: "LOCAL_IP_THAT_WILL_CONNECT_TO_THE_CONTAINER"
     KEEP_LOCAL_IP2: "LOCAL_IP2_THAT_WILL_CONNECT_TO_THE_CONTAINER"
   ```
3. Start the container:
   ```sh
   docker-compose up -d
   ```

## Configuration
### Docker Compose Setup
```yaml
docker-compose.yml:
services:
  openconnect-proxy-ssh:
    build: .
    privileged: true # Required for OpenConnect
    volumes:
      - ./sockd.conf:/etc/sockd.conf:ro
      - ./tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro
    ports:
      - "8224:8224"
      - "8223:8223"
      - "8222:8222"
    environment:
      VPN_SERVER: "VPN_SERVER_DNS_OR_IP"
      VPN_USERNAME: "VPN_USERNAME"
      VPN_PASSWORD: "VPN_PASSWORD"
      VPN_AUTHGROUP: "VPN_AUTHGROUP" # Optional
      VPN_SERVERCERT: "VPN_SERVERCERT_USUALLY_pin-sha256:XYZ123"
      ROOT_PASSWORD: "ROOT_PASSWORD"
      SSH_PUB_KEY: "YOUR_SSH_PUBLIC_KEY"
      KEEP_LOCAL_IP1: "LOCAL_IP_THAT_WILL_CONNECT_TO_THE_CONTAINER"
      KEEP_LOCAL_IP2: "LOCAL_IP2_THAT_WILL_CONNECT_TO_THE_CONTAINER"
    restart: unless-stopped
```

### Dockerfile
```Dockerfile
# Use the official Alpine base image
FROM alpine

# Copy the script to run OpenConnect and SSH
COPY run.sh /run.sh

# Install required packages
RUN apk update && apk add --no-cache \
    openssh openssl openconnect dante-server tinyproxy \
    && mkdir -p /root/.ssh /var/run/sshd /var/run/sockd /var/run/tinyproxy \
    && chmod 700 /root/.ssh \
    && ssh-keygen -A

# Configure SSHD
RUN sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?AllowTcpForwarding .*/AllowTcpForwarding yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?GatewayPorts .*/GatewayPorts yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?Port .*/Port 8223/' /etc/ssh/sshd_config

# Set permissions and entrypoint
RUN chmod +x /run.sh
ENTRYPOINT ["/bin/sh", "/run.sh"]
```

### Run Script
```sh
#!/bin/sh

# Set root password
echo "root:$ROOT_PASSWORD" | chpasswd

# Configure SSH public key
echo "$SSH_PUB_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Start services
/usr/sbin/sshd -D &
echo "$VPN_PASSWORD" | openconnect --user="$VPN_USERNAME" --passwd-on-stdin --authgroup="$VPN_AUTHGROUP" --servercert "$VPN_SERVERCERT" "$VPN_SERVER" &
/usr/bin/tinyproxy &
/usr/sbin/sockd -D &
```

### SOCKS5 Configuration
```conf
sockd.conf:
logoutput: stdout
errorlog: stderr
internal: 0.0.0.0 port = 8222
external: tun0
clientmethod: none
socksmethod: none

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
```

### TinyProxy Configuration
```conf
tinyproxy.conf:
Port 8224
Listen 0.0.0.0
Timeout 600
Allow 0.0.0.0/0
```

## Usage
- **SSH Access:** Connect to the container with:
  ```sh
  ssh -p 8223 root@CONTAINER_IP
  ```
- **SOCKS5 Proxy:** Configure your browser or application to use `socks5://CONTAINER_IP:8222`
- **HTTP Proxy:** Configure HTTP proxy settings with `http://CONTAINER_IP:8224`

## Logs and Debugging
- OpenConnect logs: `/var/log/openconnect.log`
- SSH logs: `/var/log/sshd.log`
- SOCKS5 logs: `/var/log/sockd.log`
- TinyProxy logs: `/var/log/tinyproxy.log`

To view logs:
```sh
docker logs -f openconnect-proxy-ssh
```

## Stop and Remove Container
To stop the container:
```sh
docker-compose down
```

## License
This project is licensed under the MIT License.
