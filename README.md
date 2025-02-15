# OpenConnect Proxy SSH Container

## Overview
This project provides a Dockerized environment to connect to an OpenConnect VPN and expose services such as SSH, SOCKS5, and HTTP proxy. The container is configured to handle secure authentication and routing while ensuring reliable VPN connectivity.

## Features
- OpenConnect VPN client for establishing secure connections
- SSH server for secure remote access, X11 forwarding, and as jumphost
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

## Usage

### Retrieving VPN_SERVERCERT and VPN_AUTHGROUP
To get the required VPN_SERVERCERT and VPN_AUTHGROUP, run the following command on a system with OpenConnect installed:
```sh
openconnect --authenticate --user=VPN_USERNAME VPN_SERVER
```
After entering your password, OpenConnect will display authentication groups. Choose the appropriate one, and the server certificate hash (usually in `pin-sha256:XYZ123` format) will be shown in the connection logs.

### Using as a Jumphost with X11 Forwarding
To use this container as a jumphost for SSH connections with X11 forwarding, add the following to your `~/.ssh/config` file:
```sh
Host jumphost
  HostName CONTAINER_IP
  User root
  Port 8223
  IdentityFile /path/to/your/private/key
  ForwardAgent yes
  ForwardX11 yes
  ForwardX11Trusted yes
```
Then, use it to jump to another host with X11 forwarding:
```sh
ssh -X -J jumphost user@destination_host
```

### Standard Usage
- **SSH Access:** Connect to the container with:
  ```sh
  ssh -p 8223 root@CONTAINER_IP -X
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

## License
This project is licensed under the MIT License.

