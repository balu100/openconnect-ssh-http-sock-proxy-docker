# VPN-SSH-Proxy Container

A single Alpine-based container that:

- Dials an AnyConnect/ocserv-compatible VPN with **openconnect** and pins server cert.
- Exposes **SOCKS5 (dante)** and **HTTP proxy (tinyproxy)** locally.
- Runs **OpenSSH** for admin access.
- Optionally starts **many** persistent **AutoSSH dynamic SOCKS tunnels** to remote hosts.
- Keeps selected local subnets reachable with per-IP routes.

---

## Contents
- [Architecture](#architecture)
- [Ports](#ports)
- [Environment variables](#environment-variables)
- [Quick start](#quick-start)
- [Usage examples](#usage-examples)
- [Routing exceptions](#routing-exceptions)
- [Logs](#logs)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

---

## Architecture
```
┌────────────────────────── Host ──────────────────────────┐
│                                                          │
│  :8223  SSH    →  container sshd                          │
│  :8224  HTTP   →  tinyproxy                               │
│  :8222  SOCKS5 →  dante (sockd)                           │
│  :8225  SOCKS5 →  AutoSSH dynamic tunnel #1 (optional)    │
│  :8226  SOCKS5 →  AutoSSH dynamic tunnel #2 (optional)    │
│  :8999  SOCKS5 →  AutoSSH dynamic tunnel #999 (optional)  │
│                                                          │
└───────────────┬──────────────────────────────────────────┘
                │
        openconnect → tun0 → VPN/Corporate network
```

---

## Ports
| Host Port | Service | In-container | Notes |
|---:|---|---:|---|
| 8223 | SSH admin | 8223 | Root login enabled. Key or password. |
| 8224 | HTTP proxy (tinyproxy) | 8224 | For apps that require HTTP/HTTPS proxy. |
| 8222 | SOCKS5 proxy (dante) | 8222 | Full SOCKS5. Use `socks5h://` to resolve via proxy. |
| 8225 | SOCKS5 tunnel #1 (AutoSSH) | 8225 | Created with `autossh -D <bind>` to `SSH_TUNNEL1_HOST`. |
| 8226 | SOCKS5 tunnel #2 (AutoSSH) | 8226 | Created with `autossh -D <bind>` to `SSH_TUNNEL2_HOST`. |
| 8999 | SOCKS5 tunnel #999 (AutoSSH) | 8999 | Example showing tunnels can be sparse: `SSH_TUNNEL999_*`. |

> Only map ports for tunnels you actually define.

---

## Environment variables
| Variable | Required | Encoding | Purpose / Example |
|---|:---:|---|---|
| `VPN_SERVER` | ✔ | plain | VPN host (FQDN or IP). Example: `vpn.example.com`. |
| `VPN_USERNAME` | ✔ | plain | VPN username. |
| `VPN_PASSWORD_BASE64` | ✔ | base64 | VPN password, base64-encoded. |
| `VPN_AUTHGROUP` | ☐ | plain | AnyConnect/ocserv auth-group. Empty is allowed. |
| `ROOT_PASSWORD_BASE64` | ✔ | base64 | Root password for sshd. |
| `SSH_PUB_KEY_BASE64` | ☐ | base64 | Public key for `/root/.ssh/authorized_keys`. |
| `SSH_PRIVATEKEY_BASE64` | ☐ | base64 | Private key loaded into ssh-agent for AutoSSH. |
| `SSH_TUNNEL<N>_HOST` | ☐ | plain | Remote SSH host for tunnel **N**. Example: `SSH_TUNNEL1_HOST=tunnel.example.com`. |
| `SSH_TUNNEL<N>_USER` | ☐ | plain | SSH username for tunnel **N**. |
| `SSH_TUNNEL<N>_BIND` | ☐ | plain | Local bind address for SOCKS listener, e.g. `0.0.0.0:8225`. Quote in YAML. |
| `SSH_TUNNEL<N>_OPTS` | ☐ | plain | Optional extra ssh options for tunnel **N** (e.g. `-p 2222`). |
| `KEEP_LOCAL_IP1..N` | ☐ | plain | IPs that must stay local (add routes via default GW). |

**Base64 helpers**
```bash
# Linux
base64 -w0 < file > file.b64
# macOS
base64 < file | tr -d '\n' > file.b64
# Windows
https://tools.ebalazs.com/base64-string-converter
```

---

## Quick start

### 1) docker-compose.yml
```yaml
---
services:
  vpn-ssh-container:
    build: .
    container_name: vpn-ssh-container
    privileged: true
    volumes:
      - ./sockd.conf:/etc/sockd.conf:ro
      - ./tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro
    ports:
      - "8999:8999"   # AutoSSH Tunnel 999 (SOCKS)  ← only if you define it
      - "8226:8226"   # AutoSSH Tunnel 2   (SOCKS)  ← only if you define it
      - "8225:8225"   # AutoSSH Tunnel 1   (SOCKS)  ← only if you define it
      - "8224:8224"   # HTTP proxy (tinyproxy)
      - "8223:8223"   # SSH admin
      - "8222:8222"   # SOCKS5 proxy (dante)
    environment:
      VPN_SERVER: "vpn.example.com"
      VPN_USERNAME: "MyVpnUsername"
      VPN_PASSWORD_BASE64: "Base64Password"
      VPN_AUTHGROUP: "MyVpnAuthgroup"   # optional

      SSH_PRIVATEKEY_BASE64: "Base64PrivateKeyForTunnels"
      ROOT_PASSWORD_BASE64: "Base64RootPassword"
      SSH_PUB_KEY_BASE64: "Base64PublicKeyFor8223"

      # --- Dynamic autossh tunnels (numbered; can be sparse: 1, 2, 999, etc.) ---
      SSH_TUNNEL1_HOST: "tunnel-1.example.com"
      SSH_TUNNEL1_USER: "myuser"
      SSH_TUNNEL1_BIND: "0.0.0.0:8225"

      SSH_TUNNEL2_HOST: "tunnel-2.example.com"
      SSH_TUNNEL2_USER: "myuser"
      SSH_TUNNEL2_BIND: "0.0.0.0:8226"

      # Tunnel 999 (example to show “no practical limit”)
      SSH_TUNNEL999_HOST: "tunnel-999.example.com"
      SSH_TUNNEL999_USER: "myuser"
      SSH_TUNNEL999_BIND: "0.0.0.0:8999"

      KEEP_LOCAL_IP1: "192.168.1.10"
      KEEP_LOCAL_IP2: "192.168.1.11"
      #KEEP_LOCAL_IP3: "192.168.1.12"
      #KEEP_LOCAL_IP999: "192.168.1.13"
    restart: unless-stopped
```

### 2) Proxy configs
**tinyproxy.conf**
```conf
Port 8224
Listen 0.0.0.0
Timeout 600
Allow 0.0.0.0/0
```

**sockd.conf**
```conf
logoutput: stdout
errorlog: stderr

internal: 0.0.0.0 port = 8222
external: tun0

clientmethod: none
socksmethod: none

# Recommended to avoid running “unprivileged” as root:
user.notprivileged: nobody

client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error connect disconnect
}
socks pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error connect disconnect
}
```

### 3) Build and run
```bash
docker compose build
docker compose up -d
```

---

## Usage examples
HTTP proxy through VPN:
```bash
curl -x http://localhost:8224 https://ifconfig.io
```

SOCKS5 proxy through VPN (DNS via proxy):
```bash
curl --socks5-hostname localhost:8222 https://ifconfig.io
```

SOCKS5 via AutoSSH Tunnel 1:
```bash
export ALL_PROXY=socks5h://localhost:8225
curl https://ifconfig.io
```

SSH into container:
```bash
ssh -p 8223 root@localhost    # uses key if provided, else ROOT_PASSWORD_BASE64
```

Using as a Jumphost with X11 Forwarding:

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

---

## Routing exceptions
Add `KEEP_LOCAL_IP{N}` envs to keep specific hosts off the VPN. On start the script runs:
```sh
ip route add "$KEEP_LOCAL_IPN" via <host-default-gw> dev eth0
```
Add as many sequentially numbered variables as needed.

---

## Logs
| File | Service |
|---|---|
| `/var/log/stack.log` | unified log (openconnect/sshd/tinyproxy/sockd/autossh) |

Container exits if a `BYE` disconnect is detected in the log. Background processes are stopped.

---

## Security notes
- **Server cert pinning** is auto-generated at runtime with OpenSSL and fed to openconnect via `--servercert pin-sha256:...`.
- Base64 is **not** encryption. Protect compose files and CI logs.
- Root login is enabled intentionally for admin. Prefer key auth via `SSH_PUB_KEY_BASE64`.
- AutoSSH uses `StrictHostKeyChecking=no` by default in this setup. Consider baking known_hosts or enabling checking for production.

---

## Troubleshooting
**SSH agent has no keys**
- Verify `SSH_PRIVATEKEY_BASE64` is valid, unencrypted, and loads with `ssh-add -l` inside the container.

**sockd binds but no traffic**
- Ensure `external: tun0` is valid and the VPN is up.

**AutoSSH tunnel not reachable**
- Ensure you mapped the port in compose (`ports:`) and set `SSH_TUNNEL<N>_BIND` to that port.

**VPN on non-443 port**
- The pin generator connects to `${VPN_SERVER}:443`. If your portal uses another port, adjust the `openssl s_client -connect` line in `run.sh` accordingly.

**No internet through proxies**
- Verify corporate split-tunnel policies. Try `--socks5-hostname` to force DNS via proxy.

---

## FAQ
**Q: Do I need both HTTP and SOCKS?**  
A: Keep both. Some apps only support HTTP. Others work better with SOCKS5.

**Q: Can I add more than two AutoSSH tunnels?**  
A: Yes. Add more `SSH_TUNNEL<N>_*` environment variables. Numbers can be sparse (e.g., `1`, `2`, `999`).

**Q: Can I avoid `privileged: true`?**  
A: You need TUN access. You can try `cap_add: [NET_ADMIN, SYS_ADMIN]` plus `/dev/net/tun` device mapping, but `privileged` is simplest.

---

## Included files
- `Dockerfile` – Alpine base, installs openconnect, sshd, dante, tinyproxy, autossh; configures sshd on 8223.
- `run.sh` – boots sshd, pins VPN server cert, dials VPN, starts proxies, sets routes, launches AutoSSH, monitors disconnect.
- `sockd.conf` – Dante server bound to 0.0.0.0:8222, egress `tun0`.
- `tinyproxy.conf` – Tinyproxy on 0.0.0.0:
